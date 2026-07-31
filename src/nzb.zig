const std = @import("std");
const c = @cImport({
    @cInclude("libxml/xmlreader.h");
    @cInclude("libxml/parser.h");
    @cInclude("libxml/xmlstring.h");
});

pub const max_files = 10_000;
pub const max_segments = 100_000;
const nzb_ns = "http://www.newzbin.com/DTD/2003/nzb";

pub const Segment = struct {
    number: u32,
    declared_bytes: u64,
    message_id: []const u8,
};

pub const File = struct {
    segments: []Segment,

    pub fn deinit(self: File, allocator: std.mem.Allocator) void {
        for (self.segments) |segment| allocator.free(segment.message_id);
        allocator.free(self.segments);
    }
};

pub const Document = struct {
    files: []File,

    pub fn deinit(self: Document, allocator: std.mem.Allocator) void {
        for (self.files) |file| file.deinit(allocator);
        allocator.free(self.files);
    }
};

pub const ParseError = error{
    NzbParseFailed,
    UnsupportedNzbNamespace,
    EntityReferenceRejected,
    InternalEntityRejected,
    PasswordProtectedNzb,
    TooManyNzbFiles,
    TooManyNzbSegments,
    EmptyNzbFile,
    MissingSegmentNumber,
    MissingSegmentBytes,
    InvalidSegmentNumber,
    InvalidSegmentBytes,
    DuplicateSegmentNumber,
    NonContiguousSegmentNumbers,
    InvalidMessageId,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Document {
    const options = c.XML_PARSE_NONET;
    const reader = c.xmlReaderForMemory(
        @ptrCast(bytes.ptr),
        @intCast(bytes.len),
        null,
        null,
        options,
    ) orelse return error.NzbParseFailed;
    defer c.xmlFreeTextReader(reader);

    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |file| file.deinit(allocator);
        files.deinit(allocator);
    }
    var current_segments: std.ArrayList(Segment) = .empty;
    errdefer {
        for (current_segments.items) |segment| allocator.free(segment.message_id);
        current_segments.deinit(allocator);
    }
    var in_file = false;
    var in_segment = false;
    var segment_number: u32 = 0;
    var segment_bytes: u64 = 0;
    var total_segments: usize = 0;

    while (true) {
        const rc = c.xmlTextReaderRead(reader);
        if (rc == 0) break;
        if (rc < 0) return error.NzbParseFailed;
        const node_type = c.xmlTextReaderNodeType(reader);
        if (node_type == c.XML_READER_TYPE_ENTITY_REFERENCE) return error.EntityReferenceRejected;
        if (node_type == c.XML_READER_TYPE_DOCUMENT_TYPE) {
            const value = xmlText(c.xmlTextReaderConstValue(reader));
            if (std.mem.indexOf(u8, value, "<!ENTITY") != null or std.mem.indexOf(u8, value, "<!entity") != null)
                return error.InternalEntityRejected;
            continue;
        }
        if (node_type == c.XML_READER_TYPE_ELEMENT) {
            try validateNamespace(reader);
            const name = xmlText(c.xmlTextReaderConstLocalName(reader));
            if (std.mem.eql(u8, name, "file")) {
                if (files.items.len >= max_files) return error.TooManyNzbFiles;
                in_file = true;
                current_segments.clearRetainingCapacity();
            } else if (std.mem.eql(u8, name, "segment") and in_file) {
                in_segment = true;
                segment_number = try attrInt(u32, reader, "number") orelse return error.MissingSegmentNumber;
                segment_bytes = try attrInt(u64, reader, "bytes") orelse return error.MissingSegmentBytes;
                if (segment_number == 0) return error.InvalidSegmentNumber;
            } else if (std.mem.eql(u8, name, "meta")) {
                if (hasPasswordMeta(reader)) return error.PasswordProtectedNzb;
            }
            continue;
        }
        if (node_type == c.XML_READER_TYPE_TEXT and in_segment) {
            const value = std.mem.trim(u8, xmlText(c.xmlTextReaderConstValue(reader)), " \t\r\n");
            const message_id = try normalizeMessageId(allocator, value);
            errdefer allocator.free(message_id);
            try current_segments.append(allocator, .{
                .number = segment_number,
                .declared_bytes = segment_bytes,
                .message_id = message_id,
            });
            total_segments += 1;
            if (total_segments > max_segments) return error.TooManyNzbSegments;
            continue;
        }
        if (node_type == c.XML_READER_TYPE_END_ELEMENT) {
            const name = xmlText(c.xmlTextReaderConstLocalName(reader));
            if (std.mem.eql(u8, name, "segment")) {
                in_segment = false;
            } else if (std.mem.eql(u8, name, "file") and in_file) {
                try validateSegments(current_segments.items);
                const owned = try current_segments.toOwnedSlice(allocator);
                try files.append(allocator, .{ .segments = owned });
                current_segments = .empty;
                in_file = false;
            }
        }
    }
    if (files.items.len == 0) return error.EmptyNzbFile;
    return .{ .files = try files.toOwnedSlice(allocator) };
}

fn validateNamespace(reader: *c.xmlTextReader) !void {
    const ns = xmlText(c.xmlTextReaderConstNamespaceUri(reader));
    if (ns.len != 0 and !std.mem.eql(u8, ns, nzb_ns)) return error.UnsupportedNzbNamespace;
}

fn hasPasswordMeta(reader: *c.xmlTextReader) bool {
    const value = std.mem.trim(u8, attrValue(reader, "type") orelse return false, " \t\r\n");
    return std.ascii.eqlIgnoreCase(value, "password") and c.xmlTextReaderIsEmptyElement(reader) == 0;
}

fn attrInt(comptime T: type, reader: *c.xmlTextReader, comptime name: []const u8) !?T {
    const raw = attrValue(reader, name) orelse return null;
    return std.fmt.parseInt(T, raw, 10) catch switch (T) {
        u32 => error.InvalidSegmentNumber,
        else => error.InvalidSegmentBytes,
    };
}

fn attrValue(reader: *c.xmlTextReader, comptime name: []const u8) ?[]const u8 {
    if (c.xmlTextReaderMoveToFirstAttribute(reader) != 1) return null;
    defer _ = c.xmlTextReaderMoveToElement(reader);
    while (true) {
        const attr_name = xmlText(c.xmlTextReaderConstLocalName(reader));
        if (std.mem.eql(u8, attr_name, name)) {
            return xmlText(c.xmlTextReaderConstValue(reader));
        }
        if (c.xmlTextReaderMoveToNextAttribute(reader) != 1) return null;
    }
}

fn validateSegments(segments: []Segment) !void {
    if (segments.len == 0) return error.EmptyNzbFile;
    std.mem.sort(Segment, segments, {}, struct {
        fn lessThan(_: void, a: Segment, b: Segment) bool {
            return a.number < b.number;
        }
    }.lessThan);
    for (segments, 0..) |segment, i| {
        const expected: u32 = @intCast(i + 1);
        if (segment.number < expected) return error.DuplicateSegmentNumber;
        if (segment.number != expected) return error.NonContiguousSegmentNumbers;
    }
}

fn normalizeMessageId(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var value = raw;
    if (value.len >= 2 and value[0] == '<' and value[value.len - 1] == '>')
        value = value[1 .. value.len - 1];
    if (value.len == 0) return error.InvalidMessageId;
    for (value) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidMessageId;
    }
    if ("BODY ".len + 1 + value.len + 1 + "\r\n".len > 512) return error.InvalidMessageId;
    return allocator.dupe(u8, value);
}

fn xmlText(raw: [*c]const u8) []const u8 {
    if (raw == null) return "";
    return std.mem.span(raw);
}

test "parses direct segment text" {
    const text =
        \\<?xml version="1.0"?>
        \\<!DOCTYPE nzb PUBLIC "-//newzBin//DTD NZB 1.1//EN" "http://www.newzbin.com/DTD/nzb/nzb-1.1.dtd">
        \\<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb"><file><segments>
        \\<segment bytes="3" number="1">abc@example</segment>
        \\</segments></file></nzb>
    ;
    const doc = try parse(std.testing.allocator, text);
    defer doc.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), doc.files.len);
    try std.testing.expectEqualStrings("abc@example", doc.files[0].segments[0].message_id);
}

test "rejects duplicate segments" {
    const text =
        \\<nzb><file><segments>
        \\<segment bytes="1" number="1">a</segment>
        \\<segment bytes="1" number="1">b</segment>
        \\</segments></file></nzb>
    ;
    try std.testing.expectError(error.DuplicateSegmentNumber, parse(std.testing.allocator, text));
}

test "rejects entity references" {
    const text =
        \\<!DOCTYPE nzb [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        \\<nzb><file><segments><segment bytes="1" number="1">&xxe;</segment></segments></file></nzb>
    ;
    try std.testing.expectError(error.EntityReferenceRejected, parse(std.testing.allocator, text));
}
