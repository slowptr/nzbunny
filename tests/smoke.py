import os
import re
import sys
import time
import tempfile
import subprocess
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from integration import yenc_encode, FakeNNTPServer, generate_certs

CONTAINER_PORT = 13371
IMAGE = "nzbunny:test"

def http_get(url):
    with urllib.request.urlopen(url, timeout=5) as resp:
        return resp.status, resp.read(), resp.headers

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
        with opener.open(req, timeout=10) as resp:
            return resp.getcode(), resp.headers.get("Location")
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Location")

def build_nzb(file_segments):
    xml = ['<?xml version="1.0" encoding="UTF-8"?>', '<nzb>']
    for segments in file_segments:
        xml.append('<file><segments>')
        for number, bytes_val, msgid in segments:
            xml.append(f'<segment bytes="{bytes_val}" number="{number}">{msgid}</segment>')
        xml.append('</segments></file>')
    xml.append('</nzb>')
    return "\n".join(xml).encode("utf-8")

def wait_for_ready(base_url, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            status, _, _ = http_get(f"{base_url}/readyz")
            if status == 200:
                return True
        except Exception:
            pass
        time.sleep(0.3)
    return False

def main():
    with tempfile.TemporaryDirectory() as temp_dir:
        print("[smoke] Generating TLS certificates...")
        certs = generate_certs(temp_dir)
        os.chmod(temp_dir, 0o755)
        for f in os.listdir(temp_dir):
            os.chmod(os.path.join(temp_dir, f), 0o644)

        print("[smoke] Starting fake NNTP server...")
        server = FakeNNTPServer(certs, greeting_code=201, two_step_auth=True)
        server.start()
        time.sleep(0.2)

        fname = "smoke_test.bin"
        fdata = b"Smoke test payload from container"
        msgid = "smoke@nzbunny.test"
        server.articles[msgid] = yenc_encode(fname, len(fdata), 1, 1, 1, len(fdata), fdata)

        nzb_bytes = build_nzb([[(1, len(fdata), msgid)]])

        print("[smoke] Starting container...")
        container_id = subprocess.check_output([
            "docker", "run", "--rm", "-d",
            "--network", "host",
            "-v", f"{temp_dir}:{temp_dir}:ro",
            "-e", f"PORT={CONTAINER_PORT}",
            "-e", f"NNTP_HOST=127.0.0.1",
            "-e", f"NNTP_PORT={server.port}",
            "-e", "NNTP_USER=testuser",
            "-e", "NNTP_PASS=testpass",
            "-e", f"NNTP_CA_FILE={certs['ca_crt']}",
            "-e", "DOWNLOAD_DIR=/downloads",
            "-e", "DB_PATH=/data/smoke.db",
            "-e", "RETENTION_TTL=5m",
            "-e", "CLEANUP_INTERVAL=30s",
            "-e", "POLL_INTERVAL=1s",
            "-e", "NNTP_CONNECTIONS=1",
            "-e", "NNTP_TIMEOUT=10s",
            "-e", "DOWNLOAD_TIMEOUT=30s",
            IMAGE,
        ]).decode().strip()
        base_url = f"http://127.0.0.1:{CONTAINER_PORT}"

        try:
            print("[smoke] Waiting for /readyz...")
            assert wait_for_ready(base_url, timeout=15), "/readyz did not become ready"
            print("[smoke] /readyz OK")

            print("[smoke] Uploading NZB...")
            status, location = http_post_file(f"{base_url}/", "smoke.nzb", nzb_bytes)
            assert status == 303, f"Upload failed: {status}"
            job_id = location.split("/")[-1] if location else None
            assert job_id, f"No job ID in location: {location}"
            print(f"[smoke] Job created: {job_id}")

            print("[smoke] Waiting for download...")
            for _ in range(60):
                status, html, _ = http_get(f"{base_url}/job/{job_id}")
                body = html.decode("utf-8")
                if "COMPLETE" in body:
                    break
                time.sleep(0.5)
            else:
                raise AssertionError("Job did not complete")

            match = re.search(r'/d/([a-f0-9]+)', body)
            assert match, f"No download token found in: {body}"
            token = match.group(1)
            print(f"[smoke] Download token: {token}")

            print("[smoke] Downloading artifact...")
            status, content, _ = http_get(f"{base_url}/d/{token}")
            assert status == 200, f"Download failed: {status}"
            assert content == fdata, f"Content mismatch: {content[:50]}..."
            print(f"[smoke] Artifact verified: {len(content)} bytes match")

            print("[smoke] Testing SIGTERM shutdown...")
            start = time.time()
            subprocess.run(["docker", "stop", container_id], timeout=10, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            elapsed = time.time() - start
            assert elapsed < 5, f"Shutdown took {elapsed:.1f}s, expected < 5s"
            print(f"[smoke] Shutdown OK ({elapsed:.1f}s)")

        finally:
            subprocess.run(["docker", "kill", container_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            server.stop()

    print("[smoke] All stages passed")

if __name__ == "__main__":
    main()
