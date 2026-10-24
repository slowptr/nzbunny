const std = @import("std");
const shutdown = @import("shutdown.zig");

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    repair_name: []const u8,
    control: *shutdown.DownloadControl,
    max_output_bytes: u64,
) !void {
    try check(control);
    var output_dir = try root_dir.openDir(io, output_root, .{ .follow_symlinks = false });
    defer output_dir.close(io);
    return runInDirectory(allocator, io, output_dir, control, max_output_bytes, &.{ "/usr/bin/par2", "repair", "-q", "-m64", "--", repair_name });
}

fn runInDirectory(allocator: std.mem.Allocator, io: std.Io, output_dir: std.Io.Dir, control: *shutdown.DownloadControl, max_output_bytes: u64, argv: []const []const u8) !void {
    const remaining = control.deadline_seconds - shutdown.now(io);
    if (remaining <= 0) return error.Timeout;
    const Outcome = union(enum) {
        operation: anyerror!void,
        canceled: anyerror!void,
    };
    var result: ?std.process.RunResult = null;
    defer if (result) |owned| {
        allocator.free(owned.stdout);
        allocator.free(owned.stderr);
    };
    var outcomes: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &outcomes);
    defer select.cancelDiscard();
    try select.concurrent(.operation, runProcess, .{ allocator, io, output_dir, argv, remaining, &result });
    try select.concurrent(.canceled, waitForCancellation, .{ control, output_dir, max_output_bytes });
    switch (try select.await()) {
        .operation => |outcome| try outcome,
        .canceled => |outcome| {
            try outcome;
            try check(control);
            return error.Canceled;
        },
    }
    if (try @import("storage.zig").directoryBytes(io, output_dir, ".", 0) > max_output_bytes) return error.WorkspaceTooLarge;
    try check(control);
    const completed = result.?;
    switch (completed.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    try check(control);
    const message = std.mem.trim(u8, completed.stderr, " \t\r\n");
    if (message.len != 0) std.log.err("PAR2 repair failed: {s}", .{message});
    return error.Par2RepairFailed;
}

fn check(control: *shutdown.DownloadControl) !void {
    if (control.isTimedOut()) return error.Timeout;
    if (control.isCanceled()) return error.Canceled;
    if (shutdown.now(control.io) >= control.deadline_seconds) {
        control.timeout();
        return error.Timeout;
    }
}

fn waitForCancellation(control: *shutdown.DownloadControl, output_dir: std.Io.Dir, max_output_bytes: u64) !void {
    while (!control.isCanceled()) {
        if (try @import("storage.zig").directoryBytes(control.io, output_dir, ".", 0) > max_output_bytes)
            return error.WorkspaceTooLarge;
        if (shutdown.now(control.io) >= control.deadline_seconds) {
            control.timeout();
            return;
        }
        try std.Io.sleep(control.io, .fromMilliseconds(100), .awake);
    }
}

fn runProcess(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, argv: []const []const u8, seconds: i64, result: *?std.process.RunResult) !void {
    result.* = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .dir = dir },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(seconds) } },
    });
}

test "shutdown cancels and reaps a running repair subprocess" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var state: shutdown.State = .{};
    var control = shutdown.DownloadControl.init(io, shutdown.now(io) + 60);
    control.state = &state;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, requestStop, .{ io, &state });
    try std.testing.expectError(error.Canceled, runInDirectory(std.testing.allocator, io, tmp.dir, &control, 1024, &.{ "/bin/sh", "-c", "echo $$ > child.pid; exec sleep 30" }));
    const pid_text = try tmp.dir.readFileAlloc(io, "child.pid", std.testing.allocator, .limited(64));
    defer std.testing.allocator.free(pid_text);
    const pid = try std.fmt.parseInt(c_int, std.mem.trim(u8, pid_text, " \r\n"), 10);
    const c = @cImport({
        @cInclude("signal.h");
        @cInclude("errno.h");
    });
    try std.testing.expectEqual(@as(c_int, -1), c.kill(pid, 0));
    try std.testing.expectEqual(@as(c_int, c.ESRCH), std.c._errno().*);
}

fn requestStop(io: std.Io, state: *shutdown.State) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    state.requested.store(true, .release);
}

test "repair rejects excess output even when subprocess exits between watchdog checks" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var control = shutdown.DownloadControl.init(io, shutdown.now(io) + 10);
    try std.testing.expectError(error.WorkspaceTooLarge, runInDirectory(std.testing.allocator, io, tmp.dir, &control, 1, &.{ "/bin/sh", "-c", "printf oversized > payload" }));
}
