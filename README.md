# nzbunny

nzbunny is a small, self-hosted Usenet download and rehost service. It uses
Zig 0.16, SQLite, libarchive, and SABnzbd.

A user uploads one `.nzb` file. nzbunny submits the file to SABnzbd and tracks
the job. When the download is complete, nzbunny gives the user a temporary
download link. It serves one output file directly. It puts a directory output
in a ZIP file.

## Requirements

- Zig 0.16 for a local build
- Python 3 for the integration test
- SQLite development files
- libarchive development files
- A SABnzbd server

Linux amd64 and arm64 containers are the release targets.

## Configuration

Copy `.env.example` to `.env`. Environment variables have priority over values
in `.env`.

The following values are required:

- `SABNZBD_API_KEY`
- `SABNZBD_DOWNLOAD_DIR`

The other values have these defaults:

| Name | Default |
| --- | --- |
| `SABNZBD_URL` | `http://localhost:8080` |
| `DB_PATH` | `nzbunny.db` |
| `PORT` | `1337` |
| `RETENTION_TTL` | `15m` |
| `CLEANUP_INTERVAL` | `30s` |
| `POLL_INTERVAL` | `10s` |
| `SABNZBD_REQUEST_TIMEOUT` | `30s` |
| `HTTP_HEADER_TIMEOUT` | `15s` |
| `HTTP_REQUEST_TIMEOUT` | `5m` |
| `MAX_ARTIFACT_BYTES` | `209715200` |
| `MAX_UPLOAD_BYTES` | `2097152` |
| `MAX_ACTIVE_JOBS` | `32` |
| `MAX_CONNECTIONS` | `128` |
| `UPLOADS_PER_MINUTE` | `20` |
| `TRUSTED_PROXY_CIDRS` | empty |

Use positive integers for byte, count, and port values. Use `s`, `m`, `h`, or
`d` for time values. nzbunny stops when a value is not valid.
`RETENTION_TTL` is limited to 365 days and `MAX_UPLOAD_BYTES` is limited to
64 MiB.

`TRUSTED_PROXY_CIDRS` is a comma-separated list. Keep it empty when the service
does not run behind a trusted reverse proxy. When a trusted proxy is listed,
nzbunny trusts the left-most `X-Forwarded-For` value, so the proxy must
overwrite or strip any client-supplied `X-Forwarded-For` header. Otherwise a
client can spoof its address and dodge the upload rate limit.

## Local use

```sh
make test
make dev
```

Other tasks are `build`, `run`, `fmt`, and `clean`.

The service has these routes:

- `GET /`
- `POST /`
- `GET /job/:id`
- `GET` or `HEAD /d/:token`
- `GET` or `HEAD /public/*`
- `GET /healthz`
- `GET /readyz`

## Containers

Set the SABnzbd API key and start Compose:

```sh
export SABNZBD_API_KEY=replace-with-your-api-key
docker compose -f deploy/docker-compose.yml up --build
```

Compose stores the database in the `nzbunny-data` volume. It uses the
`downloads` volume to share files between both services. Before nzbunny
starts, Compose configures SABnzbd to put completed downloads in
`/downloads/complete`.

Compose binds both HTTP ports to the host loopback interface. Keep nzbunny
behind an authenticated reverse proxy before making it reachable from another
machine. The application does not provide user authentication.

The Compose SABnzbd image is pinned by its multi-platform manifest digest.
Review and update that digest deliberately when upgrading SABnzbd.

The Docker build downloads the official Zig 0.16 toolchain for amd64 or arm64.
It verifies the fixed SHA-256 checksum before use.

## Data safety

nzbunny stores a schema version in SQLite. It does not change an old
nzbunny Go schema. Startup stops with an error when that schema is present.

Each upload has a stable SABnzbd name. If an upload result is uncertain,
nzbunny searches the SABnzbd queue and history. It does not send a second
upload. It resumes submission and artifact finalization after a restart. Jobs
that time out are removed from SABnzbd before local tracking expires.

All served and removed output paths must resolve inside the configured download
root. nzbunny rejects symbolic links and special files. Completed files and
ZIP archives are copied into per-job artifact storage before download links are
issued. A directory artifact can contain at most 10,000 entries and can be at
most 128 directories deep.

`MAX_ARTIFACT_BYTES` is enforced when SABnzbd finishes. It does not prevent
SABnzbd from downloading a larger job first. Configure SABnzbd quotas when
download storage must have a hard limit.
