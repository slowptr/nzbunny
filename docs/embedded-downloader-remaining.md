# Embedded downloader remaining work

This document records the release work that remains after the current embedded
downloader implementation. It is intentionally explicit: passing local unit
tests does not mean that the NNTP replacement is ready for production.

## Current baseline

The current tree contains the in-process configuration, SQLite state changes,
libxml2 NZB parser, yEnc decoder, implicit-TLS NNTP client, download worker,
artifact integration, deployment changes, and operator documentation. The
following local checks pass:

```text
zig fmt --check build.zig src
zig build test
ZIG_GLOBAL_CACHE_DIR=/tmp/nzbunny-zig-global zig build test -Doptimize=ReleaseSafe
python3 tests/integration.py zig-out/bin/nzbunny
docker build -t nzbunny:wrap-up .
```

`docker compose config` requires the deployment's documented `NNTP_HOST`,
`NNTP_USER`, and `NNTP_PASS` variables. Run it with those variables supplied;
the fail-fast behavior is expected when they are absent.

## Remaining implementation work

### 1. Complete protocol and parser hardening

- Add parser diagnostics with libxml2 line and column information.
- Expand NZB tests for malformed structure, wrong namespaces, numeric overflow,
  external entity attempts, limits, and all accepted metadata variants.
- Reject malformed NNTP line framing, including bare line feeds and truncated
  carriage-return sequences, while retaining the existing status and body
  length limits.
- Verify all NNTP response classes and timeout behavior against a controlled
  server, including reconnect and authentication failure handling.
- Extend yEnc validation for duplicate fields, multipart metadata consistency,
  single-part versus multipart rules, truncated input, and the complete CRC
  vector set.

### 2. Make downloading release-safe

- Replace the batch scheduler with bounded worker cancellation: one permanent
  part failure must stop new work, signal active workers, join them, and remove
  all temporary files before returning.
- Enforce `DOWNLOAD_TIMEOUT` during article fetch, retries, assembly, and
  worker waits. The current check occurs after `download.run` returns.
- Verify declared yEnc segment byte counts against downloaded metadata before
  accepting each part.
- Flush containing directories and publish the assembled job directory
  atomically. The current implementation renames individual files beneath an
  already-created job directory.
- Add interrupted shutdown handling so active work is joined and the database
  state follows the documented restart contract.

### 3. Finish worker and persistence behavior

- Make provider probes use the documented availability command and add tests
  for readiness loss, probe recovery, and queued-job preservation.
- Preserve `FINALIZING` jobs when artifact preparation fails, with retryable
  recovery behavior instead of converting them directly to `FAILED`.
- Verify schema version 1 migration with real databases, including rollback on
  migration failure and cleanup of every converted in-flight job.
- Exercise FIFO ordering, one active job, finalizer bounds, expiry cleanup, and
  startup cleanup with concurrent test cases.

### 4. Add the missing integration and acceptance suite

- Replace the current integration script's residual-reference scan with an
  implicit-TLS fake NNTP server using a test CA supplied through
  `NNTP_CA_FILE`.
- Cover both `200` and `201` greetings, both authentication flows, `BODY`,
  dot-stuffing, fragmented responses, reconnects, transient responses, `430`,
  line limits, certificate rejection, and host-name rejection.
- Record observed concurrency and assert it is greater than one for a suitable
  job and never exceeds `NNTP_CONNECTIONS`.
- Cover HTTP upload through completion for one direct file and a multi-file
  ZIP, all-or-nothing failure, expiry, provider pause and recovery, migration,
  and interrupted-download restart behavior.
- Run the acceptance commands with real deployment variables, including
  `docker compose -f deploy/docker-compose.yml config` and a clean container
  build, then record the results in the release handoff.

### 5. Close deployment and operational gaps

- Test a real provider with the required CA chain, hostname verification, TLS
  reconnects, large articles, and provider-specific response behavior.
- Test upgrade behavior with an existing SABnzbd download volume and completed
  artifact rows, confirming old links remain available until expiry.
- Document secret injection and rotation, backup/restore of SQLite plus the
  download volume, log/metric collection, alerting for readiness failures, and
  the rollback procedure.
- Add a production smoke test that proves no NNTP credentials, article data,
  or temporary paths appear in logs.

## Release gate

Do not call the embedded downloader production-ready until sections 1 through 4
are covered by tests and section 5 has been exercised in the target deployment.
The existing implementation is suitable for continued development and local
review, but it has not yet demonstrated the complete live NNTP lifecycle.
