NZBUNNY(1)                 General Commands Manual                NZBUNNY(1)

NAME
     nzbunny -- Usenet download and file distribution service

SYNOPSIS
     nzbunny

DESCRIPTION
     nzbunny is an HTTP service that accepts NZB files, submits them to
     SABnzbd, and serves the completed downloads as temporary artifacts.

     The service works as follows:

           1.   The user uploads an NZB file.
           2.   nzbunny submits the NZB file to SABnzbd.
           3.   nzbunny monitors the download progress.
           4.   When the download is complete, nzbunny provides a
                temporary download link.
           5.   If the output is a single file, nzbunny serves the file
                as a direct download.
           6.   If the output is a directory, nzbunny packs the
                directory into a ZIP archive.

     nzbunny continues incomplete submissions and artifact finalization
     across restarts.  If a job does not complete in time, nzbunny
     removes the job from SABnzbd before the local tracking expires.

FILES
     .env             Service configuration.  See ENVIRONMENT below.

     nzbunny.db       SQLite database.  The default path is set by
                      DB_PATH.

ENVIRONMENT
     nzbunny reads configuration from the environment.  If a .env file
     is present in the working directory, nzbunny loads it first;
     environment variables override the values in .env.

     The following variables are required:

     SABNZBD_API_KEY
             API key for the SABnzbd server.

     SABNZBD_DOWNLOAD_DIR
             Absolute path to the directory where SABnzbd places
             completed downloads.  All paths that nzbunny serves or
             removes must resolve within this directory.  Symbolic links
             and special files are rejected.

     The following variables are optional.  Each has a default value:

     SABNZBD_URL
             Base URL of the SABnzbd server.  Must use the http or https
             scheme and include a host.
             Default: http://localhost:8080.

     DB_PATH
             Path to the SQLite database file.
             Default: nzbunny.db.

     PORT    TCP port for the HTTP server.  Must be a positive integer.
             Default: 1337.

     RETENTION_TTL
             Maximum age of an artifact before it is removed.  Must be a
             positive duration with one of the units s (seconds),
             m (minutes), h (hours), or d (days).  The maximum value is
             365 days.
             Default: 15m.

     CLEANUP_INTERVAL
             Interval at which expired artifacts are removed.
             Default: 30s.

     POLL_INTERVAL
             Interval at which nzbunny polls SABnzbd for job status.
             Default: 10s.

     SABNZBD_REQUEST_TIMEOUT
             Timeout for HTTP requests to the SABnzbd API.
             Default: 30s.

     HTTP_HEADER_TIMEOUT
             Timeout for reading HTTP request headers.
             Default: 15s.

     HTTP_REQUEST_TIMEOUT
             Timeout for an entire HTTP request.
             Default: 5m.

     MAX_ARTIFACT_BYTES
             Maximum size in bytes of an artifact that nzbunny will
             serve.  This limit is applied when SABnzbd finishes; it
             does not prevent SABnzbd from downloading a larger job
             first.  Set quotas in SABnzbd if the download storage
             requires a strict limit.
             Default: 209715200 (200 MiB).

     MAX_UPLOAD_BYTES
             Maximum size in bytes of an uploaded NZB file.  The maximum
             permitted value is 67108864 (64 MiB).
             Default: 2097152 (2 MiB).

     MAX_ACTIVE_JOBS
             Maximum number of concurrent SABnzbd jobs.
             Default: 32.

     MAX_CONNECTIONS
             Maximum number of concurrent HTTP connections.
             Default: 128.

     UPLOADS_PER_MINUTE
             Maximum number of NZB uploads per minute per client
             address.
             Default: 20.

     TRUSTED_PROXY_CIDRS
             Comma-separated list of CIDR ranges for trusted reverse
             proxies.  If not empty, nzbunny trusts the left-most value
             in the X-Forwarded-For header when the request originates
             from a trusted proxy address.  The proxy must replace or
             remove the X-Forwarded-For header that the client sends.
             If the proxy does not replace or remove the header, the
             client can change its address and bypass the upload rate
             limit.
             Default: empty.

     Duration values use the format <number><unit>, where unit is one of
     s, m, h, or d.  Byte, count, and port values use positive integers.
     If a value is not valid, nzbunny exits with an error.

HTTP ROUTES
     GET /                       Show the upload page.
     POST /                      Submit an NZB file.
     GET /job/:id                Show the status of a job.
     GET /d/:token               Download an artifact.
     HEAD /d/:token              Check artifact availability.
     GET /public/*               Serve a static file.
     HEAD /public/*              Check a static file.
     GET /healthz                Health status endpoint.
     GET /readyz                 Readiness status endpoint.

ARTIFACT CONSTRAINTS
     Directory artifacts are limited to 10000 entries and 128 directory
     levels.  Before download links are served, completed files and ZIP
     archives are copied to per-job artifact storage.

DATA SAFETY
     nzbunny stores a schema version in SQLite.  If the schema from a
     previous nzbunny Go installation is present, nzbunny does not
     modify the schema and exits with an error.

     Each upload receives a stable name in SABnzbd.  If the result of an
     upload is not known, nzbunny searches the SABnzbd queue and
     history.  nzbunny does not submit the same upload again.

SECURITY
     nzbunny does not provide user authentication.  Before making the
     service available from a different host, place nzbunny behind a
     reverse proxy that provides authentication.

EXIT STATUS
     The nzbunny utility exits 0 on success, and >0 if an error occurs.

SEE ALSO
     sabnzbd(1), sqlite3(1)

AUTHORS
     nzbunny was written by the nzbunny contributors.

NZBUNNY                          July 2025                         NZBUNNY(1)