const std = @import("std");

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
    stream: ?std.Io.net.Stream = null,
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
        const host: std.Io.net.HostName = .{ .bytes = self.host };
        const stream = try std.Io.net.HostName.connect(host, self.io, self.port, .{
            .mode = .stream,
            .timeout = .none,
        });
        self.stream = stream;
        self.stream_reader = stream.reader(self.io, &self.read_buffer);
        self.stream_writer = stream.writer(self.io, &self.write_buffer);
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

        try self.writer().writeAll("BODY <");
        try self.writer().writeAll(message_id);
        try self.writer().writeAll(">\r\n");
        try self.flushWriter();
        const status = try self.readStatus();
        if (status.code == 430) return error.MissingArticle;
        if (status.code >= 400 and status.code < 500) return error.PermanentNntpResponse;
        if (status.code >= 500) return error.PermanentNntpResponse;
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

    pub fn deinit(self: *Session) void {
        if (self.tls) |*tls| tls.end() catch {};
        if (self.stream) |stream| stream.close(self.io);
        self.tls = null;
        self.stream = null;
        self.stream_reader = null;
        self.stream_writer = null;
    }

    fn flushWriter(self: *Session) !void {
        try self.writer().flush();
        if (self.stream_writer) |*sw| try sw.interface.flush();
    }

    fn authenticate(self: *Session) !void {
        try self.writer().writeAll("AUTHINFO USER ");
        try self.writer().writeAll(self.user);
        try self.writer().writeAll("\r\n");
        try self.flushWriter();
        const user_status = try self.readStatus();
        if (user_status.code == 281) return;
        if (user_status.code != 381) return error.NntpAuthenticationFailed;
        try self.writer().writeAll("AUTHINFO PASS ");
        try self.writer().writeAll(self.pass);
        try self.writer().writeAll("\r\n");
        try self.flushWriter();
        const pass_status = try self.readStatus();
        if (pass_status.code != 281) return error.NntpAuthenticationFailed;
    }

    fn command(self: *Session, text: []const u8) !void {
        try self.writer().writeAll(text);
        try self.writer().writeAll("\r\n");
        try self.flushWriter();
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
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        var prev_was_cr = false;
        while (true) {
            if (out.writer.end >= max) return error.NntpLineTooLong;
            const byte = self.reader().takeByte() catch return error.NntpReadFailed;
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
        return allocator.dupe(u8, out.writer.buffered());
    }

    fn reader(self: *Session) *std.Io.Reader {
        return &self.tls.?.reader;
    }

    fn writer(self: *Session) *std.Io.Writer {
        return &self.tls.?.writer;
    }
};

pub fn makeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    ca_store: *CaStore,
    timeout_seconds: u32,
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
    };
}

test "BODY command length limit includes brackets and CRLF" {
    var store: CaStore = .{};
    var session = makeSession(std.testing.allocator, std.testing.io, "example.test", 563, "u", "p", &store, 1);
    try std.testing.expectError(error.InvalidMessageId, session.requestBody("a" ** 506));
}

