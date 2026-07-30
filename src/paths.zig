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
    const z = try toZ(path, out);
    var resolved: [c.PATH_MAX]u8 = undefined;
    if (realpath(z.ptr, &resolved) == null) return error.DownloadRootNotAccessible;
    const result = std.mem.sliceTo(&resolved, 0);
    var stat: c.struct_stat = undefined;
    if (c.lstat(&resolved, &stat) != 0 or (stat.st_mode & c.S_IFMT) != c.S_IFDIR) return error.DownloadRootNotDirectory;
    if (c.access(&resolved, c.R_OK | c.W_OK | c.X_OK) != 0) return error.DownloadRootNotWritable;
    if (result.len > out.len) return error.NameTooLong;
    @memcpy(out[0..result.len], result);
    return out[0..result.len];
}

pub fn resolveContained(root: []const u8, candidate: []const u8, out: []u8) ![]const u8 {
    if (candidate.len == 0 or std.mem.findScalar(u8, candidate, 0) != null) return error.InvalidPath;
    var joined: [c.PATH_MAX]u8 = undefined;
    const text = if (candidate[0] == '/') candidate else try std.fmt.bufPrint(&joined, "{s}/{s}", .{ root, candidate });
    var zbuf: [c.PATH_MAX + 1]u8 = undefined;
    const z = try toZ(text, &zbuf);
    var resolved: [c.PATH_MAX]u8 = undefined;
    if (realpath(z.ptr, &resolved) == null) {
        if (std.c._errno().* == c.ENOENT) return error.PathNotFound;
        return error.PathNotAccessible;
    }
    const result = std.mem.sliceTo(&resolved, 0);
    if (!inside(root, result)) return error.PathOutsideRoot;
    if (result.len > out.len) return error.NameTooLong;
    @memcpy(out[0..result.len], result);
    return out[0..result.len];
}

pub fn rejectSymlinks(root: []const u8, candidate: []const u8) !void {
    var joined: [c.PATH_MAX]u8 = undefined;
    const path = if (candidate.len > 0 and candidate[0] == '/')
        candidate
    else
        try std.fmt.bufPrint(&joined, "{s}/{s}", .{ root, candidate });
    if (!inside(root, path)) return error.PathOutsideRoot;
    var current: [c.PATH_MAX]u8 = undefined;
    @memcpy(current[0..root.len], root);
    var used = root.len;
    var parts = std.mem.splitScalar(u8, path[root.len..], '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (used + 1 + part.len >= current.len) return error.NameTooLong;
        current[used] = '/';
        used += 1;
        @memcpy(current[used .. used + part.len], part);
        used += part.len;
        var zbuf: [c.PATH_MAX + 1]u8 = undefined;
        const z = try toZ(current[0..used], &zbuf);
        var stat: c.struct_stat = undefined;
        if (c.lstat(z.ptr, &stat) != 0) {
            if (std.c._errno().* == c.ENOENT) return error.PathNotFound;
            return error.PathNotAccessible;
        }
        if ((stat.st_mode & c.S_IFMT) == c.S_IFLNK) return error.SymbolicLinkRejected;
    }
}

pub fn inside(root: []const u8, candidate: []const u8) bool {
    return std.mem.eql(u8, root, candidate) or
        (candidate.len > root.len and std.mem.startsWith(u8, candidate, root) and candidate[root.len] == '/');
}

fn toZ(text: []const u8, out: []u8) ![:0]u8 {
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
