const std = @import("std");

pub const Part = struct {
    name: []const u8,
    size: u64,
    part: u32,
    total: u32,
    begin: u64,
    end: u64,
    pcrc32: ?u32,
    crc32: ?u32,
    decoded: u64,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    max_size: u64 = std.math.maxInt(u64),
    budget: u64 = 0,
    meta: ?Part = null,
    in_data: bool = false,
    saw_yend: bool = false,
    crc: std.hash.Crc32 = .init(),

    pub fn init(allocator: std.mem.Allocator, output: *std.Io.Writer, max_size: u64) Decoder {
        return .{ .allocator = allocator, .output = output, .max_size = max_size };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.meta) |meta| self.allocator.free(meta.name);
        self.meta = null;
    }

    pub fn consumeLine(self: *Decoder, line: []const u8) !void {
        if (std.mem.startsWith(u8, line, "=ybegin ")) {
            if (self.meta != null) return error.DuplicateYbegin;
            self.meta = try parseYbegin(self.allocator, line);
            if (self.meta.?.size > self.max_size) return error.YencSizeExceedsBudget;
            self.budget = self.meta.?.size;
            self.in_data = true;
            return;
        }
        if (std.mem.startsWith(u8, line, "=ypart ")) {
            if (self.meta == null or !self.in_data) return error.YpartBeforeYbegin;
            if (self.meta.?.part == 0) return error.YpartInSinglepart;
            const range = try parseYpart(line);
            var meta = self.meta.?;
            if (range.begin == 0 or range.end < range.begin or range.end > meta.size) return error.InvalidYencRange;
            meta.begin = range.begin;
            meta.end = range.end;
            self.meta = meta;
            self.budget = try inclusiveRangeLength(range.begin, range.end);
            return;
        }
        if (std.mem.startsWith(u8, line, "=yend ")) {
            if (self.meta == null or !self.in_data) return error.YendBeforeYbegin;
            var meta = self.meta.?;
            const end = try parseYend(line);
            if (end.part) |part| {
                if (meta.part == 0) return error.UnexpectedMultipartEnd;
                if (part != meta.part) return error.InvalidYencPart;
            } else if (meta.part != 0) {
                return error.MissingYencPart;
            }
            if (end.size != meta.decoded) return error.InvalidYencDecodedSize;
            if (meta.part != 0) {
                if (meta.begin == 0 or meta.end < meta.begin) return error.MissingYpart;
                if (try inclusiveRangeLength(meta.begin, meta.end) != meta.decoded) return error.InvalidYencRange;
            } else {
                meta.begin = 1;
                meta.end = meta.size;
                if (meta.size != meta.decoded) return error.InvalidYencDecodedSize;
            }
            const actual = self.crc.final();
            if (meta.part == 0) {
                if (end.crc32) |expected| if (expected != actual) return error.YencCrcMismatch;
            } else {
                if (end.pcrc32) |expected| if (expected != actual) return error.YencCrcMismatch;
                if (end.crc32) |expected| meta.crc32 = expected;
            }
            meta.pcrc32 = end.pcrc32;
            meta.crc32 = end.crc32;
            self.meta = meta;
            self.saw_yend = true;
            self.in_data = false;
            return;
        }
        if (!self.in_data or self.meta == null) return;
        try self.decodeData(line);
    }

    pub fn finish(self: *Decoder) !Part {
        if (!self.saw_yend or self.meta == null) return error.MissingYend;
        return self.meta.?;
    }

    fn decodeData(self: *Decoder, line: []const u8) !void {
        var meta = self.meta.?;
        var i: usize = 0;
        while (i < line.len) {
            var byte = line[i];
            i += 1;
            if (byte == '=') {
                if (i >= line.len) return error.InvalidYencEscape;
                byte = line[i] -% 64;
                i += 1;
            }
            byte -%= 42;
            try self.output.writeByte(byte);
            self.crc.update(&.{byte});
            meta.decoded = std.math.add(u64, meta.decoded, 1) catch return error.InvalidYencDecodedSize;
            if (meta.decoded > self.budget) return error.InvalidYencDecodedSize;
        }
        self.meta = meta;
    }
};

const Range = struct { begin: u64, end: u64 };
const End = struct { size: u64, part: ?u32, pcrc32: ?u32, crc32: ?u32 };

fn parseYbegin(allocator: std.mem.Allocator, line: []const u8) !Part {
    const size = try requiredInt(u64, line, "size=");
    if (size == 0) return error.InvalidYencRange;
    const name = try requiredText(line, "name=");
    try validateName(name);
    const part = optionalInt(u32, line, "part=") catch return error.InvalidYencPart;
    const total = optionalInt(u32, line, "total=") catch return error.InvalidYencPart;
    if (total != null and total.? == 0) return error.InvalidYencPart;
    return .{
        .name = try allocator.dupe(u8, name),
        .size = size,
        .part = part orelse 0,
        .total = total orelse 0,
        .begin = 0,
        .end = 0,
        .pcrc32 = null,
        .crc32 = null,
        .decoded = 0,
    };
}

fn inclusiveRangeLength(begin: u64, end: u64) !u64 {
    if (begin == 0 or end < begin) return error.InvalidYencRange;
    return std.math.add(u64, end - begin, 1) catch error.InvalidYencRange;
}

fn parseYpart(line: []const u8) !Range {
    return .{
        .begin = try requiredInt(u64, line, "begin="),
        .end = try requiredInt(u64, line, "end="),
    };
}

fn parseYend(line: []const u8) !End {
    return .{
        .size = try requiredInt(u64, line, "size="),
        .part = optionalInt(u32, line, "part=") catch return error.InvalidYencPart,
        .pcrc32 = optionalHex(line, "pcrc32=") catch return error.InvalidYencCrc,
        .crc32 = optionalHex(line, "crc32=") catch return error.InvalidYencCrc,
    };
}

fn requiredText(line: []const u8, key: []const u8) ![]const u8 {
    return (try field(line, key)) orelse error.MissingYencField;
}

fn requiredInt(comptime T: type, line: []const u8, key: []const u8) !T {
    const value = (try field(line, key)) orelse return error.MissingYencField;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidYencInteger;
}

fn optionalInt(comptime T: type, line: []const u8, key: []const u8) !?T {
    const value = (try field(line, key)) orelse return null;
    return std.fmt.parseInt(T, value, 10) catch error.InvalidYencInteger;
}

fn optionalHex(line: []const u8, key: []const u8) !?u32 {
    const value = (try field(line, key)) orelse return null;
    return std.fmt.parseInt(u32, value, 16) catch error.InvalidYencCrc;
}

fn field(line: []const u8, key: []const u8) !?[]const u8 {
    const start = findFieldKey(line, key, 0) orelse return null;
    if (findFieldKey(line, key, start + 1) != null) return error.DuplicateYencField;
    const rest = line[start + key.len ..];
    if (std.mem.eql(u8, key, "name=")) return rest;
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    return rest[0..end];
}

fn findFieldKey(line: []const u8, key: []const u8, offset: usize) ?usize {
    var pos = offset;
    while (pos < line.len) {
        const found = std.mem.indexOfPos(u8, line, pos, key) orelse return null;
        if (found == 0 or line[found - 1] == ' ') return found;
        pos = found + 1;
    }
    return null;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 255) return error.InvalidYencName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidYencName;
    for (name) |byte| {
        if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\') return error.InvalidYencName;
    }
}

test "decodes escaped bytes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    try decoder.consumeLine("=ybegin line=128 size=1 name=a.bin");
    defer decoder.deinit();
    try decoder.consumeLine("=\xa7");
    try decoder.consumeLine("=yend size=1");
    _ = try decoder.finish();
    try std.testing.expectEqualStrings("=", out.writer.buffered());
}

test "rejects zero-size yenc" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try std.testing.expectError(error.InvalidYencRange, decoder.consumeLine("=ybegin line=128 size=0 name=a.bin"));
}

test "validates optional crc" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var crc: std.hash.Crc32 = .init();
    crc.update("abc");
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try decoder.consumeLine("=ybegin line=128 size=3 name=a.bin");
    try decoder.consumeLine("\x8b\x8c\x8d");
    const end = try std.fmt.allocPrint(std.testing.allocator, "=yend size=3 crc32={x}", .{crc.final()});
    defer std.testing.allocator.free(end);
    try decoder.consumeLine(end);
    _ = try decoder.finish();
    try std.testing.expectEqualStrings("abc", out.writer.buffered());
}

test "rejects invalid multipart range" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try decoder.consumeLine("=ybegin part=1 line=128 size=3 name=a.bin");
    try std.testing.expectError(error.InvalidYencRange, decoder.consumeLine("=ypart begin=3 end=2"));
}

test "rejects duplicate yenc fields" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try std.testing.expectError(error.DuplicateYencField, decoder.consumeLine("=ybegin line=128 size=3 size=5 name=a.bin"));
}

test "rejects ypart for single-part yenc" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try decoder.consumeLine("=ybegin line=128 size=3 name=a.bin");
    try std.testing.expectError(error.YpartInSinglepart, decoder.consumeLine("=ypart begin=1 end=3"));
}

test "per-part budget rejects oversized decoded body" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try decoder.consumeLine("=ybegin part=1 line=128 size=10 name=a.bin");
    try decoder.consumeLine("=ypart begin=1 end=3");
    try std.testing.expectError(error.InvalidYencDecodedSize, decoder.consumeLine("\x8b\x8c\x8d\x8e"));
}

test "max size rejects yEnc exceeding artifact limit" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, 10);
    defer decoder.deinit();
    try std.testing.expectError(error.YencSizeExceedsBudget, decoder.consumeLine("=ybegin line=128 size=11 name=a.bin"));
}

test "field key inside name value does not cause false match" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var decoder = Decoder.init(std.testing.allocator, &out.writer, std.math.maxInt(u64));
    defer decoder.deinit();
    try decoder.consumeLine("=ybegin line=128 size=3 name=size=5.bin");
    try decoder.consumeLine("\x8b\x8c\x8d");
    try decoder.consumeLine("=yend size=3");
    _ = try decoder.finish();
    try std.testing.expectEqualStrings("abc", out.writer.buffered());
}
