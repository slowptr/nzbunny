const std = @import("std");
const Config = @import("config.zig").Finalizer;
const failure = @import("failure.zig");
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
        if (job.finalize_next_at) |next| {
            if (next > now) return;
        }
        if (job.finalize_lease_until) |until| {
            if (until > now) return;
        }
        // Allocate and register memory before claiming durable ownership. No
        // fallible allocation remains after tryClaimFinalizing succeeds.
        const owned = blk: {
            const id = try self.allocator.dupe(u8, job.id);
            errdefer self.allocator.free(id);
            const path = try self.allocator.dupe(u8, job.download_path);
            errdefer self.allocator.free(path);
            try self.active.put(self.allocator, id, {});
            break :blk .{ .id = id, .path = path };
        };
        const owned_id = owned.id;
        const owned_download_path = owned.path;
        var transferred = false;
        defer if (!transferred) {
            _ = self.active.remove(owned_id);
            self.allocator.free(owned_id);
            self.allocator.free(owned_download_path);
        };
        self.state.storage.reserve(self.io, self.cfg.max_artifact_bytes) catch |err| {
            _ = self.state.finalizer_deferrals.fetchAdd(1, .monotonic);
            std.log.warn("Job {s} finalizer admission deferred: {t}", .{ job.id, err });
            return;
        };
        defer if (!transferred) self.state.storage.release(self.io, self.cfg.max_artifact_bytes);
        const token = (try self.db.tryClaimFinalizing(self.io, job.id, now, lease_duration_seconds)) orelse return;
        const attempt = job.finalize_attempts +| 1;
        transferred = true;
        self.mutex.unlock(self.io);
        locked = false;
        self.group.concurrent(self.io, runFinalize, .{ self, owned_id, token, owned_download_path, attempt }) catch
            runFinalize(self, owned_id, token, owned_download_path, attempt);
    }
};

fn runFinalize(owner: *Manager, job_id: []const u8, lease_token: []const u8, download_path: []const u8, attempt: u32) void {
    defer owner.db.allocator.free(lease_token);
    defer owner.allocator.free(download_path);
    defer owner.state.storage.release(owner.io, owner.cfg.max_artifact_bytes);
    std.log.info("job {s} finalization started (attempt {d}/{d})", .{ job_id, attempt, max_finalize_attempts });
    finalize(owner.allocator, owner, job_id, download_path, lease_token) catch |err| {
        const deferred = failure.isInfrastructure(err) or owner.state.shutdown.requested.load(.acquire);
        if (deferred) {
            _ = owner.state.finalizer_deferrals.fetchAdd(1, .monotonic);
        } else _ = owner.state.finalizer_retries.fetchAdd(1, .monotonic);
        std.log.warn("Job {s} finalization {s} (attempt {d}/{d}): {t}", .{ job_id, if (deferred) "deferred" else "failed", attempt, max_finalize_attempts, err });
        // Retain task ownership while retrying a failed state write. Restart
        // reclaims any lease that shutdown prevented us from releasing.
        var write_failed = false;
        defer {
            if (write_failed) _ = owner.state.finalizer_write_failures.fetchSub(1, .acq_rel);
        }
        while (true) {
            const now = std.Io.Clock.real.now(owner.io).toSeconds();
            const persisted = if (!deferred and attempt >= max_finalize_attempts)
                owner.db.failFinalizing(owner.io, job_id, lease_token, "The output artifact could not be prepared after multiple attempts.", now)
            else
                owner.db.releaseFinalizing(owner.io, job_id, lease_token, now + failure.retryDelay(if (deferred) 1 else attempt), now, deferred);
            persisted catch |db_err| {
                if (!write_failed) {
                    write_failed = true;
                    _ = owner.state.finalizer_write_failures.fetchAdd(1, .acq_rel);
                }
                std.log.err("Job {s} finalizer state write will be retried: {t}", .{ job_id, db_err });
                if (owner.state.shutdown.requested.load(.acquire)) break;
                std.Io.sleep(owner.io, .fromMilliseconds(200), .awake) catch break;
                continue;
            };
            break;
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
                cleanup.workDirs(owner.io, dir, id) catch |err| {
                    _ = owner.state.cleanup_failures.fetchAdd(1, .monotonic);
                    std.log.err("Job {s} source cleanup deferred: {t}", .{ id, err });
                };
            }
            std.log.info("job {s} complete: artifact ready ({d} bytes)", .{ id, result.size });
            return;
        }
        return error.LeaseRenewalFailed;
    }
    return error.DownloadTokenCollision;
}

test "admission allocation failures release memory without claiming a lease" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const id = (try db.createIfCapacity(io, "allocation.nzb", "<nzb/>", 1, 1)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expect(try db.beginProcessing(io, id, 2));
    try std.testing.expect(try db.beginFinalizing(io, id, "source", 3));
    const token = (try db.tryClaimFinalizing(io, id, 4, 60)).?;
    defer std.testing.allocator.free(token);
    try db.releaseFinalizing(io, id, token, std.math.maxInt(i64), 4, true);
    var job = (try db.get(io, id)).?;
    job.finalize_next_at = null;
    defer job.deinit(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkAdmissionAllocation, .{ &db, root, job });
}

fn checkAdmissionAllocation(allocator: std.mem.Allocator, db: *Database, root: []const u8, job: Job) !void {
    const io = std.testing.io;
    var cfg = std.mem.zeroes(@import("config.zig").Config);
    cfg.max_artifact_bytes = 1;
    cfg.max_storage_bytes = 1024;
    var state = AppState.init(cfg, root);
    var manager: Manager = .{ .allocator = allocator, .io = io, .db = db, .cfg = cfg.finalizer(), .root = root, .state = &state };
    defer manager.deinit();
    defer std.debug.assert(manager.active.count() == 0 and state.storage.reserved == 0);
    try manager.schedule(job);
    const stored = (try db.get(io, job.id)).?;
    defer stored.deinit(db.allocator);
    try std.testing.expect(stored.finalize_lease_until == null);
    try std.testing.expectEqual(@as(u32, 0), stored.finalize_attempts);
}

test "preparation allocation failure after claim refunds ownership and reservations" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &buffer);
    const root = buffer[0..root_len];
    try tmp.dir.writeFile(io, .{ .sub_path = "source.bin", .data = "verified bytes" });
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const id = (try db.createIfCapacity(io, "allocation.nzb", "<nzb/>", 1, 1)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expect(try db.beginProcessing(io, id, 2));
    try std.testing.expect(try db.beginFinalizing(io, id, "source.bin", 3));
    const token = (try db.tryClaimFinalizing(io, id, 4, 60)).?;
    // These resources have already transferred to the task before injecting OOM.
    const owned_id = try std.testing.allocator.dupe(u8, id);
    const owned_path = try std.testing.allocator.dupe(u8, "source.bin");
    var cfg = std.mem.zeroes(@import("config.zig").Config);
    cfg.max_artifact_bytes = 64;
    cfg.max_storage_bytes = 1024;
    cfg.download_timeout_seconds = 60;
    var state = AppState.init(cfg, root);
    try state.storage.reserve(io, cfg.max_artifact_bytes);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var manager: Manager = .{ .allocator = failing.allocator(), .io = io, .db = &db, .cfg = cfg.finalizer(), .root = root, .state = &state };
    defer manager.deinit();
    try manager.active.put(std.testing.allocator, owned_id, {});
    runFinalize(&manager, owned_id, token, owned_path, 1);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), manager.active.count());
    try std.testing.expectEqual(@as(u64, 0), state.storage.reserved);
    const job = (try db.get(io, id)).?;
    defer job.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), job.finalize_attempts);
    try std.testing.expectEqual(@as(u64, 1), state.finalizer_deferrals.load(.acquire));
    try std.testing.expectEqual(@import("database.zig").Status.finalizing, job.status);
    try std.testing.expect(job.finalize_lease_until == null);
}
