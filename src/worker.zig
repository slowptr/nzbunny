const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const Status = @import("database.zig").Status;
const artifact = @import("artifact.zig");
const download = @import("download.zig");
const nntp = @import("nntp.zig");
const shutdown = @import("shutdown.zig");

pub var provider_ready: std.atomic.Value(bool) = .init(false);

const max_concurrent_finalizers = 2;
const max_concurrent_cleanup = 8;
const max_finalize_attempts = 5;
const lease_duration_seconds: i64 = 60;
const lease_renew_seconds: i64 = 45;

const Finalizers = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    active: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Finalizers) void {
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
        self.active.deinit(self.allocator);
    }

    fn schedule(self: *Finalizers, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active.count() >= max_concurrent_finalizers) return;
        if (self.active.contains(job.id)) return;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const token = (try self.db.tryClaimFinalizing(self.io, job.id, now, lease_duration_seconds, self.io)) orelse return;
        errdefer self.allocator.free(token);
        const owned_id = try self.allocator.dupe(u8, job.id);
        errdefer self.allocator.free(owned_id);
        const owned_download_path = try self.allocator.dupe(u8, job.download_path);
        errdefer self.allocator.free(owned_download_path);
        try self.active.put(self.allocator, owned_id, {});
        const attempt = job.finalize_attempts + 1;
        self.group.concurrent(self.io, runFinalize, .{ self, owned_id, token, owned_download_path, attempt }) catch
            runFinalize(self, owned_id, token, owned_download_path, attempt);
    }
};

const CleanupTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    root: []const u8,
    job: *const Job,
    now: i64,
};

pub fn startup(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
) !void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const interrupted = try db.failProcessingOnStartup(io, now);
    defer {
        for (interrupted) |job| job.deinit(db.allocator);
        db.allocator.free(interrupted);
    }
    db.reclaimStaleLeases(io, now) catch |err|
        std.log.err("Stale lease reclaim failed: {t}", .{err});
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    for (interrupted) |job| {
        cleanupWorkDirs(io, root_dir, job.id) catch |err|
            std.log.err("Job {s} interrupted cleanup failed: {t}", .{ job.id, err });
    }
    var session = nntp.makeSession(
        allocator,
        io,
        cfg.nntp_host,
        cfg.nntp_port,
        cfg.nntp_user,
        cfg.nntp_pass,
        ca_store,
        cfg.nntp_timeout_seconds,
        null,
    );
    defer session.deinit();
    try session.connect();
    provider_ready.store(true, .release);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
) void {
    var finalizers = Finalizers{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cfg = cfg,
        .root = root,
    };
    defer finalizers.deinit();
    var last_cleanup: i64 = 0;
    while (!shutdown.requested.load(.acquire)) {
        const now = std.Io.Clock.real.now(io).toSeconds();
        cycle(allocator, io, db, cfg, root, ca_store, &finalizers, now) catch |err|
            std.log.err("The worker cycle failed: {t}", .{err});
        if (now - last_cleanup >= cfg.cleanup_seconds) {
            cleanup(allocator, io, db, cfg, root, now) catch |err|
                std.log.err("The cleanup cycle failed: {t}", .{err});
            db.maintain() catch |err|
                std.log.err("SQLite maintenance failed: {t}", .{err});
            last_cleanup = now;
        }
        shutdown.waitForRequest(io, cfg.poll_seconds) catch return;
    }
}

fn cycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
    finalizers: *Finalizers,
    now: i64,
) !void {
    if (!provider_ready.load(.acquire)) {
        probeProvider(allocator, io, cfg, ca_store) catch return;
    }
    const jobs = try db.listWork(io);
    defer {
        for (jobs) |job| job.deinit(db.allocator);
        db.allocator.free(jobs);
    }
    var active_processing = false;
    var pending: ?*const Job = null;
    for (jobs) |*job| switch (job.status) {
        .processing => active_processing = true,
        .finalizing => try finalizers.schedule(job.*),
        .pending => {
            if (pending == null) pending = job;
        },
        else => {},
    };
    if (active_processing or pending == null or !provider_ready.load(.acquire)) return;
    try processPending(allocator, io, db, cfg, root, ca_store, pending.?.*, now);
}

fn processPending(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    ca_store: *nntp.CaStore,
    job_ref: Job,
    now: i64,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const job = (try db.getWithContent(io, job_ref.id)) orelse return;
    defer job.deinit(db.allocator);
    if (job.status != .pending) return;
    _ = @import("nzb.zig").parse(arena.allocator(), job.content) catch |err| {
        try db.fail(io, job.id, "The NZB file is not supported by the embedded downloader.", now);
        return err;
    };
    if (!try db.beginProcessing(io, job.id, now)) return;
    const started = std.Io.Clock.real.now(io).toSeconds();
    const deadline = std.math.add(i64, started, cfg.download_timeout_seconds) catch return error.Timeout;
    var control = @import("shutdown.zig").DownloadControl.init(io, deadline);
    const result = download.run(arena.allocator(), io, root, job.id, job.content, cfg, ca_store, &control) catch |err| {
        const root_dir = std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false }) catch null;
        if (root_dir) |dir| {
            defer dir.close(io);
            cleanupWorkDirs(io, dir, job.id) catch {};
        }
        if (providerFailure(err)) provider_ready.store(false, .release);
        const message = if (err == error.Timeout)
            "The download exceeded DOWNLOAD_TIMEOUT."
        else if (providerFailure(err))
            "The NNTP provider is unavailable; the job failed after retries."
        else
            "The NZB file or downloaded data is not supported.";
        try db.fail(io, job.id, message, std.Io.Clock.real.now(io).toSeconds());
        return;
    };
    _ = try db.beginFinalizing(io, job.id, result.relative_path, std.Io.Clock.real.now(io).toSeconds());
}

fn probeProvider(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: Config,
    ca_store: *nntp.CaStore,
) !void {
    var session = nntp.makeSession(
        allocator,
        io,
        cfg.nntp_host,
        cfg.nntp_port,
        cfg.nntp_user,
        cfg.nntp_pass,
        ca_store,
        cfg.nntp_timeout_seconds,
        null,
    );
    defer session.deinit();
    try session.connect();
    try session.probe();
    provider_ready.store(true, .release);
}

fn runFinalize(owner: *Finalizers, job_id: []const u8, lease_token: []const u8, download_path: []const u8, attempt: u32) void {
    defer owner.allocator.free(lease_token);
    defer owner.allocator.free(download_path);
    var arena = std.heap.ArenaAllocator.init(owner.allocator);
    defer arena.deinit();
    const now = std.Io.Clock.real.now(owner.io).toSeconds();
    finalize(arena.allocator(), owner, job_id, download_path, lease_token, attempt, now) catch |err| {
        std.log.err("Job {s} finalization failed (attempt {d}/{d}): {t}", .{ job_id, attempt, max_finalize_attempts, err });
        if (attempt >= max_finalize_attempts) {
            owner.db.failFinalizing(owner.io, job_id, lease_token, "The output artifact could not be prepared after multiple attempts.", now) catch |db_err|
                std.log.err("Job {s} failure state could not be saved: {t}", .{ job_id, db_err });
        } else {
            const backoff = @as(i64, 1) << @min(attempt, 4);
            owner.db.releaseFinalizing(owner.io, job_id, lease_token, now + backoff, now) catch {};
        }
    };
    owner.mutex.lockUncancelable(owner.io);
    if (owner.active.fetchRemove(job_id)) |entry| owner.allocator.free(entry.key);
    owner.mutex.unlock(owner.io);
}

fn finalize(
    allocator: std.mem.Allocator,
    owner: *Finalizers,
    id: []const u8,
    download_path: []const u8,
    lease_token: []const u8,
    attempt: u32,
    now: i64,
) !void {
    const result = try artifact.prepare(allocator, owner.root, id, download_path, owner.cfg.max_artifact_bytes);
    if (attempt < max_finalize_attempts) {
        const renew_until = std.math.add(i64, now, lease_duration_seconds) catch now + lease_duration_seconds;
        _ = owner.db.renewLease(owner.io, id, lease_token, renew_until, now) catch {};
    }
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        var random: [32]u8 = undefined;
        owner.io.random(&random);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{random}) catch unreachable;
        const saved = owner.db.completeWithToken(owner.io, id, lease_token, result.relative_path, result.size, &token, now + owner.cfg.retention_seconds, now) catch |err| switch (err) {
            error.DuplicateToken => continue,
            else => return err,
        };
        if (saved) return;
        return;
    }
    return error.DownloadTokenCollision;
}

fn cleanup(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    now: i64,
) !void {
    const jobs = try db.listCleanup(
        io,
        now,
        now - cfg.retention_seconds,
        now - cfg.retention_seconds,
        now - cfg.download_timeout_seconds,
    );
    defer {
        for (jobs) |job| job.deinit(db.allocator);
        db.allocator.free(jobs);
    }
    var offset: usize = 0;
    while (offset < jobs.len) {
        const end = @min(offset + max_concurrent_cleanup, jobs.len);
        var group: std.Io.Group = .init;
        for (jobs[offset..end]) |*job| {
            const task = CleanupTask{ .allocator = allocator, .io = io, .db = db, .root = root, .job = job, .now = now };
            group.concurrent(io, processCleanup, .{task}) catch processCleanup(task);
        }
        try group.await(io);
        offset = end;
    }
}

fn processCleanup(task: CleanupTask) void {
    const job = task.job.*;
    cleanupJob(task, job) catch |err|
        std.log.err("Job {s} cleanup failed: {t}", .{ job.id, err });
}

fn cleanupJob(task: CleanupTask, job: Job) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(task.io, task.root, .{ .follow_symlinks = false });
    defer root_dir.close(task.io);
    if (job.status == .expired) return task.db.purgeExpired(task.io, job.id, task.now - 1800);
    cleanupWorkDirs(task.io, root_dir, job.id) catch {};
    if (job.download_path.len != 0)
        artifact.removeValidated(task.root, job.download_path) catch {};
    if (job.artifact_path.len != 0 and !std.mem.eql(u8, job.artifact_path, job.download_path))
        artifact.removeValidated(task.root, job.artifact_path) catch {};
    _ = try task.db.markExpired(task.io, job.id, job.status, task.now);
}

fn cleanupWorkDirs(io: std.Io, root_dir: std.Io.Dir, job_id: []const u8) !void {
    var work_buffer: [128]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buffer, ".nzbunny-work/{s}", .{job_id});
    try root_dir.deleteTree(io, work);
    var output_buffer: [128]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_buffer, ".nzbunny-downloads/{s}", .{job_id});
    try root_dir.deleteTree(io, output);
}

fn providerFailure(err: anyerror) bool {
    return nntp.isRetryableProviderFailure(err);
}

test "provider readiness starts false" {
    provider_ready.store(false, .release);
    try std.testing.expect(!provider_ready.load(.acquire));
}
