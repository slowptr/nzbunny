# Embedded NNTP Downloader Plan

Implementation status and the complete remaining-work register are in
`docs/embedded-downloader-remaining.md`.

## Objective and release boundary

Replace SABnzbd and its HTTP API with one in-process downloader in one release. The downloader supports one NNTP provider, direct yEnc payloads, and one active FIFO job. It keeps every existing HTTP route and public job state. There is no backend feature flag and no compatibility path through SABnzbd.

The protocol basis is:

- [NZB 1.1](https://sabnzbd.org/wiki/extra/nzb-spec)
- [RFC 3977: Network News Transfer Protocol](https://www.rfc-editor.org/rfc/rfc3977.html)
- [RFC 4643: NNTP Authentication](https://www.rfc-editor.org/rfc/rfc4643.html)
- [yEnc draft 1.3](https://sources.debian.org/src/python-yenc/0.4.0-10/doc/yenc-draft.1.3.txt)

Version 1 explicitly does not support password-protected input, PAR2 repair, archive extraction, split archives, base64, uuencode, STARTTLS, fill servers, user cancellation, progress APIs, or interrupted-part resume. A single `.zip`, `.7z`, or `.rar` file is an ordinary direct output when it has no companion volume.

## Runtime model

The process admits uploads as it does now and stores jobs in SQLite. Jobs wait in `PENDING` in creation order. Only the oldest pending job may become active. Parse and preflight that job while it remains `PENDING`; transition it to `PROCESSING` only when preflight succeeds.

For the active job, start `NNTP_CONNECTIONS` segment workers. Each worker owns and reuses one authenticated TLS session. Do not add a general connection-pool abstraction. Fetch segment 1 of every NZB file before scheduling the remaining segments so its yEnc metadata establishes the output name, full size, part count, and byte ranges. Later parts may finish out of order.

One required part failing permanently fails the whole job and cancels the other workers. Publish no partial artifact. A runtime provider failure that exhausts its retries also makes provider readiness false; queued jobs remain `PENDING`. Probe once per `POLL_INTERVAL` and resume the queue only after an authenticated probe succeeds.

`DOWNLOAD_TIMEOUT` begins at the `PROCESSING` transition. Queue and preflight time do not count. On restart, fail every native `PROCESSING` job and delete its work and output directories. Preserve `PENDING` jobs and resume `FINALIZING` jobs.

## Module contracts

### `src/nzb.zig`

Use the libxml2 pull reader through `xmlReaderForMemory`. Return files containing ordered `Segment` values:

```zig
pub const Segment = struct {
    number: u32,
    declared_bytes: u64,
    message_id: []const u8,
};

pub const File = struct {
    segments: []Segment,
};

pub const Nzb = struct {
    files: []File,
};
```

The returned model owns normalized message IDs and all storage needed after the upload buffer is released. Normalization removes one optional surrounding `<` and `>` pair; the NNTP layer adds angle brackets exactly once when it formats `BODY`.

Parser rules:

- Enable non-network parsing. Do not enable entity substitution, DTD loading, validation, XInclude, recovery, or huge-input mode.
- Accept the standard external `DOCTYPE` without loading it. Reject internal entity declarations and entity-reference nodes. Follow libxml2's untrusted-input guidance.
- Accept the standard NZB namespace or no namespace. Reject a different namespace on structural NZB elements.
- Read the message ID from the text content of `<segment>message-id</segment>`; do not require a nested `<message-id>` element.
- Ignore poster, date, subject, groups, unknown head metadata, and ignorable whitespace.
- Reject a non-empty `<meta type="password">` value, case-insensitively for the type.
- Require at least one file and one segment per file. Permit at most 10,000 files and 100,000 total segments.
- Parse positive `bytes` and `number` attributes without truncation. Reject zero, duplicate, or non-contiguous numbers. Sort by number only after proving uniqueness; the final order must be `1..n`.
- Reject empty message IDs, whitespace or control bytes in them, and IDs that would make `BODY <message-id>\r\n` exceed the RFC 3977 512-byte command limit.
- Report structural and value errors with libxml2 line and column information.

Link libxml2 via `pkg-config`. Add `libxml2-dev` to the container build stage and `libxml2` to the runtime stage.

### `src/nntp.zig`

Own one reusable implicit-TLS session and expose:

```zig
pub const Session = struct {
    pub fn connect(...) !Session;
    pub fn probe(self: *Session) !void;
    pub fn requestBody(self: *Session, message_id: []const u8) !void;
    pub fn readBodyLine(self: *Session, buffer: []u8) !?[]const u8;
    pub fn deinit(self: *Session) void;
};
```

`connect` performs DNS resolution, TCP connection, TLS handshake, host-name and certificate verification, greeting validation, and authentication. It accepts greetings `200` and `201`. Send `AUTHINFO USER`; accept `281`, or send `AUTHINFO PASS` only after `381` and then require `281`. Never log the password or include it in an error.

Use implicit TLS, normally on port 563. There is no plaintext, STARTTLS, or verification-disable mode. Load the system CA bundle at process startup and append certificates from `NNTP_CA_FILE` when configured. Before starting the HTTP listener, create and authenticate one session; exit on DNS, TCP, TLS, certificate, host-name, greeting, or authentication failure.

`probe` establishes an authenticated session if necessary and proves provider availability without retrieving an article. `requestBody` sends `BODY <normalized-id>` and requires `222`. Do not send `GROUP` and do not retrieve headers. `readBodyLine` streams the RFC 3977 multi-line block, recognizes a line containing only `.`, and removes one leading dot from dot-stuffed lines.

Limit status lines to 8 KiB and body lines to 64 KiB, including protocol framing. Treat overlong lines, malformed status codes, invalid CRLF framing, unexpected responses, and malformed termination as protocol errors. Do not expose a whole-article API.

### `src/yenc.zig`

Consume unstuffed NNTP body lines and stream decoded bytes to a caller-owned file. Return:

```zig
pub const Metadata = struct {
    name: []const u8,
    full_size: u64,
    part_number: ?u32,
    begin: u64,
    end: u64,
    pcrc32: ?u32,
    crc32: ?u32,
};
```

Require one valid `=ybegin` and one matching `=yend`. Require `=ypart` for multipart data and reject it for a declared single-part file. The decoder subtracts 64 from an escaped encoded byte, then subtracts 42 from every encoded byte, all modulo 256. It writes incrementally and computes CRC32 while writing.

Validate declared file size, part number, per-part decoded size, inclusive `begin` and `end`, `yend size`, and consistent metadata across every part. A CRC is optional. Verify `pcrc32` against a multipart part and `crc32` against a complete single-part file whenever present. Reject duplicate metadata fields and numeric overflow.

Names are at most 255 bytes and must be non-empty UTF-8 or opaque non-control bytes suitable for a Linux filename. Reject `/`, `\\`, NUL, all control bytes, `.`, and `..`. The download layer performs case-insensitive duplicate-name checks.

### `src/download.zig`

Preflight an NZB, run segment workers, assemble verified files, and return one contained output path. It must not read or update SQLite.

Its input includes the parsed NZB, provider/TLS configuration, job ID, download root, maximum artifact bytes, absolute processing deadline, and a cancellation signal. Its successful result is a path beneath the configured download root: the file path for one output, or a directory path for several outputs.

Preflight and execution rules:

1. Validate all static NZB limits before creating work.
2. Fetch segment 1 of each file serially or within the worker bound before other segments.
3. Establish and cross-check yEnc name, full size, multipart status, part number, and byte range.
4. Reject password metadata, `.par2`, and known split-volume patterns: `.partNN.rar`, `.rNN`, `.zNN`, `.7z.NNN`, or a numbered multi-file sequence. Matching is case-insensitive. Reject case-insensitive duplicate output names.
5. Sum established decoded full sizes with checked arithmetic and reject a sum greater than `MAX_ARTIFACT_BYTES` before scheduling remaining parts.
6. Store each verified decoded part beneath `DOWNLOAD_DIR/.nzbunny-work/<job-id>/<file-index>/` using a temporary file followed by rename.
7. Retry retryable part failures three times after the initial attempt, with delays of 1, 2, and 4 seconds. Reconnect and authenticate before every retry. Retry timeouts, disconnects, transient server responses, and CRC mismatches. Treat `430` as permanent. Never retry authentication, certificate, host-name, input, or protocol errors.
8. Assemble files by validated inclusive yEnc ranges. Reject gaps, overlaps, duplicates, range overflow, and final-size mismatches. Stream parts into outputs beneath a job-specific temporary directory in `DOWNLOAD_DIR/.nzbunny-downloads`.
9. Flush every output file and the containing directory, then atomically rename the job directory into its final location. For a single file, return the contained file path; for multiple files, return the directory.
10. On any failure or cancellation, stop scheduling, signal all workers, join them, close sessions and files, and remove every part and job output. Return no path.

The segment scheduler holds bounded metadata only. Article bodies, decoded parts, assembled files, and final artifacts are always streamed; never allocate a complete article or output file in memory.

### `src/worker.zig`

Own provider availability, FIFO queue selection, database transitions, download invocation, artifact finalization, and cleanup. `download.zig` reports typed outcomes; the worker maps them to stable public failure messages and state transitions.

The successful path is:

```text
PENDING -> PROCESSING -> FINALIZING -> COMPLETE
```

Parsing or preflight failure transitions directly from `PENDING` to `FAILED`. Download failure transitions from `PROCESSING` to `FAILED`. Artifact failure remains resumable in `FINALIZING` according to the current artifact policy. Expiry continues to transition terminal jobs to `EXPIRED` and removes their stored artifact.

The current artifact layer copies one returned file directly. For a returned directory, it creates one ZIP by streaming directory entries. Re-apply `MAX_ARTIFACT_BYTES` to bytes read and written during finalization, regardless of the preflight sum.

## Configuration

Remove:

- `SABNZBD_URL`
- `SABNZBD_API_KEY`
- `SABNZBD_DOWNLOAD_DIR`
- `SABNZBD_REQUEST_TIMEOUT`

Add:

| Variable | Required/default | Validation |
|---|---|---|
| `NNTP_HOST` | required | non-empty; no NUL, CR, or LF |
| `NNTP_PORT` | `563` | integer `1..65535` |
| `NNTP_USER` | required | non-empty; no NUL, CR, or LF |
| `NNTP_PASS` | required | non-empty; no NUL, CR, or LF; never logged |
| `NNTP_CONNECTIONS` | `4` | integer `1..16` |
| `NNTP_TIMEOUT` | `30s` | positive duration representable by runtime timers |
| `NNTP_CA_FILE` | optional | no NUL, CR, or LF; readable regular file |
| `DOWNLOAD_DIR` | required | absolute directory path |
| `DOWNLOAD_TIMEOUT` | `2h` | positive duration representable by runtime timers |

Keep `POLL_INTERVAL`; it becomes both the queue polling and unavailable-provider probe interval. Keep all HTTP, retention, admission, upload, artifact, and `MAX_ARTIFACT_BYTES` settings. Reject NUL, CR, and LF in every NNTP configuration string. Error messages may name a bad variable but must not echo its value when it can contain credentials.

## SQLite migration and restart behavior

Migrate schema version 1 to version 2 in one transaction:

- Rebuild the jobs table without `sab_name` and `nzo_id` and without `SUBMITTING` in the state constraint.
- Copy version 1 `PENDING`, `FINALIZING`, `COMPLETE`, `FAILED`, and `EXPIRED` rows without changing their public state or artifact fields.
- Convert version 1 `SUBMITTING` and `PROCESSING` rows to `FAILED`. Clear obsolete provider/download fields and set a stable reason such as: `Download was interrupted by the downloader upgrade; upload the NZB again.`
- Preserve identifiers, timestamps, ownership or tokens, upload paths needed for queued jobs, completed artifact paths, expiry data, and failure details for unaffected rows.
- Set `user_version = 2` only after the rebuilt table and indexes are complete. Roll back the entire migration on error.

After migration, every startup transaction converts any native version 2 `PROCESSING` row to `FAILED` with an interrupted-download message. After committing, remove `DOWNLOAD_DIR/.nzbunny-work/<job-id>` and the corresponding temporary output directory for each converted row. Cleanup must use contained-path helpers and tolerate missing paths. Keep `PENDING`; resume `FINALIZING`.

Remove `SUBMITTING` from internal state enums and transitions while keeping all states that the public HTTP API currently returns.

## Readiness, startup, and shutdown

Startup order is: parse configuration, initialize the system and optional CA roots, migrate/open SQLite, clean interrupted jobs, authenticate an NNTP session, start the worker, then bind the HTTP listener. Failure before the listener is fatal and produces a credential-safe diagnostic.

`/healthz` remains process-local. `/readyz` succeeds only when SQLite is usable and provider availability is true. A failed runtime provider operation marks readiness false after its retry policy is exhausted. A successful authenticated probe marks it true. SQLite failure independently keeps readiness false.

On shutdown, stop admission, signal the active job, join segment workers, close TLS sessions, and leave the active database row as `PROCESSING`; the next startup applies the explicit interrupted-download rule. Do not publish or preserve its partial output.

## Deployment and operator migration

Remove SABnzbd and its configuration service from Compose. Keep one persistent download volume mounted at `DOWNLOAD_DIR`; it contains `.nzbunny-work`, `.nzbunny-downloads`, and the existing artifact storage. Expose no NNTP or SAB ports.

Update the environment example, `readme.txt`, `ARCHITECTURE.md`, and deployment instructions with the new variables, required CA behavior, readiness semantics, FIFO/single-job behavior, supported input, retry policy, and restart behavior. Tell upgrading operators to mount the old SAB download volume and set `DOWNLOAD_DIR` to its former root until previously completed artifacts expire. Existing completed links work only when their recorded contained paths remain visible.

## Implementation sequence

1. Repair the baseline: set the `build.zig.zon` fingerprint to `0xc3a1db7964a2eda3`, replace its stale `README.md` package path with `readme.txt`, and record passing Debug and ReleaseSafe tests before downloader changes.
2. Add libxml2 build/container dependencies and implement the bounded parser plus its table-driven tests.
3. Implement yEnc line parsing, streaming decode, metadata/range validation, and vector tests.
4. Implement verified implicit TLS, NNTP authentication, bounded response/body streaming, reconnect behavior, and fake-server tests.
5. Implement the bounded segment scheduler, first-segment preflight, retry classification, assembly, atomic publication, cleanup, and timeout.
6. Add schema version 2, restart cleanup, FIFO transitions, provider readiness/probing, and artifact integration. Remove SAB HTTP code and types.
7. Replace the fake SAB integration server with an implicit-TLS NNTP server and cover the end-to-end lifecycle.
8. Remove SAB deployment/configuration and update operator documentation.
9. Run all acceptance gates and scan for residual active SAB dependencies.

Each step should leave its unit tests passing. Keep changes dependency-ordered so parser, decoder, transport, downloader, persistence, and deployment failures remain separately reviewable.

## Critical tests

Keep the suite focused on release-critical behavior:

- One table-driven NZB suite covers standard external DTD plus namespace, no namespace, malformed structure, wrong namespace, limits, numeric overflow, zero/duplicate/non-contiguous segments, password metadata, internal entities, entity references, and malicious external entities that prove no network or file expansion occurs.
- yEnc vectors cover escaped bytes, single-part data, multipart data delivered out of order, missing optional CRC, valid `pcrc32` and `crc32`, CRC mismatch, truncated input, inconsistent metadata, invalid ranges, gaps, overlaps, and unsafe names.
- One implicit-TLS fake NNTP server uses a test CA through `NNTP_CA_FILE`. It covers `200` and `201` greetings, both valid authentication flows, `BODY`, dot-stuffing, fragmented lines, reconnect, timeout, transient responses, `430`, line limits, certificate rejection, and host-name rejection.
- The fake server records simultaneous requests. Assert observed concurrency is greater than one for a suitable job and never exceeds `NNTP_CONNECTIONS`.
- One end-to-end HTTP lifecycle covers a direct file, a multi-file ZIP, all-or-nothing part failure, expiry cleanup, provider pause and authenticated recovery, version 1 migration, and the interrupted-download startup rule.

## Acceptance gates

Run and record:

```sh
zig fmt --check build.zig src
zig build test
ZIG_GLOBAL_CACHE_DIR=/tmp/nzbunny-zig-global zig build test -Doptimize=ReleaseSafe
python3 tests/integration.py
docker compose -f deploy/docker-compose.yml config
docker build .
```

Also use `rg` across active source, configuration, deployment, tests, and user documentation to confirm no SAB HTTP API dependency or removed configuration remains. Historical migration text may mention SABnzbd where needed.

Acceptance requires all tests to pass, correct version 1 migration, verified TLS and host names on every provider connection, bounded line and metadata handling, no whole-article or whole-output allocation, no partial artifact after failure, FIFO single-job execution with bounded segment concurrency, and a container deployment with no SABnzbd service. The draft's SAB throughput comparison is not a release gate.

## Assumptions

- The service is one Linux process built with Zig 0.16.0.
- The provider supports implicit TLS, `AUTHINFO USER/PASS`, and `BODY` by message ID.
- Uploaded NZBs describe direct yEnc files and obey the supported limits.
- Existing HTTP route shapes and public job states remain compatible even though internal submission and polling disappear.
- Existing completed links remain valid only while the new `DOWNLOAD_DIR` exposes their recorded artifact paths.
- Comments remain rare; implementation errors are specific and credential-safe.
