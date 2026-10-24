import os
import re
import sys
import time
import sqlite3
import zipfile
import tempfile
import urllib.request
import subprocess
from pathlib import Path
from support import (
    FakeNNTPServer, ManagedProcess, build_nzb, free_port, generate_certs,
    http_get, http_post_file, test_residual_references, wait_for_server, yenc_encode,
)

def main():
    executable = Path(sys.argv[1]).resolve()
    port = free_port()
    base_url = f"http://127.0.0.1:{port}"
    assert executable.exists(), executable
    root = Path(__file__).resolve().parents[1]

    print("[1/16] Testing residual SABnzbd references...")
    test_residual_references(root)

    with tempfile.TemporaryDirectory() as temp_dir:
        print("[2/16] Generating test TLS certificates...")
        certs = generate_certs(temp_dir)

        print("[3/16] Starting fake NNTP server...")
        server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        server.start()
        time.sleep(0.2)

        direct_data = b"Hello Antigravity direct file payload! 1234567890"
        msgid1 = "part1@nzbunny.test"
        yenc1 = yenc_encode("test_direct.bin", len(direct_data), 1, 1, 1, len(direct_data), direct_data)
        server.articles[msgid1] = yenc1

        download_dir = os.path.join(temp_dir, "downloads")
        db_path = os.path.join(temp_dir, "nzbunny.db")
        os.makedirs(download_dir, exist_ok=True)

        env = os.environ.copy()
        env.update({
            "NNTP_HOST": "127.0.0.1",
            "NNTP_PORT": str(server.port),
            "NNTP_USER": "testuser",
            "NNTP_PASS": "testpass",
            "NNTP_CA_FILE": certs["ca_crt"],
            "DOWNLOAD_DIR": download_dir,
            "DB_PATH": db_path,
            "PORT": str(port),
            "NNTP_CONNECTIONS": "4",
            "POLL_INTERVAL": "1s",
        })

        print("[4/16] Testing single direct file E2E download...")
        proc = ManagedProcess([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", proc)
            code, body, _ = http_get(base_url + "/readyz")
            assert code == 200, (code, body)

            nzb1 = build_nzb([[(1, len(direct_data), msgid1)]])
            code, loc = http_post_file(base_url + "/", "sample.nzb", nzb1)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]

            token = None
            for _ in range(30):
                code, html, _ = http_get(f"{base_url}/job/{job_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m, html_str
                    token = m.group(1)
                    break
                time.sleep(0.2)
            if not token:
                conn = sqlite3.connect(db_path)
                try:
                    state = conn.execute(
                        "SELECT status, fail_reason FROM jobs WHERE id=?", (job_id,)
                    ).fetchone()
                finally:
                    conn.close()
                raise AssertionError(f"Job did not reach COMPLETE: {state}")

            head_req = urllib.request.Request(f"{base_url}/d/{token}", method="HEAD")
            with urllib.request.urlopen(head_req, timeout=5) as head_resp:
                assert head_resp.status == 200
                assert head_resp.read() == b""
                assert int(head_resp.headers.get("content-length")) == len(direct_data)
                assert head_resp.headers.get("referrer-policy") == "no-referrer"
                assert head_resp.headers.get("x-content-type-options") == "nosniff"

            code, content, headers = http_get(f"{base_url}/d/{token}")
            assert code == 200
            assert content == direct_data
            assert 'attachment; filename="test_direct.bin"' in headers.get("content-disposition")
            assert headers.get("referrer-policy") == "no-referrer"
        finally:
            proc.terminate()
            stdout, stderr = proc.communicate()

        log_output = (stdout or "") + (stderr or "")
        print("[5/16] Auditing logs for credential/payload leaks...")
        assert "testpass" not in log_output
        assert "Antigravity" not in log_output
        assert ".nzbunny-work" not in log_output

        print("[6/16] Testing multi-file ZIP download & concurrency...")
        server.articles.clear()
        f1_data = b"File 1 content data"
        f2_p1_data = b"File 2 part 1 data "
        f2_p2_data = b"File 2 part 2 data "
        f2_p3_data = b"File 2 part 3 data"
        f2_total_size = len(f2_p1_data) + len(f2_p2_data) + len(f2_p3_data)

        msg_f1 = "f1@nzbunny.test"
        msg_f2_1 = "f2_1@nzbunny.test"
        msg_f2_2 = "f2_2@nzbunny.test"
        msg_f2_3 = "f2_3@nzbunny.test"

        server.articles[msg_f1] = yenc_encode("file1.txt", len(f1_data), 1, 1, 1, len(f1_data), f1_data)
        server.articles[msg_f2_1] = yenc_encode("file2.txt", f2_total_size, 1, 3, 1, len(f2_p1_data), f2_p1_data)
        server.articles[msg_f2_2] = yenc_encode("file2.txt", f2_total_size, 2, 3, len(f2_p1_data) + 1, len(f2_p1_data) + len(f2_p2_data), f2_p2_data)
        server.articles[msg_f2_3] = yenc_encode("file2.txt", f2_total_size, 3, 3, len(f2_p1_data) + len(f2_p2_data) + 1, f2_total_size, f2_p3_data)
        server.fragment_sends = True
        server.body_delay_seconds = 0.3  # hold connections open long enough for concurrency

        proc = ManagedProcess([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", proc)
            nzb_multi = build_nzb([
                [(1, len(f1_data), msg_f1)],
                [
                    (1, len(f2_p1_data), msg_f2_1),
                    (2, len(f2_p2_data), msg_f2_2),
                    (3, len(f2_p3_data), msg_f2_3),
                ]
            ])
            code, loc = http_post_file(base_url + "/", "multi.nzb", nzb_multi)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]

            token = None
            for _ in range(50):
                code, html, _ = http_get(f"{base_url}/job/{job_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m
                    token = m.group(1)
                    break
                time.sleep(0.2)
            assert token, "Multi-file job did not reach COMPLETE"

            code, zip_bytes, headers = http_get(f"{base_url}/d/{token}")
            assert code == 200
            assert "application/zip" in headers.get("content-type")
            assert 'attachment; filename="multi.zip"' in headers.get("content-disposition")

            zip_path = os.path.join(temp_dir, "art.zip")
            with open(zip_path, "wb") as f:
                f.write(zip_bytes)
            with zipfile.ZipFile(zip_path, "r") as zf:
                names = zf.namelist()
                assert "file1.txt" in names
                assert "file2.txt" in names
                assert zf.read("file1.txt") == f1_data
                assert zf.read("file2.txt") == f2_p1_data + f2_p2_data + f2_p3_data

            assert server.peak_conns > 1, f"Expected concurrency > 1, got {server.peak_conns}"
            assert server.peak_conns <= 4, f"Expected concurrency <= 4, got {server.peak_conns}"

            repair_data = b"PAR2 repair metadata"
            comic_data = b"CBR payload bytes"
            repair_msg = "repair@nzbunny.test"
            repair_msg2 = "repair_seg2@nzbunny.test"
            comic_msg = "comic@nzbunny.test"
            server.articles.clear()
            with server.lock:
                server.body_requests.clear()
            server.articles[repair_msg] = yenc_encode("comic.vol00+01.par2", len(repair_data) * 2, 1, 2, 1, len(repair_data), repair_data)
            server.articles[repair_msg2] = yenc_encode("comic.vol00+01.par2", len(repair_data) * 2, 2, 2, len(repair_data) + 1, len(repair_data) * 2, repair_data)
            server.articles[comic_msg] = yenc_encode("comic.cbr", len(comic_data), 1, 1, 1, len(comic_data), comic_data)
            mixed_nzb = build_nzb([
                [(1, len(repair_data) + 200, repair_msg), (2, len(repair_data) + 200, repair_msg2)],
                [(1, len(comic_data) + 200, comic_msg)],
            ])
            code, loc = http_post_file(base_url + "/", "mixed.nzb", mixed_nzb)
            assert code == 303, (code, loc)
            mixed_id = loc.split("/")[-1]
            mixed_token = None
            for _ in range(50):
                _, html, _ = http_get(f"{base_url}/job/{mixed_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    match = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert match, html_str
                    mixed_token = match.group(1)
                    break
                time.sleep(0.2)
            assert mixed_token, "NZB with PAR2 repair files did not complete"
            with server.lock:
                assert repair_msg2 not in server.body_requests, "Undamaged download should not fetch PAR2 segment 2+"
            code, mixed_content, _ = http_get(f"{base_url}/d/{mixed_token}")
            assert code == 200
            assert mixed_content == comic_data

            repairable_data = bytes(range(256)) * 1024
            server.fragment_sends = False
            server.body_delay_seconds = 0
            repairable_path = os.path.join(temp_dir, "repairable.bin")
            repair_set_path = os.path.join(temp_dir, "repairable.par2")
            with open(repairable_path, "wb") as f:
                f.write(repairable_data)
            subprocess.run(
                ["/usr/bin/par2", "create", "-q", "-b8", "-r100", "-n1", repair_set_path, repairable_path],
                check=True,
                timeout=30,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            split_at = len(repairable_data) // 2
            data_first = repairable_data[:split_at]
            data_second = repairable_data[split_at:]
            first_msg = "repairable-1@nzbunny.test"
            missing_msg = "repairable-2@nzbunny.test"
            server.articles.clear()
            server.missing_articles.add(missing_msg)
            server.articles[first_msg] = yenc_encode(
                "repairable.bin", len(repairable_data), 1, 2, 1, split_at, data_first
            )
            repair_nzb_files = [[
                (1, len(data_first) + 200, first_msg),
                (2, len(data_second) + 200, missing_msg),
            ]]
            for index, par_path in enumerate(sorted(Path(temp_dir).glob("repairable*.par2"))):
                par_data = par_path.read_bytes()
                message_id = f"repair-{index}@nzbunny.test"
                server.articles[message_id] = yenc_encode(
                    par_path.name, len(par_data), 1, 1, 1, len(par_data), par_data
                )
                repair_nzb_files.append([(1, len(par_data) + 200, message_id)])
            repair_nzb = build_nzb(repair_nzb_files)
            code, loc = http_post_file(base_url + "/", "repair.nzb", repair_nzb)
            assert code == 303, (code, loc)
            repair_id = loc.split("/")[-1]
            repair_token = None
            for _ in range(100):
                _, html, _ = http_get(f"{base_url}/job/{repair_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    match = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert match, html_str
                    repair_token = match.group(1)
                    break
                time.sleep(0.2)
            assert repair_token, "PAR2 recovery job did not complete"
            code, repaired_content, _ = http_get(f"{base_url}/d/{repair_token}")
            assert code == 200
            assert repaired_content == repairable_data
            assert not os.path.exists(os.path.join(download_dir, ".nzbunny-downloads", repair_id)), "Staging download dir should be removed after finalization"
            assert not os.path.exists(os.path.join(download_dir, ".nzbunny-work", repair_id)), "Staging work dir should be removed after finalization"
            server.missing_articles.remove(missing_msg)

            # Also verify PAR2 recovery when segment 1 (index 0) of the payload file is missing
            second_msg = "repairable-seg2-ok@nzbunny.test"
            server.missing_articles.add(first_msg)
            server.articles[second_msg] = yenc_encode(
                "repairable.bin", len(repairable_data), 2, 2, split_at + 1, len(repairable_data), data_second
            )
            seg0_repair_files = [[
                (1, len(data_first) + 200, first_msg),
                (2, len(data_second) + 200, second_msg),
            ]] + repair_nzb_files[1:]
            seg0_repair_nzb = build_nzb(seg0_repair_files)
            code, loc = http_post_file(base_url + "/", "repair_seg0.nzb", seg0_repair_nzb)
            assert code == 303, (code, loc)
            seg0_repair_id = loc.split("/")[-1]
            seg0_repair_token = None
            for _ in range(100):
                _, html, _ = http_get(f"{base_url}/job/{seg0_repair_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    match = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert match, html_str
                    seg0_repair_token = match.group(1)
                    break
                time.sleep(0.2)
            assert seg0_repair_token, "PAR2 recovery job for missing segment 1 did not complete"
            code, seg0_repaired_content, _ = http_get(f"{base_url}/d/{seg0_repair_token}")
            assert code == 200
            assert seg0_repaired_content == repairable_data
            server.missing_articles.remove(first_msg)

            # Verify a completely missing payload file in a multi-file PAR2 set fails instead of being silently omitted
            totally_missing_msg = "totally-missing-payload@nzbunny.test"
            server.missing_articles.add(totally_missing_msg)
            omission_nzb_files = [
                [(1, len(data_first) + 200, first_msg), (2, len(data_second) + 200, second_msg)],
                [(1, 500, totally_missing_msg)],
            ] + repair_nzb_files[1:]
            omission_nzb = build_nzb(omission_nzb_files)
            code, loc = http_post_file(base_url + "/", "omission.nzb", omission_nzb)
            assert code == 303, (code, loc)
            omission_id = loc.split("/")[-1]
            omission_failed = False
            for _ in range(50):
                _, html, _ = http_get(f"{base_url}/job/{omission_id}")
                html_str = html.decode("utf-8")
                assert "COMPLETE" not in html_str, "Job with completely missing payload file must not complete with omitted file"
                if "FAILED" in html_str:
                    omission_failed = True
                    break
                time.sleep(0.2)
            assert omission_failed, "Job with completely missing payload file did not fail"
            server.missing_articles.remove(totally_missing_msg)
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()

        print("[7/16] Testing malformed zero-size yEnc cleanup...")
        server.articles.clear()
        zero_msgid = "zero@nzbunny.test"
        server.articles[zero_msgid] = b"=ybegin line=128 size=0 name=zero.bin\r\n=yend size=0 crc32=00000000\r\n"
        proc = ManagedProcess([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", proc)
            nzb_zero = build_nzb([[(1, 1, zero_msgid)]])
            code, loc = http_post_file(base_url + "/", "zero.nzb", nzb_zero)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]

            for _ in range(30):
                assert proc.poll() is None, "Process aborted on zero-size yEnc"
                _, html, _ = http_get(f"{base_url}/job/{job_id}")
                if "FAILED" in html.decode("utf-8"):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("Zero-size yEnc job did not fail")

            assert not os.path.exists(os.path.join(download_dir, ".nzbunny-work", job_id))
            assert not os.path.exists(os.path.join(download_dir, ".nzbunny-downloads", job_id))
        finally:
            proc.terminate()
            proc.communicate()

        print("[8/16] Testing all-or-nothing failure & cleanup...")
        server.articles.clear()
        server.missing_articles.add("missing@nzbunny.test")
        proc = ManagedProcess([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", proc)
            nzb_fail = build_nzb([[(1, 10, "missing@nzbunny.test")]])
            code, loc = http_post_file(base_url + "/", "fail.nzb", nzb_fail)
            assert code == 303
            job_id = loc.split("/")[-1]

            failed = False
            for _ in range(30):
                code, html, _ = http_get(f"{base_url}/job/{job_id}")
                if "FAILED" in html.decode("utf-8"):
                    failed = True
                    break
                time.sleep(0.2)
            assert failed

            work_dir = os.path.join(download_dir, ".nzbunny-work", job_id)
            out_dir = os.path.join(download_dir, ".nzbunny-downloads", job_id)
            assert not os.path.exists(work_dir)
            assert not os.path.exists(out_dir)
        finally:
            proc.terminate()
            proc.communicate()

        print("[9/16] Testing stall after TLS handshake, before greeting (P0-1)...")
        stall_server = FakeNNTPServer(certs, greeting_code=200, two_step_auth=True)
        stall_server.stall_after_tls = True
        stall_server.start()
        time.sleep(0.2)
        stall_dl = os.path.join(temp_dir, "stall_downloads")
        os.makedirs(stall_dl, exist_ok=True)
        stall_env = env.copy()
        stall_env["NNTP_PORT"] = str(stall_server.port)
        stall_env["NNTP_TIMEOUT"] = "2s"
        stall_env["DOWNLOAD_TIMEOUT"] = "1h"
        stall_env["DOWNLOAD_DIR"] = stall_dl
        stall_env["DB_PATH"] = os.path.join(temp_dir, "stall.db")
        stall_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=stall_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/healthz", proc)
            time.sleep(2.5)
            assert proc.poll() is None, "Provider outage must leave HTTP available"
            assert http_get(base_url + "/readyz")[0] == 503
            assert not any(os.scandir(stall_dl)), "No work/output files should remain"
            proc.terminate()
            proc.wait(timeout=3)
        finally:
            proc.kill()
            proc.communicate()
            stall_server.stop()

        print("[10/16] Testing transient 400 then 222 recovery (P1-1)...")
        t_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        t_server.start()
        time.sleep(0.2)
        t_data = b"Transient recovery payload data"
        t_msgid = "trecov@nzbunny.test"
        t_server.articles[t_msgid] = yenc_encode("trecov.bin", len(t_data), 1, 1, 1, len(t_data), t_data)
        t_server.transient_errors.add(t_msgid)
        t_server.no_group_once.add(t_msgid)
        t_server.close_body_once.add(t_msgid)
        t_dl = os.path.join(temp_dir, "t_downloads")
        os.makedirs(t_dl, exist_ok=True)
        t_env = env.copy()
        t_env["NNTP_PORT"] = str(t_server.port)
        t_env["NNTP_TIMEOUT"] = "5s"
        t_env["DOWNLOAD_DIR"] = t_dl
        t_env["DB_PATH"] = os.path.join(temp_dir, "t.db")
        t_env["NNTP_CONNECTIONS"] = "1"
        t_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=t_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_t = build_nzb([[(1, len(t_data), t_msgid)]])
            code, loc = http_post_file(base_url + "/", "t.nzb", nzb_t)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]
            token = None
            for _ in range(60):
                _, html, _ = http_get(f"{base_url}/job/{job_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m, html_str
                    token = m.group(1)
                    break
                time.sleep(0.3)
            assert token, "Transient 400 job did not recover and complete"
            _, content, _ = http_get(f"{base_url}/d/{token}")
            assert content == t_data
            assert len(t_server.body_requests) >= 3, t_server.body_requests
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()
            t_server.stop()

        print("[11/16] Testing repeated 400 to exhaustion and readiness (P1-1)...")
        ex_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        ex_server.start()
        time.sleep(0.2)
        ex_data = b"Exhaustion test data"
        ex_bad_msgid = "exhaust@nzbunny.test"
        ex_good_msgid = "exgood@nzbunny.test"
        ex_server.persistent_transient.add(ex_bad_msgid)
        ex_server.articles[ex_good_msgid] = yenc_encode("exgood.bin", len(ex_data), 1, 1, 1, len(ex_data), ex_data)
        ex_dl = os.path.join(temp_dir, "ex_downloads")
        os.makedirs(ex_dl, exist_ok=True)
        ex_env = env.copy()
        ex_env["NNTP_PORT"] = str(ex_server.port)
        ex_env["NNTP_TIMEOUT"] = "5s"
        ex_env["DOWNLOAD_DIR"] = ex_dl
        ex_env["DB_PATH"] = os.path.join(temp_dir, "ex.db")
        ex_env["NNTP_CONNECTIONS"] = "1"
        ex_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=ex_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_bad = build_nzb([[(1, len(ex_data), ex_bad_msgid)]])
            code, loc = http_post_file(base_url + "/", "bad.nzb", nzb_bad)
            assert code == 303
            bad_job = loc.split("/")[-1]
            for _ in range(60):
                _, html, _ = http_get(f"{base_url}/job/{bad_job}")
                if "FAILED" in html.decode("utf-8"):
                    break
                time.sleep(0.3)
            else:
                raise AssertionError("400-exhaustion job did not fail")
            code, _, _ = http_get(base_url + "/readyz")
            assert code == 503, f"readyz should be 503 after provider failure, got {code}"
            ex_server.persistent_transient.discard(ex_bad_msgid)
            code = None
            for _ in range(30):
                code, _, _ = http_get(base_url + "/readyz")
                if code == 200:
                    break
                time.sleep(0.5)
            assert code == 200, "readyz should restore to 200 after DATE probe"
            nzb_good = build_nzb([[(1, len(ex_data), ex_good_msgid)]])
            code, loc = http_post_file(base_url + "/", "good.nzb", nzb_good)
            assert code == 303
            good_job = loc.split("/")[-1]
            token = None
            for _ in range(30):
                _, html, _ = http_get(f"{base_url}/job/{good_job}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m, html_str
                    token = m.group(1)
                    break
                time.sleep(0.3)
            assert token, "Good job did not complete after readiness restored (FIFO resume)"
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()
            ex_server.stop()

        print("[12/16] Testing 430 missing article, no readiness loss (P1-1)...")
        m_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        m_server.start()
        time.sleep(0.2)
        m_server.missing_articles.add("miss430@nzbunny.test")
        m_dl = os.path.join(temp_dir, "m_downloads")
        os.makedirs(m_dl, exist_ok=True)
        m_env = env.copy()
        m_env["NNTP_PORT"] = str(m_server.port)
        m_env["NNTP_TIMEOUT"] = "5s"
        m_env["DOWNLOAD_DIR"] = m_dl
        m_env["DB_PATH"] = os.path.join(temp_dir, "m.db")
        m_env["NNTP_CONNECTIONS"] = "1"
        m_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=m_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_miss = build_nzb([[(1, 10, "miss430@nzbunny.test")]])
            code, loc = http_post_file(base_url + "/", "miss.nzb", nzb_miss)
            assert code == 303
            job_id = loc.split("/")[-1]
            for _ in range(30):
                _, html, _ = http_get(f"{base_url}/job/{job_id}")
                if "FAILED" in html.decode("utf-8"):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("430 job did not fail")
            code, _, _ = http_get(base_url + "/readyz")
            assert code == 200, f"readyz should stay 200 after 430 (no readiness loss), got {code}"
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()
            m_server.stop()

        print("[13/16] Testing SIGTERM clean shutdown during stalled download (P0-7)...")
        sig_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        sig_server.start()
        time.sleep(0.2)
        sig_data = b"SIGTERM test payload data"
        sig_msgid = "sigterm@nzbunny.test"
        sig_server.articles[sig_msgid] = yenc_encode("sigterm.bin", len(sig_data), 1, 1, 1, len(sig_data), sig_data)
        sig_server.body_delay_seconds = 30
        sig_server.stall_body.add(sig_msgid)
        sig_dl = os.path.join(temp_dir, "sig_downloads")
        os.makedirs(sig_dl, exist_ok=True)
        sig_env = env.copy()
        sig_env["NNTP_PORT"] = str(sig_server.port)
        sig_env["NNTP_TIMEOUT"] = "10s"
        sig_env["DOWNLOAD_DIR"] = sig_dl
        sig_env["DB_PATH"] = os.path.join(temp_dir, "sig.db")
        sig_env["NNTP_CONNECTIONS"] = "1"
        sig_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=sig_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_sig = build_nzb([[(1, len(sig_data), sig_msgid)]])
            code, loc = http_post_file(base_url + "/", "sig.nzb", nzb_sig)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]
            time.sleep(1.0)
            assert proc.poll() is None, "Process should still be running"
            proc.terminate()
            start = time.monotonic()
            proc.wait(timeout=5)
            elapsed = time.monotonic() - start
            assert elapsed < 2, f"Process took {elapsed:.1f}s to exit after SIGTERM, should be < 2s"
            conn = sqlite3.connect(os.path.join(temp_dir, "sig.db"))
            cur = conn.execute("SELECT status, fail_reason FROM jobs WHERE id=?", (job_id,))
            row = cur.fetchone()
            conn.close()
            assert row is not None, "Job should exist in DB"
            assert row[0] == "FAILED", f"Job should be FAILED after SIGTERM, got {row[0]}"
            assert "interrupted" in (row[1] or "").lower() or "unavailable" in (row[1] or "").lower(), f"Fail reason should mention interruption: {row[1]}"
            assert not os.path.exists(os.path.join(sig_dl, ".nzbunny-work", job_id)), "Work dir should be cleaned"
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.kill()
            proc.communicate()
            sig_server.stop()

        print("[14/16] Testing first-part preflight barrier (P0-4)...")
        pf_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        pf_server.start()
        time.sleep(0.2)
        pf_f0_s0_data = b"Preflight file 0 segment 0"
        pf_f0_s1_data = b"Preflight file 0 segment 1"
        pf_f0_total = len(pf_f0_s0_data) + len(pf_f0_s1_data)
        pf_f1_data = b"Preflight file 1 segment 0"
        pf_server.articles["pf_f0_s0@nzbunny.test"] = yenc_encode("pf_file0.txt", pf_f0_total, 1, 2, 1, len(pf_f0_s0_data), pf_f0_s0_data)
        pf_server.articles["pf_f0_s1@nzbunny.test"] = yenc_encode("pf_file0.txt", pf_f0_total, 2, 2, len(pf_f0_s0_data) + 1, pf_f0_total, pf_f0_s1_data)
        pf_server.missing_articles.add("pf_f1_s0@nzbunny.test")
        pf_dl = os.path.join(temp_dir, "pf_downloads")
        os.makedirs(pf_dl, exist_ok=True)
        pf_env = env.copy()
        pf_env["NNTP_PORT"] = str(pf_server.port)
        pf_env["NNTP_TIMEOUT"] = "5s"
        pf_env["DOWNLOAD_DIR"] = pf_dl
        pf_env["DB_PATH"] = os.path.join(temp_dir, "pf.db")
        pf_env["NNTP_CONNECTIONS"] = "2"
        pf_env["POLL_INTERVAL"] = "1s"
        proc = ManagedProcess([str(executable)], env=pf_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_pf = build_nzb([
                [(1, len(pf_f0_s0_data), "pf_f0_s0@nzbunny.test"), (2, len(pf_f0_s1_data), "pf_f0_s1@nzbunny.test")],
                [(1, len(pf_f1_data), "pf_f1_s0@nzbunny.test")],
            ])
            code, loc = http_post_file(base_url + "/", "pf.nzb", nzb_pf)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]
            for _ in range(30):
                _, html, _ = http_get(f"{base_url}/job/{job_id}")
                if "FAILED" in html.decode("utf-8"):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("Preflight barrier job did not fail")
            with pf_server.lock:
                body_reqs = list(pf_server.body_requests)
            assert "pf_f0_s1@nzbunny.test" not in body_reqs, f"Segment 2+ was requested: {body_reqs}"
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()
            pf_server.stop()

        print("[15/16] Testing ZIP envelope size cap before segment 2+ (P0-5)...")
        env_server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        env_server.start()
        time.sleep(0.2)
        env_f0_s0_data = b"A" * 100
        env_f0_s1_data = b"B" * 100
        env_f0_total = len(env_f0_s0_data) + len(env_f0_s1_data)
        env_f1_data = b"C" * 100
        env_server.articles["env_f0_s0@nzbunny.test"] = yenc_encode("env_file0.bin", env_f0_total, 1, 2, 1, len(env_f0_s0_data), env_f0_s0_data)
        env_server.articles["env_f0_s1@nzbunny.test"] = yenc_encode("env_file0.bin", env_f0_total, 2, 2, len(env_f0_s0_data) + 1, env_f0_total, env_f0_s1_data)
        env_server.articles["env_f1_s0@nzbunny.test"] = yenc_encode("env_file1.bin", len(env_f1_data), 1, 1, 1, len(env_f1_data), env_f1_data)
        env_dl = os.path.join(temp_dir, "env_downloads")
        os.makedirs(env_dl, exist_ok=True)
        env_env = env.copy()
        env_env["NNTP_PORT"] = str(env_server.port)
        env_env["NNTP_TIMEOUT"] = "5s"
        env_env["DOWNLOAD_DIR"] = env_dl
        env_env["DB_PATH"] = os.path.join(temp_dir, "env.db")
        env_env["NNTP_CONNECTIONS"] = "2"
        env_env["POLL_INTERVAL"] = "1s"
        env_env["MAX_ARTIFACT_BYTES"] = "300"
        proc = ManagedProcess([str(executable)], env=env_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(f"{base_url}/readyz", proc)
            nzb_env = build_nzb([
                [(1, len(env_f0_s0_data), "env_f0_s0@nzbunny.test"), (2, len(env_f0_s1_data), "env_f0_s1@nzbunny.test")],
                [(1, len(env_f1_data), "env_f1_s0@nzbunny.test")],
            ])
            code, loc = http_post_file(base_url + "/", "env.nzb", nzb_env)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]
            for _ in range(30):
                _, html, _ = http_get(f"{base_url}/job/{job_id}")
                if "FAILED" in html.decode("utf-8"):
                    break
                time.sleep(0.2)
            else:
                raise AssertionError("ZIP envelope cap job did not fail")
            with env_server.lock:
                body_reqs = list(env_server.body_requests)
            assert "env_f0_s1@nzbunny.test" not in body_reqs, f"Segment 2+ was requested before envelope rejection: {body_reqs}"
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()
            env_server.stop()

        print("[16/16] Testing DB V1 migration & interrupted download restart...")
        mig_db_path = os.path.join(temp_dir, "v1_migrate.db")
        conn = sqlite3.connect(mig_db_path)
        conn.execute("CREATE TABLE nzbunny_schema (version INTEGER NOT NULL)")
        conn.execute("INSERT INTO nzbunny_schema VALUES (1)")
        conn.execute("""
            CREATE TABLE jobs (
                id TEXT PRIMARY KEY, filename TEXT NOT NULL, content BLOB, status TEXT NOT NULL,
                download_path TEXT, artifact_path TEXT, artifact_size INTEGER NOT NULL DEFAULT 0,
                download_token TEXT UNIQUE, fail_reason TEXT, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, expires_at INTEGER, sab_name TEXT, nzo_id TEXT
            )
        """)
        now_ts = int(time.time())
        m1_id = "1" * 32
        m2_id = "2" * 32
        conn.execute("INSERT INTO jobs VALUES (?, 'a.nzb', NULL, 'SUBMITTING', NULL, NULL, 0, NULL, NULL, ?, ?, NULL, NULL, NULL)", (m1_id, now_ts, now_ts))
        conn.execute("INSERT INTO jobs VALUES (?, 'b.nzb', NULL, 'PROCESSING', 'dl2', NULL, 0, NULL, NULL, ?, ?, NULL, NULL, NULL)", (m2_id, now_ts, now_ts))
        conn.commit()
        conn.close()

        env_mig = env.copy()
        env_mig["DB_PATH"] = mig_db_path
        proc = ManagedProcess([str(executable)], env=env_mig, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", proc)
            code, html, _ = http_get(f"{base_url}/job/{m1_id}")
            assert "FAILED" in html.decode("utf-8")
            code, html, _ = http_get(f"{base_url}/job/{m2_id}")
            assert "FAILED" in html.decode("utf-8")
            assert "interrupted" in html.decode("utf-8")
        finally:
            proc.terminate()
            proc.communicate()

        final_db_path = os.path.join(temp_dir, "finalizing_recovery.db")
        final_id = "f" * 32
        final_root = os.path.join(temp_dir, "finalizing_downloads")
        final_source = os.path.join(final_root, ".nzbunny-downloads", final_id, "nested")
        os.makedirs(final_source, exist_ok=True)
        with open(os.path.join(final_source, "file.txt"), "wb") as f:
            f.write(b"finalizing recovery payload")
        conn = sqlite3.connect(final_db_path)
        conn.executescript("""
            CREATE TABLE nzbunny_schema (version INTEGER NOT NULL);
            INSERT INTO nzbunny_schema VALUES (3);
            CREATE TABLE jobs (
                id TEXT PRIMARY KEY, filename TEXT NOT NULL, content BLOB, status TEXT NOT NULL,
                download_path TEXT, artifact_path TEXT, artifact_size INTEGER NOT NULL DEFAULT 0,
                download_token TEXT UNIQUE, fail_reason TEXT, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, expires_at INTEGER, finalize_attempts INTEGER NOT NULL DEFAULT 0,
                finalize_next_at INTEGER, finalize_lease_until INTEGER, finalize_lease_token TEXT
            );
        """)
        conn.execute("INSERT INTO jobs VALUES (?, 'recovery.nzb', NULL, 'FINALIZING', ?, NULL, 0, NULL, NULL, ?, ?, NULL, 0, ?, ?, ?)",
                     (final_id, f".nzbunny-downloads/{final_id}", now_ts, now_ts, now_ts - 1, now_ts - 1, "stale-token"))
        conn.commit()
        conn.close()
        final_env = env.copy()
        final_env["NNTP_PORT"] = str(server.port)
        final_env["DOWNLOAD_DIR"] = final_root
        final_env["DB_PATH"] = final_db_path
        final_env["NNTP_CONNECTIONS"] = "1"
        final_proc = ManagedProcess([str(executable)], env=final_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", final_proc)
            token = None
            for _ in range(60):
                _, html, _ = http_get(f"{base_url}/job/{final_id}")
                match = re.search(r'/d/([0-9a-f]{64})', html.decode("utf-8"))
                if "COMPLETE" in html.decode("utf-8") and match:
                    token = match.group(1)
                    break
                time.sleep(0.2)
            assert token, "stale finalizing job did not recover"
            _, content, _ = http_get(f"{base_url}/d/{token}")
            assert content.startswith(b"PK"), "recovered finalizing artifact is not a zip"
        finally:
            final_proc.terminate()
            final_proc.communicate()

        archive_fail_db = os.path.join(temp_dir, "archive_failure.db")
        archive_fail_id = "a" * 32
        archive_fail_root = os.path.join(temp_dir, "archive_failure_downloads")
        archive_fail_source = os.path.join(archive_fail_root, ".nzbunny-downloads", archive_fail_id)
        os.makedirs(archive_fail_source, exist_ok=True)
        os.mkfifo(os.path.join(archive_fail_source, "unsafe.pipe"))
        conn = sqlite3.connect(archive_fail_db)
        conn.executescript("""
            CREATE TABLE nzbunny_schema (version INTEGER NOT NULL);
            INSERT INTO nzbunny_schema VALUES (3);
            CREATE TABLE jobs (
                id TEXT PRIMARY KEY, filename TEXT NOT NULL, content BLOB, status TEXT NOT NULL,
                download_path TEXT, artifact_path TEXT, artifact_size INTEGER NOT NULL DEFAULT 0,
                download_token TEXT UNIQUE, fail_reason TEXT, created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL, expires_at INTEGER, finalize_attempts INTEGER NOT NULL DEFAULT 0,
                finalize_next_at INTEGER, finalize_lease_until INTEGER, finalize_lease_token TEXT
            );
        """)
        conn.execute("INSERT INTO jobs VALUES (?, 'archive-failure.nzb', NULL, 'FINALIZING', ?, NULL, 0, NULL, NULL, ?, ?, NULL, 5, ?, ?, ?)",
                     (archive_fail_id, f".nzbunny-downloads/{archive_fail_id}", now_ts, now_ts, now_ts - 1, now_ts - 1, "archive-token"))
        conn.commit()
        conn.close()
        archive_fail_env = env.copy()
        archive_fail_env["NNTP_PORT"] = str(server.port)
        archive_fail_env["DOWNLOAD_DIR"] = archive_fail_root
        archive_fail_env["DB_PATH"] = archive_fail_db
        archive_fail_env["NNTP_CONNECTIONS"] = "1"
        archive_fail_proc = ManagedProcess([str(executable)], env=archive_fail_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server(base_url + "/readyz", archive_fail_proc)
            failed = False
            for _ in range(60):
                _, html, _ = http_get(f"{base_url}/job/{archive_fail_id}")
                if "FAILED" in html.decode("utf-8"):
                    failed = True
                    break
                time.sleep(0.2)
            assert failed, "archive failure job did not fail"
            assert not os.path.exists(os.path.join(archive_fail_root, ".nzbunny-artifacts", f"{archive_fail_id}.zip"))
        finally:
            archive_fail_proc.terminate()
            archive_fail_proc.communicate()

        server.stop()


    print("All integration tests PASSED successfully!")


if __name__ == "__main__":
    main()
