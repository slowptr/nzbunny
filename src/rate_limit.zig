const std = @import("std");

const RateEntry = struct {
    key: u64 = 0,
    count: u32 = 0,
    window: i64 = 0,
    used: bool = false,
};

const RateShard = struct {
    entries: [32]RateEntry = @splat(.{}),
    mutex: std.Io.Mutex = .init,
};

pub const RateLimiter = struct {
    shards: [256]RateShard = @splat(.{}),
    seed: u64 = 0,

    pub fn allow(self: *RateLimiter, io: std.Io, key_text: []const u8, limit: u32, now: i64) bool {
        const key = std.hash.Wyhash.hash(self.seed, key_text);
        const shard = &self.shards[@as(u8, @truncate(key))];
        shard.mutex.lockUncancelable(io);
        defer shard.mutex.unlock(io);
        var free: ?usize = null;
        var oldest: usize = 0;
        for (&shard.entries, 0..) |*entry, i| {
            if (!entry.used) {
                free = i;
                break;
            }
            if (entry.key == key) {
                if (now - entry.window >= 60) {
                    entry.* = .{ .key = key, .count = 1, .window = now, .used = true };
                    return true;
                }
                if (entry.count >= limit) return false;
                entry.count += 1;
                return true;
            }
            if (entry.window < shard.entries[oldest].window) oldest = i;
        }
        const slot = free orelse oldest;
        shard.entries[slot] = .{ .key = key, .count = 1, .window = now, .used = true };
        return true;
    }
};

test "rate limits are isolated and windows expire" {
    var limiter: RateLimiter = .{};
    const io = std.testing.io;
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 100));
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 101));
    try std.testing.expect(!limiter.allow(io, "192.0.2.1", 2, 102));
    try std.testing.expect(limiter.allow(io, "192.0.2.2", 2, 102));
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 160));
}
