const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const AppState = @import("runtime.zig").AppState;
const artifact = @import("artifact.zig");
const cleanup = @import("cleanup.zig");
const shutdown = @import("shutdown.zig");

const max_concurrent_finalizers = 2;
const max_finalize_attempts = 5;
const lease_duration_seconds: i64 = 60;

pub const Manager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    state: *AppState,
    group: std.Io.Group = .init,
    mutex: std.Io.Mutex = .init,
    active: std.StringHashMapUnmanaged(void) = .empty,

    pub fn deinit(self: *Manager) void {
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
        var it = self.active.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.active.deinit(self.allocator);
    }

    pub fn schedule(self: *Manager, job: Job) !void {
        self.mutex.lockUncancelable(self.io);
        var locked = true;
        defer if (locked) self.mutex.unlock(self.io);
        if (self.active.count() >= max_concurrent_finalizers) return;
        if (self.active.contains(job.id)) return;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const token = (try self.db.tryClaimFinalizing(self.io, job.id, now, lease_duration_seconds)) orelse return;
        errdefer self.allocator.free(token);
        const owned_id = try self.allocator.dupe(u8, job.id);
        errdefer self.allocator.free(owned_id);
        const owned_download_path = try self.allocator.dupe(u8, job.download_path);
        errdefer self.allocator.free(owned_download_path);
        try self.active.put(self.allocator, owned_id, {});
        const attempt = job.finalize_attempts + 1;
        self.mutex.unlock(self.io);
        locked = false;
        self.group.concurrent(self.io, runFinalize, .{ self, owned_id, token, owned_download_path, attempt }) catch
            runFinalize(self, owned_id, token, owned_download_path, attempt);
    }
};

fn runFinalize(owner: *Manager, job_id: []const u8, lease_token: []const u8, download_path: []const u8, attempt: u32) void {
    defer owner.allocator.free(lease_token);
    defer owner.allocator.free(download_path);
    std.log.info("job {s} finalization started (attempt {d}/{d})", .{ job_id, attempt, max_finalize_attempts });
    finalize(owner.allocator, owner, job_id, download_path, lease_token) catch |err| {
        const failed_at = std.Io.Clock.real.now(owner.io).toSeconds();
        std.log.err("Job {s} finalization failed (attempt {d}/{d}): {t}", .{ job_id, attempt, max_finalize_attempts, err });
        if (attempt >= max_finalize_attempts and !owner.state.shutdown.requested.load(.acquire)) {
            owner.db.failFinalizing(owner.io, job_id, lease_token, "The output artifact could not be prepared after multiple attempts.", failed_at) catch |db_err|
                std.log.err("Job {s} failure state could not be saved: {t}", .{ job_id, db_err });
        } else {
            const backoff = @as(i64, 1) << @min(attempt, 4);
            owner.db.releaseFinalizing(owner.io, job_id, lease_token, failed_at + backoff, failed_at) catch |db_err|
                std.log.err("Job {s} lease release deferred: {t}", .{ job_id, db_err });
        }
    };
    owner.mutex.lockUncancelable(owner.io);
    if (owner.active.fetchRemove(job_id)) |entry| owner.allocator.free(entry.key);
    owner.mutex.unlock(owner.io);
}

fn finalize(
    allocator: std.mem.Allocator,
    owner: *Manager,
    id: []const u8,
    download_path: []const u8,
    lease_token: []const u8,
) !void {
    const before = std.Io.Clock.real.now(owner.io).toSeconds();
    const before_until = std.math.add(i64, before, lease_duration_seconds) catch return error.LeaseRenewalFailed;
    if (!(try owner.db.renewLease(owner.io, id, lease_token, before_until, before))) return error.LeaseRenewalFailed;
    try owner.state.storage.reserve(owner.io, owner.cfg.max_artifact_bytes);
    defer owner.state.storage.release(owner.io, owner.cfg.max_artifact_bytes);
    var control = shutdown.DownloadControl.init(owner.io, shutdown.now(owner.io) + owner.cfg.download_timeout_seconds);
    control.state = &owner.state.shutdown;
    const result = try artifact.prepareControlled(allocator, owner.root, id, download_path, owner.cfg.max_artifact_bytes, lease_token, &control);
    defer allocator.free(result.relative_path);
    const after = std.Io.Clock.real.now(owner.io).toSeconds();
    const after_until = std.math.add(i64, after, lease_duration_seconds) catch return error.LeaseRenewalFailed;
    if (!(try owner.db.renewLease(owner.io, id, lease_token, after_until, after))) return error.LeaseRenewalFailed;
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        var random: [32]u8 = undefined;
        owner.io.random(&random);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{random}) catch unreachable;
        const saved = owner.db.completeWithToken(owner.io, id, lease_token, result.relative_path, result.size, &token, after + owner.cfg.retention_seconds, after) catch |err| switch (err) {
            error.DuplicateToken => continue,
            else => return err,
        };
        if (saved) {
            if (std.Io.Dir.openDirAbsolute(owner.io, owner.root, .{ .follow_symlinks = false }) catch null) |dir| {
                defer dir.close(owner.io);
                cleanup.workDirs(owner.io, dir, id) catch |err|
                    std.log.err("Job {s} source cleanup deferred: {t}", .{ id, err });
            }
            std.log.info("job {s} complete: artifact ready ({d} bytes)", .{ id, result.size });
            return;
        }
        return error.LeaseRenewalFailed;
    }
    return error.DownloadTokenCollision;
}
