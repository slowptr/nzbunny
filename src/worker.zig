const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const Job = @import("database.zig").Job;
const artifact = @import("artifact.zig");

const SabState = enum { queued, complete, failed, deleted, unknown };
const SabResult = struct {
    state: SabState,
    nzo_id: []const u8 = "",
    storage: []const u8 = "",
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8) void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    var last_cleanup: i64 = 0;
    while (true) {
        const now = std.Io.Clock.real.now(io).toSeconds();
        cycle(allocator, io, db, cfg, root, &client, now) catch |err|
            std.log.err("The worker cycle failed: {t}", .{err});
        if (now - last_cleanup >= cfg.cleanup_seconds) {
            cleanup(allocator, io, db, cfg, root, &client, now) catch |err|
                std.log.err("The cleanup cycle failed: {t}", .{err});
            last_cleanup = now;
        }
        std.Io.sleep(io, .fromSeconds(cfg.poll_seconds), .awake) catch return;
    }
}

fn cycle(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    client: *std.http.Client,
    now: i64,
) !void {
    const jobs = try db.listWork(io);
    defer db.allocator.free(jobs);
    for (jobs) |job| {
        defer job.deinit(db.allocator);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const job_allocator = arena.allocator();
        switch (job.status) {
            .pending => submitPending(job_allocator, io, db, cfg, client, job, now) catch |err|
                std.log.err("Job {s} submission failed: {t}", .{ job.id, err }),
            .submitting => reconcileSubmitting(job_allocator, io, db, cfg, client, job, now) catch |err|
                std.log.err("Job {s} reconciliation failed: {t}", .{ job.id, err }),
            .processing => pollProcessing(job_allocator, io, db, cfg, client, job, now) catch |err|
                std.log.err("Job {s} poll failed: {t}", .{ job.id, err }),
            .finalizing => finalize(job_allocator, io, db, cfg, root, job, now) catch |err| {
                std.log.err("Job {s} finalization failed: {t}", .{ job.id, err });
                db.fail(io, job.id, "The output artifact could not be prepared.", now) catch |db_err|
                    std.log.err("Job {s} failure state could not be saved: {t}", .{ job.id, db_err });
            },
            else => {},
        }
    }
}

fn submitPending(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    client: *std.http.Client,
    job: Job,
    now: i64,
) !void {
    if (!try db.claimPending(io, job.id, now)) return;
    const nzo_id = upload(allocator, client, cfg, job) catch |err| {
        if (err == error.SabnzbdRejectedUpload) {
            try db.fail(io, job.id, "SABnzbd rejected the uploaded NZB.", now);
            return;
        }
        if (definitelyNotSent(err)) {
            if (now - job.created_at >= 1800)
                try db.fail(io, job.id, "SABnzbd did not accept the upload in 30 minutes.", now)
            else
                _ = try db.retryPending(io, job.id, now);
        }
        return err;
    };
    _ = try db.resumeSubmitting(io, job.id, nzo_id, now);
}

fn reconcileSubmitting(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    client: *std.http.Client,
    job: Job,
    now: i64,
) !void {
    const result = findByName(allocator, client, cfg, job.sab_name) catch |err| {
        if (now - job.created_at >= 1800) {
            try db.fail(io, job.id, "SABnzbd could not confirm the upload result within 30 minutes.", now);
            return;
        }
        return err;
    };
    if (result.nzo_id.len != 0) {
        _ = try db.resumeSubmitting(io, job.id, result.nzo_id, now);
        return;
    }
    if (now - job.created_at >= 1800)
        try db.fail(io, job.id, "The SABnzbd upload result stayed unknown for 30 minutes.", now);
}

fn pollProcessing(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    client: *std.http.Client,
    job: Job,
    now: i64,
) !void {
    const result = findById(allocator, client, cfg, job.nzo_id) catch |err| {
        if (now - job.created_at >= 7200) {
            try db.fail(io, job.id, "SABnzbd could not report the job state within two hours.", now);
            return;
        }
        return err;
    };
    switch (result.state) {
        .complete => {
            if (result.storage.len == 0) {
                if (now - job.created_at >= 7200)
                    try db.fail(io, job.id, "SABnzbd did not give an output path.", now);
                return;
            }
            _ = try db.beginFinalizing(io, job.id, result.storage, now);
        },
        .failed, .deleted => try db.fail(io, job.id, "SABnzbd reported that the job failed or was deleted.", now),
        .unknown => if (now - job.created_at >= 7200)
            try db.fail(io, job.id, "The SABnzbd job state stayed unknown for two hours.", now),
        .queued => {},
    }
}

fn finalize(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    job: Job,
    now: i64,
) !void {
    const result = try artifact.prepare(allocator, root, job.id, job.download_path, cfg.max_artifact_bytes);
    var attempts: usize = 0;
    while (attempts < 4) : (attempts += 1) {
        var random: [32]u8 = undefined;
        io.random(&random);
        var token: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{random}) catch unreachable;
        const saved = db.complete(io, job.id, result.relative_path, result.size, &token, now + cfg.retention_seconds, now) catch |err| switch (err) {
            error.DuplicateToken => continue,
            else => return err,
        };
        if (saved) return;
        return;
    }
    return error.DownloadTokenCollision;
}

fn cleanup(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    client: *std.http.Client,
    now: i64,
) !void {
    const submission_age = @max(cfg.retention_seconds, 1800);
    const processing_age = @max(cfg.retention_seconds, 7200);
    const jobs = try db.listCleanup(
        io,
        now,
        now - cfg.retention_seconds,
        now - submission_age,
        now - processing_age,
    );
    defer db.allocator.free(jobs);
    for (jobs) |job| {
        defer job.deinit(db.allocator);
        if (job.status == .expired) {
            try db.purgeExpired(io, job.id, now - 1800);
            continue;
        }
        if (job.status == .submitting or job.status == .processing or job.status == .failed) {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            cancelSabWork(arena.allocator(), client, cfg, job) catch |err| {
                std.log.err("Job {s} SABnzbd cleanup failed: {t}", .{ job.id, err });
                continue;
            };
        }
        if (job.download_path.len != 0)
            artifact.removeValidated(root, job.download_path) catch |err| {
                std.log.err("Job {s} output cleanup was rejected: {t}", .{ job.id, err });
                continue;
            };
        if (job.artifact_path.len != 0 and !std.mem.eql(u8, job.artifact_path, job.download_path))
            artifact.removeValidated(root, job.artifact_path) catch |err| {
                std.log.err("Job {s} artifact cleanup was rejected: {t}", .{ job.id, err });
                continue;
            };
        _ = try db.markExpired(io, job.id, job.status, now);
    }
}

fn cancelSabWork(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    job: Job,
) !void {
    const nzo_id = if (job.nzo_id.len != 0) job.nzo_id else id: {
        const result = try findByName(allocator, client, cfg, job.sab_name);
        if (result.nzo_id.len == 0) return;
        break :id result.nzo_id;
    };
    if (try deleteSabJob(allocator, client, cfg, "queue", nzo_id)) return;
    if (try deleteSabJob(allocator, client, cfg, "history", nzo_id)) return;
    return error.SabnzbdDeleteFailed;
}

fn deleteSabJob(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    mode: []const u8,
    nzo_id: []const u8,
) !bool {
    const key = try encode(allocator, cfg.sab_api_key);
    const id = try encode(allocator, nzo_id);
    const archive = if (std.mem.eql(u8, mode, "history")) "&archive=0" else "";
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/api?mode={s}&name=delete&output=json&apikey={s}&value={s}&del_files=1{s}",
        .{ cfg.sab_url, mode, key, id, archive },
    );
    const response = try fetchJson(
        allocator,
        client,
        url,
        .GET,
        null,
        &.{},
        cfg.sab_request_seconds,
    );
    const object = switch (response) {
        .object => |object| object,
        else => return error.InvalidSabnzbdResponse,
    };
    const status = object.get("status") orelse return error.InvalidSabnzbdResponse;
    if (status != .bool) return error.InvalidSabnzbdResponse;
    return status.bool;
}

fn upload(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, job: Job) ![]const u8 {
    var boundary_random: [12]u8 = undefined;
    client.io.random(&boundary_random);
    var boundary: [24]u8 = undefined;
    _ = std.fmt.bufPrint(&boundary, "{x}", .{boundary_random}) catch unreachable;
    var body = std.Io.Writer.Allocating.init(allocator);
    try body.writer.print("--{s}\r\nContent-Disposition: form-data; name=\"name\"; filename=\"{s}.nzb\"\r\n", .{ boundary, job.id });
    try body.writer.writeAll("Content-Type: application/x-nzb\r\n\r\n");
    try body.writer.writeAll(job.content);
    try body.writer.print("\r\n--{s}--\r\n", .{boundary});
    const encoded_key = try encode(allocator, cfg.sab_api_key);
    const encoded_name = try encode(allocator, job.sab_name);
    const url = try std.fmt.allocPrint(allocator, "{s}/api?mode=addfile&output=json&apikey={s}&nzbname={s}", .{
        cfg.sab_url, encoded_key, encoded_name,
    });
    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
    const response = try fetchJson(
        allocator,
        client,
        url,
        .POST,
        body.writer.buffered(),
        &.{.{ .name = "content-type", .value = content_type }},
        cfg.sab_request_seconds,
    );
    const object = switch (response) {
        .object => |object| object,
        else => return error.InvalidSabnzbdResponse,
    };
    if (object.get("status")) |status| if (status == .bool and !status.bool) return error.SabnzbdRejectedUpload;
    const ids = object.get("nzo_ids") orelse return error.InvalidSabnzbdResponse;
    if (ids != .array or ids.array.items.len == 0 or ids.array.items[0] != .string)
        return error.InvalidSabnzbdResponse;
    return allocator.dupe(u8, ids.array.items[0].string);
}

fn findByName(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, name: []const u8) !SabResult {
    const queue = try query(allocator, client, cfg, "queue", name, "");
    if (queue.nzo_id.len != 0) return queue;
    return query(allocator, client, cfg, "history", name, "");
}

fn findById(allocator: std.mem.Allocator, client: *std.http.Client, cfg: Config, id: []const u8) !SabResult {
    const queue = try query(allocator, client, cfg, "queue", "", id);
    if (queue.state != .unknown) return queue;
    return query(allocator, client, cfg, "history", "", id);
}

fn query(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    cfg: Config,
    mode: []const u8,
    name: []const u8,
    id: []const u8,
) !SabResult {
    const key = try encode(allocator, cfg.sab_api_key);
    const search = if (name.len != 0) try std.fmt.allocPrint(allocator, "&search={s}", .{try encode(allocator, name)}) else "";
    const id_query = if (id.len != 0) try std.fmt.allocPrint(allocator, "&nzo_ids={s}", .{try encode(allocator, id)}) else "";
    const url = try std.fmt.allocPrint(allocator, "{s}/api?mode={s}&output=json&apikey={s}{s}{s}", .{
        cfg.sab_url, mode, key, search, id_query,
    });
    const root = try fetchJson(allocator, client, url, .GET, null, &.{}, cfg.sab_request_seconds);
    const top = switch (root) {
        .object => |object| object.get(mode) orelse return error.InvalidSabnzbdResponse,
        else => return error.InvalidSabnzbdResponse,
    };
    if (top != .object) return error.InvalidSabnzbdResponse;
    const slots = top.object.get("slots") orelse return .{ .state = .unknown };
    if (slots != .array) return error.InvalidSabnzbdResponse;
    for (slots.array.items) |slot_value| {
        if (slot_value != .object) continue;
        const slot = slot_value.object;
        const slot_id = stringField(slot, "nzo_id");
        const slot_name = firstString(slot, &.{ "name", "filename", "nzb_name" });
        if ((id.len != 0 and std.mem.eql(u8, slot_id, id)) or
            (name.len != 0 and std.mem.eql(u8, slot_name, name)))
        {
            return .{
                .state = normalizeState(stringField(slot, "status")),
                .nzo_id = try allocator.dupe(u8, slot_id),
                .storage = try allocator.dupe(u8, stringField(slot, "storage")),
            };
        }
    }
    return .{ .state = .unknown };
}

fn fetchJson(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    method: std.http.Method,
    payload: ?[]const u8,
    headers: []const std.http.Header,
    timeout_seconds: u32,
) !std.json.Value {
    const response_bytes = try allocator.alloc(u8, 2 * 1024 * 1024);
    var response = std.Io.Writer.fixed(response_bytes);
    const uri = std.Uri.parse(url) catch return error.InvalidSabnzbdUrl;
    var request = try client.request(method, uri, .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .accept_encoding = .omit },
        .extra_headers = headers,
    });
    defer request.deinit();
    var timeout: std.Io.Group = .init;
    timeout.concurrent(client.io, shutdownClientAfter, .{
        request.connection.?,
        client.io,
        timeout_seconds,
    }) catch return error.SabnzbdConcurrencyUnavailable;
    defer timeout.cancel(client.io);
    if (payload) |body_bytes| {
        request.transfer_encoding = .{ .content_length = body_bytes.len };
        var body = try request.sendBodyUnflushed(&.{});
        try body.writer.writeAll(body_bytes);
        try body.end();
        try request.connection.?.flush();
    } else {
        try request.sendBodiless();
    }
    var response_head = request.receiveHead(&.{}) catch |err| {
        if (response.end == response.buffer.len) return error.SabnzbdResponseTooLarge;
        return err;
    };
    if (response_head.head.status.class() != .success) return error.SabnzbdHttpError;
    const reader = response_head.reader(&.{});
    _ = reader.streamRemaining(&response) catch |err| {
        if (response.end == response.buffer.len) return error.SabnzbdResponseTooLarge;
        return switch (err) {
            error.ReadFailed => response_head.bodyErr().?,
            else => |stream_err| stream_err,
        };
    };
    if (response.end == response_bytes.len) return error.SabnzbdResponseTooLarge;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.buffered(), .{});
    return parsed.value;
}

fn shutdownClientAfter(
    connection: *std.http.Client.Connection,
    io: std.Io,
    seconds: u32,
) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
    connection.stream_reader.stream.shutdown(io, .both) catch |err|
        std.log.debug("Timed out SABnzbd connection shutdown failed: {t}", .{err});
}

fn stringField(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return if (value == .string) value.string else "";
}

fn firstString(object: std.json.ObjectMap, keys: []const []const u8) []const u8 {
    for (keys) |key| {
        const value = stringField(object, key);
        if (value.len != 0) return value;
    }
    return "";
}

fn normalizeState(value: []const u8) SabState {
    if (std.ascii.eqlIgnoreCase(value, "complete") or std.ascii.eqlIgnoreCase(value, "completed")) return .complete;
    if (std.ascii.eqlIgnoreCase(value, "failed")) return .failed;
    if (std.ascii.eqlIgnoreCase(value, "deleted")) return .deleted;
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "unknown")) return .unknown;
    return .queued;
}

fn encode(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~')
            try output.writer.writeByte(byte)
        else
            try output.writer.print("%{X:0>2}", .{byte});
    }
    return allocator.dupe(u8, output.writer.buffered());
}

fn definitelyNotSent(err: anyerror) bool {
    return err == error.ConnectionRefused or
        err == error.UnknownHostName or
        err == error.NetworkUnreachable or
        err == error.AddressFamilyUnsupported;
}

test "SABnzbd state normalization" {
    try std.testing.expectEqual(SabState.complete, normalizeState("Completed"));
    try std.testing.expectEqual(SabState.failed, normalizeState("FAILED"));
    try std.testing.expectEqual(SabState.queued, normalizeState("Downloading"));
}
