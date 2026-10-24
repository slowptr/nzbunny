const std = @import("std");
const Database = @import("database.zig").Database;
const Config = @import("config.zig").Config;
const AppState = @import("runtime.zig").AppState;

pub const Readiness = enum {
    ready,
    shutting_down,
    database_unavailable,
    download_state_write_failed,
    finalizer_state_write_failed,
    provider_unavailable,
    storage_capacity_unavailable,
};

pub fn readiness(io: std.Io, db: *Database, cfg: Config, state: *AppState) Readiness {
    if (state.shutdown.requested.load(.acquire)) return .shutting_down;
    if (!db.ready(io) or !state.database_ready.load(.acquire)) return .database_unavailable;
    if (!state.download_writes_ready.load(.acquire)) return .download_state_write_failed;
    if (!state.finalizer_admission_ready.load(.acquire) or state.finalizer_write_failures.load(.acquire) != 0)
        return .finalizer_state_write_failed;
    if (!state.providerAvailable(io, cfg)) return .provider_unavailable;
    state.storage.check(io, cfg.max_work_bytes) catch return .storage_capacity_unavailable;
    return .ready;
}

/// Fixed metric names and status labels only: no tokens, filenames, or job IDs.
pub fn metrics(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, state: *AppState) ![]u8 {
    const queue = try db.queueSnapshot(io);
    const storage = try state.storage.snapshot(io);
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    const w = &output.writer;
    try w.print(
        "# TYPE nzbunny_jobs gauge\nnzbunny_jobs{{status=\"pending\"}} {d}\n" ++
            "nzbunny_jobs{{status=\"processing\"}} {d}\nnzbunny_jobs{{status=\"finalizing\"}} {d}\n" ++
            "# TYPE nzbunny_oldest_pending_seconds gauge\nnzbunny_oldest_pending_seconds {d}\n" ++
            "# TYPE nzbunny_storage_managed_bytes gauge\nnzbunny_storage_managed_bytes {d}\n" ++
            "# TYPE nzbunny_storage_reserved_bytes gauge\nnzbunny_storage_reserved_bytes {d}\n" ++
            "# TYPE nzbunny_storage_available_bytes gauge\nnzbunny_storage_available_bytes {d}\n" ++
            "# TYPE nzbunny_ready gauge\nnzbunny_ready {d}\n",
        .{ queue.pending, queue.processing, queue.finalizing, if (queue.oldest_pending) |created| @max(0, std.Io.Clock.real.now(io).toSeconds() - created) else 0, storage.managed_bytes, storage.reserved_bytes, storage.available_bytes, @intFromBool(readiness(io, db, cfg, state) == .ready) },
    );
    inline for (.{ "download_deferrals", "finalizer_deferrals", "finalizer_retries", "cleanup_failures", "cleanup_cycles" }) |name| {
        try w.print("# TYPE nzbunny_" ++ name ++ "_total counter\nnzbunny_" ++ name ++ "_total {d}\n", .{@field(state, name).load(.acquire)});
    }
    return allocator.dupe(u8, output.writer.buffered());
}
