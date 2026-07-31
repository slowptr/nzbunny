const std = @import("std");
const shutdown = @import("shutdown.zig");

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
    stream_reader: ?std.Io.net.Stream.Reader = null,
    stream_writer: ?std.Io.net.Stream.Writer = null,
    tls: ?std.crypto.tls.Client = null,
    read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_read_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,
    tls_write_buffer: [std.crypto.tls.Client.min_buffer_len]u8 = undefined,

    pub fn connect(self: *Session) !void {
        self.deinit();
        try std.Io.net.HostName.validate(self.host);
        try self.runWithDeadline(connectTransport, .{self});
        errdefer self.deinit();
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
        for (message_id) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidMessageId;
        if (self.tls == null) try self.connect();

        try self.sendParts("BODY <", message_id, ">\r\n");
        const status = try self.readStatus();
        if (status.code == 400) return error.NntpTransientResponse;
        if (status.code == 430) return error.MissingArticle;
        if (status.code >= 400) return error.PermanentNntpResponse;
        if (status.code != 222) return error.NntpBodyRequestFailed;
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
        if (self.stream) |stream| stream.shutdown(self.io, .both) catch {};
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
        const host: std.Io.net.HostName = .{ .bytes = self.host };
        const stream = try std.Io.net.HostName.connect(host, self.io, self.port, .{
            .mode = .stream,
            .timeout = .none,
        });
        self.stream = stream;
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

    const Status = struct { code: u16 };

    fn readStatus(self: *Session) !Status {
        const line = try self.readLine(self.allocator, 8 * 1024);
        defer self.allocator.free(line);
        if (line.len < 3) return error.InvalidNntpStatus;
        const code = std.fmt.parseInt(u16, line[0..3], 10) catch return error.InvalidNntpStatus;
        if (line.len > 3 and line[3] != ' ' and line[3] != '-') return error.InvalidNntpStatus;
        return .{ .code = code };
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
                return error.NntpOperationTimeout;
            },
        }
    }

    fn operationTimeoutSeconds(self: *Session) !i64 {
        if (self.control) |control| if (control.isCanceled()) return error.Canceled;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        const configured_deadline = std.math.add(i64, now, self.timeout_seconds) catch return error.NntpOperationTimeout;
        const deadline = if (self.control) |control| @min(configured_deadline, control.deadline_seconds) else configured_deadline;
        if (now >= deadline) return error.NntpOperationTimeout;
        return deadline - now;
    }

    fn normalizeTransportError(self: *Session, err: anyerror) anyerror {
        if (self.control) |control| if (control.isCanceled()) return error.Canceled;
        if (err == error.ReadFailed or err == error.WriteFailed) {
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
    };
}

test "BODY command length limit includes brackets and CRLF" {
    var store: CaStore = .{};
    var session = makeSession(std.testing.allocator, std.testing.io, "example.test", 563, "u", "p", &store, 1, null);
    try std.testing.expectError(error.InvalidMessageId, session.requestBody("a" ** 506));
}
