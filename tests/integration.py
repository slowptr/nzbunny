import re
import sys
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


def main():
    executable = Path(sys.argv[1])
    assert executable.exists(), executable
    root = Path(__file__).resolve().parents[1]
    scanned = []
    for path in (
        list((root / "src").glob("*.zig"))
        + [root / "readme.txt", root / "ARCHITECTURE.md", root / "Dockerfile", root / "deploy/docker-compose.yml"]
    ):
        rel = path.relative_to(root)
        if rel in ALLOW:
            continue
        text = path.read_text(errors="replace")
        for needle in REMOVED:
            if re.search(re.escape(needle), text, re.IGNORECASE):
                raise AssertionError(f"removed downloader reference {needle!r} remains in {rel}")
        scanned.append(rel)
    assert scanned


if __name__ == "__main__":
    main()
