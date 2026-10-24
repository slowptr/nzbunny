const std = @import("std");
const shutdown = @import("shutdown.zig");
const Progress = @import("progress.zig").Progress;
const yenc = @import("yenc.zig");

pub const FileManifest = struct {
    name: []const u8 = "",
    size: u64 = 0,
    parts: []Part = &.{},
    preflight_err: ?anyerror = null,

    pub fn deinit(self: FileManifest, allocator: std.mem.Allocator) void {
        if (self.name.len != 0) allocator.free(self.name);
        for (self.parts) |part| if (part.rel_path.len != 0) allocator.free(part.rel_path);
        if (self.parts.len > 0) allocator.free(self.parts);
    }
};

pub const Part = struct {
    begin: u64,
    end: u64,
    rel_path: []const u8,
    crc32: ?u32 = null,
};

pub fn allPartsPresent(parts: []const Part) bool {
    for (parts) |part| if (part.rel_path.len == 0) return false;
    return true;
}

pub fn hasAnyPartPresent(parts: []const Part) bool {
    for (parts) |part| if (part.rel_path.len != 0) return true;
    return false;
}

pub fn hasUsableRepairFile(manifest: []const FileManifest, included: []const bool) bool {
    for (manifest, included) |file, keep| {
        if (!keep and file.name.len != 0 and file.size > 0 and hasAnyPartPresent(file.parts)) return true;
    }
    return false;
}

pub fn assembleRepairFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    manifest: []FileManifest,
    included: []const bool,
    control: *shutdown.DownloadControl,
    progress: *Progress,
) ![]const u8 {
    var repair_name: ?[]const u8 = null;
    for (manifest, included) |file, keep| {
        if (keep or file.name.len == 0 or file.size == 0 or !hasAnyPartPresent(file.parts)) continue;
        if (allPartsPresent(file.parts)) {
            try validatePartRanges(file.parts, file.size);
            try assembleFile(allocator, io, root_dir, output_root, file, control, progress);
        } else {
            try assembleDamagedFile(allocator, io, root_dir, output_root, file, control, progress);
        }
        if (repair_name == null or !isRecoveryName(file.name)) repair_name = file.name;
    }
    return repair_name orelse error.InsufficientPar2Data;
}

pub fn sortPresentParts(parts: []Part) void {
    std.mem.sort(Part, parts, {}, struct {
        fn lessThan(_: void, a: Part, b: Part) bool {
            const a_present = a.rel_path.len != 0;
            const b_present = b.rel_path.len != 0;
            if (a_present != b_present) return a_present;
            return a.begin < b.begin;
        }
    }.lessThan);
}

pub fn assembleDamagedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    output: FileManifest,
    control: *shutdown.DownloadControl,
    progress: *Progress,
) !void {
    sortPresentParts(output.parts);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, output.name });
    defer allocator.free(final_path);
    var out = try root_dir.createFile(io, final_path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out.close(io);
    try out.setLength(io, output.size);
    var previous_end: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    for (output.parts) |part| {
        if (part.rel_path.len == 0) continue;
        try checkCanceled(control);
        if (part.begin <= previous_end or part.end < part.begin or part.end > output.size) return error.InvalidYencRange;
        previous_end = part.end;
        var input = try root_dir.openFile(io, part.rel_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        defer input.close(io);
        const size = try yenc.inclusiveRangeLength(part.begin, part.end);
        var offset: u64 = 0;
        while (offset < size) {
            try checkCanceled(control);
            const chunk: usize = @intCast(@min(size - offset, buffer.len));
            const read = try preadChunk(input, io, buffer[0..chunk], offset);
            try pwriteAll(out, io, buffer[0..read], part.begin - 1 + offset);
            offset += read;
        }
        progress.touch(io);
    }
    try out.sync(io);
}

pub fn cleanupRepairFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    manifest: []const FileManifest,
    included: []const bool,
) void {
    for (manifest, included) |file, keep| {
        if (file.name.len == 0) continue;
        if (!keep) {
            const par_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, file.name }) catch continue;
            defer allocator.free(par_path);
            root_dir.deleteFile(io, par_path) catch {};
            const par_bak = std.fmt.allocPrint(allocator, "{s}/{s}.1", .{ output_root, file.name }) catch continue;
            defer allocator.free(par_bak);
            root_dir.deleteFile(io, par_bak) catch {};
        } else {
            const bak_path = std.fmt.allocPrint(allocator, "{s}/{s}.1", .{ output_root, file.name }) catch continue;
            defer allocator.free(bak_path);
            root_dir.deleteFile(io, bak_path) catch {};
        }
    }
}

pub fn preadChunk(file: std.Io.File, io: std.Io, buffer: []u8, offset: u64) !usize {
    const count = file.readPositional(io, &.{buffer}, offset) catch return error.DecodedPartChanged;
    if (count == 0) return error.DecodedPartChanged;
    return count;
}

pub fn pwriteAll(file: std.Io.File, io: std.Io, bytes: []const u8, start_offset: u64) !void {
    file.writePositionalAll(io, bytes, start_offset) catch return error.DecodedPartChanged;
}

pub fn expectedFileCrc(parts: []const Part) !?u32 {
    var expected: ?u32 = null;
    for (parts) |part| {
        if (part.crc32) |crc| {
            if (expected) |prev| {
                if (prev != crc) return error.InconsistentYencMetadata;
            } else {
                expected = crc;
            }
        }
    }
    return expected;
}

pub fn validateRepairedFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    output: FileManifest,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, output.name });
    defer allocator.free(path);
    var file = try root_dir.openFile(io, path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
    defer file.close(io);
    if (try file.length(io) != output.size) return error.Par2RepairFailed;
    const expected = try expectedFileCrc(output.parts);
    if (!allPartsPresent(output.parts) and expected == null) {
        const bak_path = try std.fmt.allocPrint(allocator, "{s}/{s}.1", .{ output_root, output.name });
        defer allocator.free(bak_path);
        var bak = root_dir.openFile(io, bak_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true }) catch
            return error.Par2RepairFailed;
        bak.close(io);
    }
    if (expected) |crc| {
        var actual: std.hash.Crc32 = .init();
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < output.size) {
            const chunk: usize = @intCast(@min(output.size - offset, buffer.len));
            const read = preadChunk(file, io, buffer[0..chunk], offset) catch return error.Par2RepairFailed;
            actual.update(buffer[0..read]);
            offset += read;
        }
        if (actual.final() != crc) return error.YencCrcMismatch;
    }
    // PAR2 may have rewritten the inode after assembly synced it.
    try file.sync(io);
}

pub fn assembleFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    output_root: []const u8,
    output: FileManifest,
    control: *shutdown.DownloadControl,
    progress: *Progress,
) !void {
    try checkCanceled(control);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_root, output.name });
    defer allocator.free(final_path);
    var out = try root_dir.createFile(io, final_path, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer out.close(io);
    var out_buffer: [64 * 1024]u8 = undefined;
    var writer = out.writer(io, &out_buffer);
    var reader_buf: [64 * 1024]u8 = undefined;
    const expected_crc = try expectedFileCrc(output.parts);
    var file_crc: std.hash.Crc32 = .init();
    for (output.parts) |part| {
        try checkCanceled(control);
        var input = try root_dir.openFile(io, part.rel_path, .{ .allow_directory = false, .follow_symlinks = false, .resolve_beneath = true });
        defer input.close(io);
        const size = try yenc.inclusiveRangeLength(part.begin, part.end);
        var remaining = size;
        var off: u64 = 0;
        while (remaining > 0) {
            try checkCanceled(control);
            const chunk: usize = @intCast(@min(remaining, reader_buf.len));
            const n = try preadChunk(input, io, reader_buf[0..chunk], off);
            file_crc.update(reader_buf[0..n]);
            try writer.interface.writeAll(reader_buf[0..n]);
            remaining -= n;
            off += n;
        }
        progress.touch(io);
    }
    try writer.interface.flush();
    try out.sync(io);
    if (expected_crc) |crc| {
        if (file_crc.final() != crc) return error.YencCrcMismatch;
    }
}

pub fn validatePartRanges(parts: []Part, size: u64) !void {
    std.mem.sort(Part, parts, {}, struct {
        fn lessThan(_: void, a: Part, b: Part) bool {
            return a.begin < b.begin;
        }
    }.lessThan);
    var expected: u64 = 1;
    for (parts) |part| {
        if (part.begin != expected or part.end < part.begin or part.end > size) return error.InvalidYencRange;
        expected = std.math.add(u64, part.end, 1) catch return error.InvalidYencRange;
    }
    if (expected != std.math.add(u64, size, 1) catch return error.InvalidYencRange) return error.InvalidYencRange;
}

pub fn isRecoveryName(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, ".vol") != null and std.ascii.endsWithIgnoreCase(name, ".par2");
}

fn checkCanceled(control: *shutdown.DownloadControl) !void {
    if (control.isTimedOut()) return error.Timeout;
    if (control.isCanceled()) return error.Canceled;
    if (shutdown.now(control.io) >= control.deadline_seconds) {
        control.timeout();
        return error.Timeout;
    }
}

test "repaired payload must sync successfully before it can be published" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "repaired.bin", .data = "abc" });
    // Override only the sync operation; the real file is opened and validated.
    // A rejected sync must propagate instead of treating verified bytes as durable.
    var vtable = io.vtable.*;
    vtable.fileSync = struct {
        fn fail(_: ?*anyopaque, _: std.Io.File) std.Io.File.SyncError!void {
            return error.InputOutput;
        }
    }.fail;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    const manifest: FileManifest = .{ .name = "repaired.bin", .size = 3 };
    try std.testing.expectError(error.InputOutput, validateRepairedFile(std.testing.allocator, failing_io, tmp.dir, ".", manifest));
    try validateRepairedFile(std.testing.allocator, io, tmp.dir, ".", manifest);
}
