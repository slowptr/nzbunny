const std = @import("std");

pub var requested: std.atomic.Value(bool) = .init(false);

pub fn installSignalHandlers() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, null);
    std.posix.sigaction(.INT, &action, null);
}

fn handleSignal(_: std.posix.SIG) callconv(.c) void {
    requested.store(true, .release);
}

pub fn waitForRequest(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const deadline = std.math.add(i64, now, seconds) catch std.math.maxInt(i64);
    while (!requested.load(.acquire) and std.Io.Clock.real.now(io).toSeconds() < deadline)
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
}

pub const DownloadControl = struct {
    io: std.Io,
    deadline_seconds: i64,
    canceled: std.atomic.Value(bool) = .init(false),
    mutex: std.Io.Mutex = .init,
    streams: [16]?std.Io.net.Stream = @splat(null),

    pub fn init(io: std.Io, deadline_seconds: i64) DownloadControl {
        return .{ .io = io, .deadline_seconds = deadline_seconds };
    }

    pub fn isCanceled(self: *DownloadControl) bool {
        if (requested.load(.acquire)) self.cancel();
        return self.canceled.load(.acquire);
    }

    pub fn cancel(self: *DownloadControl) void {
        if (self.canceled.swap(true, .acq_rel)) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.streams) |stream| {
            if (stream) |active| active.shutdown(self.io, .both) catch {};
        }
    }

    pub fn register(self: *DownloadControl, stream: std.Io.net.Stream) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.canceled.load(.acquire)) return error.Canceled;
        for (&self.streams) |*slot| {
            if (slot.* == null) {
                slot.* = stream;
                return;
            }
        }
        return error.TooManyActiveSessions;
    }

    pub fn unregister(self: *DownloadControl, stream: std.Io.net.Stream) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (&self.streams) |*slot| {
            if (slot.*) |active| {
                if (active.socket.handle == stream.socket.handle) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    pub fn wait(self: *DownloadControl, seconds: i64) !void {
        const end = std.math.add(i64, std.Io.Clock.real.now(self.io).toSeconds(), seconds) catch self.deadline_seconds;
        while (true) {
            if (self.isCanceled()) return error.Canceled;
            const now = std.Io.Clock.real.now(self.io).toSeconds();
            if (now >= end or now >= self.deadline_seconds) return;
            std.Io.sleep(self.io, .fromMilliseconds(100), .awake) catch return error.Canceled;
        }
    }

    pub fn watch(self: *DownloadControl) std.Io.Cancelable!void {
        while (!self.isCanceled()) {
            if (std.Io.Clock.real.now(self.io).toSeconds() >= self.deadline_seconds) {
                self.cancel();
                return;
            }
            try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
        }
    }
};

test "cancellation interrupts waits" {
    var control = DownloadControl.init(std.testing.io, std.math.maxInt(i64));
    control.cancel();
    try std.testing.expectError(error.Canceled, control.wait(1));
}
