const std = @import("std");
const nzb = @import("nzb.zig");
const nntp = @import("nntp.zig");
const shutdown = @import("shutdown.zig");
const yenc = @import("yenc.zig");

const Config = @import("config.zig").Config;

pub const Result = struct {
    relative_path: []const u8,
};

pub const Phase = enum(u8) {
    idle,
    parsing,
    preparing,
    preflight,
    downloading,
    assembling,
};

pub const ProgressSnapshot = struct {
    phase: Phase,
    completed: usize,
    total: usize,
    last_activity: i64,
};

pub const Progress = struct {
    phase: std.atomic.Value(Phase) = .init(.idle),
    completed: std.atomic.Value(usize) = .init(0),
    total: std.atomic.Value(usize) = .init(0),
    last_activity: std.atomic.Value(i64) = .init(0),
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
    }

    pub fn advanced(self: *Progress, io: std.Io) void {
        const completed = self.completed.fetchAdd(1, .acq_rel) + 1;
        self.last_activity.store(std.Io.Clock.real.now(io).toSeconds(), .release);
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
        };
    }
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
    progress: *Progress,
) !Result {
    progress.start(io, 0);
    progress.setPhase(io, .parsing);
    std.log.info("job {s} parsing NZB metadata ({d} bytes)", .{ job_id, nzb_bytes.len });
    var watchdog: std.Io.Group = .init;
    try watchdog.concurrent(io, watchDownload, .{ progress, control, job_id });
    defer watchdog.cancel(io);
    const document = try nzb.parse(allocator, nzb_bytes);
    defer document.deinit(allocator);
    var total_segments: usize = 0;
    for (document.files) |file| total_segments += file.segments.len;
    progress.setTotal(total_segments);
    progress.setPhase(io, .preparing);
    std.log.info("download plan: {d} files, {d} segments, {d} connections", .{ document.files.len, total_segments, cfg.nntp_connections });
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

    progress.setPhase(io, .preflight);
    std.log.info("download phase: checking the first segment of {d} files", .{document.files.len});
    try preflightPhase(allocator, io, root_dir, work_root, manifest, document.files, cfg, ca_store, control, progress);
    try validateAggregate(manifest, cfg);

    var remaining = std.ArrayList(WorkItem).empty;
    defer remaining.deinit(allocator);
    for (document.files, 0..) |file, file_index| {
        for (1..file.segments.len) |segment_index| {
            try remaining.append(allocator, .{ .file_index = file_index, .segment_index = segment_index });
        }
    }
    if (remaining.items.len > 0) {
        progress.setPhase(io, .downloading);
        std.log.info("download phase: fetching {d} remaining segments", .{remaining.items.len});
        try downloadPhase(allocator, io, root_dir, work_root, manifest, remaining.items, document.files, cfg, ca_store, control, progress);
    }

    for (manifest) |file| {
        try checkCanceled(control);
        validatePartRanges(file.parts, file.size) catch |err| return err;
    }

    progress.setPhase(io, .assembling);
    std.log.info("download phase: assembling {d} files", .{manifest.len});
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
    crc32: ?u32 = null,
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
    progress: *Progress,
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
    progress: *Progress,
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
        .progress = progress,
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
    progress: *Progress,
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
        .progress = progress,
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
            std.log.warn("segment {d}/{d} retry {d}/3 after {t}", .{ file_index + 1, segment_index + 1, attempt + 1, err });
            session.abort();
            connected.* = false;
            try ctx.control.wait(@as(i64, 1) << @intCast(attempt));
            continue;
        };
        ctx.progress.advanced(ctx.io);
        return;
    }
}

fn watchDownload(progress: *Progress, control: *shutdown.DownloadControl, job_id: []const u8) std.Io.Cancelable!void {
    var last_warning: i64 = 0;
    while (!control.isCanceled()) {
        const now = std.Io.Clock.real.now(control.io).toSeconds();
        if (now >= control.deadline_seconds) {
            control.timeout();
            return;
        }
        if (now - last_warning >= 30) {
            const snapshot = progress.snapshot();
            const quiet = now - snapshot.last_activity;
            if (quiet >= 30) {
                std.log.warn("job {s} possible stall: no segment or phase activity for {d}s ({d}/{d} segments)", .{ job_id, quiet, snapshot.completed, snapshot.total });
                last_warning = now;
            }
        }
        try std.Io.sleep(control.io, .fromMilliseconds(100), .awake);
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
        if (!((meta.part == 0 and meta.total == 0) or (meta.part == 1 and meta.total == 1)))
            return error.YencPartMismatch;
    } else {
        if (meta.part != segment.number or meta.total != @as(u32, @intCast(ctx.files[file_index].segments.len)))
            return error.YencPartMismatch;
    }
    if (meta.total != 0) {
        const expected_total: u32 = @intCast(ctx.files[file_index].segments.len);
        if (meta.total != expected_total) return error.YencPartMismatch;
    }
    try file_writer.interface.flush();
    try out_file.sync(ctx.io);

    try validateDecodedPartSize(meta, segment.declared_bytes);

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
        .crc32 = meta.crc32,
    };
}

fn validateDecodedPartSize(meta: yenc.Part, declared_bytes: u64) !void {
    const range_bytes = try inclusiveRangeLength(meta.begin, meta.end);
    if (range_bytes != declared_bytes or meta.decoded != declared_bytes)
        return error.InconsistentSegmentSize;
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
    var reader_buf: [64 * 1024]u8 = undefined;
    var expected_crc: ?u32 = null;
    var file_crc: std.hash.Crc32 = .init();
    for (output.parts) |part| {
        try checkCanceled(control);
        var input = try root_dir.openFile(io, part.rel_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        defer input.close(io);
        const size = try inclusiveRangeLength(part.begin, part.end);
        var remaining = size;
        var off: u64 = 0;
        while (remaining > 0) {
            const chunk = @min(remaining, reader_buf.len);
            const n = std.os.linux.pread(input.handle, &reader_buf, chunk, @intCast(off));
            if (n == 0) return error.DecodedPartChanged;
            if (@as(isize, @bitCast(n)) < 0) return error.DecodedPartChanged;
            file_crc.update(reader_buf[0..n]);
            try writer.interface.writeAll(reader_buf[0..n]);
            remaining -= n;
            off += n;
        }
        if (part.crc32) |crc| {
            if (expected_crc) |prev| {
                if (prev != crc) return error.YencCrcMismatch;
            } else {
                expected_crc = crc;
            }
        }
    }
    try writer.interface.flush();
    try out.sync(io);
    if (expected_crc) |crc| {
        if (file_crc.final() != crc) return error.YencCrcMismatch;
    }
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
    if (control.isTimedOut()) return error.Timeout;
    if (control.isCanceled()) return error.Canceled;
    if (std.Io.Clock.real.now(control.io).toSeconds() >= control.deadline_seconds) {
        control.timeout();
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

test "validates decoded part size against NZB declaration" {
    var meta: yenc.Part = .{
        .name = "a.bin",
        .size = 3,
        .part = 0,
        .total = 0,
        .begin = 1,
        .end = 3,
        .pcrc32 = null,
        .crc32 = null,
        .decoded = 3,
    };
    try validateDecodedPartSize(meta, 3);
    meta.decoded = 2;
    try std.testing.expectError(error.InconsistentSegmentSize, validateDecodedPartSize(meta, 3));
    meta.decoded = 3;
    meta.end = 2;
    try std.testing.expectError(error.InconsistentSegmentSize, validateDecodedPartSize(meta, 3));
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
