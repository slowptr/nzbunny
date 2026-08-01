NZBUNNY(1)                 General Commands Manual                NZBUNNY(1)

NAME
     nzbunny -- Usenet download and file distribution service

SYNOPSIS
     nzbunny

DESCRIPTION
     nzbunny is an HTTP service that accepts NZB files, downloads direct yEnc
     articles from one NNTP provider, and serves completed downloads as
     temporary artifacts.

     The service works as follows:

           1.   The user uploads an NZB file.
           2.   nzbunny queues the job in SQLite.
           3.   The oldest queued job is parsed and preflighted.
           4.   nzbunny downloads required BODY articles over implicit TLS.
           5.   Verified yEnc parts are assembled into one file or directory.
           6.   nzbunny copies a single file directly or creates one ZIP for
                several files, then serves a temporary download link.

     Only one job is processed at a time.  Queued jobs remain in FIFO order.
     The active job may use multiple NNTP connections.  If one required part
     fails permanently, the complete job fails and no partial artifact is
     published.

SUPPORTED INPUT
     NZB files must contain direct yEnc files.  The downloader uses complete
     PAR2 files when provider backends cannot return all payload articles.  It
     rejects split archives, base64, and uuencode.  A single .zip, .7z, or .rar
     file is allowed when it is not part of a split volume.  Password metadata
     is preserved in the NZB but is not used because archives are not extracted.

     PAR2 recovery requires /usr/bin/par2 from par2cmdline.  The container image
     includes this dependency.

FILES
     .env             Service configuration.  See ENVIRONMENT below.
     nzbunny.db       SQLite database.  The default path is set by DB_PATH.

ENVIRONMENT
     nzbunny reads configuration from the environment.  If a .env file is
     present in the working directory, nzbunny loads it first; environment
     variables override the values in .env.

     Required variables:

     NNTP_HOST
             NNTP provider host name.  The host name is verified against the
             TLS certificate.

     NNTP_USER
             User name sent with AUTHINFO USER.

     NNTP_PASS
             Password sent with AUTHINFO PASS.  The password is never logged.

     DOWNLOAD_DIR
             Absolute path to the download root.  Work files, assembled output,
             and artifacts are stored below this directory.

     Optional variables:

     NNTP_PORT
             Implicit TLS port.  Default: 563.

     NNTP_CONNECTIONS
             Number of NNTP sessions for the active job.  Range: 1 through 16.
             Default: 4.

     NNTP_TIMEOUT
             Timeout for NNTP connect and provider operations.  Default: 30s.

     NNTP_CA_FILE
             Additional PEM CA file.  The system CA bundle is always loaded.

     DOWNLOAD_TIMEOUT
             Maximum processing time after a job enters PROCESSING.  Queue time
             does not count.  Default: 2h.

     DB_PATH
             Path to the SQLite database file.  Default: nzbunny.db.

     PORT    TCP port for the HTTP server.  Default: 1337.

     RETENTION_TTL
             Maximum age of an artifact before it is removed.  Default: 15m.

     CLEANUP_INTERVAL
             Interval at which expired artifacts are removed.  Default: 30s.

     POLL_INTERVAL
             Queue and provider probe interval.  Default: 10s.

     HTTP_HEADER_TIMEOUT
             Timeout for reading HTTP request headers.  Default: 15s.

     HTTP_REQUEST_TIMEOUT
             Timeout for an entire HTTP request.  Default: 5m.

     MAX_ARTIFACT_BYTES
             Maximum decoded output bytes and final artifact bytes.
             Default: 209715200 (200 MiB).

     MAX_UPLOAD_BYTES
             Maximum uploaded NZB size.  The hard maximum is 67108864
             (64 MiB).  Default: 2097152 (2 MiB).

     MAX_ACTIVE_JOBS
             Maximum number of queued or active jobs.  Default: 32.

     MAX_CONNECTIONS
             Maximum number of concurrent HTTP connections.  Default: 128.

     UPLOADS_PER_MINUTE
             Maximum NZB uploads per minute per client address.  Default: 20.

     TRUSTED_PROXY_CIDRS
             Comma-separated trusted reverse proxy CIDR ranges.  Default: empty.

HTTP ROUTES
     GET /                       Show the upload page.
     POST /                      Submit an NZB file.
     GET /job/:id                Show the status of a job.
     GET /d/:token               Download an artifact.
     HEAD /d/:token              Check artifact availability.
     GET /public/*               Serve a static file.
     HEAD /public/*              Check a static file.
     GET /healthz                Process-local health endpoint.
     GET /readyz                 Readiness endpoint.  Requires SQLite and an
                                 authenticated NNTP provider probe.

DATA SAFETY
     On startup, nzbunny fails any job that was PROCESSING during a previous
     process lifetime and removes its work and temporary output directories.
     Queued jobs remain pending.  Finalizing jobs resume artifact preparation.

     Upgrading operators should mount the old download volume and set
     DOWNLOAD_DIR to the former completed download root until old completed
     artifacts expire.  Existing completed links work only while their stored
     artifact paths remain visible below DOWNLOAD_DIR.

SECURITY
     The NNTP connection always uses implicit TLS with certificate and host-name
     verification.  The system CA bundle is loaded, and NNTP_CA_FILE can add one
     more CA file.  There is no option to disable verification.

     nzbunny does not provide user authentication.  Before making the service
     available from a different host, place it behind a reverse proxy that
     provides authentication.

TESTING
     Unit tests:
           zig build test

     ReleaseSafe unit tests:
           ZIG_GLOBAL_CACHE_DIR=/tmp/nzbunny-zig-global zig build test -Doptimize=ReleaseSafe

     Python integration test suite:
           python3 tests/integration.py zig-out/bin/nzbunny

SEE ALSO
     sqlite3(1)

AUTHORS
     nzbunny was written by the nzbunny contributors.

NZBUNNY                          July 2026                         NZBUNNY(1)
