const std = @import("std");
const nzb = @import("nzb.zig");
const nntp = @import("nntp.zig");
const shutdown = @import("shutdown.zig");
const yenc = @import("yenc.zig");

const Config = @import("config.zig").Config;

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

    const manifest = try allocator.alloc(FileManifest, document.files.len);
    @memset(manifest, .{});
    defer {
        for (manifest) |file| file.deinit(allocator);
        allocator.free(manifest);
    }

    for (document.files, 0..) |file, file_index| {
        var file_work_buffer: [256]u8 = undefined;
        const file_work = try std.fmt.bufPrint(&file_work_buffer, "{s}/{d}", .{ work_root, file_index });
        try ensureDir(io, root_dir, file_work);
        manifest[file_index].parts = try allocator.alloc(Part, file.segments.len);
        for (manifest[file_index].parts) |*p| p.* = .{ .begin = 0, .end = 0, .rel_path = "" };
    }

    try preflightPhase(allocator, io, root_dir, work_root, manifest, document.files, cfg, ca_store, control);
    try validateAggregate(manifest, cfg);

    var remaining = std.ArrayList(WorkItem).empty;
    defer remaining.deinit(allocator);
    for (document.files, 0..) |file, file_index| {
        for (1..file.segments.len) |segment_index| {
            try remaining.append(allocator, .{ .file_index = file_index, .segment_index = segment_index });
        }
    }
    if (remaining.items.len > 0)
        try downloadPhase(allocator, io, root_dir, work_root, manifest, remaining.items, document.files, cfg, ca_store, control);

    for (manifest) |file| {
        try checkCanceled(control);
        validatePartRanges(file.parts, file.size) catch |err| return err;
    }

    for (manifest, 0..) |file, file_index| {
        try checkCanceled(control);
        std.log.info("file {d}/{d} assembled: {s} ({d} segments)", .{ file_index + 1, document.files.len, file.name, file.parts.len });
        try assembleFile(allocator, io, root_dir, tmp_output_root, file, control);
    }

    var tmp_dir_file = try root_dir.openFile(io, tmp_output_root, .{ .allow_directory = true, .follow_symlinks = false });
    try tmp_dir_file.sync(io);
    tmp_dir_file.close(io);

    try root_dir.rename(tmp_output_root, root_dir, output_root, io);

    var downloads_dir_file = try root_dir.openFile(io, ".nzbunny-downloads", .{ .allow_directory = true, .follow_symlinks = false });
    try downloads_dir_file.sync(io);
    downloads_dir_file.close(io);

    try removeTree(io, root_dir, work_root);

    if (document.files.len == 1)
        return .{ .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, manifest[0].name }) };
    return .{ .relative_path = try allocator.dupe(u8, output_root) };
}

const FileManifest = struct {
    name: []const u8 = "",
    size: u64 = 0,
    parts: []Part = &.{},

    fn deinit(self: FileManifest, allocator: std.mem.Allocator) void {
        if (self.name.len != 0) allocator.free(self.name);
        for (self.parts) |part| if (part.rel_path.len != 0) allocator.free(part.rel_path);
        if (self.parts.len > 0) allocator.free(self.parts);
    }
};

const Part = struct {
    begin: u64,
    end: u64,
    rel_path: []const u8,
};

const WorkItem = struct {
    file_index: usize,
    segment_index: usize,
};

const SharedCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    work_root: []const u8,
    files: []const nzb.File,
    manifest: []FileManifest,
    cfg: Config,
    ca_store: *nntp.CaStore,
    control: *shutdown.DownloadControl,
    mutex: std.Io.Mutex = .init,
    first_error: ?anyerror = null,
    canceled: std.atomic.Value(bool) = .init(false),
};

fn preflightPhase(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    work_root: []const u8,
    manifest: []FileManifest,
    files: []const nzb.File,
    cfg: anytype,
    ca_store: *nntp.CaStore,
    control: *shutdown.DownloadControl,
) !void {
    if (files.len == 0) return;
    var ctx = SharedCtx{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .work_root = work_root,
        .files = files,
        .manifest = manifest,
        .cfg = cfg,
        .ca_store = ca_store,
        .control = control,
    };
    var next: std.atomic.Value(usize) = .init(0);
    const worker_count = @min(files.len, cfg.nntp_connections);
    if (worker_count == 0) return;
    var group: std.Io.Group = .init;
    var w: usize = 0;
    while (w < worker_count) : (w += 1) {
        group.concurrent(io, preflightWorker, .{ &ctx, &next }) catch preflightWorker(&ctx, &next);
    }
    try group.await(io);
    if (ctx.first_error) |err| return err;
}

fn preflightWorker(ctx: *SharedCtx, next: *std.atomic.Value(usize)) void {
    var session = nntp.makeSession(
        ctx.allocator,
        ctx.io,
        ctx.cfg.nntp_host,
        ctx.cfg.nntp_port,
        ctx.cfg.nntp_user,
        ctx.cfg.nntp_pass,
        ctx.ca_store,
        ctx.cfg.nntp_timeout_seconds,
        ctx.control,
    );
    defer session.deinit();
    var connected = false;
    while (!ctx.canceled.load(.acquire)) {
        if (ctx.control.isCanceled()) {
            ctx.canceled.store(true, .release);
            return;
        }
        const file_index = next.fetchAdd(1, .monotonic);
        if (file_index >= ctx.files.len) break;
        fetchItemWithSession(ctx, &session, &connected, file_index, 0, true) catch |err| {
            recordError(ctx, err);
            return;
        };
    }
}

fn downloadPhase(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    work_root: []const u8,
    manifest: []FileManifest,
    items: []const WorkItem,
    files: []const nzb.File,
    cfg: anytype,
    ca_store: *nntp.CaStore,
    control: *shutdown.DownloadControl,
) !void {
    var ctx = SharedCtx{
        .allocator = allocator,
        .io = io,
        .root_dir = root_dir,
        .work_root = work_root,
        .files = files,
        .manifest = manifest,
        .cfg = cfg,
        .ca_store = ca_store,
        .control = control,
    };
    var next: std.atomic.Value(usize) = .init(0);
    const worker_count = @min(items.len, cfg.nntp_connections);
    var group: std.Io.Group = .init;
    var w: usize = 0;
    while (w < worker_count) : (w += 1) {
        group.concurrent(io, downloadWorker, .{ &ctx, items, &next }) catch downloadWorker(&ctx, items, &next);
    }
    try group.await(io);
    if (ctx.first_error) |err| return err;
}

fn downloadWorker(ctx: *SharedCtx, items: []const WorkItem, next: *std.atomic.Value(usize)) void {
    var session = nntp.makeSession(
        ctx.allocator,
        ctx.io,
        ctx.cfg.nntp_host,
        ctx.cfg.nntp_port,
        ctx.cfg.nntp_user,
        ctx.cfg.nntp_pass,
        ctx.ca_store,
        ctx.cfg.nntp_timeout_seconds,
        ctx.control,
    );
    defer session.deinit();
    var connected = false;
    while (!ctx.canceled.load(.acquire)) {
        if (ctx.control.isCanceled()) {
            ctx.canceled.store(true, .release);
            return;
        }
        const idx = next.fetchAdd(1, .monotonic);
        if (idx >= items.len) break;
        const item = items[idx];
        fetchItemWithSession(ctx, &session, &connected, item.file_index, item.segment_index, false) catch |err| {
            recordError(ctx, err);
            return;
        };
    }
}

fn recordError(ctx: *SharedCtx, err: anyerror) void {
    ctx.mutex.lockUncancelable(ctx.io);
    defer ctx.mutex.unlock(ctx.io);
    if (ctx.first_error == null) ctx.first_error = err;
    ctx.canceled.store(true, .release);
    ctx.control.cancel();
}

fn fetchItemWithSession(
    ctx: *SharedCtx,
    session: *nntp.Session,
    connected: *bool,
    file_index: usize,
    segment_index: usize,
    is_preflight: bool,
) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        try checkCanceled(ctx.control);
        fetchItemOnce(ctx, session, connected, file_index, segment_index, is_preflight) catch |err| {
            if (attempt >= 3 or !retryable(err)) return err;
            session.abort();
            connected.* = false;
            try ctx.control.wait(@as(i64, 1) << @intCast(attempt));
            continue;
        };
        return;
    }
}

fn fetchItemOnce(
    ctx: *SharedCtx,
    session: *nntp.Session,
    connected: *bool,
    file_index: usize,
    segment_index: usize,
    is_preflight: bool,
) !void {
    const file = ctx.files[file_index];
    const segment = file.segments[segment_index];

    var part_path_buffer: [320]u8 = undefined;
    const part_path = try std.fmt.bufPrint(&part_path_buffer, "{s}/{d}/{d}.part", .{ ctx.work_root, file_index, segment_index });
    var tmp_path_buffer: [324]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buffer, "{s}.tmp", .{part_path});
    ctx.root_dir.deleteFile(ctx.io, tmp_path) catch {};
    var out_file = try ctx.root_dir.createFile(ctx.io, tmp_path, .{ .read = true, .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out_file.close(ctx.io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = out_file.writer(ctx.io, &file_buffer);
    var decoder = yenc.Decoder.init(ctx.allocator, &file_writer.interface, ctx.cfg.max_artifact_bytes);
    defer decoder.deinit();

    if (!connected.*) {
        try session.connect();
        connected.* = true;
    }
    try session.requestBody(segment.message_id);
    while (true) {
        const item = try session.readBodyLine(ctx.allocator);
        switch (item) {
            .end => break,
            .line => |line| {
                defer ctx.allocator.free(line);
                try decoder.consumeLine(line);
            },
        }
    }
    const meta = try decoder.finish();
    if (ctx.files[file_index].segments.len == 1) {
        if (meta.part != 0) return error.YencPartMismatch;
    } else if (meta.part != segment.number) return error.YencPartMismatch;
    try file_writer.interface.flush();
    try out_file.sync(ctx.io);

    const part_bytes = try inclusiveRangeLength(meta.begin, meta.end);
    if (part_bytes != segment.declared_bytes) return error.InconsistentSegmentSize;

    if (is_preflight) {
        try rejectUnsupportedName(meta.name);
        ctx.manifest[file_index].name = try ctx.allocator.dupe(u8, meta.name);
        ctx.manifest[file_index].size = meta.size;
    } else {
        if (!std.mem.eql(u8, ctx.manifest[file_index].name, meta.name) or
            ctx.manifest[file_index].size != meta.size)
            return error.InconsistentYencMetadata;
    }

    try ctx.root_dir.rename(tmp_path, ctx.root_dir, part_path, ctx.io);
    ctx.manifest[file_index].parts[segment_index] = .{
        .begin = meta.begin,
        .end = meta.end,
        .rel_path = try ctx.allocator.dupe(u8, part_path),
    };
}

fn validateAggregate(manifest: []FileManifest, cfg: anytype) !void {
    for (manifest) |file| if (file.name.len == 0) return error.PreflightIncomplete;
    try rejectDuplicateNames(manifest);
    try rejectUnsupportedSet(manifest);
    var total_size: u64 = 0;
    for (manifest) |file| {
        total_size = std.math.add(u64, total_size, file.size) catch return error.ArtifactTooLarge;
        if (total_size > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
    if (manifest.len > 1) {
        const envelope = zipEnvelope(manifest.len);
        const total_with_envelope = std.math.add(u64, total_size, envelope) catch return error.ArtifactTooLarge;
        if (total_with_envelope > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
}

fn zipEnvelope(num_entries: usize) u64 {
    const per_entry: u64 = 30 + 46 + 24 + 510;
    const overhead: u64 = 22 + 56 + 20;
    return per_entry * @as(u64, @intCast(num_entries)) + overhead;
}

fn assembleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    output: FileManifest,
    control: *shutdown.DownloadControl,
) !void {
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

fn rejectDuplicateNames(outputs: []FileManifest) !void {
    for (outputs, 0..) |a, i| {
        for (outputs[i + 1 ..]) |b| {
            if (std.ascii.eqlIgnoreCase(a.name, b.name)) return error.DuplicateOutputName;
        }
    }
}

fn rejectUnsupportedSet(outputs: []FileManifest) !void {
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
    var opened = dir.openFile(io, path, .{ .allow_directory = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.SymLinkLoop => return error.PathNotSafe,
        else => return err,
    };
    opened.close(io);
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

test "zip envelope grows with entry count" {
    try std.testing.expect(zipEnvelope(2) < zipEnvelope(10));
    try std.testing.expect(zipEnvelope(0) > 0);
}
