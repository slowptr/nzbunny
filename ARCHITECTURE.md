# nzbunny architecture

nzbunny is one Linux process with an HTTP upload surface, SQLite job storage,
and an embedded NNTP downloader.  It accepts NZB uploads, downloads direct yEnc
articles from one provider over implicit TLS, prepares one temporary artifact,
and serves the artifact through existing HTTP download routes.

## Source layout

```
src/
  root.zig       Startup, configuration, database, CA loading, provider probe
  config.zig     Environment and .env parsing
  web.zig        HTTP routes, upload streaming, rate limits, download serving
  database.zig   SQLite schema, migration, job transitions
  worker.zig     FIFO queue driver, provider readiness, finalization, cleanup
  download.zig   NZB preflight, article fetch, part storage, assembly
  nzb.zig        libxml2 pull-reader NZB parser
  nntp.zig       Reusable implicit-TLS NNTP session
  yenc.zig       Streaming yEnc decoder and metadata validator
  artifact.zig   Artifact copy/ZIP creation and contained cleanup
  paths.zig      Contained path and symlink checks
```

## Runtime flow

Uploads are admitted by `web.zig` and stored as `PENDING` rows with the NZB
content in SQLite.  `worker.zig` processes only the oldest pending job.  It
parses and preflights the NZB while the row is still `PENDING`; only after that
succeeds does it transition the row to `PROCESSING`.

`download.zig` fetches required `BODY <message-id>` articles through `nntp.zig`.
Article body lines are dot-unstuffed and streamed into `yenc.zig`, which writes
decoded bytes directly to part files under:

```
DOWNLOAD_DIR/.nzbunny-work/<job-id>/<file-index>/
```

After all required ranges are verified, files are assembled below:

```
DOWNLOAD_DIR/.nzbunny-downloads/<job-id>/
```

The worker then moves the row to `FINALIZING`.  Finalizers call `artifact.zig`,
which copies a single file directly or creates one ZIP for several files under
artifact storage.  Completion records the artifact path, size, token, and
expiry.  Expired jobs are cleaned later by the worker.

## State model

Internal states:

```
PENDING -> PROCESSING -> FINALIZING -> COMPLETE
                    \-> FAILED
COMPLETE/FAILED -> EXPIRED
```

The public HTTP API still reports active `PROCESSING` for processing and
finalizing work.  There is no submission state and no external downloader ID.

On startup, schema version 1 rows are migrated to version 2.  Stable terminal
and queued rows are preserved.  Version 1 in-flight rows are converted to
`FAILED` with an operator-facing reupload message.  Native version 2
`PROCESSING` rows are also failed on each startup, and their work/output
directories are removed.  `PENDING` rows remain queued; `FINALIZING` rows resume.

## Provider readiness

Startup loads the system CA bundle and an optional `NNTP_CA_FILE`, then opens
and authenticates one implicit-TLS NNTP session before the HTTP listener starts.
Certificate and host-name verification are always enabled.

`/healthz` is process-local.  `/readyz` requires SQLite readiness and provider
availability.  If a runtime provider operation exhausts retries, the active job
fails, provider readiness becomes false, and queued jobs remain pending.  The
worker probes once per `POLL_INTERVAL` and resumes the queue after a successful
authenticated probe.

## Limits

The NZB parser accepts the standard NZB namespace or no namespace and uses
libxml2's pull reader with network access disabled.  It rejects internal entity
declarations, entity references, password metadata, more than 10000 files, more
than 100000 segments, duplicate or non-contiguous segment numbers, and unsafe
message IDs.

The NNTP reader limits status lines to 8 KiB and body lines to 64 KiB.  yEnc
file names are limited to 255 bytes and may not contain path separators,
control bytes, empty names, `.`, or `..`.  Decoded output size and final
artifact size are both bounded by `MAX_ARTIFACT_BYTES`.

## Deployment

The Compose deployment contains one `nzbunny` service and one persistent
download volume mounted at `DOWNLOAD_DIR`.  That volume contains work files,
assembled output, and artifacts.  No downloader HTTP API or extra downloader
service is deployed.
