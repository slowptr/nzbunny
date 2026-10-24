const std = @import("std");

/// Infrastructure errors preserve accepted work. Input errors and exhausted
/// provider retries remain terminal in the downloader. Finalization retries
/// unknown errors a bounded number of times to avoid retaining broken jobs.
pub fn isInfrastructure(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory,
        error.StorageFull,
        error.StorageUnavailable,
        error.AccessDenied,
        error.PermissionDenied,
        error.ReadOnlyFileSystem,
        error.NoSpaceLeft,
        error.DiskQuota,
        error.InputOutput,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.DatabaseBusy,
        error.DatabaseFull,
        error.DatabaseReadOnly,
        error.DatabaseIOFailed,
        error.DatabaseOperationFailed,
        error.ArchiveWriteFailed,
        error.ArtifactDirectoryFailed,
        error.ArchiveOpenFailed,
        error.ArchiveRenameFailed,
        error.ArchiveCloseFileFailed,
        => true,
        else => false,
    };
}

pub fn retryDelay(attempt: u32) i64 {
    return @as(i64, 1) << @min(attempt, 4);
}

test "infrastructure deferral is distinct from malformed input and retry exhaustion" {
    try std.testing.expect(isInfrastructure(error.StorageFull));
    try std.testing.expect(isInfrastructure(error.DatabaseIOFailed));
    try std.testing.expect(isInfrastructure(error.OutOfMemory));
    try std.testing.expect(!isInfrastructure(error.YencCrcMismatch));
    try std.testing.expect(!isInfrastructure(error.DatabaseConstraint));
    try std.testing.expectEqual(@as(i64, 16), retryDelay(std.math.maxInt(u32)));
}
