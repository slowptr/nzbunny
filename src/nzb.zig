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
    subject: []const u8 = "",
    segments: []Segment,

    pub fn deinit(self: File, allocator: std.mem.Allocator) void {
        if (self.subject.len != 0) allocator.free(self.subject);
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
    InvalidNzbStructure,
    OutOfMemory,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Document {
    return parseWithDiagnostic(allocator, bytes, null);
}

pub const Diagnostic = struct {
    line: c_int = 0,
    column: c_int = 0,
};

pub fn parseWithDiagnostic(allocator: std.mem.Allocator, bytes: []const u8, diag: ?*Diagnostic) ParseError!Document {
    if (containsOutsideMarkup(bytes, "<!entity")) {
        return error.InternalEntityRejected;
    }
    if (containsEntityReference(bytes)) {
        return error.EntityReferenceRejected;
    }

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
    var current_subject: []const u8 = "";
    errdefer {
        if (current_subject.len != 0) allocator.free(current_subject);
        for (current_segments.items) |segment| allocator.free(segment.message_id);
        current_segments.deinit(allocator);
    }
    var in_file = false;
    var in_segments = false;
    var in_segment = false;
    var in_head = false;
    var saw_root = false;
    var segment_number: u32 = 0;
    var segment_bytes: u64 = 0;
    var total_segments: usize = 0;

    const setDiag = struct {
        fn set(d: ?*Diagnostic, r: *c.xmlTextReader) void {
            if (d) |target| {
                target.line = c.xmlTextReaderGetParserLineNumber(r);
                target.column = c.xmlTextReaderGetParserColumnNumber(r);
            }
        }
    }.set;

    while (true) {
        const rc = c.xmlTextReaderRead(reader);
        if (rc == 0) break;
        if (rc < 0) {
            setDiag(diag, reader);
            if (containsEntityReference(bytes)) return error.EntityReferenceRejected;
            return error.NzbParseFailed;
        }
        const node_type = c.xmlTextReaderNodeType(reader);
        if (node_type == c.XML_READER_TYPE_ENTITY_REFERENCE) {
            setDiag(diag, reader);
            return error.EntityReferenceRejected;
        }
        if (node_type == c.XML_READER_TYPE_ENTITY) {
            setDiag(diag, reader);
            return error.InternalEntityRejected;
        }
        if (node_type == c.XML_READER_TYPE_DOCUMENT_TYPE) {
            const value = xmlText(c.xmlTextReaderConstValue(reader));
            if (std.ascii.indexOfIgnoreCase(value, "<!entity") != null) {
                setDiag(diag, reader);
                return error.InternalEntityRejected;
            }
            continue;
        }
        if (node_type == c.XML_READER_TYPE_ELEMENT) {
            const name = xmlText(c.xmlTextReaderConstLocalName(reader));
            const is_structural = std.mem.eql(u8, name, "nzb") or std.mem.eql(u8, name, "file") or
                std.mem.eql(u8, name, "segments") or std.mem.eql(u8, name, "segment");
            if (!in_head or is_structural) {
                validateNamespace(reader) catch |err| {
                    setDiag(diag, reader);
                    return err;
                };
            }
            if (!saw_root) {
                if (!std.mem.eql(u8, name, "nzb")) {
                    setDiag(diag, reader);
                    return error.UnsupportedNzbNamespace;
                }
                saw_root = true;
            } else if (std.mem.eql(u8, name, "nzb") or
                (std.mem.eql(u8, name, "file") and in_file) or
                (std.mem.eql(u8, name, "segments") and !in_file) or
                (std.mem.eql(u8, name, "segment") and (!in_file or !in_segments or in_segment)) or
                (std.mem.eql(u8, name, "head") and in_head) or
                (std.mem.eql(u8, name, "meta") and !in_head))
            {
                setDiag(diag, reader);
                return error.InvalidNzbStructure;
            }
            if (std.mem.eql(u8, name, "file") and !in_head and !in_segment) {
                if (files.items.len >= max_files) {
                    setDiag(diag, reader);
                    return error.TooManyNzbFiles;
                }
                in_file = true;
                current_segments.clearRetainingCapacity();
                const subject = attrValue(reader, "subject") orelse "";
                if (subject.len != 0) current_subject = allocator.dupe(u8, subject) catch |err| {
                    setDiag(diag, reader);
                    return err;
                };
            } else if (std.mem.eql(u8, name, "segments")) {
                if (!in_file) {
                    setDiag(diag, reader);
                    return error.InvalidNzbStructure;
                }
                in_segments = true;
            } else if (std.mem.eql(u8, name, "head")) {
                in_head = true;
            } else if (std.mem.eql(u8, name, "segment") and in_file and in_segments) {
                in_segment = true;
                segment_number = (attrInt(u32, reader, "number") catch |err| {
                    setDiag(diag, reader);
                    return err;
                }) orelse {
                    setDiag(diag, reader);
                    return error.MissingSegmentNumber;
                };
                segment_bytes = (attrInt(u64, reader, "bytes") catch |err| {
                    setDiag(diag, reader);
                    return err;
                }) orelse {
                    setDiag(diag, reader);
                    return error.MissingSegmentBytes;
                };
                if (segment_number == 0) {
                    setDiag(diag, reader);
                    return error.InvalidSegmentNumber;
                }
                if (segment_bytes == 0) {
                    setDiag(diag, reader);
                    return error.InvalidSegmentBytes;
                }
            }
            continue;
        }
        if (node_type == c.XML_READER_TYPE_TEXT and in_segment) {
            const value = std.mem.trim(u8, xmlText(c.xmlTextReaderConstValue(reader)), " \t\r\n");
            const message_id = normalizeMessageId(allocator, value) catch |err| {
                setDiag(diag, reader);
                return err;
            };
            errdefer allocator.free(message_id);
            current_segments.append(allocator, .{
                .number = segment_number,
                .declared_bytes = segment_bytes,
                .message_id = message_id,
            }) catch |err| {
                setDiag(diag, reader);
                return err;
            };
            total_segments += 1;
            if (total_segments > max_segments) {
                setDiag(diag, reader);
                return error.TooManyNzbSegments;
            }
            continue;
        }
        if (node_type == c.XML_READER_TYPE_END_ELEMENT) {
            const name = xmlText(c.xmlTextReaderConstLocalName(reader));
            if (std.mem.eql(u8, name, "segment")) {
                if (!in_segment) {
                    setDiag(diag, reader);
                    return error.InvalidNzbStructure;
                }
                in_segment = false;
            } else if (std.mem.eql(u8, name, "segments")) {
                if (!in_segments or in_segment) {
                    setDiag(diag, reader);
                    return error.InvalidNzbStructure;
                }
                in_segments = false;
            } else if (std.mem.eql(u8, name, "head")) {
                if (!in_head) {
                    setDiag(diag, reader);
                    return error.InvalidNzbStructure;
                }
                in_head = false;
            } else if (std.mem.eql(u8, name, "meta")) {
                if (!in_head) {
                    setDiag(diag, reader);
                    return error.InvalidNzbStructure;
                }
            } else if (std.mem.eql(u8, name, "file") and in_file) {
                validateSegments(current_segments.items) catch |err| {
                    setDiag(diag, reader);
                    return err;
                };
                const owned = current_segments.toOwnedSlice(allocator) catch |err| {
                    setDiag(diag, reader);
                    return err;
                };
                files.append(allocator, .{ .subject = current_subject, .segments = owned }) catch |err| {
                    setDiag(diag, reader);
                    return err;
                };
                current_segments = .empty;
                current_subject = "";
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

// Skips over XML comment and CDATA regions before checking for entity
// references to avoid false positives when &custom; appears inside
// markup regions.
fn containsEntityReference(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        if (skipMarkupRegion(bytes, i)) |end| {
            i = end;
            continue;
        }
        if (bytes[i] == '&') {
            if (i + 1 < bytes.len and bytes[i + 1] != '#') {
                const rest = bytes[i + 1 ..];
                const semi = std.mem.indexOfScalar(u8, rest, ';') orelse {
                    i += 1;
                    continue;
                };
                const name = rest[0..semi];
                if (!std.mem.eql(u8, name, "lt") and
                    !std.mem.eql(u8, name, "gt") and
                    !std.mem.eql(u8, name, "amp") and
                    !std.mem.eql(u8, name, "quot") and
                    !std.mem.eql(u8, name, "apos"))
                {
                    return true;
                }
                i += 1 + semi + 1; // skip past &name;
                continue;
            }
        }
        i += 1;
    }
    return false;
}

fn containsOutsideMarkup(bytes: []const u8, needle: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        if (skipMarkupRegion(bytes, i)) |end| {
            i = end;
            continue;
        }
        if (i + needle.len <= bytes.len and
            std.ascii.eqlIgnoreCase(bytes[i..][0..needle.len], needle))
        {
            return true;
        }
        i += 1;
    }
    return false;
}

fn skipMarkupRegion(bytes: []const u8, pos: usize) ?usize {
    if (pos + 4 <= bytes.len and std.mem.eql(u8, bytes[pos..][0..4], "<!--")) {
        if (std.mem.indexOf(u8, bytes[pos + 4 ..], "-->")) |end| {
            return pos + 4 + end + 3;
        }
        return bytes.len;
    }
    if (pos + 9 <= bytes.len and std.mem.eql(u8, bytes[pos..][0..9], "<![CDATA[")) {
        if (std.mem.indexOf(u8, bytes[pos + 9 ..], "]]>")) |end| {
            return pos + 9 + end + 3;
        }
        return bytes.len;
    }
    return null;
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

test "rejects incomplete structural containers" {
    const missing_segments_close = "<nzb><file><segments><segment bytes=\"1\" number=\"1\">a@b</segment></file></nzb>";
    try std.testing.expectError(error.NzbParseFailed, parse(std.testing.allocator, missing_segments_close));
    const missing_segment_close = "<nzb><file><segments><segment bytes=\"1\" number=\"1\">a@b</segments></file></nzb>";
    try std.testing.expectError(error.NzbParseFailed, parse(std.testing.allocator, missing_segment_close));
}

test "rejects invalid structural nesting" {
    const direct_segment = "<nzb><file><segment bytes=\"1\" number=\"1\">a@b</segment></file></nzb>";
    try std.testing.expectError(error.InvalidNzbStructure, parse(std.testing.allocator, direct_segment));
    const nested_file = "<nzb><file><file><segments><segment bytes=\"1\" number=\"1\">a@b</segment></segments></file></file></nzb>";
    try std.testing.expectError(error.InvalidNzbStructure, parse(std.testing.allocator, nested_file));
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

test "rejects zero-byte segments" {
    const text =
        \\<nzb><file><segments>
        \\<segment bytes="0" number="1">a@b</segment>
        \\</segments></file></nzb>
    ;
    try std.testing.expectError(error.InvalidSegmentBytes, parse(std.testing.allocator, text));
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
        \\<nzb><file><segments><segment bytes="1" number="1">&xxe;</segment></segments></file></nzb>
    ;
    try std.testing.expectError(error.EntityReferenceRejected, parse(std.testing.allocator, text));
}

test "accepts predefined entity references" {
    const text =
        \\<nzb><file><segments><segment bytes="1" number="1">a&amp;b</segment></segments></file></nzb>
    ;
    const doc = try parse(std.testing.allocator, text);
    defer doc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a&b", doc.files[0].segments[0].message_id);
}

test "provides line and column diagnostics on failure" {
    const text =
        \\<nzb>
        \\  <file>
        \\    <segments>
        \\      <segment bytes="invalid" number="1">a@b</segment>
        \\    </segments>
        \\  </file>
        \\</nzb>
    ;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSegmentBytes, parseWithDiagnostic(std.testing.allocator, text, &diag));
    try std.testing.expect(diag.line > 0);
}

test "rejects wrong namespace and non-nzb root element" {
    const wrong_ns =
        \\<nzb xmlns="http://example.com/wrong"><file><segments>
        \\<segment bytes="1" number="1">a@b</segment>
        \\</segments></file></nzb>
    ;
    try std.testing.expectError(error.UnsupportedNzbNamespace, parse(std.testing.allocator, wrong_ns));

    const wrong_root =
        \\<other><file><segments><segment bytes="1" number="1">a@b</segment></segments></file></other>
    ;
    try std.testing.expectError(error.UnsupportedNzbNamespace, parse(std.testing.allocator, wrong_root));
}

test "accepts password metadata for direct archive downloads" {
    const text =
        \\<nzb><head><meta type="PASSWORD">secret</meta></head><file><segments>
        \\<segment bytes="1" number="1">a@b</segment>
        \\</segments></file></nzb>
    ;
    var doc = try parse(std.testing.allocator, text);
    doc.deinit(std.testing.allocator);
}

test "rejects non-contiguous segment numbers" {
    const text =
        \\<nzb><file><segments>
        \\<segment bytes="1" number="1">a@b</segment>
        \\<segment bytes="1" number="3">c@d</segment>
        \\</segments></file></nzb>
    ;
    try std.testing.expectError(error.NonContiguousSegmentNumbers, parse(std.testing.allocator, text));
}

test "rejects internal entity declaration" {
    const text =
        \\<!DOCTYPE nzb [<!ENTITY foo "bar">]>
        \\<nzb><file><segments><segment bytes="1" number="1">a@b</segment></segments></file></nzb>
    ;
    try std.testing.expectError(error.InternalEntityRejected, parse(std.testing.allocator, text));
}

test "entity references inside comments are not rejected" {
    const text =
        \\<nzb><!-- use &custom; syntax --><file><segments>
        \\<segment bytes="1" number="1">a@b</segment>
        \\</segments></file></nzb>
    ;
    var doc = try parse(std.testing.allocator, text);
    doc.deinit(std.testing.allocator);
}

test "entity declarations inside comments are not rejected" {
    const text =
        \\<nzb><!-- <!ENTITY foo "bar"> --><file><segments>
        \\<segment bytes="1" number="1">a@b</segment>
        \\</segments></file></nzb>
    ;
    var doc = try parse(std.testing.allocator, text);
    doc.deinit(std.testing.allocator);
}

test "silently skips foreign-namespaced elements inside head" {
    const text =
        \\<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
        \\  <head>
        \\    <meta type="x" xmlns="http://other.com/ns">value</meta>
        \\  </head>
        \\  <file><segments><segment bytes="1" number="1">a@b</segment></segments></file>
        \\</nzb>
    ;
    var doc = try parse(std.testing.allocator, text);
    doc.deinit(std.testing.allocator);
}

test "foreign-namespaced structural element inside head is still rejected" {
    const text =
        \\<nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
        \\  <head>
        \\    <file xmlns="http://other.com/ns"><segments><segment bytes="1" number="1">a@b</segment></segments></file>
        \\  </head>
        \\  <file><segments><segment bytes="2" number="1">b@c</segment></segments></file>
        \\</nzb>
    ;
    try std.testing.expectError(error.UnsupportedNzbNamespace, parse(std.testing.allocator, text));
}
