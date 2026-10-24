const std = @import("std");

pub const Part = struct {
    filename: []const u8,
    content: []const u8,

    pub fn deinit(self: Part, allocator: std.mem.Allocator) void {
        allocator.free(self.filename);
        allocator.free(self.content);
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    boundary: []const u8,
    max: u64,
) !Part {
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
    errdefer allocator.free(filename);

    var next_marker_buffer: [78]u8 = undefined;
    const next_marker = try std.fmt.bufPrint(&next_marker_buffer, "\r\n--{s}\r\n", .{boundary});
    var closing_buffer: [80]u8 = undefined;
    const closing = try std.fmt.bufPrint(&closing_buffer, "\r\n--{s}--\r\n", .{boundary});
    const chunk = try allocator.alloc(u8, 64 * 1024 + closing.len);
    defer allocator.free(chunk);
    var pending: usize = 0;
    var size: u64 = 0;
    var content_out = std.Io.Writer.Allocating.init(allocator);
    defer content_out.deinit();
    while (true) {
        const count = reader.readSliceShort(chunk[pending..]) catch return error.InvalidMultipart;
        const available = pending + count;
        if (std.mem.findPosLinear(u8, chunk[0..available], 0, next_marker) != null)
            return error.InvalidMultipart;
        if (std.mem.findPosLinear(u8, chunk[0..available], 0, closing)) |pos| {
            size = std.math.add(u64, size, pos) catch return error.FileTooLarge;
            if (size > max) return error.FileTooLarge;
            try content_out.writer.writeAll(chunk[0..pos]);
            if (pos + closing.len != available) return error.InvalidMultipart;
            var extra: [1]u8 = undefined;
            if ((reader.readSliceShort(&extra) catch return error.InvalidMultipart) != 0)
                return error.InvalidMultipart;
            if (size == 0) return error.EmptyFile;
            return .{
                .filename = filename,
                .content = try allocator.dupe(u8, content_out.writer.buffered()),
            };
        }
        if (count == 0) return error.InvalidMultipart;
        if (available > closing.len) {
            const write_len = available - closing.len;
            size = std.math.add(u64, size, write_len) catch return error.FileTooLarge;
            if (size > max) return error.FileTooLarge;
            try content_out.writer.writeAll(chunk[0..write_len]);
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
    if (!std.ascii.endsWithIgnoreCase(name, ".nzb")) return error.WrongFileType;
    return name;
}

pub fn parseBoundary(content_type: []const u8) ![]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data;")) return error.InvalidBoundary;
    const marker = "boundary=";
    const pos = std.mem.findPosLinear(u8, content_type, 0, marker) orelse return error.InvalidBoundary;
    const after = content_type[pos + marker.len ..];
    const end = std.mem.findScalar(u8, after, ';') orelse after.len;
    var value = std.mem.trim(u8, after[0..end], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    if (value.len == 0 or value.len > 70 or std.mem.findAny(u8, value, "\r\n") != null) return error.InvalidBoundary;
    return value;
}

pub fn normalizeFilename(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const output = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(output);
    for (raw, 0..) |byte, i| {
        if (byte < 0x20 or byte == 0x7f) return error.UnsafeFilename;
        output[i] = if (std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_') byte else '_';
    }
    if (output.len == 4 and std.ascii.endsWithIgnoreCase(output, ".nzb")) return error.UnsafeFilename;
    return output;
}

test "strict multipart accepts one non-empty nzb" {
    const body =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"ok.nzb\"\r\n" ++
        "Content-Type: application/octet-stream\r\n\r\n<nzb/>\r\n--abc--\r\n";
    {
        var reader = std.Io.Reader.fixed(body);
        const part = try parse(std.testing.allocator, &reader, "abc", 1024);
        defer part.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("ok.nzb", part.filename);
        try std.testing.expectEqualStrings("<nzb/>", part.content);
    }
    {
        var reader = std.Io.Reader.fixed(body);
        try std.testing.expectError(error.FileTooLarge, parse(std.testing.allocator, &reader, "abc", 2));
    }
}

test "multipart rejects unsafe metadata and extra parts" {
    const unsafe =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"../bad.nzb\"\r\n\r\nx\r\n--abc--\r\n";
    {
        var reader = std.Io.Reader.fixed(unsafe);
        try std.testing.expectError(error.UnsafeFilename, parse(std.testing.allocator, &reader, "abc", 100));
    }
    const extra =
        "--abc\r\nContent-Disposition: form-data; name=\"nzbfile\"; filename=\"ok.nzb\"\r\n\r\nx\r\n" ++
        "--abc\r\nContent-Disposition: form-data; name=\"other\"\r\n\r\ny\r\n--abc--\r\n";
    {
        var reader = std.Io.Reader.fixed(extra);
        try std.testing.expectError(error.InvalidMultipart, parse(std.testing.allocator, &reader, "abc", 100));
    }
    try std.testing.expectEqualStrings("abc", try parseBoundary("multipart/form-data; boundary=\"abc\"; charset=utf-8"));
    try std.testing.expectEqualStrings("abc", try parseBoundary("multipart/form-data; boundary=abc; charset=utf-8"));
}
