const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const Status = @import("database.zig").Status;
const cleanup = @import("cleanup.zig");
const artifact = @import("artifact.zig");
const download = @import("download.zig");
const nntp = @import("nntp.zig");
const nzb = @import("nzb.zig");
const failure = @import("failure.zig");
const shutdown = @import("shutdown.zig");

const AppState = @import("runtime.zig").AppState;

const Finalizers = @import("finalizer.zig").Manager;

pub fn startup(
    io: std.Io,
    db: *Database,
    root: []const u8,
) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const interrupted = try db.failProcessingOnStartup(io, now);
    defer {
        for (interrupted) |job| job.deinit(db.allocator);
        db.allocator.free(interrupted);
    }
    try db.reclaimAllFinalizingLeases(io, now);
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    try root_dir.deleteTree(io, ".nzbunny-work");
    artifact.sweepOrphanTemps(root);
    for (interrupted) |job| {
        cleanup.workDirs(io, root_dir, job.id) catch |err|
            std.log.err("Job {s} interrupted cleanup failed: {t}", .{ job.id, err });
    }
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
    state: *AppState,
) void {
    var finalizers = Finalizers{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cfg = cfg.finalizer(),
        .root = root,
        .state = state,
    };
    defer finalizers.deinit();
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.concurrent(io, downloadLoop, .{ allocator, io, db, cfg, root, ca_store, state }) catch {
        state.shutdown.requested.store(true, .release);
        return;
    };
    group.concurrent(io, maintenanceLoop, .{ allocator, io, db, cfg, root, state }) catch {
        state.shutdown.requested.store(true, .release);
        return;
    };
    group.concurrent(io, providerLoop, .{ allocator, io, cfg, ca_store, state }) catch {
        state.shutdown.requested.store(true, .release);
        return;
    };
    while (!state.shutdown.requested.load(.acquire)) {
        const jobs = db.listWork(io) catch |err| {
            state.database_ready.store(false, .release);
            std.log.err("Finalizer scheduling failed: {t}", .{err});
            state.shutdown.waitForRequest(io, 1) catch break;
            continue;
        };
        state.database_ready.store(true, .release);
        var admission_ready = true;
        for (jobs) |job| {
            if (job.status == .finalizing) {
                finalizers.schedule(job) catch |err| {
                    admission_ready = false;
                    std.log.err("Job {s} finalizer admission failed: {t}", .{ job.id, err });
                    job.deinit(db.allocator);
                    continue;
                };
            }
            job.deinit(db.allocator);
        }
        db.allocator.free(jobs);
        state.finalizer_admission_ready.store(admission_ready, .release);
        state.shutdown.waitForRequest(io, 1) catch break;
    }
    group.await(io) catch {};
}

fn downloadLoop(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, ca_store: *nntp.CaStore, state: *AppState) void {
    while (!state.shutdown.requested.load(.acquire)) {
        cycle(allocator, io, db, cfg, root, ca_store, state) catch |err| {
            if (failure.isInfrastructure(err)) _ = state.download_deferrals.fetchAdd(1, .monotonic);
            std.log.err("Download scheduling failed: {t}", .{err});
        };
        state.shutdown.waitForRequest(io, cfg.poll_seconds) catch return;
    }
}

fn maintenanceLoop(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, state: *AppState) void {
    while (!state.shutdown.requested.load(.acquire)) {
        const cleanup_errors = cleanup.run(allocator, io, db, cfg, root, std.Io.Clock.real.now(io).toSeconds()) catch |err| blk: {
            std.log.err("Cleanup cycle failed: {t}", .{err});
            break :blk 1;
        };
        _ = state.cleanup_failures.fetchAdd(cleanup_errors, .monotonic);
        _ = state.cleanup_cycles.fetchAdd(1, .monotonic);
        db.maintain(io) catch |err|
            std.log.err("SQLite maintenance failed: {t}", .{err});
        const deadline = shutdown.now(io) + cfg.cleanup_seconds;
        while (!state.shutdown.requested.load(.acquire) and shutdown.now(io) < deadline)
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return;
    }
}

fn providerLoop(allocator: std.mem.Allocator, io: std.Io, cfg: Config, ca_store: *nntp.CaStore, state: *AppState) void {
    while (!state.shutdown.requested.load(.acquire)) {
        // Active downloads supply health evidence without exceeding the provider's
        // configured connection limit. Idle service is probed periodically.
        if (state.active_job_hash.load(.acquire) == 0 and shutdown.now(io) - state.provider_checked.load(.acquire) >= cfg.poll_seconds) {
            probeProvider(allocator, io, cfg, ca_store, state) catch |err| {
                state.provider_ready.store(false, .release);
                if (!state.shutdown.requested.load(.acquire)) std.log.warn("NNTP probe failed: {t}", .{err});
            };
            state.provider_checked.store(shutdown.now(io), .release);
        }
        const deadline = shutdown.now(io) + cfg.poll_seconds;
        while (!state.shutdown.requested.load(.acquire) and shutdown.now(io) < deadline)
            std.Io.sleep(io, .fromMilliseconds(100), .awake) catch return;
    }
}

fn cycle(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, ca_store: *nntp.CaStore, state: *AppState) !void {
    const jobs = try db.listWork(io);
    defer {
        for (jobs) |job| job.deinit(db.allocator);
        db.allocator.free(jobs);
    }
    var pending: ?*const Job = null;
    var pending_count: usize = 0;
    for (jobs) |*job| switch (job.status) {
        .processing => {
            // This loop owns the sole downloader. A PROCESSING row seen here
            // cannot have a live task; reconcile it after any failed error write.
            if (!try db.fail(io, job.id, .processing, "The download was interrupted by a storage failure; upload the NZB again.", std.Io.Clock.real.now(io).toSeconds())) continue;
            var dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
            defer dir.close(io);
            try cleanup.workDirs(io, dir, job.id);
        },
        .pending => {
            if (pending == null) pending = job;
            pending_count += 1;
        },
        else => {},
    };
    if (pending == null or !state.providerAvailable(io, cfg)) return;
    const progressed = try processPending(allocator, io, db, cfg, root, ca_store, state, pending.?.*, std.Io.Clock.real.now(io).toSeconds());
    if (progressed and pending_count > 1) state.shutdown.notifyWorker();
}

fn processPending(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
    state: *AppState,
    job_ref: Job,
    now: i64,
) !bool {
    const job = (try db.getWithContent(io, job_ref.id)) orelse return true;
    defer job.deinit(db.allocator);
    if (job.status != .pending) return true;
    std.log.info("job {s} parsing NZB metadata ({d} bytes)", .{ job.id, job.content.len });
    var diag: nzb.Diagnostic = .{};
    const document = nzb.parseWithDiagnostic(allocator, job.content, &diag) catch |err| {
        if (failure.isInfrastructure(err)) return err;
        const message = "The NZB file is not supported by the embedded downloader.";
        _ = try db.fail(io, job.id, .pending, message, now);
        std.log.warn("job {s} NZB parse failed at line {d}, column {d}: {t}", .{ job.id, diag.line, diag.column, err });
        return true;
    };
    defer document.deinit(allocator);
    state.storage.reserve(io, cfg.max_work_bytes) catch |err| {
        _ = state.download_deferrals.fetchAdd(1, .monotonic);
        std.log.warn("Job {s} download admission deferred: {t}", .{ job.id, err });
        return false;
    };
    defer state.storage.release(io, cfg.max_work_bytes);
    state.provider_gate.lockUncancelable(io);
    defer state.provider_gate.unlock(io);
    if (!state.providerAvailable(io, cfg)) return false;
    if (!try db.beginProcessing(io, job.id, now)) return true;
    errdefer _ = db.fail(io, job.id, .processing, "The download was interrupted by a storage failure.", std.Io.Clock.real.now(io).toSeconds()) catch |err|
        std.log.err("Job {s} failure persistence deferred to reconciliation: {t}", .{ job.id, err });
    state.progress.start(io, 0);
    state.active_job_hash.store(AppState.jobHash(job.id), .release);
    defer state.active_job_hash.store(0, .release);
    std.log.info("job {s} started: {s}", .{ job.id, job.filename });
    const started = shutdown.now(io);
    const deadline = std.math.add(i64, started, cfg.download_timeout_seconds) catch return error.Timeout;
    var control = shutdown.DownloadControl.init(io, deadline);
    control.state = &state.shutdown;
    const result = download.run(allocator, io, root, job.id, document, cfg.download(), ca_store, &control, &state.progress) catch |err| {
        const root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false }) catch null;
        if (root_dir) |dir| {
            defer dir.close(io);
            cleanup.workDirs(io, dir, job.id) catch |cleanup_err|
                std.log.err("Job {s} failed download cleanup deferred: {t}", .{ job.id, cleanup_err });
        }
        if (nntp.isRetryableProviderFailure(err)) {
            state.provider_ready.store(false, .release);
            state.provider_checked.store(shutdown.now(io), .release);
            state.shutdown.wake_worker.store(false, .release);
        }
        const deferred = failure.isInfrastructure(err) and !state.shutdown.requested.load(.acquire);
        const message = failureMessage(if (state.shutdown.requested.load(.acquire)) error.Canceled else err);
        while (true) {
            const saved = (if (deferred)
                db.retryProcessing(io, job.id, std.Io.Clock.real.now(io).toSeconds())
            else
                db.fail(io, job.id, .processing, message, std.Io.Clock.real.now(io).toSeconds())) catch |db_err| {
                state.download_writes_ready.store(false, .release);
                std.log.err("Job {s} failure write will be retried: {t}", .{ job.id, db_err });
                if (state.shutdown.requested.load(.acquire)) return db_err;
                try std.Io.sleep(io, .fromMilliseconds(200), .awake);
                continue;
            };
            if (!saved) return error.JobOwnershipLost;
            state.download_writes_ready.store(true, .release);
            break;
        }
        if (deferred) {
            _ = state.download_deferrals.fetchAdd(1, .monotonic);
            std.log.warn("Job {s} download deferred after infrastructure failure: {t}", .{ job.id, err });
        } else std.log.err("job {s} download failed: {s} ({t})", .{ job.id, message, err });
        return !deferred;
    };
    defer allocator.free(result.relative_path);
    while (true) {
        const saved = db.beginFinalizing(io, job.id, result.relative_path, std.Io.Clock.real.now(io).toSeconds()) catch |err| {
            state.download_writes_ready.store(false, .release);
            std.log.err("Job {s} finalizing write will be retried: {t}", .{ job.id, err });
            if (state.shutdown.requested.load(.acquire)) return err;
            try std.Io.sleep(io, .fromMilliseconds(200), .awake);
            continue;
        };
        if (!saved) return error.JobOwnershipLost;
        state.download_writes_ready.store(true, .release);
        state.shutdown.notifyWorker();
        std.log.info("job {s} download complete; finalization queued", .{job.id});
        break;
    }
    return true;
}

fn failureMessage(err: anyerror) []const u8 {
    if (err == error.Canceled) return "The download was interrupted by shutdown.";
    if (err == error.Timeout) return "The download exceeded DOWNLOAD_TIMEOUT.";
    if (nntp.isRetryableProviderFailure(err)) return "The NNTP provider is unavailable; the job failed after retries.";
    return switch (err) {
        error.MissingArticle, error.InsufficientPar2Data => "Required articles are missing on the NNTP provider and could not be repaired.",
        error.ArtifactTooLarge, error.YencSizeExceedsBudget => "The download exceeds MAX_ARTIFACT_BYTES.",
        error.WorkspaceTooLarge => "The download exceeds MAX_WORK_BYTES.",
        error.StorageFull => "There is insufficient storage capacity for this download.",
        error.SplitArchiveRejected => "Split archives are not supported by the downloader.",
        error.YencCrcMismatch, error.Par2RepairFailed, error.InconsistentSegmentSize, error.InconsistentYencMetadata => "Downloaded article data is corrupted and could not be repaired.",
        else => "The NZB file or downloaded data is not supported.",
    };
}

fn probeProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    ca_store: *nntp.CaStore,
    state: *AppState,
) !void {
    if (!state.provider_gate.tryLock()) return;
    defer state.provider_gate.unlock(io);
    var control = shutdown.DownloadControl.init(io, shutdown.now(io) + cfg.nntp_timeout_seconds);
    control.state = &state.shutdown;
    var watchdog: std.Io.Group = .init;
    try watchdog.concurrent(io, watchControl, .{&control});
    defer watchdog.cancel(io);
    var session = nntp.makeSession(
        allocator,
        io,
        cfg.nntp_host,
        cfg.nntp_port,
        cfg.nntp_user,
        cfg.nntp_pass,
        ca_store,
        cfg.nntp_timeout_seconds,
        &control,
    );
    defer session.deinit();
    try session.connect();
    try session.probe();
    state.provider_ready.store(true, .release);
    state.shutdown.notifyWorker();
}

test "malformed NZB fails job without aborting worker cycle and failed cleanup purges directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const root = root_buffer[0..root_len];
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/worker_test.db", .{root});
    defer std.testing.allocator.free(db_path);

    var db = try Database.open(std.testing.allocator, db_path);
    defer db.close();

    const bad_id = (try db.createIfCapacity(io, "bad.nzb", "<not-an-nzb/>", 100, 10)).?;
    defer std.testing.allocator.free(bad_id);
    const bad_job = (try db.get(io, bad_id)).?;
    defer bad_job.deinit(std.testing.allocator);

    var cfg = std.mem.zeroes(Config);
    cfg.retention_seconds = 60;
    var store: nntp.CaStore = .{};
    var state = AppState.init(cfg, root);

    _ = try processPending(std.testing.allocator, io, &db, cfg, root, &store, &state, bad_job, 105);
    const failed_job = (try db.get(io, bad_id)).?;
    defer failed_job.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.failed, failed_job.status);

    _ = try cleanup.run(std.testing.allocator, io, &db, cfg, root, 200);
    try std.testing.expect((try db.get(io, bad_id)) == null);
}

fn watchControl(control: *shutdown.DownloadControl) std.Io.Cancelable!void {
    while (!control.isCanceled()) {
        if (shutdown.now(control.io) >= control.deadline_seconds) {
            control.timeout();
            return;
        }
        try std.Io.sleep(control.io, .fromMilliseconds(100), .awake);
    }
}
