const std = @import("std");
const nzb = @import("nzb.zig");
const nntp = @import("nntp.zig");
const shutdown = @import("shutdown.zig");
const yenc = @import("yenc.zig");

const Budget = @import("budget.zig").Budget;

const Config = @import("config.zig").Config;

pub const Result = struct {
    relative_path: []const u8,
};

pub const Phase = @import("progress.zig").Phase;
pub const ProgressSnapshot = @import("progress.zig").ProgressSnapshot;
pub const Progress = @import("progress.zig").Progress;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    job_id: []const u8,
    document: nzb.Document,
    cfg: anytype,
    ca_store: *nntp.CaStore,
    control: *shutdown.DownloadControl,
    progress: *Progress,
) !Result {
    var watchdog: std.Io.Group = .init;
    try watchdog.concurrent(io, watchDownload, .{ progress, control, job_id });
    defer watchdog.cancel(io);
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

    const sessions = try allocator.alloc(nntp.Session, cfg.nntp_connections);
    for (sessions) |*s| {
        s.* = nntp.makeSession(
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
    }
    defer {
        for (sessions) |*s| s.deinit();
        allocator.free(sessions);
    }

    var workspace: Budget = .{ .limit = cfg.max_work_bytes };
    progress.setPhase(io, .preflight);
    std.log.info("download phase: checking the first segment of {d} files", .{document.files.len});
    try preflightPhase(allocator, io, root_dir, work_root, manifest, document.files, cfg, ca_store, sessions, control, progress, &workspace);
    const included = try allocator.alloc(bool, manifest.len);
    defer allocator.free(included);
    var included_count: usize = 0;
    for (manifest, included) |file, *keep| {
        keep.* = file.name.len != 0 and !isRepairName(file.name);
        if (keep.*) {
            try rejectUnsupportedName(file.name);
            included_count += 1;
        }
    }
    if (included_count == 0) return error.NoPayloadFiles;
    std.log.info("download selection: {d} payload files, {d} PAR2 repair files", .{ included_count, manifest.len - included_count });
    try validateAggregate(manifest, included, included_count, cfg);

    var payload_segments: usize = document.files.len;
    var remaining = std.ArrayList(WorkItem).empty;
    defer remaining.deinit(allocator);
    for (document.files, 0..) |file, file_index| {
        if (!included[file_index]) continue;
        payload_segments += file.segments.len - 1;
        for (1..file.segments.len) |segment_index| {
            if (manifest[file_index].parts[segment_index].rel_path.len != 0) continue;
            try remaining.append(allocator, .{ .file_index = file_index, .segment_index = segment_index });
        }
    }
    const has_repair_files = included_count < manifest.len;
    progress.setTotal(payload_segments);
    if (remaining.items.len > 0) {
        progress.setPhase(io, .downloading);
        std.log.info("download phase: fetching {d} remaining segments", .{remaining.items.len});
        try downloadPhase(allocator, io, root_dir, work_root, manifest, remaining.items, document.files, cfg, ca_store, sessions, control, progress, has_repair_files, &workspace);
    }

    var damaged = false;
    for (manifest, included) |file, keep| if (keep and !allPartsPresent(file.parts)) {
        damaged = true;
        break;
    };
    if (damaged) {
        if (!has_repair_files) return error.InsufficientPar2Data;
        remaining.clearRetainingCapacity();
        for (document.files, 0..) |file, file_index| {
            if (included[file_index]) continue;
            for (1..file.segments.len) |segment_index| {
                if (manifest[file_index].parts[segment_index].rel_path.len != 0) continue;
                try remaining.append(allocator, .{ .file_index = file_index, .segment_index = segment_index });
            }
        }
        if (remaining.items.len > 0) {
            progress.setTotal(total_segments);
            progress.setPhase(io, .downloading);
            std.log.info("download phase: fetching {d} PAR2 repair segments", .{remaining.items.len});
            try downloadPhase(allocator, io, root_dir, work_root, manifest, remaining.items, document.files, cfg, ca_store, sessions, control, progress, true, &workspace);
        }
        if (!hasUsableRepairFile(manifest, included)) return error.InsufficientPar2Data;
    }

    // Parts coexist with assembled output. PAR2 can retain a damaged backup,
    // so reserve a second payload copy before repair starts.
    var assembly_bytes: u64 = 0;
    for (manifest, included) |file, keep| {
        if (keep or damaged) {
            assembly_bytes = std.math.add(u64, assembly_bytes, file.size) catch return error.WorkspaceTooLarge;
            if (damaged and keep) assembly_bytes = std.math.add(u64, assembly_bytes, file.size) catch return error.WorkspaceTooLarge;
        }
    }
    const part_bytes = workspace.used.load(.acquire);
    try workspace.reserve(assembly_bytes);
    progress.setPhase(io, .assembling);
    std.log.info("download phase: assembling {d} payload files", .{included_count});
    var assembled: usize = 0;
    for (manifest, 0..) |file, file_index| {
        if (!included[file_index]) continue;
        try checkCanceled(control);
        assembled += 1;
        if (!allPartsPresent(file.parts)) {
            std.log.info("file {d}/{d} prepared for PAR2 recovery: {s}", .{ assembled, included_count, file.name });
            try assembleDamagedFile(allocator, io, root_dir, tmp_output_root, file, control, progress);
        } else {
            try validatePartRanges(file.parts, file.size);
            std.log.info("file {d}/{d} assembled: {s} ({d} segments)", .{ assembled, included_count, file.name, file.parts.len });
            try assembleFile(allocator, io, root_dir, tmp_output_root, file, control, progress);
        }
    }
    if (damaged) {
        progress.setPhase(io, .repairing);
        const repair_name = try assembleRepairFiles(allocator, io, root_dir, tmp_output_root, manifest, included, control, progress);
        std.log.info("download phase: repairing missing payload data with {s}", .{repair_name});
        try @import("repair.zig").run(allocator, io, root_dir, tmp_output_root, repair_name, control, cfg.max_work_bytes - part_bytes);
        progress.touch(io);
        for (manifest, included) |file, keep| if (keep) {
            try validateRepairedFile(allocator, io, root_dir, tmp_output_root, file);
            progress.touch(io);
        };
        cleanupRepairFiles(allocator, io, root_dir, tmp_output_root, manifest, included);
    }

    var tmp_dir_file = try root_dir.openFile(io, tmp_output_root, .{ .allow_directory = true, .follow_symlinks = false });
    try tmp_dir_file.sync(io);
    tmp_dir_file.close(io);

    try root_dir.rename(tmp_output_root, root_dir, output_root, io);

    var downloads_dir_file = try root_dir.openFile(io, ".nzbunny-downloads", .{ .allow_directory = true, .follow_symlinks = false });
    try downloads_dir_file.sync(io);
    downloads_dir_file.close(io);

    try removeTree(io, root_dir, work_root);

    if (included_count == 1) {
        for (manifest, included) |file, keep| if (keep)
            return .{ .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, file.name }) };
    }
    return .{ .relative_path = try allocator.dupe(u8, output_root) };
}

const isRecoveryName = @import("assembly.zig").isRecoveryName;
const FileManifest = @import("assembly.zig").FileManifest;
const Part = @import("assembly.zig").Part;
const allPartsPresent = @import("assembly.zig").allPartsPresent;
const hasAnyPartPresent = @import("assembly.zig").hasAnyPartPresent;
const hasUsableRepairFile = @import("assembly.zig").hasUsableRepairFile;
const assembleRepairFiles = @import("assembly.zig").assembleRepairFiles;
const sortPresentParts = @import("assembly.zig").sortPresentParts;
const assembleDamagedFile = @import("assembly.zig").assembleDamagedFile;
const cleanupRepairFiles = @import("assembly.zig").cleanupRepairFiles;
const preadChunk = @import("assembly.zig").preadChunk;
const pwriteAll = @import("assembly.zig").pwriteAll;
const expectedFileCrc = @import("assembly.zig").expectedFileCrc;
const validateRepairedFile = @import("assembly.zig").validateRepairedFile;
const assembleFile = @import("assembly.zig").assembleFile;
const validatePartRanges = @import("assembly.zig").validatePartRanges;

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
    workspace: ?*Budget = null,
    allow_repairable_errors: bool = false,
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
    sessions: []nntp.Session,
    control: *shutdown.DownloadControl,
    progress: *Progress,
    workspace: *Budget,
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
        .workspace = workspace,
    };
    var next: std.atomic.Value(usize) = .init(0);
    const worker_count = @min(files.len, sessions.len);
    if (worker_count == 0) return;
    var group: std.Io.Group = .init;
    var w: usize = 0;
    while (w < worker_count) : (w += 1) {
        group.concurrent(io, preflightWorker, .{ &ctx, &sessions[w], &next }) catch preflightWorker(&ctx, &sessions[w], &next);
    }
    try group.await(io);
    if (ctx.first_error) |err| return err;
    try resolvePreflightFailures(&ctx, &sessions[0]);
}

fn preflightWorker(ctx: *SharedCtx, session: *nntp.Session, next: *std.atomic.Value(usize)) void {
    while (!ctx.canceled.load(.acquire)) {
        if (ctx.control.isCanceled()) {
            ctx.canceled.store(true, .release);
            return;
        }
        const file_index = next.fetchAdd(1, .monotonic);
        if (file_index >= ctx.files.len) break;
        fetchItemWithSession(ctx, session, file_index, 0, true) catch |err| {
            if (ctx.files.len > 1 and isRepairableSegmentError(err)) {
                ctx.manifest[file_index].preflight_err = err;
                ctx.progress.advanced(ctx.io);
                continue;
            }
            recordError(ctx, err);
            return;
        };
    }
}

fn hasAnyKnownPar2(manifest: []const FileManifest, files: []const nzb.File) bool {
    for (manifest, files) |file, nzb_file| {
        if (file.name.len != 0 and isRepairName(file.name)) return true;
        if (subjectFileName(nzb_file.subject)) |subj| {
            if (isRepairName(subj)) return true;
        }
    }
    return false;
}

fn resolvePreflightFailures(ctx: *SharedCtx, session: *nntp.Session) !void {
    var first_err: ?anyerror = null;
    for (ctx.manifest) |file| {
        if (file.preflight_err) |err| {
            first_err = err;
            break;
        }
    }
    const initial_err = first_err orelse return;

    var has_par2 = hasAnyKnownPar2(ctx.manifest, ctx.files);
    for (ctx.manifest, 0..) |*file, file_index| {
        if (file.preflight_err == null) continue;
        if (subjectFileName(ctx.files[file_index].subject)) |subj| {
            if (isRepairName(subj)) {
                if (file.name.len == 0) file.name = try ctx.allocator.dupe(u8, subj);
                has_par2 = true;
            }
        }
    }
    if (!has_par2) return initial_err;

    for (ctx.manifest, 0..) |*file, file_index| {
        if (file.preflight_err == null) continue;
        if (file.name.len != 0 and isRepairName(file.name)) continue;
        const nzb_file = ctx.files[file_index];
        if (nzb_file.segments.len > 1) {
            for (1..nzb_file.segments.len) |seg_idx| {
                if (fetchItemWithSession(ctx, session, file_index, seg_idx, true)) |_| {
                    break;
                } else |err| {
                    if (!isRepairableSegmentError(err)) return err;
                }
            }
        }
    }

    for (ctx.manifest) |file| {
        if (file.preflight_err) |err| {
            if (file.name.len != 0 and isRepairName(file.name)) continue;
            if (file.name.len == 0 or file.size == 0) return err;
        }
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
    sessions: []nntp.Session,
    control: *shutdown.DownloadControl,
    progress: *Progress,
    allow_repairable_errors: bool,
    workspace: *Budget,
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
        .workspace = workspace,
        .allow_repairable_errors = allow_repairable_errors,
    };
    var next: std.atomic.Value(usize) = .init(0);
    const worker_count = @min(items.len, sessions.len);
    var group: std.Io.Group = .init;
    var w: usize = 0;
    while (w < worker_count) : (w += 1) {
        group.concurrent(io, downloadWorker, .{ &ctx, &sessions[w], items, &next }) catch downloadWorker(&ctx, &sessions[w], items, &next);
    }
    try group.await(io);
    if (ctx.first_error) |err| return err;
}

fn isRepairableSegmentError(err: anyerror) bool {
    return err == error.MissingArticle or
        err == error.YencCrcMismatch or
        err == error.InconsistentSegmentSize or
        err == error.InvalidYencDecodedSize or
        err == error.EmptyYencData or
        err == error.MissingYend or
        err == error.MissingYpart;
}

fn downloadWorker(ctx: *SharedCtx, session: *nntp.Session, items: []const WorkItem, next: *std.atomic.Value(usize)) void {
    while (!ctx.canceled.load(.acquire)) {
        if (ctx.control.isCanceled()) {
            ctx.canceled.store(true, .release);
            return;
        }
        const idx = next.fetchAdd(1, .monotonic);
        if (idx >= items.len) break;
        const item = items[idx];
        fetchItemWithSession(ctx, session, item.file_index, item.segment_index, false) catch |err| {
            if (ctx.allow_repairable_errors and isRepairableSegmentError(err)) {
                std.log.warn("file {d} segment {d} is unavailable or damaged ({t})", .{ item.file_index + 1, item.segment_index + 1, err });
                ctx.progress.advanced(ctx.io);
                continue;
            }
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
    file_index: usize,
    segment_index: usize,
    is_preflight: bool,
) !void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        try checkCanceled(ctx.control);
        fetchItemOnce(ctx, session, file_index, segment_index, is_preflight) catch |err| {
            if (err == error.MissingArticle) {
                if (attempt + 1 >= session.endpointCount()) return err;
                std.log.warn("segment {d}/{d} provider endpoint failover {d}/{d} after {t}", .{ file_index + 1, segment_index + 1, attempt + 2, session.endpointCount(), err });
            } else {
                if (attempt >= 3 or !nntp.isRetryableProviderFailure(err)) return err;
                std.log.warn("segment {d}/{d} retry {d}/3 after {t}", .{ file_index + 1, segment_index + 1, attempt + 1, err });
            }
            session.abort();
            if (err != error.MissingArticle) try ctx.control.wait(@as(i64, 1) << @intCast(attempt));
            continue;
        };
        ctx.progress.advanced(ctx.io);
        return;
    }
}

fn watchDownload(progress: *Progress, control: *shutdown.DownloadControl, job_id: []const u8) std.Io.Cancelable!void {
    var last_warning: i64 = 0;
    while (!control.isCanceled()) {
        const now = shutdown.now(control.io);
        if (now >= control.deadline_seconds) {
            control.timeout();
            return;
        }
        if (now - last_warning >= 30) {
            const snapshot = progress.snapshot();
            const quiet = now - snapshot.last_activity_tick;
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
    errdefer ctx.root_dir.deleteFile(ctx.io, tmp_path) catch {};
    var out_file = try ctx.root_dir.createFile(ctx.io, tmp_path, .{ .read = true, .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out_file.close(ctx.io);
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_writer = out_file.writer(ctx.io, &file_buffer);
    var decoder = yenc.Decoder.init(ctx.allocator, &file_writer.interface, ctx.cfg.max_artifact_bytes);
    defer decoder.deinit();
    decoder.workspace = ctx.workspace;

    if (session.tls == null) {
        try session.connect();
    }
    try session.requestBody(segment.message_id);
    var line_buffer: [64 * 1024 + 2]u8 = undefined;
    while (true) {
        const item = try session.readBodyLine(&line_buffer);
        switch (item) {
            .end => break,
            .line => |line| try decoder.consumeLine(line),
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

    validateDecodedPartSize(meta) catch |err| {
        std.log.err("segment {d}/{d} decoded size mismatch: begin={d} end={d} decoded={d}", .{ file_index + 1, segment_index + 1, meta.begin, meta.end, meta.decoded });
        return err;
    };

    const rel_copy = try ctx.allocator.dupe(u8, part_path);
    errdefer ctx.allocator.free(rel_copy);
    var name_copy: ?[]u8 = null;
    errdefer if (name_copy) |n| ctx.allocator.free(n);

    {
        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);
        if (!is_preflight and ctx.manifest[file_index].size != 0 and ctx.manifest[file_index].size != meta.size) {
            std.log.err("file {d} segment {d} size changed: expected {d}, received {d}", .{ file_index + 1, segment_index + 1, ctx.manifest[file_index].size, meta.size });
            return error.InconsistentYencMetadata;
        }
        if (is_preflight or ctx.manifest[file_index].size == 0) {
            const name = subjectFileName(ctx.files[file_index].subject) orelse meta.name;
            name_copy = try ctx.allocator.dupe(u8, name);
        }
    }

    try ctx.root_dir.rename(tmp_path, ctx.root_dir, part_path, ctx.io);

    {
        ctx.mutex.lockUncancelable(ctx.io);
        defer ctx.mutex.unlock(ctx.io);
        if (name_copy) |owned_name| {
            if (ctx.manifest[file_index].name.len != 0) ctx.allocator.free(ctx.manifest[file_index].name);
            ctx.manifest[file_index].name = owned_name;
            ctx.manifest[file_index].size = meta.size;
            name_copy = null;
            std.log.info("file {d} metadata: {s}, {d} bytes, {d} segments", .{ file_index + 1, owned_name, meta.size, ctx.files[file_index].segments.len });
        }
        if (ctx.manifest[file_index].parts[segment_index].rel_path.len != 0)
            ctx.allocator.free(ctx.manifest[file_index].parts[segment_index].rel_path);
        ctx.manifest[file_index].parts[segment_index] = .{
            .begin = meta.begin,
            .end = meta.end,
            .rel_path = rel_copy,
            .crc32 = meta.crc32,
        };
        decoder.keep_reservation = true;
    }
}

fn validateDecodedPartSize(meta: yenc.Part) !void {
    const range_bytes = try yenc.inclusiveRangeLength(meta.begin, meta.end);
    if (range_bytes != meta.decoded)
        return error.InconsistentSegmentSize;
}

fn validateAggregate(manifest: []FileManifest, included: []const bool, included_count: usize, cfg: anytype) !void {
    for (manifest, included) |file, keep| if (keep and file.name.len == 0) return error.PreflightIncomplete;
    try rejectDuplicateNames(manifest, included);
    try rejectUnsupportedSet(manifest, included, included_count);
    var total_size: u64 = 0;
    for (manifest, included) |file, keep| {
        if (!keep) continue;
        total_size = std.math.add(u64, total_size, file.size) catch return error.ArtifactTooLarge;
        if (total_size > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
    if (included_count > 1) {
        const envelope = zipEnvelope(included_count);
        const total_with_envelope = std.math.add(u64, total_size, envelope) catch return error.ArtifactTooLarge;
        if (total_with_envelope > cfg.max_artifact_bytes) return error.ArtifactTooLarge;
    }
}

fn zipEnvelope(num_entries: usize) u64 {
    const per_entry: u64 = 30 + 46 + 24 + 510;
    const overhead: u64 = 22 + 56 + 20;
    return per_entry * @as(u64, @intCast(num_entries)) + overhead;
}

fn rejectDuplicateNames(outputs: []FileManifest, included: []const bool) !void {
    for (outputs, 0..) |a, i| {
        if (!included[i]) continue;
        for (outputs[i + 1 ..], included[i + 1 ..]) |b, keep| {
            if (!keep) continue;
            if (std.ascii.eqlIgnoreCase(a.name, b.name)) return error.DuplicateOutputName;
        }
    }
}

fn rejectUnsupportedSet(outputs: []FileManifest, included: []const bool, included_count: usize) !void {
    if (included_count <= 1) return;
    for (outputs, included) |output, keep| {
        if (!keep) continue;
        if (archiveSingleName(output.name)) return error.SplitArchiveRejected;
    }
}

fn isRepairName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".par2");
}

fn subjectFileName(subject: []const u8) ?[]const u8 {
    var value = std.mem.trim(u8, subject, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, value, '"')) |end| {
        if (std.mem.lastIndexOfScalar(u8, value[0..end], '"')) |start| value = value[start + 1 .. end];
    } else if (std.mem.lastIndexOf(u8, value, " (")) |suffix| {
        value = std.mem.trimEnd(u8, value[0..suffix], " \t");
    }
    value = std.mem.trim(u8, value, " \t\"");
    if (value.len == 0 or value.len > 255 or std.mem.findAny(u8, value, "/\\\r\n\x00") != null) return null;
    if (std.mem.lastIndexOfScalar(u8, value, '.') == null) return null;
    return value;
}

fn rejectUnsupportedName(name: []const u8) !void {
    if (std.ascii.endsWithIgnoreCase(name, ".par2")) return error.Par2Rejected;
    if (splitName(name)) return error.SplitArchiveRejected;
}

fn archiveSingleName(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".zip") or std.ascii.endsWithIgnoreCase(name, ".7z") or std.ascii.endsWithIgnoreCase(name, ".rar");
}

fn splitName(name: []const u8) bool {
    if (std.ascii.indexOfIgnoreCase(name, ".part") != null and std.ascii.endsWithIgnoreCase(name, ".rar")) return true;
    if (name.len >= 4 and name[name.len - 4] == '.' and
        (std.ascii.toLower(name[name.len - 3]) == 'r' or std.ascii.toLower(name[name.len - 3]) == 'z') and
        std.ascii.isDigit(name[name.len - 2]) and std.ascii.isDigit(name[name.len - 1])) return true;
    if (std.ascii.indexOfIgnoreCase(name, ".7z.") != null) return true;
    return false;
}

fn checkCanceled(control: *shutdown.DownloadControl) !void {
    if (control.isTimedOut()) return error.Timeout;
    if (control.isCanceled()) return error.Canceled;
    if (shutdown.now(control.io) >= control.deadline_seconds) {
        control.timeout();
        return error.Timeout;
    }
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

test "validates decoded part size against yEnc range" {
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
    try validateDecodedPartSize(meta);
    meta.decoded = 2;
    try std.testing.expectError(error.InconsistentSegmentSize, validateDecodedPartSize(meta));
    meta.decoded = 3;
    meta.end = 2;
    try std.testing.expectError(error.InconsistentSegmentSize, validateDecodedPartSize(meta));
}

test "identifies PAR2 repair files" {
    try std.testing.expect(isRepairName("release.par2"));
    try std.testing.expect(isRepairName("release.vol03+04.PAR2"));
    try std.testing.expect(isRecoveryName("release.vol03+04.PAR2"));
    try std.testing.expect(!isRecoveryName("release.par2"));
    try std.testing.expect(!isRepairName("comic.cbr"));
}

test "extracts safe filenames from NZB subjects" {
    try std.testing.expectEqualStrings("comic.cbr", subjectFileName("comic.cbr (1/0)").?);
    try std.testing.expectEqualStrings("comic.par2", subjectFileName("\"comic.par2\" (1/1)").?);
    try std.testing.expectEqualStrings("cd915d49f55605dcc7c8853f.rar", subjectFileName("cd915d49f55605dcc7c8853f [2/4] - \"cd915d49f55605dcc7c8853f.rar\" yEnc 35472270 (1/55)").?);
    try std.testing.expect(subjectFileName("obfuscated subject") == null);
    try std.testing.expect(subjectFileName("../comic.cbr (1/1)") == null);
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

test "cleanupRepairFiles removes par2 and backup files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "out");
    {
        var f1 = try tmp.dir.createFile(io, "out/payload.bin", .{});
        f1.close(io);
        var f2 = try tmp.dir.createFile(io, "out/payload.bin.1", .{});
        f2.close(io);
        var f3 = try tmp.dir.createFile(io, "out/repair.par2", .{});
        f3.close(io);
        var f4 = try tmp.dir.createFile(io, "out/repair.vol00+01.PAR2", .{});
        f4.close(io);
    }
    const outputs = [_]FileManifest{
        .{ .name = "payload.bin", .size = 0, .parts = &.{} },
        .{ .name = "repair.par2", .size = 0, .parts = &.{} },
        .{ .name = "repair.vol00+01.PAR2", .size = 0, .parts = &.{} },
    };
    const included = [_]bool{ true, false, false };
    cleanupRepairFiles(std.testing.allocator, io, tmp.dir, "out", &outputs, &included);
    var keep = try tmp.dir.openFile(io, "out/payload.bin", .{});
    keep.close(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "out/payload.bin.1", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "out/repair.par2", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "out/repair.vol00+01.PAR2", .{}));
}

test "identifies repairable segment errors and usable repair files" {
    try std.testing.expect(isRepairableSegmentError(error.MissingArticle));
    try std.testing.expect(isRepairableSegmentError(error.YencCrcMismatch));
    try std.testing.expect(isRepairableSegmentError(error.InconsistentSegmentSize));
    try std.testing.expect(!isRepairableSegmentError(error.NntpOperationTimeout));

    const parts_ok = [_]Part{.{ .begin = 1, .end = 10, .rel_path = "0/0.part" }};
    const parts_missing = [_]Part{.{ .begin = 0, .end = 0, .rel_path = "" }};
    const manifest_incomplete = [_]FileManifest{
        .{ .name = "payload.bin", .size = 10, .parts = @constCast(&parts_ok) },
        .{ .name = "repair.par2", .size = 10, .parts = @constCast(&parts_missing) },
    };
    const included = [_]bool{ true, false };
    try std.testing.expect(!hasUsableRepairFile(&manifest_incomplete, &included));

    const parts_partial = [_]Part{
        .{ .begin = 0, .end = 0, .rel_path = "" },
        .{ .begin = 11, .end = 20, .rel_path = "1/1.part" },
    };
    const manifest_partial = [_]FileManifest{
        .{ .name = "payload.bin", .size = 10, .parts = @constCast(&parts_ok) },
        .{ .name = "repair.vol00+01.par2", .size = 20, .parts = @constCast(&parts_partial) },
    };
    try std.testing.expect(hasUsableRepairFile(&manifest_partial, &included));
}

test "validateRepairedFile requires backup proof when damaged payload lacks full-file crc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "out");
    {
        var file = try tmp.dir.createFile(io, "out/payload.bin", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "0123456789");
    }
    const damaged_parts = [_]Part{
        .{ .begin = 1, .end = 5, .rel_path = "0/0.part", .crc32 = null },
        .{ .begin = 0, .end = 0, .rel_path = "", .crc32 = null },
    };
    const output = FileManifest{
        .name = "payload.bin",
        .size = 10,
        .parts = @constCast(&damaged_parts),
    };
    try std.testing.expectError(
        error.Par2RepairFailed,
        validateRepairedFile(std.testing.allocator, io, tmp.dir, "out", output),
    );
    {
        var bak = try tmp.dir.createFile(io, "out/payload.bin.1", .{});
        bak.close(io);
    }
    try validateRepairedFile(std.testing.allocator, io, tmp.dir, "out", output);
}

test "resolvePreflightFailures rejects completely missing payload file even when par2 exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var store: nntp.CaStore = .{};
    var control = shutdown.DownloadControl.init(io, std.math.maxInt(i64));
    var progress: Progress = .{};
    var session = nntp.makeSession(std.testing.allocator, io, "example.test", 563, "u", "p", &store, 1, &control);

    var seg1 = [_]nzb.Segment{.{ .number = 1, .declared_bytes = 10, .message_id = "m1@example.test" }};
    var seg2 = [_]nzb.Segment{.{ .number = 1, .declared_bytes = 10, .message_id = "m2@example.test" }};
    var seg3 = [_]nzb.Segment{.{ .number = 1, .declared_bytes = 10, .message_id = "m3@example.test" }};
    const files = [_]nzb.File{
        .{ .subject = "part1.bin", .segments = &seg1 },
        .{ .subject = "part2.bin", .segments = &seg2 },
        .{ .subject = "repair.par2", .segments = &seg3 },
    };
    var manifest = [_]FileManifest{
        .{ .name = "part1.bin", .size = 10 },
        .{ .name = "", .size = 0, .preflight_err = error.MissingArticle },
        .{ .name = "repair.par2", .size = 10 },
    };
    var ctx = SharedCtx{
        .allocator = std.testing.allocator,
        .io = io,
        .root_dir = tmp.dir,
        .work_root = "work",
        .files = &files,
        .manifest = &manifest,
        .cfg = std.mem.zeroes(Config),
        .ca_store = &store,
        .control = &control,
        .progress = &progress,
    };
    try std.testing.expectError(error.MissingArticle, resolvePreflightFailures(&ctx, &session));
}

test "expectedFileCrc detects conflicting full-file crcs and sortPresentParts orders ranges" {
    const conflict_parts = [_]Part{
        .{ .begin = 1, .end = 5, .rel_path = "0/0.part", .crc32 = 0x11111111 },
        .{ .begin = 6, .end = 10, .rel_path = "0/1.part", .crc32 = 0x22222222 },
    };
    try std.testing.expectError(error.InconsistentYencMetadata, expectedFileCrc(&conflict_parts));

    var unsorted = [_]Part{
        .{ .begin = 0, .end = 0, .rel_path = "" },
        .{ .begin = 11, .end = 20, .rel_path = "0/2.part" },
        .{ .begin = 1, .end = 10, .rel_path = "0/1.part" },
    };
    sortPresentParts(&unsorted);
    try std.testing.expectEqual(@as(u64, 1), unsorted[0].begin);
    try std.testing.expectEqual(@as(u64, 11), unsorted[1].begin);
    try std.testing.expectEqualStrings("", unsorted[2].rel_path);
}
