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
    Path("src/database.zig"),
    Path("tests/integration.py"),
}


def test_residual_references(root):
    scanned = []
    for path in (
        list((root / "src").glob("*.zig"))
        + list((root / "docs").glob("*.md"))
        + list((root / "deploy").glob("*"))
        + list((root / "tests").glob("*.py"))
        + [root / "readme.txt", root / "Dockerfile", root / ".env.example"]
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
        check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    subprocess.run(
        ["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-keyout", server_key, "-out", server_csr, "-subj", "/CN=127.0.0.1"],
        check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    subprocess.run(
        ["openssl", "x509", "-req", "-in", server_csr, "-CA", ca_crt, "-CAkey", ca_key, "-CAcreateserial", "-out", server_crt, "-days", "1", "-extfile", ext_file],
        check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

    bad_ca_crt = os.path.join(temp_dir, "bad_ca.crt")
    bad_ca_key = os.path.join(temp_dir, "bad_ca.key")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", bad_ca_key, "-out", bad_ca_crt, "-days", "1", "-subj", "/CN=BadCA"],
        check=True, timeout=20, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
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
        end = min(offset + 128, len(encoded_data))
        if end < len(encoded_data) and encoded_data[end - 1] == 61:
            end -= 1
        chunk = encoded_data[offset:end]
        if chunk.startswith(b"."):
            chunk = b"." + chunk  # dot-stuffing
        lines.append(bytes(chunk) + b"\r\n")
        offset = end

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
        self.no_group_once = set()
        self.persistent_transient = set()
        self.missing_articles = set()
        self.reject_connections = False
        self.fragment_sends = False
        self.body_delay_seconds = 0
        self.stall_after_tls = False
        self.stall_body = set()
        self.close_body_once = set()
        self.active_conns = 0
        self.peak_conns = 0
        self.handshake_count = 0
        self.auth_count = 0
        self.body_requests = []
        self.lock = threading.Lock()
        self.server_socket = None
        self.port = 0
        self.running = False
        self.thread = None
        self.stop_event = threading.Event()
        self.client_threads = []

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
            self.client_threads.append(t)
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
            self.handshake_count += 1

        if self.stall_after_tls:
            self.stop_event.wait(30)
            with self.lock:
                if self.active_conns > 0:
                    self.active_conns -= 1
            try:
                sock.close()
            except Exception:
                pass
            return

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
                            with self.lock:
                                self.auth_count += 1
                            if self.two_step_auth:
                                sock.sendall(b"381 PASS required\r\n")
                            else:
                                authenticated = True
                                sock.sendall(b"281 Authenticated\r\n")
                            self.stop_event.wait(0.01)
                        elif subcmd == "PASS":
                            if user and self.two_step_auth:
                                authenticated = True
                                sock.sendall(b"281 Authenticated\r\n")
                            else:
                                sock.sendall(b"502 Authentication failed\r\n")
                            self.stop_event.wait(0.01)
                    elif cmd == "DATE":
                        sock.sendall(b"111 20260731171754\r\n")
                        self.stop_event.wait(0.01)
                    elif cmd == "BODY":
                        if not authenticated:
                            sock.sendall(b"480 Authentication required\r\n")
                            self.stop_event.wait(0.01)
                            continue
                        msgid = arg.strip("<>")
                        with self.lock:
                            self.body_requests.append(msgid)
                        if msgid in self.persistent_transient:
                            sock.sendall(b"400 Transient server error\r\n")
                            self.stop_event.wait(0.01)
                            continue
                        if msgid in self.no_group_once:
                            self.no_group_once.remove(msgid)
                            sock.sendall(b"412 No group selected\r\n")
                            self.stop_event.wait(0.01)
                            continue
                        if msgid in self.transient_errors:
                            self.transient_errors.remove(msgid)
                            sock.sendall(b"400 Transient server error\r\n")
                            self.stop_event.wait(0.01)
                            continue
                        if msgid in self.missing_articles:
                            sock.sendall(b"430 No such article\r\n")
                            self.stop_event.wait(0.01)
                            continue
                        if msgid in self.articles:
                            if msgid in self.close_body_once:
                                self.close_body_once.remove(msgid)
                                sock.close()
                                return
                            if msgid in self.stall_body:
                                self.stop_event.wait(self.body_delay_seconds)
                            payload = self.articles[msgid] + b".\r\n"
                            sock.sendall(f"222 {msgid} body follows\r\n".encode("latin1"))
                            if self.fragment_sends:
                                for i in range(0, len(payload), 10):
                                    sock.sendall(payload[i : i + 10])
                                    self.stop_event.wait(0.001)
                            else:
                                sock.sendall(payload)
                            if self.body_delay_seconds > 0:
                                self.stop_event.wait(self.body_delay_seconds)
                            else:
                                self.stop_event.wait(0.01)
                        else:
                            sock.sendall(b"430 No such article\r\n")
                            self.stop_event.wait(0.01)
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
        self.stop_event.set()
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
        with opener.open(req, timeout=5) as resp:
            return resp.getcode(), resp.headers.get("Location")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location")


def http_get(url):
    req = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.getcode(), resp.read(), resp.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


def wait_for_server(url, proc, timeout=10.0):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
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



def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class ManagedProcess(subprocess.Popen):
    """Drain logs to files so tests cannot deadlock on a full stderr pipe."""
    def __init__(self, *args, **kwargs):
        self._logs = [tempfile.TemporaryFile(mode="w+"), tempfile.TemporaryFile(mode="w+")]
        kwargs.update(stdout=self._logs[0], stderr=self._logs[1], text=True)
        self._captured = None
        kwargs.setdefault("cwd", kwargs.get("env", {}).get("DOWNLOAD_DIR"))
        super().__init__(*args, **kwargs)

    def communicate(self, input=None, timeout=5):
        try:
            self.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill()
            self.wait(timeout=5)
            raise
        if self._captured is None:
            for log in self._logs:
                log.seek(0)
            self._captured = tuple(log.read() for log in self._logs)
            for log in self._logs:
                log.close()
        return self._captured

    def logs(self):
        if self._captured is not None:
            return "\n".join(self._captured)
        contents = []
        for log in self._logs:
            log.flush()
            contents.append(os.pread(log.fileno(), 1024 * 1024, 0).decode())
        return "\n".join(contents)
