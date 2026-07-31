const std = @import("std");
const nzb = @import("nzb.zig");
const nntp = @import("nntp.zig");
const yenc = @import("yenc.zig");

pub const Result = struct {
    relative_path: []const u8,
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    job_id: []const u8,
    nzb_bytes: []const u8,
    cfg: anytype,
    ca_store: *nntp.CaStore,
) !Result {
    const document = try nzb.parse(allocator, nzb_bytes);
    defer document.deinit(allocator);
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    try ensureDir(io, root_dir, ".nzbunny-work");
    try ensureDir(io, root_dir, ".nzbunny-downloads");
    const work_root = try std.fmt.allocPrint(allocator, ".nzbunny-work/{s}", .{job_id});
    const output_root = try std.fmt.allocPrint(allocator, ".nzbunny-downloads/{s}", .{job_id});
    try removeTree(io, root_dir, work_root);
    try removeTree(io, root_dir, output_root);
    errdefer removeTree(io, root_dir, work_root) catch {};
    errdefer removeTree(io, root_dir, output_root) catch {};
    try ensureDir(io, root_dir, work_root);
    try ensureDir(io, root_dir, output_root);

    const outputs = try allocator.alloc(OutputFile, document.files.len);
    defer {
        for (outputs) |output| output.deinit(allocator);
        allocator.free(outputs);
    }
    var total_size: u64 = 0;
    for (document.files, 0..) |file, file_index| {
        outputs[file_index] = try fetchFile(allocator, io, root_dir, work_root, file_index, file, cfg, ca_store);
        total_size = std.math.add(u64, total_size, outputs[file_index].size) catch return error.ArtifactTooLarge;
        if (total_size > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
    try rejectDuplicateNames(outputs);
    try rejectUnsupportedSet(outputs);
    for (outputs, 0..) |output, file_index| {
        try assembleFile(allocator, io, root_dir, output_root, file_index, output);
    }
    if (document.files.len == 1)
        return .{ .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, outputs[0].name }) };
    return .{ .relative_path = output_root };
}

const OutputFile = struct {
    name: []const u8 = "",
    size: u64 = 0,
    parts: []Part = &.{},

    fn deinit(self: OutputFile, allocator: std.mem.Allocator) void {
        if (self.name.len != 0) allocator.free(self.name);
        for (self.parts) |part| allocator.free(part.rel_path);
        allocator.free(self.parts);
    }
};

const Part = struct {
    begin: u64,
    end: u64,
    rel_path: []const u8,
};

const SegmentTask = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    file_work: []const u8,
    index: usize,
    segment: nzb.Segment,
    cfg: @import("config.zig").Config,
    ca_store: *nntp.CaStore,
    parts: []Part,
    expected_name: []const u8,
    expected_size: u64,
    mutex: *std.Io.Mutex,
    first_error: *?anyerror,
};

fn fetchFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    work_root: []const u8,
    file_index: usize,
    file: nzb.File,
    cfg: anytype,
    ca_store: *nntp.CaStore,
) !OutputFile {
    var file_work_buffer: [256]u8 = undefined;
    const file_work = try std.fmt.bufPrint(&file_work_buffer, "{s}/{d}", .{ work_root, file_index });
    try ensureDir(io, root_dir, file_work);
    var parts = try allocator.alloc(Part, file.segments.len);
    errdefer allocator.free(parts);
    var name: []const u8 = "";
    var size: u64 = 0;
    const first = try fetchSegment(allocator, io, root_dir, file_work, 0, file.segments[0], cfg, ca_store);
    defer allocator.free(first.name);
    parts[0] = .{ .begin = first.begin, .end = first.end, .rel_path = first.rel_path };
    name = try allocator.dupe(u8, first.name);
    size = first.size;
    try rejectUnsupportedName(name);

    var next: usize = 1;
    while (next < file.segments.len) {
        const end = @min(file.segments.len, next + cfg.nntp_connections);
        var group: std.Io.Group = .init;
        var mutex: std.Io.Mutex = .init;
        var first_error: ?anyerror = null;
        for (file.segments[next..end], next..) |segment, index| {
            const task = SegmentTask{
                .allocator = allocator,
                .io = io,
                .root_dir = root_dir,
                .file_work = file_work,
                .index = index,
                .segment = segment,
                .cfg = cfg,
                .ca_store = ca_store,
                .parts = parts,
                .expected_name = name,
                .expected_size = size,
                .mutex = &mutex,
                .first_error = &first_error,
            };
            group.concurrent(io, fetchSegmentTask, .{task}) catch fetchSegmentTask(task);
        }
        try group.await(io);
        if (first_error) |err| return err;
        next = end;
    }
    validatePartRanges(parts, size) catch |err| {
        if (name.len != 0) allocator.free(name);
        return err;
    };
    return .{ .name = name, .size = size, .parts = parts };
}

fn fetchSegmentTask(task: SegmentTask) void {
    const decoded = fetchSegment(
        task.allocator,
        task.io,
        task.root_dir,
        task.file_work,
        task.index,
        task.segment,
        task.cfg,
        task.ca_store,
    ) catch |err| {
        recordSegmentError(task, err);
        return;
    };
    defer task.allocator.free(decoded.name);
    if (!std.mem.eql(u8, task.expected_name, decoded.name) or task.expected_size != decoded.size) {
        task.allocator.free(decoded.rel_path);
        recordSegmentError(task, error.InconsistentYencMetadata);
        return;
    }
    task.parts[task.index] = .{ .begin = decoded.begin, .end = decoded.end, .rel_path = decoded.rel_path };
}

fn recordSegmentError(task: SegmentTask, err: anyerror) void {
    task.mutex.lockUncancelable(task.io);
    defer task.mutex.unlock(task.io);
    if (task.first_error.* == null) task.first_error.* = err;
}

const DecodedPart = struct {
    name: []const u8,
    size: u64,
    begin: u64,
    end: u64,
    rel_path: []const u8,
};

fn fetchSegment(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    file_work: []const u8,
    index: usize,
    segment: nzb.Segment,
    cfg: anytype,
    ca_store: *nntp.CaStore,
) !DecodedPart {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        return fetchSegmentOnce(allocator, io, root_dir, file_work, index, segment, cfg, ca_store) catch |err| {
            if (attempt >= 3 or !retryable(err)) return err;
            std.Io.sleep(io, .fromSeconds(@as(i64, 1) << @intCast(attempt)), .awake) catch {};
            continue;
        };
    }
}

fn fetchSegmentOnce(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    file_work: []const u8,
    index: usize,
    segment: nzb.Segment,
    cfg: anytype,
    ca_store: *nntp.CaStore,
) !DecodedPart {
    var part_path_buffer: [320]u8 = undefined;
    const part_path = try std.fmt.bufPrint(&part_path_buffer, "{s}/{d}.part", .{ file_work, index });
    var tmp_path_buffer: [324]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buffer, "{s}.tmp", .{part_path});
    root_dir.deleteFile(io, tmp_path) catch {};
    var out_file = try root_dir.createFile(io, tmp_path, .{ .read = true, .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out_file.close(io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = out_file.writer(io, &file_buffer);
    var decoder = yenc.Decoder.init(allocator, &file_writer.interface);
    var session = nntp.makeSession(
        allocator,
        io,
        cfg.nntp_host,
        cfg.nntp_port,
        cfg.nntp_user,
        cfg.nntp_pass,
        ca_store,
        cfg.nntp_timeout_seconds,
    );
    defer session.deinit();
    try session.connect();
    try session.requestBody(segment.message_id);
    while (true) {
        const item = try session.readBodyLine(allocator);
        switch (item) {
            .end => break,
            .line => |line| {
                defer allocator.free(line);
                try decoder.consumeLine(line);
            },
        }
    }
    const meta = try decoder.finish();
    try file_writer.interface.flush();
    try out_file.sync(io);
    try root_dir.rename(tmp_path, root_dir, part_path, io);
    return .{
        .name = meta.name,
        .size = meta.size,
        .begin = meta.begin,
        .end = meta.end,
        .rel_path = try allocator.dupe(u8, part_path),
    };
}

fn assembleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    file_index: usize,
    output: OutputFile,
) !void {
    _ = file_index;
    const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.tmp", .{ output_root, output.name });
    defer allocator.free(out_path);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, output.name });
    defer allocator.free(final_path);
    var out = try root_dir.createFile(io, out_path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out.close(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &out_buffer);
    var buffer: [64 * 1024]u8 = undefined;
    for (output.parts) |part| {
        var input = try root_dir.openFile(io, part.rel_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        defer input.close(io);
        const size = part.end - part.begin + 1;
        var reader = std.Io.File.Reader.initSize(input, io, &buffer, size);
        const sent = try writer.interface.sendFileAll(&reader, .limited(size));
        if (sent != size) return error.DecodedPartChanged;
    }
    try writer.interface.flush();
    try out.sync(io);
    try root_dir.rename(out_path, root_dir, final_path, io);
}

fn validatePartRanges(parts: []Part, size: u64) !void {
    std.mem.sort(Part, parts, {}, struct {
        fn lessThan(_: void, a: Part, b: Part) bool {
            return a.begin < b.begin;
        }
    }.lessThan);
    var expected: u64 = 1;
    for (parts) |part| {
        if (part.begin != expected or part.end < part.begin or part.end > size) return error.InvalidYencRange;
        expected = part.end + 1;
    }
    if (expected != size + 1) return error.InvalidYencRange;
}

fn rejectDuplicateNames(outputs: []OutputFile) !void {
    for (outputs, 0..) |a, i| {
        for (outputs[i + 1 ..]) |b| {
            if (std.ascii.eqlIgnoreCase(a.name, b.name)) return error.DuplicateOutputName;
        }
    }
}

fn rejectUnsupportedSet(outputs: []OutputFile) !void {
    for (outputs) |output| try rejectUnsupportedName(output.name);
    if (outputs.len <= 1) return;
    for (outputs) |output| {
        if (archiveSingleName(output.name)) return error.SplitArchiveRejected;
    }
}

fn rejectUnsupportedName(name: []const u8) !void {
    if (endsWithIgnoreCase(name, ".par2")) return error.Par2Rejected;
    if (splitName(name)) return error.SplitArchiveRejected;
}

fn archiveSingleName(name: []const u8) bool {
    return endsWithIgnoreCase(name, ".zip") or endsWithIgnoreCase(name, ".7z") or endsWithIgnoreCase(name, ".rar");
}

fn splitName(name: []const u8) bool {
    const lower = std.ascii.allocLowerString(std.heap.page_allocator, name) catch return true;
    defer std.heap.page_allocator.free(lower);
    if (std.mem.indexOf(u8, lower, ".part") != null and endsWithIgnoreCase(lower, ".rar")) return true;
    if (lower.len >= 4 and lower[lower.len - 4] == '.' and lower[lower.len - 3] == 'r' and std.ascii.isDigit(lower[lower.len - 2]) and std.ascii.isDigit(lower[lower.len - 1])) return true;
    if (lower.len >= 4 and lower[lower.len - 4] == '.' and lower[lower.len - 3] == 'z' and std.ascii.isDigit(lower[lower.len - 2]) and std.ascii.isDigit(lower[lower.len - 1])) return true;
    if (std.mem.indexOf(u8, lower, ".7z.") != null) return true;
    return false;
}

fn retryable(err: anyerror) bool {
    return err == error.Timeout or
        err == error.ConnectionResetByPeer or
        err == error.NntpReadFailed or
        err == error.TransientNntpResponse or
        err == error.YencCrcMismatch;
}

fn ensureDir(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn removeTree(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    try dir.deleteTree(io, path);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

test "rejects split archive names" {
    try std.testing.expectError(error.SplitArchiveRejected, rejectUnsupportedName("movie.part01.rar"));
    try std.testing.expectError(error.SplitArchiveRejected, rejectUnsupportedName("movie.r01"));
    try std.testing.expectError(error.Par2Rejected, rejectUnsupportedName("movie.par2"));
    try rejectUnsupportedName("movie.rar");
}
