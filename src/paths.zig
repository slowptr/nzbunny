const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("limits.h");
    @cInclude("stdlib.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});
extern "c" fn realpath(noalias path: [*:0]const u8, noalias resolved: [*]u8) ?[*:0]u8;

pub fn resolveRoot(path: []const u8, out: []u8) ![]const u8 {
    if (path.len == 0 or path[0] != '/') return error.DownloadRootNotAbsolute;
    const z = try toZ(path, out);
    var resolved: [c.PATH_MAX]u8 = undefined;
    if (realpath(z.ptr, &resolved) == null) {
        // Auto-create a single missing leaf directory. Multi-level creation
        // is not supported; operators must ensure parent directories exist.
        if (std.c._errno().* == c.ENOENT) {
            if (c.mkdir(z.ptr, 511) != 0) return error.DownloadRootNotAccessible;
            if (realpath(z.ptr, &resolved) == null) return error.DownloadRootNotAccessible;
        } else {
            return error.DownloadRootNotAccessible;
        }
    }
    const result = std.mem.sliceTo(&resolved, 0);
    var stat: c.struct_stat = undefined;
    if (c.lstat(&resolved, &stat) != 0 or (stat.st_mode & c.S_IFMT) != c.S_IFDIR) return error.DownloadRootNotDirectory;
    if (c.access(&resolved, c.R_OK | c.W_OK | c.X_OK) != 0) return error.DownloadRootNotWritable;
    if (result.len > out.len) return error.NameTooLong;
    @memcpy(out[0..result.len], result);
    return out[0..result.len];
}

pub fn relativeToRoot(root: []const u8, candidate: []const u8) ![]const u8 {
    if (candidate.len == 0 or std.mem.findScalar(u8, candidate, 0) != null) return error.InvalidPath;
    const rel = if (candidate[0] == '/') blk: {
        if (!inside(root, candidate)) return error.PathOutsideRoot;
        if (std.mem.eql(u8, root, candidate)) return error.RefuseRootRemoval;
        break :blk candidate[root.len + 1 ..];
    } else candidate;
    var has_component = false;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.PathOutsideRoot;
        has_component = true;
    }
    if (!has_component) return error.InvalidPath;
    return rel;
}

pub fn inside(root: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, root, candidate) or
        (candidate.len > root.len and std.mem.startsWith(u8, candidate, root) and candidate[root.len] == '/');
}

pub fn toZ(text: []const u8, out: []u8) ![:0]u8 {
    if (text.len >= out.len) return error.NameTooLong;
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return out[0..text.len :0];
}

test "path containment uses component boundaries" {
    try std.testing.expect(inside("/downloads", "/downloads/item"));
    try std.testing.expect(inside("/downloads", "/downloads"));
    try std.testing.expect(!inside("/downloads", "/downloads-other/item"));
    try std.testing.expect(!inside("/downloads", "/tmp/item"));
}

test "relativeToRoot normalizes paths and rejects traversal" {
    try std.testing.expectEqualStrings("item/file.bin", try relativeToRoot("/downloads", "/downloads/item/file.bin"));
    try std.testing.expectEqualStrings("item/file.bin", try relativeToRoot("/downloads", "item/file.bin"));
    try std.testing.expectError(error.RefuseRootRemoval, relativeToRoot("/downloads", "/downloads"));
    try std.testing.expectError(error.PathOutsideRoot, relativeToRoot("/downloads", "/other/file.bin"));
    try std.testing.expectError(error.PathOutsideRoot, relativeToRoot("/downloads", "../escape"));
    try std.testing.expectError(error.PathOutsideRoot, relativeToRoot("/downloads", "a/./b"));
    try std.testing.expectError(error.InvalidPath, relativeToRoot("/downloads", ""));
    try std.testing.expectError(error.InvalidPath, relativeToRoot("/downloads", "/downloads///"));
}
