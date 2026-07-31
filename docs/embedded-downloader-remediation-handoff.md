# Embedded Downloader Remediation Handoff

This document is the working brief for an agent continuing the embedded
NNTP/NZB downloader toward a release-safe restricted v1. Read it once, then
work the items in the order at the bottom.

## 1. Goal and boundary

Make the in-process downloader production-safe. One Linux process, one NNTP
provider over implicit TLS with host and CA verification, one active FIFO
job, durable finalization, bounded resources, no SABnzbd service.

Supported in this release:

- One provider, implicit TLS, `AUTHINFO USER`/`PASS` (direct `281` and
  `381` then `281`).
- Direct yEnc files described by an NZB, single and multipart.
- One active FIFO job. Up to `NNTP_CONNECTIONS` reusable sessions.
- Existing HTTP routes, public state names, `FINALIZING` mapped to public
  `PROCESSING`.

Explicit non-goals (do not add during remediation):

- SABnzbd API/categories/priorities/history, RSS, watch folders, scripts,
  bandwidth, duplicates, throughput parity.
- Multiple providers, fill servers, provider failover, cross-job pool.
- Plaintext NNTP, STARTTLS, TLS verification bypass.
- User cancel endpoints, progress APIs, segment resume after restart.
- Multiple simultaneously downloading jobs.
- PAR2 repair, archive extraction, password-protected content, base64,
  uuencode, split archives.
- New public HTTP routes or public-state changes.

## 2. Current state (as of the latest commit)

Green:

```
zig fmt --check build.zig src
git diff --check
zig build test
ZIG_GLOBAL_CACHE_DIR=/tmp/nzbunny-zig-global zig build test -Doptimize=ReleaseSafe
python3 tests/integration.py zig-out/bin/nzbunny
```

All five exit 0. Unit and integration suites pass.

Done in the previous commit (Phase 0 + Phase 1):

- `src/shutdown.zig` with `shutdown.requested`, `DownloadControl`,
  `waitForRequest`, deadline watchdog, stream register/unregister.
- NNTP connect/TLS/greeting/auth/BODY/readLine wrapped in `runWithDeadline`
  with `Select` on operation vs timer; on expiry the stream is shut down
  and `NntpOperationTimeout` is returned.
- `web.zig` accept loop and `worker.zig` run loop check `shutdown.requested`.
- `recordSegmentError` calls `control.cancel()` so blocked siblings exit.
- Zero-byte NZB segments and zero-size yEnc are rejected with checked
  arithmetic; regression test in `tests/integration.py`.

Not done. Every item below is a separate fix; do not bundle.

## 3. Open items

Each item shows: ID, evidence (file:line), required end state, required
test. The order in section 5 is the order to do them.

### P0-1: per-operation NNTP deadlines at the socket level

- Evidence: `src/nntp.zig:118-121` calls `HostName.connect` with
  `.timeout = .none`. The outer `runWithDeadline` is the only deadline.
- Required: pass a real `.timeout = .fromSeconds(remaining)` to
  `HostName.connect` and the TLS init, computed from
  `operationTimeoutSeconds()`. Keep `runWithDeadline` for greeting, auth,
  BODY, and readLine; add the same timeout arg where the underlying
  primitive supports it. The `DownloadControl.watch` watchdog stays as the
  job-level ceiling.
- Test: in `tests/integration.py`, add a fake-server "stall after TLS
  handshake, before greeting" mode. Submit a job with `NNTP_TIMEOUT=2`.
  Assert failure within ~3s (not `DOWNLOAD_TIMEOUT`) and no work/output
  files remain.

### P0-4: job-level first-part preflight scheduler

- Evidence: `src/download.zig:53-59` fetches file 0 end-to-end before file
  1's first segment. `src/download.zig:140-179` schedules later parts only
  after file 0's first part. A bad first part of file N surfaces only
  after N-1 files complete.
- Required: queue segment 1 of every NZB file in a job-level work queue
  with up to `NNTP_CONNECTIONS` fixed workers. Each worker owns one
  reusable session (see P1-2). After every first part is validated (name
  safety, declared vs decoded size, part number, range, multipart
  metadata), validate aggregate size, duplicate names, supported set
  (PAR2, split archive). Only then queue all remaining parts globally. On
  any first-part failure, zero requests for any segment 2+. Build a
  bounded job manifest that keeps metadata only; article bodies and
  decoded files stay streamed.
- Test: multi-file NZB where file 0 first part is `222` and file 1 first
  part is `430`. Assert no `BODY` request for any segment 2+ and the job
  fails within `DOWNLOAD_TIMEOUT`.

### P0-5: pre-write size budgets

- Evidence: `src/download.zig:48-58` (artifact cap checked after each
  file's parts are written); `src/yenc.zig:87-104` (decoded bytes written
  during yEnc); `src/artifact.zig:87-124` (ZIP envelope checked only
  after libarchive writes).
- Required:
  1. Reject a yEnc full size greater than `MAX_ARTIFACT_BYTES` before any
     decoded byte.
  2. For multi-file ZIP, compute a conservative envelope (local headers,
     central directory, end records, ZIP64, bounded name lengths and
     count) and require `sum(decoded source sizes) + envelope <=
     MAX_ARTIFACT_BYTES` before any non-first-segment BODY request.
  3. Replace unbounded `archive_write_open_fd` with a bounded write
     callback that rejects each write before exceeding the cap. A
     post-write `fstat` is defense in depth, not the primary guard.
  4. Give the yEnc decoder a per-part/range write budget so a malformed
     body cannot exceed its approved range even if metadata checks miss.
- Test: a multi-file source that fits the decoded-source cap but whose
  bounded ZIP envelope would exceed `MAX_ARTIFACT_BYTES` is rejected
  before any segment 2+ request. A second fixture proves the bounded
  archive writer rejects an unexpectedly large entry before it crosses
  the output cap.

### P0-6: finalizer UAF

- Evidence: `src/worker.zig:33-49` stores `task.id` as a map key;
  `src/worker.zig:240-246` frees it. The in-memory map can outlive the
  task.
- Required: stop storing freed keys. Move finalizer retry state to
  SQLite (see P6 in the deferred work below). As an immediate shape
  change here, do not key the in-memory active set by the task ID
  pointer; use the job ID value and remove the entry only after the task
  has joined.
- Test: a deterministic artifact failure followed by recovery. No UAF,
  no leaked in-memory entry, durable retry, eventual `COMPLETE`. Run
  under a debug allocator if feasible.

### P0-7: signal handlers + interruptible listener

- Evidence: `src/shutdown.zig:5-13` defines `installSignalHandlers`; it
  is not called from `src/root.zig`. The HTTP `accept()` blocks on
  shutdown, so SIGTERM cannot exit the process.
- Required:
  1. Call `shutdown.installSignalHandlers()` during startup.
  2. Make the HTTP listener's `accept()` interruptible. Wrap accept in a
     `Select` with `shutdown.requested` (poll the flag) or a self-pipe,
     so SIGTERM breaks the accept loop and the process exits within ~1s.
  3. Keep `web.zig` and `worker.zig` checks of `shutdown.requested`.
- Test: a Python subprocess harness in `tests/integration.py` that spawns
  `nzbunny`, submits a job whose fake-server body stalls, sends SIGTERM,
  asserts clean shutdown within 2s, no orphaned work/output files, and
  SQLite state is deterministic for restart (job marked `FAILED` with a
  reupload message).

### P1-1: typed response classification

- Evidence: `src/nntp.zig:78-80` treats `400` as `NntpTransientResponse`,
  `430` as `MissingArticle`, anything else `>= 400` as
  `PermanentNntpResponse`. No typed enum, no documented policy.
- Required: replace the inline checks with a `Response` tagged enum and a
  classification function. Policy:

  | Outcome | Classification | Action |
  |---|---|---|
  | `430` missing article | permanent per-article | no retry, no readiness loss |
  | `400` service unavailable | transient provider | retry with bounded backoff, then mark provider unavailable |
  | connect reset/refused/unreachable/timeout | transient transport | retry with bounded backoff, then mark provider unavailable |
  | TLS trust/host-name failure | permanent configuration | no retry loop |
  | AUTHINFO failure | permanent account | no retry loop |
  | framing/line limit/protocol error | permanent protocol | no retry |
  | other `5xx`/unsupported command | permanent protocol | no retry unless tested |

  Retry delays must be interruptible and capped by the remaining job
  deadline. A 1/2/4-second backoff is the starting policy once it cannot
  sleep past cancellation/deadline. `provider_ready = false` only after
  retryable failures exhaust; `430`, certificate error, corrupt yEnc, or
  bad NZB must not falsely report the provider down.
- Test: `400` once then `222` (reconnect/backoff and completion);
  repeated `400` to exhaustion (`/readyz == 503`, FIFO preserved,
  authenticated `DATE` probe restores readiness, FIFO resumes); `430`
  (no retry, no readiness loss).

### P1-2: session reuse per fixed worker

- Evidence: `src/download.zig:284-296` makes a new session per segment.
  Each segment pays connect + TLS + auth.
- Required: construct at most one session per worker. Reuse it across
  successful `BODY` requests. On a retryable transport/session outcome,
  `abort()` then `deinit()`, reconnect, re-authenticate, then retry. Do
  not reuse after an ambiguous failed body request. Never exceed
  `NNTP_CONNECTIONS` during startup probing, active work, or retry.
- Test: handshake and AUTHINFO counters across many segments. One
  connection per worker, not per segment. Run with
  `NNTP_CONNECTIONS=1` and assert exactly one live session at a time;
  run with `NNTP_CONNECTIONS >= 2` and assert
  `1 < observed <= NNTP_CONNECTIONS`.

### P1-3: separate cleanup policies

- Evidence: `src/database.zig:236-258` selects `PENDING`/`PROCESSING`/
  `FINALIZING` by `created_at`.
- Required policies:

  | State | Owner / cleanup |
  |---|---|
  | `PENDING` | retain in FIFO queue; no age-based expiry |
  | `PROCESSING` | active downloader/deadline/cancel; on restart convert to `FAILED` and clean job paths |
  | `FINALIZING` | durable finalizer lease; generic cleanup must not delete source or mark expired |
  | `COMPLETE` | artifact expiry at `expires_at`; safe delete and transition to `EXPIRED` |
  | `FAILED` | retention by `updated_at` per documented policy |
  | `EXPIRED` | purge after documented terminal retention |

  Update `Database.listCleanup` and its call sites so names/parameters
  reflect this. Remove age-based destructive selection of `PENDING`,
  active `PROCESSING`, and `FINALIZING`.
- Test: set `RETENTION_TTL` shorter than a simulated provider outage.
  Submit multiple jobs. Verify all remain `PENDING` and complete in
  original FIFO order after recovery.

### P1-4: full crash and startup cleanup

- Evidence: `src/worker.zig:335-342` does not remove
  `.nzbunny-downloads/.tmp-<job-id>`.
- Required: for terminal, failed, canceled, and interrupted `PROCESSING`
  jobs, remove all three per-job roots:

  ```
  .nzbunny-work/<job-id>
  .nzbunny-downloads/<job-id>
  .nzbunny-downloads/.tmp-<job-id>
  ```

  For a valid claimed or resumable `FINALIZING` job, preserve its
  `download_path`; remove only demonstrably stale temporary roots that
  are not the source and not a live lease-token-scoped artifact temp.
- Test: force interruption during assembly of a `PROCESSING` job; verify
  restart removes work, final, and `.tmp-<job-id>` roots. Restart with a
  valid `FINALIZING` job; verify its final source remains and finalizes
  to `COMPLETE`; only stale temporary roots are removed.

### P1-5: multipart yEnc part mapping and CRC policy

- Evidence: `src/yenc.zig:68-70` parses `part` and discards it;
  `src/download.zig:210-215` compares the multipart full-file `crc32`
  against an individual part.
- Required:
  1. yEnc `part` must equal the NZB segment number. Reject swapped,
     duplicate, missing, or out-of-range parts even when byte ranges
     happen to be contiguous.
  2. For single-part, validate optional `crc32` against the decoded file.
  3. For multipart, validate optional `pcrc32` against that part.
  4. A multipart `crc32` is the full-file CRC. Validate it after ordered
     assembly. Do not compare a whole-file CRC to a single part.
  5. `total=` is required and consistent (positive, stable, equal to
     NZB segment count). Legacy multipart without `total=` may be
     accepted only if every yEnc part maps exactly to the corresponding
     NZB segment number and the NZB proves the complete `1..N` set. Do
     not accept a mix of present and absent `total=` for one file.
  6. Missing optional CRC fields are acceptable; mismatches are not.
- Test: table-driven vectors for each of the above. Out-of-order worker
  completion still produces deterministic final assembly.

### P1-6: no-follow downloader paths

- Evidence: `src/download.zig:405-413` uses path-string `createDirPath`
  and `deleteTree`. `src/artifact.zig` already uses
  descriptor-relative/no-follow.
- Required: open `DOWNLOAD_DIR` once as a pinned no-follow root
  descriptor. Under it, create, open, and remove all of these through
  descriptor-relative operations (extend helpers in `src/artifact.zig`
  and `src/paths.zig`):

  ```
  .nzbunny-work/<job-id>/<file-index>/<part>.part[.tmp]
  .nzbunny-downloads/<job-id>/...
  .nzbunny-downloads/.tmp-<job-id>/...
  ```

  Reject symlink or special-file substitutions at every component. Keep
  created part and output files `0600`.
- Test: pre-create symlinks at `.nzbunny-work`, `.nzbunny-downloads`,
  job, part, and temp components. Startup, run, and cleanup must reject
  them without reading, writing, or deleting outside `DOWNLOAD_DIR`.

### P1-7: finalizer task lifecycle

- Evidence: `src/worker.zig:27-31` cancels its group then deinits maps
  without an explicit join. Active tasks can still reference owner
  state.
- Required: worker and finalizer task groups are joined before their
  owners, maps, allocators, or context are released. In-memory active
  sets own distinct keys and free or remove them only after the task
  has joined. Never rely on a freed task ID as a map key.
- Test: force a finalizer to run concurrently with a cleanup-eligibility
  scan. Assert no UAF and no use of a cleared map.

### P2-1: NZB parser structural state

- Evidence: `src/nzb.zig:130-234` infers structure from a local element
  name and a broad `in_file` flag. It rejects all foreign namespaces
  including harmless `<head>` extensions, and rejects empty password
  metadata at element start rather than after seeing content.
- Required: explicit structural parse state. Accept the standard NZB
  namespace and no namespace for structural elements (`nzb`, `file`,
  `segments`, `segment`, and supported `head`/`meta` behavior). Safely
  ignore foreign non-structural metadata inside `<head>`. Reject
  foreign substitutions of structural elements. Reject zero, duplicate,
  non-contiguous, overflowed, or otherwise invalid `number` and `bytes`
  with line and column diagnostics. Treat `meta type="password"`
  case-insensitively as protected only when its text is nonempty after
  whitespace trimming, by waiting for its content rather than rejecting
  only at start. Continue to forbid external network access, entity
  expansion, unsafe DTD behavior, malformed entity references, and
  oversized file or segment sets.
- Test: standard namespace, no namespace, wrong structural namespace,
  safely ignored foreign head metadata, namespace shadowing, malformed
  nesting, entity attempts, entity references, limits, numeric overflow,
  zero bytes, duplicate or non-contiguous numbers, message-ID limits,
  empty/whitespace/nonempty password metadata, and diagnostics.

### P2-2: token-aware yEnc field parsing

- Evidence: `src/yenc.zig:163-168` stops `name=` at the first space and
  does not robustly model duplicate or multipart metadata.
- Required: token-aware field parsing at valid field boundaries. Reject
  duplicate recognized fields. Preserve a valid `name=` through the rest
  of the `=ybegin` line; the yEnc filename is the final field. Continue
  rejecting unsafe names (empty, too long, separators, NUL/control,
  `.`, `..`). Model single-part and multipart metadata explicitly. Do
  not use `part = 0` as an implicit state without validating it. For
  multipart, require a positive yEnc `part`, a matching `=ypart`, valid
  inclusive `begin`/`end`, and coherent name and full-size metadata.
  Validate all range and decoded-size arithmetic with checked helpers
  before writing or returning metadata. On decoder failure, free the
  owned name; on success transfer it exactly once to the caller. Audit
  all error paths.
- Test: escaped bytes, names with spaces, unsafe names, duplicate
  fields, truncated headers/trailers, duplicate `=ypart`, single vs
  multipart rule violations, missing/inconsistent `total`, invalid
  ranges, and part-number mismatch.

### P2-3: artifact publication durability

- Evidence: artifact publication in `src/artifact.zig` lacks an explicit
  directory-sync audit; finalizer temp cleanup policy is undocumented.
- Required durability order for artifact publication:

  1. Write the lease-token-scoped temporary artifact.
  2. fsync the temp file.
  3. Atomically rename it to its final name.
  4. fsync the containing artifact directory where supported.
  5. Only then record `COMPLETE` in SQLite using the active finalizer
     claim.

  Define cleanup for stale, lease-token-scoped artifact temporary files
  without racing a live, renewing, or resumable finalization claim.
- Test: kill the process during finalization. Restart resumes from a
  valid lease; stale temp is cleaned; a live finalizer is not preempted.
  Existing artifact-after-rename/before-DB-complete recovery stays
  idempotent.

### P2-4: configuration and residual scan

- Evidence: `.env.example` still contains SAB variables; `ARCHITECTURE.md`
  and `docs/` are now tracked.
- Required:
  1. `.env.example` lists only the supported env vars:
     `NNTP_HOST`, `NNTP_PORT`, `NNTP_USER`, `NNTP_PASS`,
     `NNTP_CONNECTIONS`, `NNTP_TIMEOUT`, `NNTP_CA_FILE`,
     `DOWNLOAD_DIR`, `DOWNLOAD_TIMEOUT`, `DB_PATH`, `RETENTION_TTL`,
     `CLEANUP_INTERVAL`, `POLL_INTERVAL`, `HTTP_HEADER_TIMEOUT`,
     `HTTP_REQUEST_TIMEOUT`, `MAX_ARTIFACT_BYTES`, `MAX_UPLOAD_BYTES`,
     `MAX_ACTIVE_JOBS`, `MAX_CONNECTIONS`, `UPLOADS_PER_MINUTE`,
     `TRUSTED_PROXY_CIDRS`. Remove `SABNZBD_*`.
  2. Update `readme.txt`, `ARCHITECTURE.md`, `docs/embedded-downloader-plan.md`,
     and `docs/embedded-downloader-remaining.md` to describe the
     restricted-v1 boundary, verified TLS/CA/hostname behavior, timeout
     semantics, one active FIFO job, bounded worker sessions, global
     first-part preflight, retry and provider-readiness policy, shutdown
     behavior, restart behavior, and finalization recovery. Correct any
     claim that all release work is done. State that `RETENTION_TTL`
     applies to completed artifacts, not queued uploads.
  3. Expand the residual SAB scan in `tests/integration.py` to include
     `.env.example`, active user docs, deployment, source, and tests.
     Permit only explicitly documented historical migration references
     where necessary. No active SAB configuration, service, HTTP call,
     or runtime dependency.
  4. `zig fmt` changed Zig files. `git diff --check` clean. Track
     intended docs; do not ship `tests/__pycache__/`.

### P6 (deferred phase, required by P0-6 and P1-7): durable finalizer

A separate piece of work, called out because P0-6 and P1-7 are not
releaseable without it.

- Required: schema migration (v2 to v3) with
  `finalize_attempts`, `finalize_next_at`, `finalize_lease_until`,
  `finalize_lease_token` (opaque random per claim). Atomically claim a
  due `FINALIZING` job when no unexpired lease exists. Persist the
  token, assign a bounded lease, and use the token in task-specific
  artifact temporary names so an old owner cannot reuse or remove a
  newer owner's temp. Renew the lease well before expiry; on renewal
  failure, begin cancellation and stop using the source. Release the
  matching-token lease on transient failure and schedule bounded
  backoff. On startup, reclaim only stale leases. Require `complete`,
  retry release, lease renewal, and cleanup-eligibility updates to
  compare `(id, status='FINALIZING', finalize_lease_token)`. Do not
  mark a job failed merely because it retried three times in one
  process. Verify v1 to current and v2 to current migration fixtures
  with real SQLite databases. Inject a migration failure and prove
  rollback leaves the old database usable. Document that production
  rollback restores a tested backup, not an automatic downgrade.
- Test: deterministic artifact failure followed by recovery; restart
  between attempts resumes; slow finalizer plus cleanup preserves
  source; forced lease expiry and reclaim with the original finalizer
  delayed; only the current token may publish and complete; migration
  rollback.

### Phase 7 (deferred, required by P0-7 and P1-3 end-to-end)

- When `provider_ready` is false, probe on `POLL_INTERVAL` with an
  authenticated, deadline-aware `DATE`; leave queued jobs untouched and
  in FIFO order; resume only after a successful probe.
- Map typed downloader outcomes to stable public messages without
  exposing credentials, article content, or internal paths:
  processing deadline exceeded, provider unavailable after retries,
  unsupported or corrupt NZB or article, artifact finalization issue.
- `/healthz` stays process-local. `/readyz` requires both DB readiness
  and provider readiness. A provider outage must not make `/healthz`
  fail.
- Validate `DOWNLOAD_DIR` absolute if that is the operator contract.
  Validate optional CA file errors safely. Preserve CR/LF/NUL rejection
  for NNTP configuration strings.

## 4. Test strategy

The Python integration server in `tests/integration.py` is the base.
Extend it; do not fork a second protocol harness.

Fake-server modes the server must expose (one per scenario):

- greetings `200` and `201`;
- direct and two-step authentication, rejection, stalled auth;
- one-time and repeated `400`, `430`, selected 5xx, disconnect/reset,
  and malformed replies;
- fragmented output, bad CRLF, oversized status and body lines, no
  terminator, mid-line and mid-body stalls;
- certificate trust failure and hostname failure;
- `BODY` request order, request count, concurrent connections, TLS
  handshakes, authentication count;
- controlled release of a blocked request to prove cancellation.

Every integration scenario uses fresh server state, a fresh DB/root
where isolation matters, and its own bounded test timeout. A test that
hangs is itself a failure.

Unit-level coverage targets:

- Config: duration bounds, absolute root policy, NNTP input safety,
  CA-file failures, connection count bounds.
- NZB parser: namespace and state matrix, entities and DTD, limits,
  overflow, zero values, password metadata, diagnostics, message IDs.
- yEnc: header/trailer grammar, names with spaces, duplicate fields,
  escapes, range math, multipart mapping, CRC vectors, ownership and
  error cleanup.
- NNTP: status parser and framing, command limits, typed error
  classification, deadline calculation, idempotent abort behavior
  where mockable.
- Scheduler: first-part barrier, decoded-source and ZIP-envelope
  reservation, no-later-part-on-preflight-failure, cancellation claim
  stop, session reuse policy, and both one-connection and
  multi-connection bounds.
- Paths and artifacts: descriptor-relative no-follow traversal,
  symlink and special-file rejection, cleanup containment, bounded
  archive writer, and output/artifact durability order.
- Database: state CAS, cleanup selection, queue retention, lease
  token, renewal, fencing, retry, v1/current migration, and rollback on
  migration failure.

Required end-to-end scenarios:

1. Direct single-file download and artifact retrieval.
2. Multi-file ZIP download and correct content.
3. Global first-part barrier and decoded-source/ZIP-envelope cap
   rejection with zero later `BODY` requests; bounded archive output
   rejects before crossing its output cap.
4. Transient provider error, reconnect, recovery; retry exhaustion;
   readiness loss; recovery.
5. Permanent missing article and all-or-nothing cleanup.
6. Fast terminal error plus stalled sibling cancellation.
7. Malformed, oversized, or stalled NNTP response deadline behavior.
8. Multipart yEnc ranges, part mapping, `pcrc32`, and full-file
   `crc32`.
9. Provider outage longer than artifact retention preserves queued FIFO
   jobs.
10. Finalizer transient failure, durable retry, restart recovery,
    lease-token renewal and reclaim fencing, no cleanup race.
11. v1 to current schema migration and interrupted processing restart
    cleanup.
12. SIGTERM during a delayed active download.
13. Symlink and path-component attack attempts against every
    downloader-owned managed tree.
14. Log-redaction scan for passwords, article content, sensitive IDs
    and tokens as appropriate, and temporary work paths.
15. Compose config and container image startup using the fake CA and
    provider.

Real-provider smoke test before release. Record only safe metadata.
Verify CA chain and hostname validation; direct and multi-part real
articles of representative size; session reuse and reconnect behavior;
provider response behavior relevant to the configured retry table;
readiness failure and recovery; and no credentials, payload, or work
paths in collected logs.

## 5. Implementation order

Each step keeps `zig fmt --check build.zig src`, `git diff --check`,
and `zig build test` green. Do not merge an incomplete transport,
migration, or path-hardening change without its focused regression test.

1. P0-1 + P1-1 in `src/nntp.zig`. Per-op deadlines plus typed response
   classification share a transport rewrite. Add the fake-server stall
   modes required for P0-1 and the transient response modes for P1-1.
2. P0-4 + P0-5 in `src/download.zig`. Job-level manifest, fixed
   session-owning workers, per-part write budget, bounded archive
   writer.
3. P0-6 + P1-7 + P2-3 + P6. Durable finalizer in SQLite, lease
   token, renewal, reclaim fencing, no freed keys, joined task
   groups, artifact publication durability.
4. P1-3 + P1-6 + P1-4. Cleanup separation in `src/database.zig`,
   no-follow helpers in `src/paths.zig`, full crash and startup
   cleanup.
5. P0-7 + Phase 7 readiness and shutdown wiring. Signal handler
   installation, interruptible HTTP listener, queue pause, probe
   recovery, mapped public errors.
6. P2-1 + P2-2 with unit vectors.
7. P2-4: `.env.example`, `readme.txt`, `ARCHITECTURE.md`, plan and
   remaining-work registers, expanded residual scan, formatting and
   clean tree.
8. Release qualification: full fault-injection suite, container
   build, real-provider smoke test, release evidence (commit SHA,
   image digest, schema version, test date, env var names only).

## 6. Coding rules for the work

- No docstrings. Comments only where the logic is not self-evident.
- No abstraction without concrete need. Keep code straightforward.
- No em-dash characters in any output (code, docs, commits, logs).
- Early returns and guard clauses over deep nesting.
- Fail fast and visibly. Error messages name the failure and reason.
- Keep data and behavior separate. Pair simple data structures with
  straightforward functions.
- Drastically minimize tests. Cover only complex, critical, high-risk
  edge cases. Do not chase 100% coverage or test framework features.

## 7. Release gate

Do not mark production-ready until:

- Every P0 is fixed with a regression test that ran green.
- Every P1 is fixed, or an explicit written risk acceptance from the
  owner is attached.
- Residual SAB scan covers `.env.example`, docs, deploy, source, and
  tests. Only documented historical migration references remain.
- `zig fmt --check build.zig src`, `git diff --check`, `zig build test`,
  `zig build test -Doptimize=ReleaseSafe`, and
  `python3 tests/integration.py zig-out/bin/nzbunny` all exit 0.
- Docker image builds and starts as the intended non-root user against
  a controlled provider and passes upload, download, readiness, and
  shutdown tests.
- Real-provider smoke test evidence is attached.
- Release evidence includes commit SHA, image digest, schema version,
  test date, commands, and env var names only. No secret values.
