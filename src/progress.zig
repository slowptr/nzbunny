const std = @import("std");

pub const Phase = enum(u8) {
    idle,
    parsing,
    preparing,
    preflight,
    downloading,
    assembling,
    repairing,
};

pub const ProgressSnapshot = struct {
    phase: Phase,
    completed: usize,
    total: usize,
    last_activity: i64,
    last_activity_tick: i64,
};

pub const Progress = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    completed: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    last_activity: std.atomic.Value(i64) = .init(0),
    last_activity_tick: std.atomic.Value(i64) = .init(0),
    last_report_bucket: std.atomic.Value(usize) = .init(0),

    pub fn start(self: *Progress, io: std.Io, total: usize) void {
        self.total.store(total, .release);
        self.completed.store(0, .release);
        self.last_report_bucket.store(0, .release);
        self.setPhase(io, .preparing);
    }

    pub fn setTotal(self: *Progress, total: usize) void {
        self.total.store(total, .release);
    }

    pub fn setPhase(self: *Progress, io: std.Io, phase: Phase) void {
        self.phase.store(phase, .release);
        self.last_activity.store(std.Io.Clock.real.now(io).toSeconds(), .release);
        self.last_activity_tick.store(@import("shutdown.zig").now(io), .release);
    }

    pub fn touch(self: *Progress, io: std.Io) void {
        self.last_activity.store(std.Io.Clock.real.now(io).toSeconds(), .release);
        self.last_activity_tick.store(@import("shutdown.zig").now(io), .release);
    }

    pub fn advanced(self: *Progress, io: std.Io) void {
        const completed = self.completed.fetchAdd(1, .acq_rel) + 1;
        self.last_activity.store(std.Io.Clock.real.now(io).toSeconds(), .release);
        self.last_activity_tick.store(@import("shutdown.zig").now(io), .release);
        const total = self.total.load(.acquire);
        if (total == 0) return;
        const bucket = @min(10, completed * 10 / total);
        const previous = self.last_report_bucket.load(.acquire);
        if (bucket > previous and self.last_report_bucket.cmpxchgStrong(previous, bucket, .acq_rel, .acquire) == null)
            std.log.info("download progress: {d}/{d} segments ({d}%)", .{ completed, total, completed * 100 / total });
    }

    pub fn snapshot(self: *const Progress) ProgressSnapshot {
        return .{
            .phase = self.phase.load(.acquire),
            .completed = self.completed.load(.acquire),
            .total = self.total.load(.acquire),
            .last_activity = self.last_activity.load(.acquire),
            .last_activity_tick = self.last_activity_tick.load(.acquire),
        };
    }
};
