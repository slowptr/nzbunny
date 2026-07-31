import os
import re
import ssl
import sys
import time
import zlib
import sqlite3
import zipfile
import tempfile
import urllib.request
import urllib.parse
import subprocess
import socket
import threading
from pathlib import Path

REMOVED = (
    "SAB" + "NZBD_URL",
    "SAB" + "NZBD_API_KEY",
    "SAB" + "NZBD_DOWNLOAD_DIR",
    "SAB" + "NZBD_REQUEST_TIMEOUT",
    "sab" + "nzbd",
)

ALLOW = {
    Path("docs/embedded-downloader-plan.md"),
    Path("src/database.zig"),
}


def test_residual_references(root):
    scanned = []
    for path in (
        list((root / "src").glob("*.zig"))
        + [root / "readme.txt", root / "ARCHITECTURE.md", root / "Dockerfile", root / "deploy/docker-compose.yml"]
    ):
        rel = path.relative_to(root)
        if rel in ALLOW:
            continue
        if not path.exists():
            continue
        text = path.read_text(errors="replace")
        for needle in REMOVED:
            if re.search(re.escape(needle), text, re.IGNORECASE):
                raise AssertionError(f"removed downloader reference {needle!r} remains in {rel}")
        scanned.append(rel)
    assert scanned


def generate_certs(temp_dir):
    ca_key = os.path.join(temp_dir, "ca.key")
    ca_crt = os.path.join(temp_dir, "ca.crt")
    server_key = os.path.join(temp_dir, "server.key")
    server_csr = os.path.join(temp_dir, "server.csr")
    server_crt = os.path.join(temp_dir, "server.crt")
    ext_file = os.path.join(temp_dir, "ext.cnf")

    with open(ext_file, "w") as f:
        f.write("subjectAltName=IP:127.0.0.1,DNS:127.0.0.1,DNS:localhost\n")

    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", ca_key, "-out", ca_crt, "-days", "1", "-subj", "/CN=127.0.0.1"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    subprocess.run(
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", server_key, "-out", server_csr, "-subj", "/CN=127.0.0.1"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    subprocess.run(
        ["openssl", "x509", "-req", "-in", server_csr, "-CA", ca_crt, "-CAkey", ca_key, "-CAcreateserial", "-out", server_crt, "-days", "1", "-extfile", ext_file],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    bad_ca_crt = os.path.join(temp_dir, "bad_ca.crt")
    bad_ca_key = os.path.join(temp_dir, "bad_ca.key")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", bad_ca_key, "-out", bad_ca_crt, "-days", "1", "-subj", "/CN=BadCA"],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    return {
        "ca_crt": ca_crt,
        "bad_ca_crt": bad_ca_crt,
        "server_crt": server_crt,
        "server_key": server_key,
    }


def yenc_encode(name, size, part_num, total_parts, begin, end, data):
    lines = []
    if total_parts > 1:
        lines.append(f"=ybegin part={part_num} total={total_parts} line=128 size={size} name={name}\r\n".encode("latin1"))
        lines.append(f"=ypart begin={begin} end={end}\r\n".encode("latin1"))
    else:
        lines.append(f"=ybegin line=128 size={size} name={name}\r\n".encode("latin1"))

    encoded_data = bytearray()
    for byte in data:
        enc = (byte + 42) % 256
        if enc in (0, 10, 13, 61):  # NUL, LF, CR, '='
            encoded_data.append(61)  # '='
            encoded_data.append((enc + 64) % 256)
        else:
            encoded_data.append(enc)

    offset = 0
    while offset < len(encoded_data):
        chunk = encoded_data[offset : offset + 128]
        if chunk.startswith(b"."):
            chunk = b"." + chunk  # dot-stuffing
        lines.append(bytes(chunk) + b"\r\n")
        offset += 128

    part_crc = zlib.crc32(data) & 0xFFFFFFFF
    if total_parts > 1:
        lines.append(f"=yend size={len(data)} part={part_num} pcrc32={part_crc:08x}\r\n".encode("latin1"))
    else:
        lines.append(f"=yend size={len(data)} crc32={part_crc:08x}\r\n".encode("latin1"))

    return b"".join(lines)


class FakeNNTPServer:
    def __init__(self, certs, greeting_code=200, two_step_auth=False):
        self.certs = certs
        self.greeting_code = greeting_code
        self.two_step_auth = two_step_auth
        self.articles = {}
        self.transient_errors = set()
        self.missing_articles = set()
        self.reject_connections = False
        self.fragment_sends = False
        self.body_delay_seconds = 0
        self.active_conns = 0
        self.peak_conns = 0
        self.lock = threading.Lock()
        self.server_socket = None
        self.port = 0
        self.running = False
        self.thread = None

    def start(self):
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(certfile=self.certs["server_crt"], keyfile=self.certs["server_key"])
        
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind(("127.0.0.1", 0))
        self.port = self.server_socket.getsockname()[1]
        self.server_socket.listen(16)
        self.running = True
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.thread.start()

    def _accept_loop(self):
        while self.running:
            try:
                self.server_socket.settimeout(0.5)
                client_sock, _ = self.server_socket.accept()
            except (socket.timeout, OSError):
                continue

            if self.reject_connections:
                client_sock.close()
                continue

            t = threading.Thread(target=self._handle_client, args=(client_sock,), daemon=True)
            t.start()

    def _handle_client(self, raw_sock):
        try:
            raw_sock.settimeout(5.0)
            sock = self.ctx.wrap_socket(raw_sock, server_side=True)
        except Exception:
            raw_sock.close()
            return

        with self.lock:
            self.active_conns += 1
            if self.active_conns > self.peak_conns:
                self.peak_conns = self.active_conns

        try:
            sock.settimeout(5.0)
            sock.sendall(f"{self.greeting_code} NNTP Service Ready\r\n".encode("latin1"))
            authenticated = False
            user = None
            buf = bytearray()

            while self.running:
                try:
                    chunk = sock.recv(4096)
                except (socket.timeout, ssl.SSLWantReadError):
                    continue
                if not chunk:
                    break
                buf.extend(chunk)

                while b"\r\n" in buf:
                    line_bytes, buf = buf.split(b"\r\n", 1)
                    line_str = line_bytes.decode("latin1")
                    if not line_str:
                        continue

                    parts = line_str.split(" ", 1)
                    cmd = parts[0].upper()
                    arg = parts[1] if len(parts) > 1 else ""

                    if cmd == "AUTHINFO":
                        auth_parts = arg.split(" ", 1)
                        subcmd = auth_parts[0].upper()
                        subarg = auth_parts[1] if len(auth_parts) > 1 else ""
                        if subcmd == "USER":
                            user = subarg
                            if self.two_step_auth:
                                sock.sendall(b"381 PASS required\r\n")
                            else:
                                authenticated = True
                                sock.sendall(b"281 Authenticated\r\n")
                            time.sleep(0.01)
                        elif subcmd == "PASS":
                            if user and self.two_step_auth:
                                authenticated = True
                                sock.sendall(b"281 Authenticated\r\n")
                            else:
                                sock.sendall(b"502 Authentication failed\r\n")
                            time.sleep(0.01)
                    elif cmd == "DATE":
                        sock.sendall(b"111 20260731171754\r\n")
                        time.sleep(0.01)
                    elif cmd == "BODY":
                        if not authenticated:
                            sock.sendall(b"480 Authentication required\r\n")
                            time.sleep(0.01)
                            continue
                        msgid = arg.strip("<>")
                        if msgid in self.transient_errors:
                            self.transient_errors.remove(msgid)
                            sock.sendall(b"400 Transient server error\r\n")
                            time.sleep(0.01)
                            continue
                        if msgid in self.missing_articles:
                            sock.sendall(b"430 No such article\r\n")
                            time.sleep(0.01)
                            continue
                        if msgid in self.articles:
                            payload = self.articles[msgid] + b".\r\n"
                            sock.sendall(f"222 {msgid} body follows\r\n".encode("latin1"))
                            if self.fragment_sends:
                                for i in range(0, len(payload), 10):
                                    sock.sendall(payload[i : i + 10])
                                    time.sleep(0.001)
                            else:
                                sock.sendall(payload)
                            if self.body_delay_seconds > 0:
                                time.sleep(self.body_delay_seconds)
                            else:
                                time.sleep(0.01)
                        else:
                            sock.sendall(b"430 No such article\r\n")
                            time.sleep(0.01)
                    elif cmd == "QUIT":
                        sock.sendall(b"205 Closing connection\r\n")
                        break
                    else:
                        sock.sendall(b"500 Unknown command\r\n")
        except Exception:
            pass
        finally:
            with self.lock:
                if self.active_conns > 0:
                    self.active_conns -= 1
            try:
                sock.close()
            except Exception:
                pass

    def stop(self):
        self.running = False
        if self.server_socket:
            try:
                self.server_socket.close()
            except Exception:
                pass


def build_nzb(file_segments):
    xml = ['<?xml version="1.0" encoding="UTF-8"?>']
    xml.append('<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">')
    for segments in file_segments:
        xml.append('  <file poster="p" date="1" subject="s">')
        xml.append('    <segments>')
        for num, size, msgid in segments:
            xml.append(f'      <segment bytes="{size}" number="{num}">{msgid}</segment>')
        xml.append('    </segments>')
        xml.append('  </file>')
    xml.append('</nzb>')
    return "\n".join(xml).encode("utf-8")


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def http_post_file(url, filename, content):
    boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"
    body = bytearray()
    body.extend(f"--{boundary}\r\n".encode("latin1"))
    body.extend(f'Content-Disposition: form-data; name="nzbfile"; filename="{filename}"\r\n'.encode("latin1"))
    body.extend(b"Content-Type: application/x-nzb\r\n\r\n")
    body.extend(content)
    body.extend(f"\r\n--{boundary}--\r\n".encode("latin1"))

    req = urllib.request.Request(url, data=bytes(body), headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}"
    })
    opener = urllib.request.build_opener(NoRedirectHandler())
    try:
        with opener.open(req) as resp:
            return resp.getcode(), resp.headers.get("Location")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location")


def http_get(url):
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req) as resp:
            return resp.getcode(), resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


def wait_for_server(url, proc, timeout=10.0):
    start = time.time()
    while time.time() - start < timeout:
        if proc.poll() is not None:
            stdout, stderr = proc.communicate()
            raise RuntimeError(f"Process exited prematurely with code {proc.returncode}\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}")
        try:
            req = urllib.request.Request(url)
            with urllib.request.urlopen(req, timeout=1.0) as resp:
                return resp.getcode()
        except (urllib.error.HTTPError, urllib.error.URLError, socket.timeout, ConnectionRefusedError):
            time.sleep(0.1)
    proc.kill()
    stdout, stderr = proc.communicate()
    raise RuntimeError(f"Timed out waiting for {url}\nSTDOUT:\n{stdout}\nSTDERR:\n{stderr}")


def main():
    executable = Path(sys.argv[1]).resolve()
    assert executable.exists(), executable
    root = Path(__file__).resolve().parents[1]

    print("[1/9] Testing residual SABnzbd references...")
    test_residual_references(root)

    with tempfile.TemporaryDirectory() as temp_dir:
        print("[2/9] Generating test TLS certificates...")
        certs = generate_certs(temp_dir)

        print("[3/9] Starting fake NNTP server...")
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
            "PORT": "13370",
            "NNTP_CONNECTIONS": "4",
            "POLL_INTERVAL": "1s",
        })

        print("[4/9] Testing single direct file E2E download...")
        proc = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server("http://127.0.0.1:13370/readyz", proc)
            code, body, _ = http_get("http://127.0.0.1:13370/readyz")
            assert code == 200, (code, body)

            nzb1 = build_nzb([[(1, len(direct_data), msgid1)]])
            code, loc = http_post_file("http://127.0.0.1:13370/", "sample.nzb", nzb1)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]

            token = None
            for _ in range(30):
                code, html, _ = http_get(f"http://127.0.0.1:13370/job/{job_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m, html_str
                    token = m.group(1)
                    break
                time.sleep(0.2)
            assert token, "Job did not reach COMPLETE"

            code, content, headers = http_get(f"http://127.0.0.1:13370/d/{token}")
            assert code == 200
            assert content == direct_data
            assert 'attachment; filename="test_direct.bin"' in headers.get("content-disposition")
        finally:
            proc.terminate()
            stdout, stderr = proc.communicate()

        log_output = (stdout or "") + (stderr or "")
        print("[5/9] Auditing logs for credential/payload leaks...")
        assert "testpass" not in log_output
        assert "Antigravity" not in log_output
        assert ".nzbunny-work" not in log_output

        print("[6/9] Testing multi-file ZIP download & concurrency...")
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

        proc = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server("http://127.0.0.1:13370/readyz", proc)
            nzb_multi = build_nzb([
                [(1, len(f1_data), msg_f1)],
                [
                    (1, len(f2_p1_data), msg_f2_1),
                    (2, len(f2_p2_data), msg_f2_2),
                    (3, len(f2_p3_data), msg_f2_3),
                ]
            ])
            code, loc = http_post_file("http://127.0.0.1:13370/", "multi.nzb", nzb_multi)
            assert code == 303, (code, loc)
            job_id = loc.split("/")[-1]

            token = None
            for _ in range(50):
                code, html, _ = http_get(f"http://127.0.0.1:13370/job/{job_id}")
                html_str = html.decode("utf-8")
                if "COMPLETE" in html_str:
                    m = re.search(r'/d/([0-9a-f]{64})', html_str)
                    assert m
                    token = m.group(1)
                    break
                time.sleep(0.2)
            assert token, "Multi-file job did not reach COMPLETE"

            code, zip_bytes, headers = http_get(f"http://127.0.0.1:13370/d/{token}")
            assert code == 200
            assert "application/zip" in headers.get("content-type")

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
        except Exception:
            proc.kill()
            stdout, stderr = proc.communicate()
            print(f"STDOUT:\n{stdout}\nSTDERR:\n{stderr}", flush=True)
            raise
        finally:
            proc.terminate()
            proc.communicate()

        print("[7/9] Testing all-or-nothing failure & cleanup...")
        server.articles.clear()
        server.missing_articles.add("missing@nzbunny.test")
        proc = subprocess.Popen([str(executable)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server("http://127.0.0.1:13370/readyz", proc)
            nzb_fail = build_nzb([[(1, 10, "missing@nzbunny.test")]])
            code, loc = http_post_file("http://127.0.0.1:13370/", "fail.nzb", nzb_fail)
            assert code == 303
            job_id = loc.split("/")[-1]

            failed = False
            for _ in range(30):
                code, html, _ = http_get(f"http://127.0.0.1:13370/job/{job_id}")
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

        print("[8/9] Testing DB V1 migration & interrupted download restart...")
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
        proc = subprocess.Popen([str(executable)], env=env_mig, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            wait_for_server("http://127.0.0.1:13370/readyz", proc)
            code, html, _ = http_get(f"http://127.0.0.1:13370/job/{m1_id}")
            assert "FAILED" in html.decode("utf-8")
            code, html, _ = http_get(f"http://127.0.0.1:13370/job/{m2_id}")
            assert "FAILED" in html.decode("utf-8")
            assert "interrupted" in html.decode("utf-8")
        finally:
            proc.terminate()
            proc.communicate()

        server.stop()

        print("[9/9] Testing Compose config validation...")
        compose_file = root / "deploy/docker-compose.yml"
        compose_env = env.copy()
        compose_env.update({"NNTP_HOST": "localhost", "NNTP_USER": "u", "NNTP_PASS": "p"})
        subprocess.run(["docker", "compose", "-f", str(compose_file), "config"], env=compose_env, check=True, stdout=subprocess.DEVNULL)

    print("All integration tests PASSED successfully!")


if __name__ == "__main__":
    main()
