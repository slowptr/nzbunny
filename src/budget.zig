const std = @import("std");

/// Shared by all segment decoders of one job. Reserve before writing bytes.
pub const Budget = struct {
    limit: u64,
    used: std.atomic.Value(u64) = .init(0),

    pub fn reserve(self: *Budget, bytes: u64) !void {
        var previous = self.used.load(.acquire);
        while (true) {
            const next = std.math.add(u64, previous, bytes) catch return error.WorkspaceTooLarge;
            if (next > self.limit) return error.WorkspaceTooLarge;
            previous = self.used.cmpxchgWeak(previous, next, .acq_rel, .acquire) orelse return;
        }
    }

    pub fn release(self: *Budget, bytes: u64) void {
        const previous = self.used.fetchSub(bytes, .acq_rel);
        std.debug.assert(previous >= bytes);
    }
};

test "aggregate reservations reject overflow and can be released" {
    var budget: Budget = .{ .limit = 10 };
    try budget.reserve(7);
    try std.testing.expectError(error.WorkspaceTooLarge, budget.reserve(4));
    budget.release(7);
    try budget.reserve(10);
    try std.testing.expectError(error.WorkspaceTooLarge, budget.reserve(std.math.maxInt(u64)));
}
