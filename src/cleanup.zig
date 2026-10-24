const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const artifact = @import("artifact.zig");
const max_concurrent_cleanup = 8;

const CleanupTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    root: []const u8,
    job: *const Job,
    now: i64,
    failed_before: i64,
    failures: *std.atomic.Value(u64),
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    now: i64,
) !u64 {
    var failures: std.atomic.Value(u64) = .init(0);
    const failed_before = now - cfg.retention_seconds;
    const jobs = try db.listCleanup(
        io,
        now,
        failed_before,
        now - 1800,
    );
    defer {
        for (jobs) |job| job.deinit(db.allocator);
        db.allocator.free(jobs);
    }
    var offset: usize = 0;
    while (offset < jobs.len) {
        const end = @min(offset + max_concurrent_cleanup, jobs.len);
        var group: std.Io.Group = .init;
        for (jobs[offset..end]) |*job| {
            const task = CleanupTask{ .allocator = allocator, .io = io, .db = db, .root = root, .job = job, .now = now, .failed_before = failed_before, .failures = &failures };
            group.concurrent(io, processCleanup, .{task}) catch processCleanup(task);
        }
        try group.await(io);
        offset = end;
    }
    try sweepOrphans(io, db, root);
    return failures.load(.acquire);
}

fn processCleanup(task: CleanupTask) void {
    const job = task.job.*;
    cleanupJob(task, job) catch |err| {
        _ = task.failures.fetchAdd(1, .monotonic);
        std.log.err("Job {s} cleanup failed: {t}", .{ job.id, err });
    };
}

fn cleanupJob(task: CleanupTask, job: Job) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(task.io, task.root, .{ .follow_symlinks = false });
    defer root_dir.close(task.io);
    if (job.status == .expired) return task.db.purgeExpired(task.io, job.id, task.now - 1800);
    workDirs(task.io, root_dir, job.id) catch |err| {
        std.log.err("Job {s} work cleanup failed: {t}", .{ job.id, err });
        return err;
    };
    if (job.download_path.len != 0)
        try artifact.removeValidated(task.root, job.download_path);
    if (job.artifact_path.len != 0 and !std.mem.eql(u8, job.artifact_path, job.download_path))
        try artifact.removeValidated(task.root, job.artifact_path);
    // Publication can succeed before its database commit. Generated names remain
    // owned by the job even when artifact_path was never persisted.
    for ([_][]const u8{ "bin", "zip" }) |extension| {
        var buffer: [128]u8 = undefined;
        const generated = try std.fmt.bufPrint(&buffer, ".nzbunny-artifacts/{s}.{s}", .{ job.id, extension });
        try artifact.removeValidated(task.root, generated);
    }
    if (job.status == .failed) return task.db.purgeFailed(task.io, job.id, task.failed_before);
    _ = try task.db.markExpired(task.io, job.id, job.status, task.now);
}

pub fn workDirs(io: std.Io, root_dir: std.Io.Dir, job_id: []const u8) !void {
    var work_buffer: [128]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buffer, ".nzbunny-work/{s}", .{job_id});
    try root_dir.deleteTree(io, work);
    var output_buffer: [128]u8 = undefined;
    const output = try std.fmt.bufPrint(&output_buffer, ".nzbunny-downloads/{s}", .{job_id});
    try root_dir.deleteTree(io, output);
    var tmp_buffer: [148]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buffer, ".nzbunny-downloads/.tmp-{s}", .{job_id});
    try root_dir.deleteTree(io, tmp);
}

fn sweepOrphans(io: std.Io, db: *Database, root: []const u8) !void {
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    for ([_][]const u8{ ".nzbunny-artifacts", ".nzbunny-downloads" }) |managed| {
        var dir = root_dir.openDir(io, managed, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            const is_artifact = std.mem.eql(u8, managed, ".nzbunny-artifacts");
            if (is_artifact) {
                if (entry.name.len != 36 or (!std.mem.endsWith(u8, entry.name, ".bin") and !std.mem.endsWith(u8, entry.name, ".zip"))) continue;
            } else if (entry.name.len != 32) continue;
            const id = entry.name[0..32];
            for (id) |byte| {
                if (!std.ascii.isHex(byte)) break;
            } else {
                const job = try db.get(io, id);
                if (job) |owned| {
                    owned.deinit(db.allocator);
                    continue;
                }
                var buffer: [160]u8 = undefined;
                const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ managed, entry.name });
                try artifact.removeValidated(root, path);
            }
        }
    }
}
