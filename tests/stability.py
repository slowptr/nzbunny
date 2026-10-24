"""Operational regressions for ownership, persistence, budgets, and shutdown."""
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from support import (
    build_nzb, generate_certs, http_get, http_post_file, Service, eventually,
)

EXE = Path(sys.argv.pop(1)).resolve()
FAULTS = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None


class StabilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cert_dir = tempfile.TemporaryDirectory()
        cls.certs = generate_certs(cls.cert_dir.name)

    @classmethod
    def tearDownClass(cls):
        cls.cert_dir.cleanup()

    def service(self, **settings):
        return Service(self.certs, EXE, **settings)

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

    def test_storage_headroom_blocks_admission_and_reports_reason(self):
        with self.service(ready=False, MIN_FREE_BYTES=str(2**63)) as app:
            status, _ = http_post_file(app.url + "/", "test.nzb", b"<nzb/>")
            self.assertEqual(status, 503)
            self.assertEqual(app.sql("SELECT count(*) FROM jobs"), [(0,)])
            eventually(lambda: b"storage_capacity_unavailable" in http_get(app.url + "/readyz")[1])

    def test_invalid_budgets_fail_at_startup(self):
        for settings, reason in (({"MAX_STORAGE_BYTES": "1024"}, b"StorageBudgetTooSmall"),
                                 ({"MAX_UPLOAD_MEMORY_BYTES": "1024"}, b"UploadMemoryBudgetTooSmall"),
                                 ({"MAX_WORK_BYTES": "1024"}, b"WorkBudgetTooSmall")):
            with self.subTest(settings=settings), self.service() as app:
                app.stop()
                failed = subprocess.run([str(EXE)], env=dict(app.env, **settings), cwd=app.root,
                                        capture_output=True, timeout=3)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn(reason, failed.stderr)

    def test_capacity_recovery_preserves_pending_jobs_and_finalizer_attempts(self):
        with self.service(RETENTION_TTL="60s") as app:
            # Existing retained data consumes capacity after configuration has
            # passed validation, just as it can on an operating service.
            artifacts = app.downloads / ".nzbunny-artifacts"
            artifacts.mkdir(exist_ok=True)
            pressure = artifacts / "capacity-fixture"
            pressure.write_bytes(b"P" * (32 * 1024 * 1024))
            job = app.seed_finalizing(attempts=4)
            following = "b" * 32
            now = int(time.time())
            app.sql("INSERT INTO jobs(id,filename,content,status,created_at,updated_at) VALUES (?, 'queued.nzb', ?, 'PENDING', ?, ?)",
                    (following, build_nzb([app.article("capacity@test")]), now, now))
            eventually(lambda: "download admission deferred" in app.proc.logs())
            eventually(lambda: "finalizer admission deferred" in app.proc.logs())
            self.assertEqual(app.status(following), "PENDING")
            self.assertEqual(app.sql("SELECT finalize_attempts,finalize_lease_until FROM jobs WHERE id=?", (job,)), [(4, None)])
            self.assertEqual(http_get(app.url + "/readyz")[0], 503)
            metrics = http_get(app.url + "/metrics")[1].decode()
            self.assertIn('nzbunny_jobs{status="pending"} 1', metrics)
            self.assertIn('nzbunny_jobs{status="finalizing"} 1', metrics)
            self.assertNotIn(job, metrics)
            self.assertNotIn(following, metrics)
            pressure.unlink()
            app.completed(job)
            app.completed(following)
            eventually(lambda: http_get(app.url + "/readyz")[0] == 200)
            self.assertEqual(app.sql("SELECT finalize_attempts FROM jobs WHERE id=?", (job,)), [(5,)])

    def test_finalizer_retains_ownership_while_state_writes_fail(self):
        with self.service(RETENTION_TTL="60s") as app:
            app.sql("""CREATE TRIGGER reject_complete BEFORE UPDATE OF status ON jobs
                        WHEN NEW.status='COMPLETE' BEGIN SELECT RAISE(ABORT, 'injected complete failure'); END""")
            app.sql("""CREATE TRIGGER reject_release BEFORE UPDATE OF finalize_lease_until ON jobs
                        WHEN OLD.status='FINALIZING' AND NEW.finalize_lease_until IS NULL
                        BEGIN SELECT RAISE(ABORT, 'injected release failure'); END""")
            job = app.seed_finalizing()
            eventually(lambda: "finalizer state write will be retried" in app.proc.logs())
            self.assertEqual(http_get(app.url + "/readyz")[0], 503)
            self.assertEqual(http_get(app.url + "/readyz")[1], b"finalizer_state_write_failed")
            self.assertEqual(app.sql("SELECT finalize_attempts FROM jobs WHERE id=?", (job,)), [(1,)])
            app.sql("DROP TRIGGER reject_release")
            app.sql("DROP TRIGGER reject_complete")
            app.completed(job)
            eventually(lambda: http_get(app.url + "/readyz")[0] == 200)

    def test_unsupported_schema_start_does_not_mutate_database(self):
        with self.service() as app:
            app.stop()
            app.sql("UPDATE nzbunny_schema SET version=999")
            app.sql("DROP INDEX jobs_expiry_idx")
            before = app.db.read_bytes()
            failed = subprocess.run([str(EXE)], env=app.env, cwd=app.root, capture_output=True, timeout=3)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn(b"UnsupportedSchemaVersion", failed.stderr)
            self.assertEqual(app.db.read_bytes(), before)
            self.assertEqual(app.sql("SELECT name FROM sqlite_master WHERE name='jobs_expiry_idx'"), [])

    @unittest.skipUnless(FAULTS, "pass the test-only fault library to enable syscall injection")
    def test_failed_directory_sync_retries_without_leaking_handles_or_losing_nzb(self):
        for mode in ("space", "io"):
            with self.subTest(mode=mode), self.service(RETENTION_TTL="60s") as app:
                app.stop()
                fault = app.root / "fault"
                fault.write_text(mode + "\n.nzbunny-downloads/.tmp-\n")
                app.env.update(LD_PRELOAD=str(FAULTS), NZBUNNY_TEST_FAULT_FILE=str(fault))
                app.start()
                baseline = len(list(Path(f"/proc/{app.proc.pid}/fd").iterdir()))
                job = app.upload([app.article(f"{mode}@test")])
                eventually(lambda: app.proc.logs().count("download deferred after infrastructure failure") >= 5)
                eventually(lambda: app.status(job) == "PENDING")
                self.assertIsNotNone(app.sql("SELECT content FROM jobs WHERE id=?", (job,))[0][0])
                self.assertLessEqual(len(list(Path(f"/proc/{app.proc.pid}/fd").iterdir())), baseline + 2)
                fault.unlink()
                artifact, token = app.completed(job)
                self.assertEqual(http_get(app.url + f"/d/{token}")[1], b"verified payload")
                self.assertEqual(artifact.read_bytes(), b"verified payload")
                self.assertEqual(app.sql("PRAGMA integrity_check"), [("ok",)])

    @unittest.skipUnless(FAULTS, "pass the test-only fault library to enable syscall injection")
    def test_finalizer_sync_errors_refund_attempt_and_recover(self):
        with self.service(RETENTION_TTL="60s") as app:
            app.stop()
            fault = app.root / "fault"
            fault.write_text("space\n.nzbunny-artifacts\n")
            app.env.update(LD_PRELOAD=str(FAULTS), NZBUNNY_TEST_FAULT_FILE=str(fault))
            app.start()
            job = app.seed_finalizing(attempts=4)
            eventually(lambda: "finalization deferred" in app.proc.logs())
            eventually(lambda: app.sql("SELECT finalize_attempts,finalize_lease_until FROM jobs WHERE id=?", (job,)) == [(4, None)])
            self.assertEqual(app.status(job), "FINALIZING")
            fault.unlink()
            artifact, token = app.completed(job)
            self.assertEqual(artifact.read_bytes(), b"recoverable publication")
            self.assertEqual(http_get(app.url + f"/d/{token}")[1], b"recoverable publication")

    @unittest.skipUnless(FAULTS, "pass the test-only fault library to enable syscall injection")
    def test_repeated_kill_after_artifact_rename_recovers_verified_output(self):
        with self.service(RETENTION_TTL="60s") as app:
            app.stop()
            job = app.seed_finalizing()
            fault = app.root / "fault"
            app.env.update(LD_PRELOAD=str(FAULTS), NZBUNNY_TEST_FAULT_FILE=str(fault))
            artifact = app.downloads / ".nzbunny-artifacts" / f"{job}.bin"
            for _ in range(3):
                fault.write_text("kill\n.nzbunny-artifacts\n")
                app.launch()
                eventually(lambda: app.proc.poll() is not None)
                self.assertEqual(app.proc.returncode, -signal.SIGKILL)
                app.proc.communicate()
                self.assertEqual(app.status(job), "FINALIZING")
                self.assertTrue(artifact.exists())
                self.assertEqual(artifact.read_bytes(), b"recoverable publication")
                self.assertEqual(app.sql("PRAGMA integrity_check"), [("ok",)])
            app.start()
            _, token = app.completed(job)
            self.assertEqual(http_get(app.url + f"/d/{token}")[1], b"recoverable publication")
            self.assertEqual(app.sql("SELECT finalize_attempts FROM jobs WHERE id=?", (job,)), [(1,)])
            self.assertEqual(list((app.downloads / ".nzbunny-artifacts").glob("*.tmp")), [])

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
