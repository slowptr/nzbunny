const std = @import("std");
const Config = @import("config.zig").Config;
const shutdown = @import("shutdown.zig");
const progress = @import("progress.zig");
const Budget = @import("budget.zig").Budget;
const Storage = @import("storage.zig").Storage;

pub const AppState = struct {
    shutdown: shutdown.State = .{},
    provider_gate: std.Io.Mutex = .init,
    provider_ready: std.atomic.Value(bool) = .init(false),
    provider_checked: std.atomic.Value(i64) = .init(0),
    database_ready: std.atomic.Value(bool) = .init(true),
    storage_ready: std.atomic.Value(bool) = .init(true),
    active_job_hash: std.atomic.Value(u64) = .init(0),
    progress: progress.Progress = .{},
    uploads: Budget,
    storage: Storage,

    pub fn init(cfg: Config, root: []const u8) AppState {
        return .{
            .uploads = .{ .limit = cfg.max_upload_memory_bytes },
            .storage = .{ .root = root, .limit = cfg.max_storage_bytes, .min_free = cfg.min_free_bytes },
        };
    }

    pub fn jobHash(id: []const u8) u64 {
        return std.hash.Wyhash.hash(0x6e7a62756e6e79, id);
    }

    pub fn progressFor(self: *AppState, id: []const u8) ?progress.ProgressSnapshot {
        if (self.active_job_hash.load(.acquire) != jobHash(id)) return null;
        return self.progress.snapshot();
    }

    pub fn providerAvailable(self: *AppState, io: std.Io, cfg: Config) bool {
        if (!self.provider_ready.load(.acquire)) return false;
        const age = shutdown.now(io) - self.provider_checked.load(.acquire);
        if (age <= @as(i64, cfg.poll_seconds) * 2 + cfg.nntp_timeout_seconds) return true;
        // Active downloads also provide fresh evidence of provider health.
        return self.active_job_hash.load(.acquire) != 0 and
            shutdown.now(io) - self.progress.snapshot().last_activity_tick < cfg.nntp_timeout_seconds;
    }
};
