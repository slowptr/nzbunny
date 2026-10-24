const std = @import("std");
const c = @cImport({
    @cInclude("sys/statvfs.h");
});

pub const Storage = struct {
    root: []const u8,
    limit: u64,
    min_free: u64,
    reserved: u64 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn reserve(self: *Storage, io: std.Io, bytes: u64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var root = try std.Io.Dir.openDirAbsolute(io, self.root, .{ .iterate = true, .follow_symlinks = false });
        defer root.close(io);
        const usage = try managedBytes(io, root);
        const reserved = std.math.add(u64, self.reserved, bytes) catch return error.StorageFull;
        const required = std.math.add(u64, usage, reserved) catch return error.StorageFull;
        if (required > self.limit) return error.StorageFull;
        var stats: c.struct_statvfs = undefined;
        if (c.fstatvfs(root.handle, &stats) != 0) return error.StorageUnavailable;
        const available = std.math.mul(u64, stats.f_bavail, stats.f_frsize) catch return error.StorageUnavailable;
        const free_required = std.math.add(u64, reserved, self.min_free) catch return error.StorageFull;
        if (available < free_required) return error.StorageFull;
        self.reserved = reserved;
    }

    /// An admission probe, not a reservation held on behalf of a future job.
    pub fn check(self: *Storage, io: std.Io, bytes: u64) !void {
        try self.reserve(io, bytes);
        self.release(io, bytes);
    }

    pub const Snapshot = struct { managed_bytes: u64, reserved_bytes: u64, available_bytes: u64 };

    pub fn snapshot(self: *Storage, io: std.Io) !Snapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var root = try std.Io.Dir.openDirAbsolute(io, self.root, .{ .iterate = true, .follow_symlinks = false });
        defer root.close(io);
        var stats: c.struct_statvfs = undefined;
        if (c.fstatvfs(root.handle, &stats) != 0) return error.StorageUnavailable;
        return .{ .managed_bytes = try managedBytes(io, root), .reserved_bytes = self.reserved, .available_bytes = try std.math.mul(u64, stats.f_bavail, stats.f_frsize) };
    }

    pub fn release(self: *Storage, io: std.Io, bytes: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(self.reserved >= bytes);
        self.reserved -= bytes;
    }
};

pub fn managedBytes(io: std.Io, root: std.Io.Dir) !u64 {
    var total: u64 = 0;
    for ([_][]const u8{ ".nzbunny-work", ".nzbunny-downloads", ".nzbunny-artifacts" }) |name| {
        const size = directoryBytes(io, root, name, 0) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        total = std.math.add(u64, total, size) catch return error.StorageFull;
    }
    return total;
}

pub fn directoryBytes(io: std.Io, parent: std.Io.Dir, name: []const u8, depth: usize) anyerror!u64 {
    if (depth > 128) return error.DirectoryTooDeep;
    var dir = try parent.openDir(io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var iterator = dir.iterate();
    var total: u64 = 0;
    while (try iterator.next(io)) |entry| {
        const size = switch (entry.kind) {
            .directory => directoryBytes(io, dir, entry.name, depth + 1) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            },
            .file => blk: {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                break :blk stat.size;
            },
            // Never follow symlinks or open special files while accounting.
            // They hold no managed payload bytes; artifact/download consumers
            // reject them before use. This lets invalid jobs reach validation
            // and cleanup instead of blocking all storage admission forever.
            else => 0,
        };
        total = std.math.add(u64, total, size) catch return error.StorageFull;
    }
    return total;
}
