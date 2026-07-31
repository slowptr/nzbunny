const std = @import("std");
const nzb = @import("nzb.zig");
const nntp = @import("nntp.zig");
const shutdown = @import("shutdown.zig");
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
    control: *shutdown.DownloadControl,
) !Result {
    var watchdog: std.Io.Group = .init;
    watchdog.async(io, shutdown.DownloadControl.watch, .{control});
    defer watchdog.cancel(io);
    const document = try nzb.parse(allocator, nzb_bytes);
    defer document.deinit(allocator);
    var root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    try ensureDir(io, root_dir, ".nzbunny-work");
    try ensureDir(io, root_dir, ".nzbunny-downloads");
    const work_root = try std.fmt.allocPrint(allocator, ".nzbunny-work/{s}", .{job_id});
    defer allocator.free(work_root);
    const output_root = try std.fmt.allocPrint(allocator, ".nzbunny-downloads/{s}", .{job_id});
    defer allocator.free(output_root);
    const tmp_output_root = try std.fmt.allocPrint(allocator, ".nzbunny-downloads/.tmp-{s}", .{job_id});
    defer allocator.free(tmp_output_root);

    try removeTree(io, root_dir, work_root);
    try removeTree(io, root_dir, output_root);
    try removeTree(io, root_dir, tmp_output_root);
    errdefer removeTree(io, root_dir, work_root) catch {};
    errdefer removeTree(io, root_dir, output_root) catch {};
    errdefer removeTree(io, root_dir, tmp_output_root) catch {};
    try ensureDir(io, root_dir, work_root);
    try ensureDir(io, root_dir, tmp_output_root);

    const outputs = try allocator.alloc(OutputFile, document.files.len);
    @memset(outputs, .{});
    defer {
        for (outputs) |output| output.deinit(allocator);
        allocator.free(outputs);
    }
    var total_size: u64 = 0;
    for (document.files, 0..) |file, file_index| {
        try checkCanceled(control);
        outputs[file_index] = try fetchFile(allocator, io, root_dir, work_root, file_index, file, cfg, ca_store, control);
        std.log.info("file {d}/{d} downloaded: {s} ({d} segments)", .{ file_index + 1, document.files.len, outputs[file_index].name, file.segments.len });
        total_size = std.math.add(u64, total_size, outputs[file_index].size) catch return error.ArtifactTooLarge;
        if (total_size > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
    try rejectDuplicateNames(outputs);
    try rejectUnsupportedSet(outputs);
    for (outputs, 0..) |output, file_index| {
        try checkCanceled(control);
        try assembleFile(allocator, io, root_dir, tmp_output_root, file_index, output, control);
    }

    // Flush temporary output directory
    var tmp_dir_file = try root_dir.openFile(io, tmp_output_root, .{ .allow_directory = true, .follow_symlinks = false });
    try tmp_dir_file.sync(io);
    tmp_dir_file.close(io);

    // Atomically rename temporary output directory to final output_root
    try root_dir.rename(tmp_output_root, root_dir, output_root, io);

    // Flush .nzbunny-downloads directory
    var downloads_dir_file = try root_dir.openFile(io, ".nzbunny-downloads", .{ .allow_directory = true, .follow_symlinks = false });
    try downloads_dir_file.sync(io);
    downloads_dir_file.close(io);

    // Cleanup work root after successful publication
    try removeTree(io, root_dir, work_root);

    if (document.files.len == 1)
        return .{ .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, outputs[0].name }) };
    return .{ .relative_path = try allocator.dupe(u8, output_root) };
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

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    file_work: []const u8,
    segments: []const nzb.Segment,
    cfg: @import("config.zig").Config,
    ca_store: *nntp.CaStore,
    control: *shutdown.DownloadControl,
    parts: []Part,
    expected_name: []const u8,
    expected_size: u64,
    next_segment: *std.atomic.Value(usize),
    canceled: *std.atomic.Value(bool),
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
    control: *shutdown.DownloadControl,
) !OutputFile {
    try checkCanceled(control);
    var file_work_buffer: [256]u8 = undefined;
    const file_work = try std.fmt.bufPrint(&file_work_buffer, "{s}/{d}", .{ work_root, file_index });
    try ensureDir(io, root_dir, file_work);
    var parts = try allocator.alloc(Part, file.segments.len);
    errdefer allocator.free(parts);
    for (parts) |*p| p.* = .{ .begin = 0, .end = 0, .rel_path = "" };
    errdefer for (parts) |p| if (p.rel_path.len != 0) allocator.free(p.rel_path);

    var name: []const u8 = "";
    var size: u64 = 0;
    const first = try fetchSegment(allocator, io, root_dir, file_work, 0, file.segments[0], cfg, ca_store, control);
    defer allocator.free(first.name);
    parts[0] = .{ .begin = first.begin, .end = first.end, .rel_path = first.rel_path };
    name = try allocator.dupe(u8, first.name);
    errdefer allocator.free(name);
    size = first.size;
    try rejectUnsupportedName(name);

    if (file.segments.len > 1) {
        var next_segment: std.atomic.Value(usize) = .init(1);
        var canceled: std.atomic.Value(bool) = .init(false);
        var mutex: std.Io.Mutex = .init;
        var first_error: ?anyerror = null;
        var group: std.Io.Group = .init;

        const worker_count = @min(file.segments.len - 1, cfg.nntp_connections);
        const ctx = WorkerContext{
            .allocator = allocator,
            .io = io,
            .root_dir = root_dir,
            .file_work = file_work,
            .segments = file.segments,
            .cfg = cfg,
            .ca_store = ca_store,
            .control = control,
            .parts = parts,
            .expected_name = name,
            .expected_size = size,
            .next_segment = &next_segment,
            .canceled = &canceled,
            .mutex = &mutex,
            .first_error = &first_error,
        };

        var w: usize = 0;
        while (w < worker_count) : (w += 1) {
            group.concurrent(io, fetchSegmentWorker, .{ctx}) catch fetchSegmentWorker(ctx);
        }
        try group.await(io);
        if (first_error) |err| return err;
    }

    validatePartRanges(parts, size) catch |err| return err;
    return .{ .name = name, .size = size, .parts = parts };
}

fn fetchSegmentWorker(ctx: WorkerContext) void {
    while (!ctx.canceled.load(.acquire)) {
        checkCanceled(ctx.control) catch |err| {
            recordSegmentError(ctx, err);
            return;
        };
        const index = ctx.next_segment.fetchAdd(1, .monotonic);
        if (index >= ctx.segments.len) break;
        const segment = ctx.segments[index];
        const decoded = fetchSegment(
            ctx.allocator,
            ctx.io,
            ctx.root_dir,
            ctx.file_work,
            index,
            segment,
            ctx.cfg,
            ctx.ca_store,
            ctx.control,
        ) catch |err| {
            recordSegmentError(ctx, err);
            return;
        };
        defer ctx.allocator.free(decoded.name);
        if (!std.mem.eql(u8, ctx.expected_name, decoded.name) or ctx.expected_size != decoded.size) {
            ctx.allocator.free(decoded.rel_path);
            recordSegmentError(ctx, error.InconsistentYencMetadata);
            return;
        }
        ctx.parts[index] = .{ .begin = decoded.begin, .end = decoded.end, .rel_path = decoded.rel_path };
    }
}

fn recordSegmentError(ctx: WorkerContext, err: anyerror) void {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);
    if (ctx.first_error.* == null) ctx.first_error.* = err;
    ctx.canceled.store(true, .release);
    ctx.control.cancel();
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
    control: *shutdown.DownloadControl,
) !DecodedPart {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        try checkCanceled(control);
        return fetchSegmentOnce(allocator, io, root_dir, file_work, index, segment, cfg, ca_store, control) catch |err| {
            if (attempt >= 3 or !retryable(err)) return err;
            try control.wait(@as(i64, 1) << @intCast(attempt));
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
    control: *shutdown.DownloadControl,
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
        control,
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

    // Validate declared yEnc segment byte count
    const part_bytes = try inclusiveRangeLength(meta.begin, meta.end);
    if (part_bytes != segment.declared_bytes) return error.InconsistentSegmentSize;

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
    control: *shutdown.DownloadControl,
) !void {
    _ = file_index;
    try checkCanceled(control);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, output.name });
    defer allocator.free(final_path);
    var out = try root_dir.createFile(io, final_path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out.close(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &out_buffer);
    var buffer: [64 * 1024]u8 = undefined;
    for (output.parts) |part| {
        try checkCanceled(control);
        var input = try root_dir.openFile(io, part.rel_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        defer input.close(io);
        const size = try inclusiveRangeLength(part.begin, part.end);
        var reader = std.Io.File.Reader.initSize(input, io, &buffer, size);
        const sent = try writer.interface.sendFileAll(&reader, .limited(size));
        if (sent != size) return error.DecodedPartChanged;
    }
    try writer.interface.flush();
    try out.sync(io);
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
        expected = std.math.add(u64, part.end, 1) catch return error.InvalidYencRange;
    }
    if (expected != std.math.add(u64, size, 1) catch return error.InvalidYencRange) return error.InvalidYencRange;
}

fn inclusiveRangeLength(begin: u64, end: u64) !u64 {
    if (begin == 0 or end < begin) return error.InvalidYencRange;
    return std.math.add(u64, end - begin, 1) catch error.InvalidYencRange;
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

fn checkCanceled(control: *shutdown.DownloadControl) !void {
    if (control.isCanceled()) return error.Canceled;
    if (std.Io.Clock.real.now(control.io).toSeconds() >= control.deadline_seconds) {
        control.cancel();
        return error.Timeout;
    }
}

fn retryable(err: anyerror) bool {
    return nntp.isRetryableProviderFailure(err);
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
