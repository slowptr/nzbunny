const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const shutdown = @import("shutdown.zig");
const worker = @import("worker.zig");
const nntp = @import("nntp.zig");

const css = @embedFile("assets/styles.css");
const javascript = @embedFile("assets/upload.js");
const logo = @embedFile("assets/nzbunny.png");

const index_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\    <meta charset="UTF-8">
    \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    \\    <link rel="stylesheet" href="/public/styles.css">
    \\    <title>nzbunny</title>
    \\</head>
    \\<body>
    \\    <main>
    \\      <div class="module-container">
    \\          <form method="post" action="/" enctype="multipart/form-data">
    \\              <div class="drop-zone" id="dropZone">
    \\                <input type="file" id="nzbfile" name="nzbfile" accept=".nzb" required>
    \\                <h2>Drop a file here</h2>
    \\                <p>or click to browse</p>
    \\                <div class="file-list" id="fileList"></div>
    \\              </div>
    \\              <button type="submit">Upload</button>
    \\          </form>
    \\      </div>
    \\    </main>
    \\    <img src="/public/nzbunny.png" alt="nzbunny logo" class="logo">
    \\    <script src="/public/upload.js"></script>
    \\</body>
    \\</html>
;

const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    root_dir: std.Io.Dir,
    ca_store: *nntp.CaStore,
    connections: std.Io.Semaphore,
    limiter: RateLimiter,
};

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

const RateLimiter = struct {
    shards: [256]RateShard = @splat(.{}),
    seed: u64 = 0,

    fn allow(self: *RateLimiter, io: std.Io, key_text: []const u8, limit: u32, now: i64) bool {
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

pub fn serve(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, ca_store: *nntp.CaStore) !void {
    const address = try std.Io.net.IpAddress.parse("0.0.0.0", cfg.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    var context = Context{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cfg = cfg,
        .root = try allocator.dupe(u8, root),
        .root_dir = root_dir,
        .ca_store = ca_store,
        .connections = .{ .permits = cfg.max_connections },
        .limiter = .{},
    };
    io.random(std.mem.asBytes(&context.limiter.seed));
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.async(io, worker.run, .{ allocator, io, db, cfg, context.root, ca_store });
    var watcher_group: std.Io.Group = .init;
    defer watcher_group.cancel(io);
    watcher_group.concurrent(io, shutdownWatcher, .{ io, &listener }) catch {};
    while (!shutdown.requested.load(.acquire)) {
        try context.connections.wait(io);
        const stream = listener.accept(io) catch |err| {
            context.connections.post(io);
            if (shutdown.requested.load(.acquire)) break;
            return err;
        };
        group.async(io, accept, .{ &context, stream });
    }
    group.await(io) catch {};
}

fn shutdownWatcher(io: std.Io, listener: *std.Io.net.Server) std.Io.Cancelable!void {
    while (!shutdown.requested.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    const stream: std.Io.net.Stream = .{ .socket = listener.socket };
    stream.shutdown(io, .both) catch {};
}

fn accept(context: *Context, stream: std.Io.net.Stream) void {
    defer context.connections.post(context.io);
    defer stream.close(context.io);
    var peer_buffer: [64]u8 = undefined;
    var peer_writer = std.Io.Writer.fixed(&peer_buffer);
    var peer_address = stream.socket.address;
    peer_address.setPort(0);
    peer_address.format(&peer_writer) catch return;
    const peer = peer_writer.buffered();
    var receive_buffer: [32 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var conn_reader = stream.reader(context.io, &receive_buffer);
    var conn_writer = stream.writer(context.io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    while (server.reader.state == .ready) {
        var header_timeout: std.Io.Group = .init;
        header_timeout.concurrent(context.io, shutdownAfter, .{
            stream,
            context.io,
            context.cfg.http_header_seconds,
        }) catch return;
        var request = server.receiveHead() catch {
            header_timeout.cancel(context.io);
            return;
        };
        header_timeout.cancel(context.io);
        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();
        var request_timeout: std.Io.Group = .init;
        request_timeout.concurrent(context.io, shutdownAfter, .{
            stream,
            context.io,
            context.cfg.http_request_seconds,
        }) catch return;
        route(&request, context, peer_address, peer, arena.allocator()) catch |err| {
            request_timeout.cancel(context.io);
            std.log.err("Request failed: {t}", .{err});
            return;
        };
        request_timeout.cancel(context.io);
    }
}

fn shutdownAfter(stream: std.Io.net.Stream, io: std.Io, seconds: u32) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
    stream.shutdown(io, .both) catch |err|
        std.log.debug("Timed out connection shutdown failed: {t}", .{err});
}

fn route(
    request: *std.http.Server.Request,
    context: *Context,
    peer_address: std.Io.net.IpAddress,
    peer: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const target = request.head.target;
    if (std.mem.eql(u8, target, "/healthz")) {
        if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
        return respondText(request, .ok, "ok");
    }
    if (std.mem.eql(u8, target, "/readyz")) {
        if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
        if (context.db.ready(context.io) and worker.provider_ready.load(.acquire)) return respondText(request, .ok, "ready");
        return respondText(request, .service_unavailable, "The service is not ready.");
    }
    if (std.mem.eql(u8, target, "/")) {
        return switch (request.head.method) {
            .GET, .HEAD => request.respond(index_html, .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
            } }),
            .POST => upload(request, context, peer_address, peer, allocator),
            else => methodNotAllowed(request),
        };
    }
    if (std.mem.eql(u8, target, "/public/styles.css"))
        return public(request, css, "text/css; charset=utf-8");
    if (std.mem.eql(u8, target, "/public/upload.js"))
        return public(request, javascript, "text/javascript; charset=utf-8");
    if (std.mem.eql(u8, target, "/public/nzbunny.png"))
        return public(request, logo, "image/png");
    if (std.mem.startsWith(u8, target, "/public/"))
        return respondText(request, .not_found, "Not found.");
    if (std.mem.startsWith(u8, target, "/job/"))
        return jobPage(request, context, target["/job/".len..], allocator);
    if (std.mem.startsWith(u8, target, "/d/"))
        return download(request, context, target["/d/".len..], allocator);
    return respondText(request, .not_found, "Not found.");
}

fn public(request: *std.http.Server.Request, content: []const u8, content_type: []const u8) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
    return request.respond(content, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = content_type },
        .{ .name = "cache-control", .value = "public, max-age=3600" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
    } });
}

fn upload(
    request: *std.http.Server.Request,
    context: *Context,
    peer_address: std.Io.net.IpAddress,
    peer: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const now = std.Io.Clock.real.now(context.io).toSeconds();
    const client = clientAddress(request, peer_address, peer, context.cfg.trusted_proxy_cidrs);
    if (!context.limiter.allow(context.io, client, context.cfg.uploads_per_minute, now))
        return respondText(request, .too_many_requests, "The upload rate limit is reached.");
    const length = request.head.content_length orelse
        return respondText(request, .length_required, "The Content-Length header is required.");
    const overhead: u64 = 16 * 1024;
    if (length > context.cfg.max_upload_bytes + overhead)
        return respondText(request, .payload_too_large, "The upload is too large.");
    const content_type = request.head.content_type orelse
        return respondText(request, .bad_request, "The multipart content type is required.");
    const boundary = parseBoundary(content_type) catch
        return respondText(request, .bad_request, "The multipart boundary is not valid.");

    var random: [16]u8 = undefined;
    context.io.random(&random);
    var temp_name_buffer: [64]u8 = undefined;
    const temp_name = std.fmt.bufPrint(&temp_name_buffer, ".nzbunny-upload-{x}.tmp", .{random}) catch unreachable;
    const temp_file = context.root_dir.createFile(context.io, temp_name, .{
        .read = true,
        .exclusive = true,
        .permissions = @enumFromInt(0o600),
    }) catch return respondText(request, .internal_server_error, "The upload could not be staged.");
    defer temp_file.close(context.io);
    defer context.root_dir.deleteFile(context.io, temp_name) catch |err|
        std.log.err("Temporary upload cleanup failed for {s}: {t}", .{ temp_name, err });

    var body_buffer: [8192]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buffer);
    const part = streamMultipart(
        allocator,
        reader,
        boundary,
        temp_file,
        context.io,
        context.cfg.max_upload_bytes,
    ) catch |err| switch (err) {
        error.FileTooLarge => return respondText(request, .payload_too_large, "The NZB file is too large."),
        error.EmptyFile => return respondText(request, .bad_request, "Select a non-empty NZB file."),
        error.UnsafeFilename => return respondText(request, .bad_request, "The file name is not safe."),
        error.WrongFileType => return respondText(request, .bad_request, "Select one .nzb file."),
        else => return respondText(request, .bad_request, "The multipart upload is not valid."),
    };
    const filename = try normalizeFilename(allocator, part.filename);
    const id = (context.db.createFileIfCapacity(
        context.io,
        filename,
        temp_file,
        part.size,
        now,
        context.cfg.max_active_jobs,
    ) catch return respondText(request, .internal_server_error, "The job could not be saved.")) orelse
        return respondText(request, .service_unavailable, "The service is busy. Try again soon.");
    defer context.db.allocator.free(id);
    const location = try std.fmt.allocPrint(allocator, "/job/{s}", .{id});
    return request.respond("", .{
        .status = .see_other,
        .extra_headers = &.{.{ .name = "location", .value = location }},
    });
}

fn jobPage(
    request: *std.http.Server.Request,
    context: *Context,
    id: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
    if (!validHex(id, 32)) return respondText(request, .not_found, "Not found.");
    const job = (try context.db.get(context.io, id)) orelse return respondText(request, .not_found, "Not found.");
    defer job.deinit(context.db.allocator);
    var page = std.Io.Writer.Allocating.init(allocator);
    const w = &page.writer;
    try w.writeAll(
        \\<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<link rel="stylesheet" href="/public/styles.css">
    );
    const details = describe(job);
    if (details.refresh) try w.writeAll("<meta http-equiv=\"refresh\" content=\"2\">");
    try w.writeAll("<title>nzbunny - job ");
    try htmlEscape(w, job.id);
    try w.writeAll("</title></head><body><main><div class=\"module-container\"><h2>");
    try w.writeAll(details.title);
    try w.writeAll("</h2><p>");
    try w.writeAll(details.detail);
    try w.writeAll("</p><div class=\"job-card\"><p><strong>job id:</strong> ");
    try htmlEscape(w, job.id);
    try w.writeAll("</p><p><strong>file:</strong> ");
    try htmlEscape(w, job.filename);
    try w.writeAll("</p><p><strong>status:</strong> <span class=\"status-");
    try w.writeAll(job.status.publicName());
    try w.writeAll("\">");
    try w.writeAll(job.status.publicName());
    try w.writeAll("</span></p>");
    const now = std.Io.Clock.real.now(context.io).toSeconds();
    if (job.status == .processing) {
        if (worker.progressFor(job.id)) |progress| {
            const percent = if (progress.total == 0) 0 else @min(100, progress.completed * 100 / progress.total);
            try w.writeAll("<p><strong>phase:</strong> ");
            try w.writeAll(progressPhaseName(progress.phase));
            try w.writeAll("</p><div class=\"progress-track\" role=\"progressbar\" aria-label=\"Download progress\" aria-valuemin=\"0\" aria-valuemax=\"100\" aria-valuenow=\"");
            try w.print("{d}\"><span style=\"width:{d}%\"></span></div>", .{ percent, percent });
            try w.print("<p class=\"progress-detail\">{d} of {d} segments ({d}%)</p>", .{ progress.completed, progress.total, percent });
            try activityStatus(w, now, progress.last_activity, 30);
        } else {
            try w.writeAll("<p><strong>phase:</strong> starting downloader</p>");
            try activityStatus(w, now, job.updated_at, 30);
        }
    } else if (job.status == .finalizing) {
        try activityStatus(w, now, job.updated_at, 90);
    } else if (job.status == .pending) {
        try w.writeAll("<p><strong>queued for:</strong> ");
        try formatDuration(w, @max(0, now - job.created_at));
        try w.writeAll("</p>");
    }
    if (job.fail_reason.len != 0) {
        try w.writeAll("<p><strong>reason:</strong> ");
        try htmlEscape(w, job.fail_reason);
        try w.writeAll("</p>");
    }
    if (job.status == .complete and job.download_token.len != 0) {
        try w.writeAll("<p><strong>download:</strong> <a href=\"/d/");
        try htmlEscape(w, job.download_token);
        try w.writeAll("\">download artifact</a></p>");
    }
    if (job.artifact_size > 0) try w.print("<p><strong>size:</strong> {d} bytes</p>", .{job.artifact_size});
    if (job.expires_at) |expiry| {
        try w.writeAll("<p><strong>expires:</strong> ");
        try formatTimestamp(w, expiry);
        try w.writeAll("</p>");
    }
    try w.writeAll("<p><strong>created:</strong> ");
    try formatTimestamp(w, job.created_at);
    try w.writeAll("</p>");
    try w.writeAll(
        \\</div></div><div class="module-container"><a href="/">upload another file</a></div>
        \\<img src="/public/nzbunny.png" alt="nzbunny logo" class="logo"></main></body></html>
    );
    return request.respond(page.writer.buffered(), .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn progressPhaseName(phase: @import("download.zig").Phase) []const u8 {
    return switch (phase) {
        .idle => "starting downloader",
        .parsing => "reading NZB metadata",
        .preparing => "preparing workspace",
        .preflight => "checking files",
        .downloading => "downloading segments",
        .assembling => "assembling files",
    };
}

fn activityStatus(writer: *std.Io.Writer, now: i64, last_activity: i64, stall_seconds: i64) !void {
    const age = @max(0, now - last_activity);
    try writer.writeAll("<p><strong>last activity:</strong> ");
    try formatDuration(writer, age);
    try writer.writeAll(" ago</p>");
    if (age >= stall_seconds) {
        try writer.writeAll("<p class=\"stall-warning\"><strong>possible stall:</strong> no progress was recorded recently. The downloader timeout is still active.</p>");
    } else {
        try writer.writeAll("<p class=\"activity-ok\">activity is current</p>");
    }
}

fn formatDuration(writer: *std.Io.Writer, seconds: i64) !void {
    if (seconds < 60) return writer.print("{d}s", .{seconds});
    const minutes = @divFloor(seconds, 60);
    const remaining = @mod(seconds, 60);
    return writer.print("{d}m {d}s", .{ minutes, remaining });
}

fn download(
    request: *std.http.Server.Request,
    context: *Context,
    token: []const u8,
    allocator: std.mem.Allocator,
) !void {
    if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
    if (!validHex(token, 64)) return respondText(request, .not_found, "The download link is not valid.");
    const job = (try context.db.getByToken(context.io, token)) orelse
        return respondText(request, .not_found, "The download link is not valid.");
    defer job.deinit(context.db.allocator);
    const now = std.Io.Clock.real.now(context.io).toSeconds();
    if (job.status == .expired or (job.expires_at != null and now >= job.expires_at.?))
        return respondText(request, .gone, "The download link has expired.");
    if (job.status != .complete or job.artifact_path.len == 0)
        return respondText(request, .conflict, "The file is not ready.");
    const file = context.root_dir.openFile(context.io, job.artifact_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch
        return respondText(request, .not_found, "The download file is not available.");
    defer file.close(context.io);
    const stat = file.stat(context.io) catch
        return respondText(request, .not_found, "The download file is not available.");
    if (stat.kind != .file or stat.size > context.cfg.max_artifact_bytes)
        return respondText(request, .not_found, "The download file is not available.");
    const safe_name = try safeDownloadName(allocator, downloadName(job));
    const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{safe_name});
    const content_type = if (std.mem.endsWith(u8, safe_name, ".zip")) "application/zip" else "application/octet-stream";
    var response_buffer: [64 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .content_length = stat.size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "private, no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        } },
    });
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = std.Io.File.Reader.initSize(file, context.io, &file_buffer, stat.size);
    const sent = try response.writer.sendFileAll(&file_reader, .limited(stat.size));
    if (sent != stat.size) return error.DownloadFileChanged;
    return response.end();
}

const MultipartPart = struct { filename: []const u8, content: []const u8 };
const StreamedMultipartPart = struct { filename: []const u8, size: u64 };

fn streamMultipart(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    boundary: []const u8,
    file: std.Io.File,
    io: std.Io,
    max: u64,
) !StreamedMultipartPart {
    var opening_buffer: [76]u8 = undefined;
    const opening = try std.fmt.bufPrint(&opening_buffer, "--{s}\r\n", .{boundary});
    var actual_opening: [76]u8 = undefined;
    reader.readSliceAll(actual_opening[0..opening.len]) catch return error.InvalidMultipart;
    if (!std.mem.eql(u8, opening, actual_opening[0..opening.len])) return error.InvalidMultipart;

    var headers = std.Io.Writer.Allocating.init(allocator);
    defer headers.deinit();
    while (true) {
        if (headers.writer.end >= 16 * 1024) return error.InvalidMultipart;
        const byte = reader.takeByte() catch return error.InvalidMultipart;
        try headers.writer.writeByte(byte);
        if (std.mem.endsWith(u8, headers.writer.buffered(), "\r\n\r\n")) break;
    }
    const header_bytes = headers.writer.buffered()[0 .. headers.writer.end - 4];
    const raw_filename = try parsePartHeaders(header_bytes);
    const filename = try allocator.dupe(u8, raw_filename);

    var closing_buffer: [80]u8 = undefined;
    const closing = try std.fmt.bufPrint(&closing_buffer, "\r\n--{s}--\r\n", .{boundary});
    const chunk = try allocator.alloc(u8, 64 * 1024 + closing.len);
    defer allocator.free(chunk);
    var pending: usize = 0;
    var size: u64 = 0;
    var file_buffer: [8192]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    while (true) {
        const count = reader.readSliceShort(chunk[pending..]) catch return error.InvalidMultipart;
        const available = pending + count;
        if (std.mem.findPosLinear(u8, chunk[0..available], 0, closing)) |pos| {
            size = std.math.add(u64, size, pos) catch return error.FileTooLarge;
            if (size > max) return error.FileTooLarge;
            try file_writer.interface.writeAll(chunk[0..pos]);
            if (pos + closing.len != available) return error.InvalidMultipart;
            var extra: [1]u8 = undefined;
            if ((reader.readSliceShort(&extra) catch return error.InvalidMultipart) != 0)
                return error.InvalidMultipart;
            try file_writer.interface.flush();
            if (size == 0) return error.EmptyFile;
            return .{ .filename = filename, .size = size };
        }
        if (count == 0) return error.InvalidMultipart;
        if (available > closing.len) {
            const write_len = available - closing.len;
            size = std.math.add(u64, size, write_len) catch return error.FileTooLarge;
            if (size > max) return error.FileTooLarge;
            try file_writer.interface.writeAll(chunk[0..write_len]);
            std.mem.copyForwards(u8, chunk[0..closing.len], chunk[write_len..available]);
            pending = closing.len;
        } else {
            pending = available;
        }
    }
}

fn parsePartHeaders(headers: []const u8) ![]const u8 {
    var filename: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "Content-Disposition:")) {
            if (filename != null or std.mem.findPosLinear(u8, line, 0, "name=\"nzbfile\"") == null or
                std.mem.findPosLinear(u8, line, 0, "filename*=") != null) return error.InvalidMultipart;
            const key = "filename=\"";
            const start = std.mem.findPosLinear(u8, line, 0, key) orelse return error.InvalidMultipart;
            const rest = line[start + key.len ..];
            const end = std.mem.findScalar(u8, rest, '"') orelse return error.InvalidMultipart;
            filename = rest[0..end];
        }
    }
    const name = filename orelse return error.InvalidMultipart;
    if (name.len == 0 or std.mem.findAny(u8, name, "/\\\r\n\x00") != null) return error.UnsafeFilename;
    if (!endsWithIgnoreCase(name, ".nzb")) return error.WrongFileType;
    return name;
}

pub fn parseBoundary(content_type: []const u8) ![]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data;")) return error.InvalidBoundary;
    const marker = "boundary=";
    const pos = std.mem.findPosLinear(u8, content_type, 0, marker) orelse return error.InvalidBoundary;
    var value = std.mem.trim(u8, content_type[pos + marker.len ..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len == 0 or value.len > 70 or std.mem.findAny(u8, value, "\r\n") != null) return error.InvalidBoundary;
    return value;
}

pub fn parseMultipart(body: []const u8, boundary: []const u8, max: u64) !MultipartPart {
    var marker_buffer: [76]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buffer, "--{s}", .{boundary});
    if (!std.mem.startsWith(u8, body, marker)) return error.InvalidMultipart;
    const head_start = marker.len + 2;
    if (body.len <= head_start or !std.mem.eql(u8, body[marker.len..head_start], "\r\n")) return error.InvalidMultipart;
    const head_end = std.mem.findPosLinear(u8, body, head_start, "\r\n\r\n") orelse return error.InvalidMultipart;
    const headers = body[head_start..head_end];
    if (std.mem.findPosLinear(u8, headers, 0, "\r\n\r\n") != null) return error.InvalidMultipart;
    const name = try parsePartHeaders(headers);
    const data_start = head_end + 4;
    var closing_buffer: [80]u8 = undefined;
    const closing = try std.fmt.bufPrint(&closing_buffer, "\r\n--{s}--\r\n", .{boundary});
    if (!std.mem.endsWith(u8, body, closing)) return error.InvalidMultipart;
    const data_end = body.len - closing.len;
    if (data_end < data_start) return error.InvalidMultipart;
    const content = body[data_start..data_end];
    var next_marker_buffer: [80]u8 = undefined;
    const next_marker = try std.fmt.bufPrint(&next_marker_buffer, "\r\n--{s}\r\n", .{boundary});
    if (std.mem.findPosLinear(u8, content, 0, next_marker) != null) return error.InvalidMultipart;
    if (content.len == 0) return error.EmptyFile;
    if (content.len > max) return error.FileTooLarge;
    return .{ .filename = name, .content = content };
}

fn normalizeFilename(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var output = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |byte, i| {
        if (byte < 0x20 or byte == 0x7f) return error.UnsafeFilename;
        output[i] = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_') byte else '_';
    }
    if (output.len == 4 and endsWithIgnoreCase(output, ".nzb")) return error.UnsafeFilename;
    return output;
}

pub fn htmlEscape(writer: *std.Io.Writer, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(byte),
    };
}

fn describe(job: Job) struct { title: []const u8, detail: []const u8, refresh: bool } {
    return switch (job.status) {
        .pending => .{ .title = "Queued", .detail = "Your NZB is in the queue.", .refresh = true },
        .processing => .{ .title = "Downloading", .detail = "The embedded downloader processes the job. This page refreshes automatically.", .refresh = true },
        .finalizing => .{ .title = "Finalizing", .detail = "The file is almost ready. Wait a few seconds.", .refresh = true },
        .complete => .{ .title = "Ready", .detail = "Your temporary download link is active until it expires.", .refresh = false },
        .expired => .{ .title = "Expired", .detail = "This temporary download expired and was removed.", .refresh = false },
        .failed => .{ .title = "Failed", .detail = "The job did not complete.", .refresh = false },
    };
}

fn formatTimestamp(writer: *std.Io.Writer, timestamp: i64) !void {
    if (timestamp < 0) return writer.print("{d} UTC", .{timestamp});
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(timestamp) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    try writer.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        weekdays[epoch_day.day % 7],
        month_day.day_index + 1,
        months[month_day.month.numeric() - 1],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn clientAddress(
    request: *const std.http.Server.Request,
    peer_address: std.Io.net.IpAddress,
    peer: []const u8,
    trusted: []const u8,
) []const u8 {
    if (!trustedAddress(peer_address, trusted)) return peer;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "x-forwarded-for")) {
            const comma = std.mem.findScalar(u8, header.value, ',') orelse header.value.len;
            const first = std.mem.trim(u8, header.value[0..comma], " \t");
            if (validIp(first)) return first;
        }
    }
    return peer;
}

pub fn trustedPeer(peer_text: []const u8, cidrs: []const u8) bool {
    const peer = std.Io.net.IpAddress.parse(peer_text, 0) catch return false;
    return trustedAddress(peer, cidrs);
}

fn trustedAddress(peer: std.Io.net.IpAddress, cidrs: []const u8) bool {
    var values = std.mem.splitScalar(u8, cidrs, ',');
    while (values.next()) |raw| {
        const value = std.mem.trim(u8, raw, " \t");
        if (value.len == 0) continue;
        const slash = std.mem.findScalar(u8, value, '/') orelse continue;
        const network = std.Io.net.IpAddress.parse(value[0..slash], 0) catch continue;
        const prefix = std.fmt.parseInt(u8, value[slash + 1 ..], 10) catch continue;
        const matches = switch (peer) {
            .ip4 => |peer4| switch (network) {
                .ip4 => |network4| prefixMatch(&peer4.bytes, &network4.bytes, prefix),
                else => false,
            },
            .ip6 => |peer6| switch (network) {
                .ip6 => |network6| prefixMatch(&peer6.bytes, &network6.bytes, prefix),
                else => false,
            },
        };
        if (matches) return true;
    }
    return false;
}

fn prefixMatch(peer: []const u8, network: []const u8, prefix: u8) bool {
    if (prefix > peer.len * 8 or peer.len != network.len) return false;
    const whole = prefix / 8;
    if (!std.mem.eql(u8, peer[0..whole], network[0..whole])) return false;
    const bits = prefix % 8;
    if (bits == 0) return true;
    const mask: u8 = @as(u8, 0xff) << @intCast(8 - bits);
    return peer[whole] & mask == network[whole] & mask;
}

fn validIp(value: []const u8) bool {
    _ = std.Io.net.IpAddress.parse(value, 0) catch return false;
    return true;
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, message: []const u8) !void {
    return request.respond(message, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn methodNotAllowed(request: *std.http.Server.Request) !void {
    return respondText(request, .method_not_allowed, "The method is not allowed.");
}

fn validHex(value: []const u8, length: usize) bool {
    if (value.len != length) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (value.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn downloadName(job: Job) []const u8 {
    const path = if (std.mem.endsWith(u8, job.artifact_path, ".zip"))
        job.artifact_path
    else
        job.download_path;
    const last = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[last + 1 ..];
}

fn safeDownloadName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len == 0) return allocator.dupe(u8, "download.bin");
    const result = try allocator.alloc(u8, raw.len);
    for (raw, 0..) |byte, i| {
        result[i] = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_')
            byte
        else
            '_';
    }
    return result;
}

test "strict multipart accepts one non-empty nzb" {
    const body =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"ok.nzb\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n<nzb/>\r\n--abc--\r\n";
    const part = try parseMultipart(body, "abc", 1024);
    try std.testing.expectEqualStrings("ok.nzb", part.filename);
    try std.testing.expectEqualStrings("<nzb/>", part.content);
    try std.testing.expectError(error.FileTooLarge, parseMultipart(body, "abc", 2));
}

test "multipart rejects unsafe metadata and extra parts" {
    const unsafe =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"../bad.nzb\"\r\n\r\nx\r\n--abc--\r\n";
    try std.testing.expectError(error.UnsafeFilename, parseMultipart(unsafe, "abc", 100));
    const extra =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"ok.nzb\"\r\n\r\nx\r\n" ++
        "--abc\r\nContent-Disposition: form-data; name=\"other\"\r\n\r\ny\r\n--abc--\r\n";
    try std.testing.expectError(error.InvalidMultipart, parseMultipart(extra, "abc", 100));
}

test "HTML escaping covers active characters" {
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    try htmlEscape(&output.writer, "<a x='\"'>&");
    try std.testing.expectEqualStrings("&lt;a x=&#39;&quot;&#39;&gt;&amp;", output.writer.buffered());
}

test "download names cannot inject response headers" {
    const name = try safeDownloadName(std.testing.allocator, "result\r\nx-review: injected.bin");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("result__x-review__injected.bin", name);
}

test "forwarded addresses require a trusted direct peer" {
    try std.testing.expect(trustedPeer("10.1.2.3", "10.0.0.0/8,192.0.2.0/24"));
    try std.testing.expect(!trustedPeer("198.51.100.2", "10.0.0.0/8"));
    try std.testing.expect(trustedPeer("2001:db8::2", "2001:db8::/32"));
}

test "rate limits are isolated and windows expire" {
    var limiter: RateLimiter = .{};
    const io = std.testing.io;
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 100));
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 101));
    try std.testing.expect(!limiter.allow(io, "192.0.2.1", 2, 102));
    try std.testing.expect(limiter.allow(io, "192.0.2.2", 2, 102));
    try std.testing.expect(limiter.allow(io, "192.0.2.1", 2, 160));
}
