const std = @import("std");
const config = @import("config.zig");
const Config = config.Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const shutdown = @import("shutdown.zig");
const AppState = @import("runtime.zig").AppState;
const nntp = @import("nntp.zig");

const css = @embedFile("assets/styles.css");
const javascript = @embedFile("assets/upload.js");
const logo = @embedFile("assets/nzbunny.png");

const http = @import("http.zig");
const Context = http.Context;
const multipart = @import("multipart.zig");
const diagnostics = @import("diagnostics.zig");
const pages = @import("pages.zig");

pub fn serve(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, ca_store: *nntp.CaStore, state: *AppState) !void {
    return http.serve(allocator, io, db, cfg, root, ca_store, state, route);
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
        const reason = diagnostics.readiness(context.io, context.db, context.cfg, context.state);
        return respondText(request, if (reason == .ready) .ok else .service_unavailable, @tagName(reason));
    }
    if (std.mem.eql(u8, target, "/metrics")) {
        if (request.head.method != .GET and request.head.method != .HEAD) return methodNotAllowed(request);
        const body = diagnostics.metrics(allocator, context.io, context.db, context.cfg, context.state) catch
            return respondText(request, .service_unavailable, "Diagnostics are unavailable.");
        defer allocator.free(body);
        return request.respond(body, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; version=0.0.4; charset=utf-8" },
            .{ .name = "cache-control", .value = "no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
        } });
    }
    if (std.mem.eql(u8, target, "/")) {
        return switch (request.head.method) {
            .GET, .HEAD => request.respond(pages.index_html, .{ .extra_headers = &.{
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
                .{ .name = "cache-control", .value = "no-store" },
                .{ .name = "x-content-type-options", .value = "nosniff" },
                .{ .name = "referrer-policy", .value = "no-referrer" },
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
    if (!context.limiter.allow(context.io, client, context.cfg.uploads_per_minute, shutdown.now(context.io)))
        return respondText(request, .too_many_requests, "The upload rate limit is reached.");
    const length = request.head.content_length orelse
        return respondText(request, .length_required, "The Content-Length header is required.");
    const overhead: u64 = 16 * 1024;
    if (length > context.cfg.max_upload_bytes + overhead)
        return respondText(request, .payload_too_large, "The upload is too large.");
    const content_type = request.head.content_type orelse
        return respondText(request, .bad_request, "The multipart content type is required.");
    const boundary = multipart.parseBoundary(content_type) catch
        return respondText(request, .bad_request, "The multipart boundary is not valid.");
    const has_capacity = context.db.hasCapacity(context.io, context.cfg.max_active_jobs) catch
        return respondText(request, .internal_server_error, "The job could not be saved.");
    if (!has_capacity)
        return respondText(request, .service_unavailable, "The service is busy. Try again soon.");

    // Account for parser growth, the returned content, and fixed buffers before
    // reading any body. Admission is independent of HTTP connection capacity.
    const upload_charge = config.uploadCharge(context.cfg.max_upload_bytes) catch
        return respondText(request, .service_unavailable, "Upload capacity is unavailable.");
    context.state.uploads.reserve(upload_charge) catch
        return respondText(request, .service_unavailable, "The service is busy. Try again soon.");
    defer context.state.uploads.release(upload_charge);
    context.state.storage.reserve(context.io, context.cfg.max_work_bytes) catch
        return respondText(request, .service_unavailable, "Storage capacity is unavailable. Try again soon.");
    context.state.storage.release(context.io, context.cfg.max_work_bytes);

    var body_buffer: [8192]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buffer);
    const part = multipart.parse(
        context.allocator,
        reader,
        boundary,
        context.cfg.max_upload_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return respondText(request, .service_unavailable, "Upload capacity is unavailable."),
        error.FileTooLarge => return respondText(request, .payload_too_large, "The NZB file is too large."),
        error.EmptyFile => return respondText(request, .bad_request, "Select a non-empty NZB file."),
        error.UnsafeFilename => return respondText(request, .bad_request, "The file name is not safe."),
        error.WrongFileType => return respondText(request, .bad_request, "Select one .nzb file."),
        else => return respondText(request, .bad_request, "The multipart upload is not valid."),
    };
    defer part.deinit(context.allocator);
    const filename = multipart.normalizeFilename(allocator, part.filename) catch |err| switch (err) {
        error.UnsafeFilename => return respondText(request, .bad_request, "The file name is not safe."),
        else => return err,
    };
    const id = (context.db.createIfCapacity(
        context.io,
        filename,
        part.content,
        now,
        context.cfg.max_active_jobs,
    ) catch return respondText(request, .internal_server_error, "The job could not be saved.")) orelse
        return respondText(request, .service_unavailable, "The service is busy. Try again soon.");
    defer context.db.allocator.free(id);
    context.state.shutdown.notifyWorker();
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
    const page = try pages.render(allocator, job, context.state.progressFor(job.id), std.Io.Clock.real.now(context.io).toSeconds());
    defer allocator.free(page);
    return request.respond(page, .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
    } });
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
    const safe_name = try downloadName(allocator, job);
    defer allocator.free(safe_name);
    const disposition = try std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{safe_name});
    defer allocator.free(disposition);
    const content_type = if (std.mem.endsWith(u8, safe_name, ".zip")) "application/zip" else "application/octet-stream";
    var response_buffer: [64 * 1024]u8 = undefined;
    var response = try request.respondStreaming(&response_buffer, .{
        .content_length = stat.size,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = content_type },
            .{ .name = "content-disposition", .value = disposition },
            .{ .name = "cache-control", .value = "private, no-store" },
            .{ .name = "x-content-type-options", .value = "nosniff" },
            .{ .name = "referrer-policy", .value = "no-referrer" },
        } },
    });
    if (response.isEliding()) {
        response.state = .{ .content_length = 0 };
        return response.end();
    }
    var file_buffer: [64 * 1024]u8 = undefined;
    var file_reader = std.Io.File.Reader.initSize(file, context.io, &file_buffer, stat.size);
    const sent = try response.writer.sendFileAll(&file_reader, .limited(stat.size));
    if (sent != stat.size) return error.DownloadFileChanged;
    return response.end();
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
        const cidr = config.parseCidr(raw) catch continue;
        const matches = switch (peer) {
            .ip4 => |peer4| switch (cidr.address) {
                .ip4 => |network4| prefixMatch(&peer4.bytes, &network4.bytes, cidr.prefix),
                else => false,
            },
            .ip6 => |peer6| switch (cidr.address) {
                .ip6 => |network6| prefixMatch(&peer6.bytes, &network6.bytes, cidr.prefix),
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
        .{ .name = "x-content-type-options", .value = "nosniff" },
        .{ .name = "referrer-policy", .value = "no-referrer" },
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

fn downloadName(allocator: std.mem.Allocator, job: Job) ![]const u8 {
    if (std.mem.endsWith(u8, job.artifact_path, ".zip")) {
        const base = if (std.mem.lastIndexOfScalar(u8, job.filename, '/')) |last|
            job.filename[last + 1 ..]
        else
            job.filename;
        const stem = if (base.len > 4 and std.ascii.endsWithIgnoreCase(base, ".nzb"))
            base[0 .. base.len - 4]
        else
            base;
        if (stem.len > 0) {
            const raw_zip = try std.fmt.allocPrint(allocator, "{s}.zip", .{stem});
            defer allocator.free(raw_zip);
            return safeDownloadName(allocator, raw_zip);
        }
        const path = job.artifact_path;
        const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |last| path[last + 1 ..] else path;
        return safeDownloadName(allocator, name);
    }
    const path = job.download_path;
    const name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |last| path[last + 1 ..] else path;
    return safeDownloadName(allocator, name);
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

test "download names cannot inject response headers" {
    const name = try safeDownloadName(std.testing.allocator, "result\r\nx-review: injected.bin");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("result__x-review__injected.bin", name);
}

test "downloadName derives zip name from nzb stem and preserves single-file names" {
    var zip_job = std.mem.zeroes(Job);
    zip_job.filename = "Ubuntu-24.04.NZB";
    zip_job.artifact_path = ".nzbunny-artifacts/0123456789abcdef0123456789abcdef.zip";
    const zip_name = try downloadName(std.testing.allocator, zip_job);
    defer std.testing.allocator.free(zip_name);
    try std.testing.expectEqualStrings("Ubuntu-24.04.zip", zip_name);

    var file_job = std.mem.zeroes(Job);
    file_job.filename = "sample.nzb";
    file_job.download_path = ".nzbunny-downloads/0123/test_direct.bin";
    file_job.artifact_path = ".nzbunny-artifacts/0123456789abcdef0123456789abcdef";
    const file_name = try downloadName(std.testing.allocator, file_job);
    defer std.testing.allocator.free(file_name);
    try std.testing.expectEqualStrings("test_direct.bin", file_name);
}

test "forwarded addresses require a trusted direct peer" {
    try std.testing.expect(trustedPeer("10.1.2.3", "10.0.0.0/8,192.0.2.0/24"));
    try std.testing.expect(!trustedPeer("198.51.100.2", "10.0.0.0/8"));
    try std.testing.expect(trustedPeer("2001:db8::2", "2001:db8::/32"));
}
