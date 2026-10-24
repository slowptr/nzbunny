"""Operational regressions for ownership, persistence, budgets, and shutdown."""
import os
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from support import (
    FakeNNTPServer, ManagedProcess, build_nzb, free_port, generate_certs,
    http_get, http_post_file, wait_for_server, yenc_encode,
)

EXE = Path(sys.argv.pop(1)).resolve()


def eventually(condition, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = condition()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("Condition did not become true before its deadline")


class Service:
    def __init__(self, certs, ready=True, **settings):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.downloads = self.root / "downloads"
        self.downloads.mkdir()
        self.db = self.root / "jobs.db"
        self.server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        self.server.start()
        self.port = free_port()
        self.url = f"http://127.0.0.1:{self.port}"
        self.env = dict(os.environ, NNTP_HOST="127.0.0.1", NNTP_PORT=str(self.server.port),
                        NNTP_USER="test", NNTP_PASS="test", NNTP_CA_FILE=certs["ca_crt"],
                        DOWNLOAD_DIR=str(self.downloads), DB_PATH=str(self.db), PORT=str(self.port),
                        NNTP_CONNECTIONS="1", NNTP_TIMEOUT="2s", DOWNLOAD_TIMEOUT="30s",
                        POLL_INTERVAL="1s", CLEANUP_INTERVAL="1s", RETENTION_TTL="10s",
                        HTTP_HEADER_TIMEOUT="30s", HTTP_REQUEST_TIMEOUT="30s", SHUTDOWN_TIMEOUT="3s",
                        MAX_ARTIFACT_BYTES="1048576", MAX_WORK_BYTES="4194304",
                        MAX_STORAGE_BYTES="33554432", MIN_FREE_BYTES="1048576",
                        MAX_UPLOAD_BYTES="65536", MAX_UPLOAD_MEMORY_BYTES="1048576",
                        MAX_ACTIVE_JOBS="32", MAX_CONNECTIONS="16", UPLOADS_PER_MINUTE="100")
        self.env.update(settings)
        self.proc = None
        self.ready = ready

    def __enter__(self):
        try:
            self.start(self.ready)
        except Exception:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def start(self, ready=True):
        self.proc = ManagedProcess([str(EXE)], env=self.env, cwd=self.root)
        wait_for_server(self.url + ("/readyz" if ready else "/healthz"), self.proc)

    def stop(self):
        started = time.monotonic()
        self.proc.terminate()
        self.proc.communicate(timeout=4)
        return time.monotonic() - started

    def __exit__(self, exc_type, exc, traceback):
        try:
            if self.proc and self.proc.poll() is None:
                self.stop()
            if exc_type:
                print(self.proc.logs(), file=sys.stderr)
        finally:
            if self.proc:
                self.proc.communicate(timeout=4)
            self.server.stop()
            self.temp.cleanup()

    def sql(self, query, params=()):
        with sqlite3.connect(self.db, timeout=2) as db:
            return db.execute(query, params).fetchall()

    def article(self, message, name="test.bin", data=b"verified payload"):
        self.server.articles[message] = yenc_encode(name, len(data), 1, 1, 1, len(data), data)
        return [(1, len(data), message)]

    def upload(self, files):
        code, location = http_post_file(self.url + "/", "test.nzb", build_nzb(files))
        assert code == 303, code
        return location.rsplit("/", 1)[-1]

    def status(self, job):
        rows = self.sql("SELECT status FROM jobs WHERE id=?", (job,))
        return rows[0][0] if rows else None

    def completed(self, job):
        eventually(lambda: self.status(job) == "COMPLETE")
        row = self.sql("SELECT artifact_path,download_token FROM jobs WHERE id=?", (job,))[0]
        return self.downloads / row[0], row[1]

    def seed_finalizing(self, job="f" * 32, attempts=0):
        source = self.downloads / ".nzbunny-downloads" / job
        source.mkdir(parents=True)
        (source / "test.bin").write_bytes(b"recoverable publication")
        now = int(time.time())
        self.sql("""INSERT INTO jobs(id,filename,status,download_path,created_at,updated_at,finalize_attempts)
                    VALUES (?, 'test.nzb', 'FINALIZING', ?, ?, ?, ?)""",
                 (job, f".nzbunny-downloads/{job}/test.bin", now, now, attempts))
        return job


class StabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert_dir = tempfile.TemporaryDirectory()
        cls.certs = generate_certs(cls.cert_dir.name)

    @classmethod
    def tearDownClass(cls):
        cls.cert_dir.cleanup()

    def service(self, **settings):
        return Service(self.certs, **settings)

    def test_duplicate_start_preserves_active_job_and_storage(self):
        with self.service(NNTP_TIMEOUT="20s") as app:
            app.server.stall_body.add("active@test")
            app.server.body_delay_seconds = 20
            job = app.upload([app.article("active@test")])
            eventually(lambda: "active@test" in app.server.body_requests)
            work = app.downloads / ".nzbunny-work" / job
            for changes in ({}, {"DB_PATH": str(app.root / "other.db")},
                            {"DOWNLOAD_DIR": str(app.root / "other-downloads")}):
                env = dict(app.env, **changes)
                duplicate = subprocess.run([str(EXE)], env=env, cwd=app.root,
                                           capture_output=True, timeout=3)
                self.assertNotEqual(duplicate.returncode, 0)
                self.assertIn(b"StorageAlreadyInUse", duplicate.stderr)
                self.assertEqual(app.status(job), "PROCESSING")
                self.assertTrue(work.exists())

    def test_download_handoff_recovers_after_database_write_error(self):
        with self.service() as app:
            app.sql("""CREATE TRIGGER reject_finalizing BEFORE UPDATE OF status ON jobs
                        WHEN NEW.status='FINALIZING' BEGIN SELECT RAISE(ABORT, 'injected handoff failure'); END""")
            job = app.upload([app.article("handoff@test")])
            eventually(lambda: "finalizing write will be retried" in app.proc.logs())
            self.assertEqual(http_get(app.url + "/readyz")[0], 503)
            following = app.upload([app.article("following@test")])
            app.sql("DROP TRIGGER reject_finalizing")
            app.completed(job)
            app.completed(following)
            self.assertEqual(http_get(app.url + "/readyz")[0], 200)

    def test_failed_error_write_recovers_without_wedging_queue(self):
        with self.service() as app:
            app.sql("""CREATE TRIGGER reject_failure BEFORE UPDATE OF status ON jobs
                        WHEN NEW.status='FAILED' BEGIN SELECT RAISE(ABORT, 'injected failure write'); END""")
            job = app.upload([[(1, 123, "missing@test")]])
            eventually(lambda: "failure write will be retried" in app.proc.logs())
            following = app.upload([app.article("following@test")])
            app.sql("DROP TRIGGER reject_failure")
            eventually(lambda: app.status(job) == "FAILED")
            app.completed(following)

    def test_publication_failure_cleans_unrecorded_artifact_before_purge(self):
        with self.service(RETENTION_TTL="1s") as app:
            app.sql("""CREATE TRIGGER reject_complete BEFORE UPDATE OF status ON jobs
                        WHEN NEW.status='COMPLETE' BEGIN SELECT RAISE(ABORT, 'injected publication failure'); END""")
            job = app.seed_finalizing(attempts=4)
            artifact = app.downloads / ".nzbunny-artifacts" / f"{job}.bin"
            eventually(artifact.exists)
            eventually(lambda: app.status(job) is None)
            self.assertFalse(artifact.exists())

    def test_expiry_and_finalization_progress_during_stalled_download(self):
        with self.service(RETENTION_TTL="2s", NNTP_TIMEOUT="20s") as app:
            job = app.upload([app.article("finished@test")])
            artifact, token = app.completed(job)
            app.server.stall_body.add("stalled@test")
            app.server.body_delay_seconds = 20
            app.upload([app.article("stalled@test")])
            eventually(lambda: "stalled@test" in app.server.body_requests)
            finalizing = app.seed_finalizing()
            app.completed(finalizing)
            eventually(lambda: not artifact.exists(), timeout=6)
            self.assertEqual(http_get(app.url + f"/d/{token}")[0], 410)

    def test_idle_provider_health_is_refreshed_and_recovers(self):
        with self.service() as app:
            app.server.stall_after_tls = True
            eventually(lambda: http_get(app.url + "/readyz")[0] == 503, timeout=6)
            self.assertEqual(http_get(app.url + "/healthz")[0], 200)
            app.server.stall_after_tls = False
            eventually(lambda: http_get(app.url + "/readyz")[0] == 200, timeout=6)

    def test_degraded_start_serves_existing_artifacts(self):
        with self.service() as app:
            job = app.upload([app.article("persisted@test")])
            _, token = app.completed(job)
            app.stop()
            app.server.stall_after_tls = True
            app.start(ready=False)
            self.assertEqual(http_get(app.url + "/readyz")[0], 503)
            self.assertEqual(http_get(app.url + f"/d/{token}")[1], b"verified payload")

    def test_idle_and_partial_upload_clients_do_not_delay_shutdown(self):
        with self.service() as app:
            idle = socket.create_connection(("127.0.0.1", app.port), timeout=2)
            upload = socket.create_connection(("127.0.0.1", app.port), timeout=2)
            try:
                idle.sendall(b"GET / HTTP/1.1\r\n")
                upload.sendall(b'POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 65536\r\nContent-Type: multipart/form-data; boundary=test\r\n\r\n--test\r\n')
                time.sleep(0.2)
                self.assertLess(app.stop(), 2)
                self.assertEqual(app.proc.returncode, 0)
            finally:
                idle.close()
                upload.close()

    def test_aggregate_preflight_budget_includes_repair_parts(self):
        with self.service(MAX_ARTIFACT_BYTES="16384", MAX_WORK_BYTES="16384") as app:
            files = [app.article(f"repair{i}@test", f"repair{i}.par2", b"P" * 12288) for i in range(3)]
            files.append(app.article("payload@test"))
            job = app.upload(files)
            eventually(lambda: app.status(job) == "FAILED")
            reason = app.sql("SELECT fail_reason FROM jobs WHERE id=?", (job,))[0][0]
            self.assertIn("MAX_WORK_BYTES", reason)
            self.assertFalse((app.downloads / ".nzbunny-work" / job).exists())
            self.assertFalse(app.sql("SELECT 1 FROM jobs WHERE id=? AND download_token IS NOT NULL", (job,)))

    def test_storage_headroom_and_upload_memory_admission(self):
        for settings in ({"MIN_FREE_BYTES": str(2**63)}, {"MAX_STORAGE_BYTES": "1024"},
                         {"MAX_UPLOAD_MEMORY_BYTES": "1024"}):
            with self.subTest(settings=settings), self.service(**settings) as app:
                status, _ = http_post_file(app.url + "/", "test.nzb", b"<nzb/>")
                self.assertEqual(status, 503)
                self.assertEqual(app.sql("SELECT count(*) FROM jobs"), [(0,)])

    def test_restart_recovers_finalization_and_sweeps_unowned_files(self):
        with self.service() as app:
            app.stop()
            job = app.seed_finalizing()
            artifacts = app.downloads / ".nzbunny-artifacts"
            artifacts.mkdir(exist_ok=True)
            orphan = artifacts / ("a" * 32 + ".bin")
            orphan.write_bytes(b"historical orphan")
            app.start()
            app.completed(job)
            eventually(lambda: not orphan.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
