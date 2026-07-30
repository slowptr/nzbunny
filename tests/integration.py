import http.client
import json
import os
import re
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class SabState:
    uploads = 0
    accepted_name = ""
    nzo_id = "SAB-UNCERTAIN-1"
    lock = threading.Lock()


class SabHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_POST(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if query.get("mode") != ["addfile"]:
            self.send_json({"error": "bad mode"}, 400)
            return
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        with SabState.lock:
            SabState.uploads += 1
            SabState.accepted_name = query["nzbname"][0]
        self.connection.shutdown(socket.SHUT_RDWR)
        self.connection.close()

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        mode = query.get("mode", [""])[0]
        if mode == "queue":
            if query.get("search") == [SabState.accepted_name]:
                slots = [{
                    "nzo_id": SabState.nzo_id,
                    "name": SabState.accepted_name,
                    "status": "Downloading",
                }]
            else:
                slots = []
            self.send_json({"queue": {"slots": slots}})
            return
        if mode == "history":
            if query.get("nzo_ids") == [SabState.nzo_id]:
                slots = [{
                    "nzo_id": SabState.nzo_id,
                    "name": SabState.accepted_name,
                    "status": "Completed",
                    "storage": "result.bin",
                }]
            else:
                slots = []
            self.send_json({"history": {"slots": slots}})
            return
        self.send_json({"error": "bad mode"}, 400)

    def send_json(self, value, status=200):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    request_headers = {"Connection": "close"}
    request_headers.update(headers or {})
    connection.request(method, path, body=body, headers=request_headers)
    response = connection.getresponse()
    data = response.read()
    result = response.status, dict(response.getheaders()), data
    connection.close()
    return result


def wait_ready(port):
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            status, _, body = request(port, "GET", "/readyz")
            if status == 200 and body == b"ready":
                return
        except OSError:
            pass
        time.sleep(0.1)
    raise AssertionError("nzigbunny did not become ready")


def wait_job(port, location, wanted):
    deadline = time.time() + 15
    last = ""
    while time.time() < deadline:
        status, _, body = request(port, "GET", location)
        assert status == 200
        text = body.decode()
        match = re.search(r'class="status-([A-Z]+)"', text)
        last = match.group(1) if match else ""
        if last == wanted:
            return text
        time.sleep(0.2)
    raise AssertionError(f"job did not reach {wanted}; last state was {last}")


def stop_process(process):
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def upload(port):
    boundary = "nzigbunny-integration"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="nzbfile"; filename="sample.nzb"\r\n'
        "Content-Type: application/x-nzb\r\n\r\n"
        "<nzb/>\r\n"
        f"--{boundary}--\r\n"
    ).encode()
    status, headers, _ = request(port, "POST", "/", body, {
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(body)),
    })
    assert status == 303
    return headers["location"]


def main():
    executable = Path(sys.argv[1]).resolve()
    sab_port = free_port()
    app_port = free_port()
    server = ThreadingHTTPServer(("127.0.0.1", sab_port), SabHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    with tempfile.TemporaryDirectory(prefix="nzigbunny-integration-") as root:
        root_path = Path(root)
        artifact = root_path / "result.bin"
        artifact.write_bytes(b"integration artifact")
        environment = os.environ.copy()
        environment.update({
            "SABNZBD_URL": f"http://127.0.0.1:{sab_port}",
            "SABNZBD_API_KEY": "test-key",
            "SABNZBD_DOWNLOAD_DIR": root,
            "DB_PATH": str(root_path / "jobs.db"),
            "PORT": str(app_port),
            "RETENTION_TTL": "3s",
            "CLEANUP_INTERVAL": "1s",
            "POLL_INTERVAL": "1s",
            "SABNZBD_REQUEST_TIMEOUT": "5s",
            "HTTP_HEADER_TIMEOUT": "1s",
            "HTTP_REQUEST_TIMEOUT": "5s",
            "MAX_CONNECTIONS": "4",
            "UPLOADS_PER_MINUTE": "1",
        })
        slow_process = subprocess.Popen(
            [str(executable)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        slow_connections = []
        try:
            wait_ready(app_port)
            for _ in range(4):
                connection = socket.create_connection(("127.0.0.1", app_port), timeout=2)
                connection.sendall(b"GET / HTTP/1.1\r\nHost: slow")
                slow_connections.append(connection)
            time.sleep(1.5)
            status, _, body = request(app_port, "GET", "/healthz")
            assert status == 200
            assert body == b"ok"
        finally:
            for connection in slow_connections:
                connection.close()
            stop_process(slow_process)

        process = subprocess.Popen(
            [str(executable)],
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            wait_ready(app_port)
            location = upload(app_port)
            status, _, _ = request(app_port, "POST", "/", b"")
            assert status == 429
            page = wait_job(app_port, location, "COMPLETE")
            match = re.search(r'href="(/d/[0-9a-f]{64})"', page)
            assert match
            status, headers, body = request(app_port, "GET", match.group(1))
            assert status == 200
            assert body == b"integration artifact"
            assert headers["cache-control"] == "private, no-store"
            artifact.write_bytes(b"replacement artifact")
            status, _, body = request(app_port, "GET", match.group(1))
            assert status == 200
            assert body == b"integration artifact"
            status, headers, body = request(app_port, "HEAD", match.group(1))
            assert status == 200
            assert body == b""
            assert headers["content-length"] == str(len(b"integration artifact"))
            wait_job(app_port, location, "EXPIRED")
            status, _, _ = request(app_port, "GET", match.group(1))
            assert status == 410
            assert not artifact.exists()
            assert SabState.uploads == 1
        finally:
            stop_process(process)
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
