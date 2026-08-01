const std = @import("std");
const shutdown = @import("shutdown.zig");

var next_endpoint: std.atomic.Value(usize) = .init(0);

pub const CaStore = struct {
    bundle: std.crypto.Certificate.Bundle = .empty,
    lock: std.Io.RwLock = .init,

    pub fn load(allocator: std.mem.Allocator, io: std.Io, extra_file: []const u8) !CaStore {
        var store: CaStore = .{};
        errdefer store.bundle.deinit(allocator);
        try store.bundle.rescan(allocator, io, std.Io.Clock.real.now(io));
        if (extra_file.len != 0) {
            var file = try std.Io.Dir.cwd().openFile(io, extra_file, .{ .allow_directory = false });
            defer file.close(io);
            var buffer: [16 * 1024]u8 = undefined;
            var reader = std.Io.File.Reader.init(file, io, &buffer);
            try store.bundle.addCertsFromFile(allocator, &reader, std.Io.Clock.real.now(io).toSeconds());
        }
        return store;
    }

    pub fn deinit(self: *CaStore, allocator: std.mem.Allocator) void {
        self.bundle.deinit(allocator);
    }
};

pub const Response = struct {
    code: u16,

    pub const Class = enum {
        ok,
        missing_article,
        provider_transient,
        auth_required,
        permanent_protocol,
        unexpected,
    };

    pub fn classifyBody(self: Response) Class {
        return switch (self.code) {
            222 => .ok,
            430, 423 => .missing_article,
            400...422, 424...429, 431...479 => .provider_transient,
            480, 481, 482 => .auth_required,
            else => if (self.code >= 400) .permanent_protocol else .unexpected,
        };
    }
};

pub const BodyLine = union(enum) {
    line: []const u8,
    end,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    ca_store: *CaStore,
    timeout_seconds: u32,
    control: ?*shutdown.DownloadControl = null,
    stream: ?std.Io.net.Stream = null,
    registered: bool = false,
    endpoints: [32]std.Io.net.IpAddress = undefined,
    endpoint_count: usize = 0,
    endpoint_index: usize = 0,
    stream_reader: ?std.Io.net.Stream.Reader = null,
    stream_writer: ?std.Io.net.Stream.Writer = null,
    tls: ?std.crypto.tls.Client = null,
    read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,

    pub fn connect(self: *Session) !void {
        self.deinit();
        errdefer self.deinit();
        try std.Io.net.HostName.validate(self.host);
        try self.runWithDeadline(connectTransport, .{self});
        try self.runWithDeadline(initializeTls, .{self});
        const greeting_code = try self.readStatus();
        if (greeting_code.code != 200 and greeting_code.code != 201) return error.NntpGreetingFailed;
        try self.authenticate();
    }

    pub fn probe(self: *Session) !void {
        if (self.tls == null) try self.connect();
        try self.command("DATE");
        const status = try self.readStatus();
        if (status.code != 111) return error.NntpProbeFailed;
    }

    pub fn requestBody(self: *Session, message_id: []const u8) !void {
        if (message_id.len == 0 or "BODY ".len + 1 + message_id.len + 1 + "\r\n".len > 512)
            return error.InvalidMessageId;
        try validateMessageId(message_id);
        if (self.tls == null) try self.connect();

        try self.sendParts("BODY <", message_id, ">\r\n");
        const status = try self.readStatus();
        switch (status.classifyBody()) {
            .ok => return,
            .missing_article => return error.MissingArticle,
            .provider_transient => return error.NntpTransientResponse,
            .auth_required => return error.PermanentNntpResponse,
            .permanent_protocol => return error.PermanentNntpResponse,
            .unexpected => return error.NntpBodyRequestFailed,
        }
    }

    pub fn readBodyLine(self: *Session, allocator: std.mem.Allocator) !BodyLine {
        const raw = try self.readLine(allocator, 64 * 1024 + 2);
        errdefer allocator.free(raw);
        if (std.mem.eql(u8, raw, ".")) {
            allocator.free(raw);
            return .end;
        }
        if (std.mem.startsWith(u8, raw, "..")) {
            const unstuffed = try allocator.dupe(u8, raw[1..]);
            allocator.free(raw);
            return .{ .line = unstuffed };
        }
        return .{ .line = raw };
    }

    pub fn abort(self: *Session) void {
        if (self.stream) |stream| {
            stream.shutdown(self.io, .both) catch {};
            self.deinit();
        }
    }

    pub fn endpointCount(self: *const Session) usize {
        return self.endpoint_count;
    }

    pub fn deinit(self: *Session) void {
        if (self.tls) |*tls| tls.end() catch {};
        if (self.stream) |stream| {
            if (self.registered) if (self.control) |control| control.unregister(stream);
            stream.close(self.io);
        }
        self.tls = null;
        self.stream = null;
        self.stream_reader = null;
        self.stream_writer = null;
        self.registered = false;
    }

    fn connectTransport(self: *Session) !void {
        if (self.endpoint_count == 0) try self.resolveEndpoints();
        var attempts: usize = 0;
        var last_error: ?std.Io.net.IpAddress.ConnectError = null;
        const stream = while (attempts < self.endpoint_count) : (attempts += 1) {
            const index = self.endpoint_index % self.endpoint_count;
            self.endpoint_index +%= 1;
            break self.endpoints[index].connect(self.io, .{
                .mode = .stream,
                .timeout = .none,
            }) catch |err| {
                last_error = err;
                continue;
            };
        } else return last_error orelse error.UnknownHostName;
        self.stream = stream;
        const seconds = self.operationTimeoutSeconds() catch return error.NntpOperationTimeout;
        var tv: std.os.linux.timeval = .{ .sec = @intCast(seconds), .usec = 0 };
        const tv_bytes: [*]const u8 = @ptrCast(&tv);
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, tv_bytes[0..@sizeOf(@TypeOf(tv))]);
        try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, tv_bytes[0..@sizeOf(@TypeOf(tv))]);
        if (self.control) |control| {
            control.register(stream) catch |err| {
                self.stream = null;
                stream.close(self.io);
                return err;
            };
            self.registered = true;
        }
        self.stream_reader = stream.reader(self.io, &self.read_buffer);
        self.stream_writer = stream.writer(self.io, &self.write_buffer);
    }

    fn resolveEndpoints(self: *Session) !void {
        const host: std.Io.net.HostName = .{ .bytes = self.host };
        var results_buffer: [32]std.Io.net.HostName.LookupResult = undefined;
        var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results_buffer);
        try host.lookup(self.io, &results, .{ .port = self.port });
        while (results.getOneUncancelable(self.io)) |result| switch (result) {
            .canonical_name => {},
            .address => |address| {
                for (self.endpoints[0..self.endpoint_count]) |existing| {
                    if (std.meta.eql(existing, address)) break;
                } else {
                    if (self.endpoint_count == self.endpoints.len) return error.TooManyProviderEndpoints;
                    self.endpoints[self.endpoint_count] = address;
                    self.endpoint_count += 1;
                }
            },
        } else |err| switch (err) {
            error.Closed => {},
        }
        if (self.endpoint_count == 0) return error.UnknownHostName;
        self.endpoint_index %= self.endpoint_count;
    }

    fn initializeTls(self: *Session) !void {
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        self.io.random(&entropy);
        self.tls = try std.crypto.tls.Client.init(
            &self.stream_reader.?.interface,
            &self.stream_writer.?.interface,
            .{
                .host = .{ .explicit = self.host },
                .ca = .{ .bundle = .{
                    .gpa = self.allocator,
                    .io = self.io,
                    .lock = &self.ca_store.lock,
                    .bundle = &self.ca_store.bundle,
                } },
                .write_buffer = &self.tls_write_buffer,
                .read_buffer = &self.tls_read_buffer,
                .entropy = &entropy,
                .realtime_now = std.Io.Clock.real.now(self.io),
            },
        );
    }

    fn sendParts(self: *Session, first: []const u8, second: []const u8, third: []const u8) !void {
        try self.runWithDeadline(sendPartsStage, .{ self, first, second, third });
    }

    fn sendPartsStage(self: *Session, first: []const u8, second: []const u8, third: []const u8) !void {
        try self.writer().writeAll(first);
        try self.writer().writeAll(second);
        try self.writer().writeAll(third);
        try self.writer().flush();
        if (self.stream_writer) |*sw| try sw.interface.flush();
    }

    fn authenticate(self: *Session) !void {
        try self.sendParts("AUTHINFO USER ", self.user, "\r\n");
        const user_status = try self.readStatus();
        if (user_status.code == 281) return;
        if (user_status.code != 381) return error.NntpAuthenticationFailed;
        try self.sendParts("AUTHINFO PASS ", self.pass, "\r\n");
        const pass_status = try self.readStatus();
        if (pass_status.code != 281) return error.NntpAuthenticationFailed;
    }

    fn command(self: *Session, text: []const u8) !void {
        try self.sendParts(text, "\r\n", "");
    }

    const Status = Response;

    fn readStatus(self: *Session) !Status {
        const line = try self.readLine(self.allocator, 8 * 1024);
        defer self.allocator.free(line);
        return parseStatusLine(line);
    }

    fn readLine(self: *Session, allocator: std.mem.Allocator, max: usize) ![]u8 {
        var result: ?[]u8 = null;
        try self.runWithDeadline(readLineStage, .{ self, allocator, max, &result });
        return result orelse error.NntpReadFailed;
    }

    fn readLineStage(self: *Session, allocator: std.mem.Allocator, max: usize, result: *?[]u8) !void {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var prev_was_cr = false;
        while (true) {
            if (out.writer.end >= max) return error.NntpLineTooLong;
            const byte = self.reader().takeByte() catch |err| return self.normalizeTransportError(err);
            if (byte == '\n') {
                if (!prev_was_cr) return error.InvalidNntpFraming;
                break;
            }
            if (prev_was_cr) return error.InvalidNntpFraming;
            if (byte == '\r') {
                prev_was_cr = true;
            } else {
                try out.writer.writeByte(byte);
            }
        }
        result.* = try allocator.dupe(u8, out.writer.buffered());
    }

    fn runWithDeadline(self: *Session, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !void {
        const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        const Outcome = union(enum) {
            operation: Result,
            timeout: std.Io.Cancelable!void,
        };
        const seconds = try self.operationTimeoutSeconds();
        var outcomes: [2]Outcome = undefined;
        var select = std.Io.Select(Outcome).init(self.io, &outcomes);
        defer select.cancelDiscard();
        try select.concurrent(.operation, function, args);
        try select.concurrent(.timeout, waitForDeadline, .{ self.io, seconds });
        switch (try select.await()) {
            .operation => |result| result catch |err| return self.normalizeTransportError(err),
            .timeout => {
                self.abort();
                if (self.control) |control| {
                    if (std.Io.Clock.real.now(self.io).toSeconds() >= control.deadline_seconds)
                        control.timeout();
                }
                return error.NntpOperationTimeout;
            },
        }
    }

    fn operationTimeoutSeconds(self: *Session) !i64 {
        if (self.control) |control| {
            if (control.isTimedOut()) return error.Timeout;
            if (control.isCanceled()) return error.Canceled;
        }
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const configured_deadline = std.math.add(i64, now, self.timeout_seconds) catch return error.NntpOperationTimeout;
        const deadline = if (self.control) |control| @min(configured_deadline, control.deadline_seconds) else configured_deadline;
        if (now >= deadline) {
            if (self.control) |control| control.timeout();
            return error.NntpOperationTimeout;
        }
        return deadline - now;
    }

    fn normalizeTransportError(self: *Session, err: anyerror) anyerror {
        if (self.control) |control| {
            if (control.isTimedOut()) return error.Timeout;
            if (control.isCanceled()) return error.Canceled;
        }
        if (err == error.ReadFailed or err == error.WriteFailed or err == error.EndOfStream) {
            if (self.stream_reader) |stream_reader| if (stream_reader.err) |stream_err| return stream_err;
            if (self.stream_writer) |stream_writer| if (stream_writer.err) |stream_err| return stream_err;
            return error.NntpTransportFailure;
        }
        return err;
    }

    fn reader(self: *Session) *std.Io.Reader {
        return &self.tls.?.reader;
    }

    fn writer(self: *Session) *std.Io.Writer {
        return &self.tls.?.writer;
    }
};

fn validateMessageId(message_id: []const u8) !void {
    if (message_id.len == 0 or "BODY ".len + 1 + message_id.len + 1 + "\r\n".len > 512)
        return error.InvalidMessageId;
    for (message_id) |byte| if (byte <= 0x20 or byte == 0x7f or byte == '<' or byte == '>' or byte == ',' or byte == ';' or byte == '"') return error.InvalidMessageId;
    const at = std.mem.indexOfScalar(u8, message_id, '@') orelse return error.InvalidMessageId;
    if (at == 0 or at + 1 >= message_id.len or std.mem.indexOfScalarPos(u8, message_id, at + 1, '@') != null)
        return error.InvalidMessageId;
    if (message_id[0] == '.' or message_id[at - 1] == '.' or message_id[at + 1] == '.' or message_id[message_id.len - 1] == '.')
        return error.InvalidMessageId;
}

fn parseStatusLine(line: []const u8) !Response {
    if (line.len < 3) return error.InvalidNntpStatus;
    const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.InvalidNntpStatus;
    if (code < 100 or code > 599) return error.InvalidNntpStatus;
    if (line.len > 3 and line[3] == '-') return error.UnsupportedMultilineStatus;
    if (line.len > 3 and line[3] != ' ') return error.InvalidNntpStatus;
    return .{ .code = code };
}

fn waitForDeadline(io: std.Io, seconds: i64) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
}

pub fn isRetryableProviderFailure(err: anyerror) bool {
    return err == error.NntpOperationTimeout or
        err == error.NntpTransportFailure or
        err == error.NntpTransientResponse or
        err == error.Timeout or
        err == error.ConnectionRefused or
        err == error.ConnectionResetByPeer or
        err == error.NetworkUnreachable or
        err == error.HostUnreachable or
        err == error.NetworkDown or
        err == error.UnknownHostName;
}

pub fn makeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    ca_store: *CaStore,
    timeout_seconds: u32,
    control: ?*shutdown.DownloadControl,
) Session {
    return .{
        .allocator = allocator,
        .io = io,
        .host = host,
        .port = port,
        .user = user,
        .pass = pass,
        .ca_store = ca_store,
        .timeout_seconds = timeout_seconds,
        .control = control,
        .endpoint_index = next_endpoint.fetchAdd(1, .monotonic),
    };
}

test "classifies dropped connections as retryable transport failures" {
    try std.testing.expect(isRetryableProviderFailure(error.NntpTransportFailure));
    try std.testing.expect(!isRetryableProviderFailure(error.MissingArticle));
}

test "parses valid status lines" {
    try std.testing.expectEqual(@as(u16, 222), (try parseStatusLine("222 body follows")).code);
    try std.testing.expectEqual(@as(u16, 200), (try parseStatusLine("200")).code);
}

test "rejects malformed status lines" {
    try std.testing.expectError(error.InvalidNntpStatus, parseStatusLine("99 bad"));
    try std.testing.expectError(error.InvalidNntpStatus, parseStatusLine("600 bad"));
    try std.testing.expectError(error.InvalidNntpStatus, parseStatusLine("abc bad"));
    try std.testing.expectError(error.InvalidNntpStatus, parseStatusLine("222: bad"));
    try std.testing.expectError(error.UnsupportedMultilineStatus, parseStatusLine("222-continued"));
}

test "BODY command length limit includes brackets and CRLF" {
    var store: CaStore = .{};
    var session = makeSession(std.testing.allocator, std.testing.io, "example.test", 563, "u", "p", &store, 1, null);
    try std.testing.expectError(error.InvalidMessageId, session.requestBody("a" ** 506));
}

test "validates message ids" {
    try validateMessageId("abc.def@example.test");
    try std.testing.expectError(error.InvalidMessageId, validateMessageId("missing-at"));
    try std.testing.expectError(error.InvalidMessageId, validateMessageId("a@@example.test"));
    try std.testing.expectError(error.InvalidMessageId, validateMessageId(".a@example.test"));
    try std.testing.expectError(error.InvalidMessageId, validateMessageId("a.@example.test"));
    try std.testing.expectError(error.InvalidMessageId, validateMessageId("a@example.test."));
}

test "rejects malformed message ids" {
    var store: CaStore = .{};
    var session = makeSession(std.testing.allocator, std.testing.io, "example.test", 563, "u", "p", &store, 1, null);
    try std.testing.expectError(error.InvalidMessageId, session.requestBody("missing-at"));
    try std.testing.expectError(error.InvalidMessageId, session.requestBody("bad<id@example"));
}

test "response classification maps body codes" {
    try std.testing.expectEqual(Response.Class.ok, (Response{ .code = 222 }).classifyBody());
    try std.testing.expectEqual(Response.Class.missing_article, (Response{ .code = 430 }).classifyBody());
    try std.testing.expectEqual(Response.Class.missing_article, (Response{ .code = 423 }).classifyBody());
    try std.testing.expectEqual(Response.Class.provider_transient, (Response{ .code = 412 }).classifyBody());
    try std.testing.expectEqual(Response.Class.provider_transient, (Response{ .code = 411 }).classifyBody());
    try std.testing.expectEqual(Response.Class.provider_transient, (Response{ .code = 421 }).classifyBody());
    try std.testing.expectEqual(Response.Class.auth_required, (Response{ .code = 481 }).classifyBody());
    try std.testing.expectEqual(Response.Class.auth_required, (Response{ .code = 482 }).classifyBody());
    try std.testing.expectEqual(Response.Class.permanent_protocol, (Response{ .code = 500 }).classifyBody());
    try std.testing.expectEqual(Response.Class.permanent_protocol, (Response{ .code = 502 }).classifyBody());
    try std.testing.expectEqual(Response.Class.unexpected, (Response{ .code = 100 }).classifyBody());
}
