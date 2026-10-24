const std = @import("std");

/// Lock the actual storage objects, rather than a removable sidecar. The root
/// lock also protects instances using different databases on the same volume.
pub const Lock = struct {
    fd: std.posix.fd_t,

    pub fn acquire(path: [:0]const u8, directory: bool) !Lock {
        const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{
            .ACCMODE = if (directory) .RDONLY else .RDWR,
            .CREAT = !directory,
            .DIRECTORY = directory,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0o600);
        errdefer _ = std.posix.system.close(fd);
        switch (std.os.linux.errno(std.os.linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => {},
            .AGAIN, .ACCES => return error.StorageAlreadyInUse,
            else => return error.StorageLockFailed,
        }
        return .{ .fd = fd };
    }

    pub fn deinit(self: Lock) void {
        _ = std.posix.system.close(self.fd);
    }
};
