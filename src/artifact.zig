const std = @import("std");
const paths = @import("paths.zig");
const c = @cImport({
    @cInclude("archive.h");
    @cInclude("archive_entry.h");
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("limits.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const at_removedir = std.os.linux.AT.REMOVEDIR;

pub const Result = struct {
    relative_path: []const u8,
    size: u64,
};

const Limits = struct {
    max_bytes: u64,
    entries: usize = 0,
    input_bytes: u64 = 0,
};

const max_entries = 10_000;
const max_depth = 128;

pub fn prepare(
    allocator: std.mem.Allocator,
    root: []const u8,
    job_id: []const u8,
    source: []const u8,
    max_bytes: u64,
) !Result {
    var source_buffer: [c.PATH_MAX]u8 = undefined;
    const resolved = try paths.resolveContained(root, source, &source_buffer);
    try paths.rejectSymlinks(root, source);
    const root_fd = std.posix.openat(std.posix.AT.FDCWD, root, .{
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0) catch return error.DownloadRootNotAccessible;
    defer _ = c.close(root_fd);
    const artifact_name = ".nzigbunny-artifacts";
    if (c.mkdirat(root_fd, artifact_name, 0o755) != 0 and std.c._errno().* != c.EEXIST)
        return error.ArtifactDirectoryFailed;
    const artifact_fd = std.posix.openat(
        root_fd,
        artifact_name,
        .{
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        },
        0,
    ) catch return error.ArtifactDirectoryUnsafe;
    defer _ = c.close(artifact_fd);

    if (!paths.inside(root, resolved) or resolved.len <= root.len) return error.PathOutsideRoot;
    const source_fd = openRelative(root_fd, resolved[root.len + 1 ..]) catch
        return error.ArtifactSourceNotAccessible;
    defer _ = c.close(source_fd.fd);
    const mode = source_fd.stat.st_mode & c.S_IFMT;
    if (mode != c.S_IFREG and mode != c.S_IFDIR) return error.SpecialFileRejected;

    var final_name_buffer: [96]u8 = undefined;
    const final_name = if (mode == c.S_IFDIR)
        try std.fmt.bufPrintZ(&final_name_buffer, "{s}.zip", .{job_id})
    else
        try std.fmt.bufPrintZ(&final_name_buffer, "{s}.bin", .{job_id});
    if (existingRegularAt(artifact_fd, final_name, max_bytes)) |size| {
        return .{
            .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ artifact_name, final_name }),
            .size = size,
        };
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var temp_name_buffer: [100]u8 = undefined;
    const temp_name = try std.fmt.bufPrintZ(&temp_name_buffer, "{s}.tmp", .{final_name});
    try removeFileAt(artifact_fd, temp_name);
    errdefer removeFileAt(artifact_fd, temp_name) catch |err|
        std.log.err("Temporary artifact cleanup failed for {s}: {t}", .{ temp_name, err });
    const temp_fd = std.posix.openat(
        artifact_fd,
        temp_name,
        .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        },
        @as(c.mode_t, 0o600),
    ) catch return error.ArchiveOpenFailed;
    var temp_open = true;
    defer {
        if (temp_open) _ = c.close(temp_fd);
    }

    if (mode == c.S_IFREG) {
        const source_size: u64 = @intCast(source_fd.stat.st_size);
        if (source_size > max_bytes) return error.ArtifactTooLarge;
        try copyFd(source_fd.fd, temp_fd, source_size);
    } else {
        const archive = c.archive_write_new() orelse return error.ArchiveCreateFailed;
        defer _ = c.archive_write_free(archive);
        if (c.archive_write_set_format_zip(archive) != c.ARCHIVE_OK) return error.ArchiveFormatFailed;
        if (c.archive_write_open_fd(archive, temp_fd) != c.ARCHIVE_OK)
            return error.ArchiveOpenFailed;
        var archive_open = true;
        defer {
            if (archive_open) _ = c.archive_write_close(archive);
        }
        var limits = Limits{ .max_bytes = max_bytes };
        try walkFd(archive, source_fd.fd, "", &limits, 0);
        if (c.archive_write_close(archive) != c.ARCHIVE_OK) return error.ArchiveCloseFailed;
        archive_open = false;
    }

    var temp_stat: c.struct_stat = undefined;
    if (c.fstat(temp_fd, &temp_stat) != 0 or (temp_stat.st_mode & c.S_IFMT) != c.S_IFREG)
        return error.ArchiveStatFailed;
    const size: u64 = @intCast(temp_stat.st_size);
    if (size > max_bytes) return error.ArtifactTooLarge;
    if (c.close(temp_fd) != 0) return error.ArchiveCloseFileFailed;
    temp_open = false;
    if (c.renameat(artifact_fd, temp_name, artifact_fd, final_name) != 0)
        return error.ArchiveRenameFailed;
    return .{
        .relative_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ artifact_name, final_name }),
        .size = size,
    };
}

const Opened = struct { fd: c_int, stat: c.struct_stat, is_dir: bool };

const RemoveError = error{
    SymbolicLinkRejected,
    ArtifactSourceNotAccessible,
    ArtifactStatFailed,
    DirectoryReadFailed,
    CleanupFailed,
    DirectoryNotEmpty,
    DirectoryTooDeep,
    NameTooLong,
    SpecialFileRejected,
};

fn walkFd(
    archive: *c.struct_archive,
    dir_fd: c_int,
    prefix: []const u8,
    limits: *Limits,
    depth: usize,
) !void {
    if (depth > max_depth) return error.DirectoryTooDeep;
    const scan_fd = c.dup(dir_fd);
    if (scan_fd < 0) return error.DirectoryReadFailed;
    const dir = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.DirectoryReadFailed;
    };
    defer _ = c.closedir(dir);
    const base = c.dirfd(dir);
    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(dir);
        if (entry == null) {
            if (std.c._errno().* != 0) return error.DirectoryReadFailed;
            break;
        }
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        limits.entries += 1;
        if (limits.entries > max_entries) return error.TooManyArtifactEntries;
        var name_z: [c.PATH_MAX + 1]u8 = undefined;
        const z = try toZ(name, &name_z);
        const opened = openChild(base, z) catch |err| switch (err) {
            error.SymbolicLinkRejected => return error.SymbolicLinkRejected,
            else => return error.ArtifactSourceNotAccessible,
        };
        defer _ = c.close(opened.fd);
        if (opened.is_dir) {
            var child_prefix: [c.PATH_MAX + 1]u8 = undefined;
            const next_prefix = std.fmt.bufPrint(&child_prefix, "{s}{s}/", .{ prefix, name }) catch
                return error.NameTooLong;
            try walkFd(archive, opened.fd, next_prefix, limits, depth + 1);
            continue;
        }
        const mode = opened.stat.st_mode & c.S_IFMT;
        if (mode != c.S_IFREG) return error.SpecialFileRejected;
        const size: u64 = @intCast(opened.stat.st_size);
        limits.input_bytes = std.math.add(u64, limits.input_bytes, size) catch return error.ArtifactTooLarge;
        if (limits.input_bytes > limits.max_bytes) return error.ArtifactTooLarge;
        var entry_name: [c.PATH_MAX + 1]u8 = undefined;
        const archive_name = std.fmt.bufPrint(&entry_name, "{s}{s}", .{ prefix, name }) catch
            return error.NameTooLong;
        try addFd(archive, opened.fd, archive_name, size);
    }
}

fn copyFd(source_fd: c_int, destination_fd: c_int, expected_size: u64) !void {
    var copied: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (copied < expected_size) {
        const wanted: usize = @intCast(@min(expected_size - copied, buffer.len));
        const read_count = c.read(source_fd, &buffer, wanted);
        if (read_count < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.ArtifactReadFailed;
        }
        if (read_count == 0) return error.ArtifactSourceChanged;
        var written: usize = 0;
        const bytes_read: usize = @intCast(read_count);
        while (written < bytes_read) {
            const write_count = c.write(destination_fd, buffer[written..].ptr, bytes_read - written);
            if (write_count < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return error.ArchiveWriteFailed;
            }
            if (write_count == 0) return error.ArchiveWriteFailed;
            written += @intCast(write_count);
        }
        copied += bytes_read;
    }
    var extra: [1]u8 = undefined;
    while (true) {
        const read_count = c.read(source_fd, &extra, extra.len);
        if (read_count < 0 and std.c._errno().* == c.EINTR) continue;
        if (read_count < 0) return error.ArtifactReadFailed;
        if (read_count != 0) return error.ArtifactSourceChanged;
        break;
    }
    if (c.fsync(destination_fd) != 0) return error.ArchiveWriteFailed;
}

fn openChild(parent_fd: c_int, name: [:0]const u8) !Opened {
    const fd = std.posix.openat(parent_fd, name, .{
        .ACCMODE = .RDONLY,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        error.SymLinkLoop => return error.SymbolicLinkRejected,
        else => return error.ArtifactSourceNotAccessible,
    };
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) {
        _ = c.close(fd);
        return error.ArtifactStatFailed;
    }
    return .{ .fd = fd, .stat = stat, .is_dir = (stat.st_mode & c.S_IFMT) == c.S_IFDIR };
}

fn addFd(archive: *c.struct_archive, fd: c_int, name: []const u8, size: u64) !void {
    const entry = c.archive_entry_new() orelse return error.ArchiveEntryFailed;
    defer c.archive_entry_free(entry);
    var name_z: [c.PATH_MAX + 1]u8 = undefined;
    c.archive_entry_set_pathname(entry, (try toZ(name, &name_z)).ptr);
    c.archive_entry_set_filetype(entry, c.S_IFREG);
    c.archive_entry_set_perm(entry, 0o600);
    c.archive_entry_set_size(entry, @intCast(size));
    if (c.archive_write_header(archive, entry) != c.ARCHIVE_OK) return error.ArchiveHeaderFailed;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n == 0) break;
        if (n < 0) return error.ArtifactReadFailed;
        if (c.archive_write_data(archive, &buffer, @intCast(n)) != n) return error.ArchiveWriteFailed;
    }
}

pub fn removeValidated(root: []const u8, candidate: []const u8) !void {
    if (candidate.len == 0) return;
    paths.rejectSymlinks(root, candidate) catch |err| switch (err) {
        error.PathNotFound => return,
        else => return err,
    };
    var resolved_buffer: [c.PATH_MAX]u8 = undefined;
    const resolved = paths.resolveContained(root, candidate, &resolved_buffer) catch |err| switch (err) {
        error.PathNotFound => return,
        else => return err,
    };
    if (std.mem.eql(u8, resolved, root)) return error.RefuseRootRemoval;
    const root_fd = std.posix.openat(std.posix.AT.FDCWD, root, .{
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0) catch return error.DownloadRootNotAccessible;
    defer _ = c.close(root_fd);
    try removeRelative(root_fd, resolved[root.len + 1 ..]);
}

fn removeRelative(root_fd: c_int, rel: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, rel, '/')) |slash| {
        const name = rel[slash + 1 ..];
        if (name.len == 0) return error.InvalidPath;
        const parent_fd = try openDirPath(root_fd, rel[0..slash]);
        defer _ = c.close(parent_fd);
        var name_z: [c.PATH_MAX + 1]u8 = undefined;
        try removeUnder(parent_fd, try toZ(name, &name_z), 0);
    } else {
        var name_z: [c.PATH_MAX + 1]u8 = undefined;
        try removeUnder(root_fd, try toZ(rel, &name_z), 0);
    }
}

fn openDirPath(start_fd: c_int, rel: []const u8) !c_int {
    var current = start_fd;
    var own_current = false;
    errdefer {
        if (own_current) _ = c.close(current);
    }
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        var zbuf: [c.PATH_MAX + 1]u8 = undefined;
        const z = try toZ(comp, &zbuf);
        const next = std.posix.openat(current, z, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0) catch |err| switch (err) {
            error.FileNotFound => return error.PathNotFound,
            error.SymLinkLoop => return error.SymbolicLinkRejected,
            else => return error.PathNotAccessible,
        };
        if (own_current) _ = c.close(current);
        current = next;
        own_current = true;
    }
    if (!own_current) return error.PathNotFound;
    return current;
}

fn openRelative(root_fd: c_int, rel: []const u8) !Opened {
    if (rel.len == 0) return error.InvalidPath;
    if (std.mem.lastIndexOfScalar(u8, rel, '/')) |slash| {
        const name = rel[slash + 1 ..];
        if (name.len == 0) return error.InvalidPath;
        const parent_fd = try openDirPath(root_fd, rel[0..slash]);
        defer _ = c.close(parent_fd);
        var name_z: [c.PATH_MAX + 1]u8 = undefined;
        return openChild(parent_fd, try toZ(name, &name_z));
    }
    var name_z: [c.PATH_MAX + 1]u8 = undefined;
    return openChild(root_fd, try toZ(rel, &name_z));
}

fn removeUnder(parent_fd: c_int, name: [:0]const u8, depth: usize) RemoveError!void {
    if (depth > max_depth) return error.DirectoryTooDeep;
    const opened = openChild(parent_fd, name) catch |err| switch (err) {
        error.FileNotFound => return,
        error.SymbolicLinkRejected => return error.SymbolicLinkRejected,
        error.ArtifactStatFailed => return error.ArtifactStatFailed,
        else => return error.ArtifactSourceNotAccessible,
    };
    defer _ = c.close(opened.fd);
    if (opened.is_dir) {
        try emptyDirFd(opened.fd, depth);
        if (c.unlinkat(parent_fd, name.ptr, at_removedir) != 0) {
            const e = std.c._errno().*;
            if (e == c.ENOENT) return;
            if (e == c.ENOTEMPTY) return error.DirectoryNotEmpty;
            return error.CleanupFailed;
        }
        return;
    }
    const mode = opened.stat.st_mode & c.S_IFMT;
    if (mode != c.S_IFREG) return error.SpecialFileRejected;
    if (c.unlinkat(parent_fd, name.ptr, 0) != 0) {
        if (std.c._errno().* == c.ENOENT) return;
        return error.CleanupFailed;
    }
}

fn emptyDirFd(dir_fd: c_int, depth: usize) RemoveError!void {
    const scan_fd = c.dup(dir_fd);
    if (scan_fd < 0) return error.DirectoryReadFailed;
    const dir = c.fdopendir(scan_fd) orelse {
        _ = c.close(scan_fd);
        return error.DirectoryReadFailed;
    };
    defer _ = c.closedir(dir);
    const base = c.dirfd(dir);
    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(dir);
        if (entry == null) {
            if (std.c._errno().* != 0) return error.DirectoryReadFailed;
            break;
        }
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var name_z: [c.PATH_MAX + 1]u8 = undefined;
        try removeUnder(base, try toZ(name, &name_z), depth + 1);
    }
}

fn existingRegularAt(directory_fd: c_int, name: [:0]const u8, max: u64) !u64 {
    const fd = std.posix.openat(directory_fd, name, .{
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.ArtifactFileUnsafe,
    };
    defer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.ArtifactStatFailed;
    if ((stat.st_mode & c.S_IFMT) != c.S_IFREG) return error.SpecialFileRejected;
    const size: u64 = @intCast(stat.st_size);
    if (size > max) return error.ArtifactTooLarge;
    return size;
}

fn removeFileAt(directory_fd: c_int, name: [:0]const u8) !void {
    if (c.unlinkat(directory_fd, name.ptr, 0) == 0 or std.c._errno().* == c.ENOENT) return;
    return error.TemporaryArtifactCleanupFailed;
}

fn toZ(text: []const u8, out: []u8) ![:0]u8 {
    if (text.len >= out.len) return error.NameTooLong;
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return out[0..text.len :0];
}

test "cleanup accepts an already missing artifact" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    try removeValidated(root_buffer[0..root_len], "missing");
}

test "artifact directory cannot be a symlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "downloads", .default_dir);
    try tmp.dir.createDir(io, "downloads/source", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "downloads/source/file.txt", .data = "content" });

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const base = root_buffer[0..root_len];
    var download_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const download = try std.fmt.bufPrint(&download_buffer, "{s}/downloads", .{base});
    var outside_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const outside = try std.fmt.bufPrint(&outside_buffer, "{s}/outside", .{base});
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buffer, "{s}/.nzigbunny-artifacts", .{download});
    var outside_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    var link_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (c.symlink((try toZ(outside, &outside_z)).ptr, (try toZ(link, &link_z)).ptr) != 0)
        return error.TestSymlinkFailed;

    try std.testing.expectError(
        error.ArtifactDirectoryUnsafe,
        prepare(std.testing.allocator, download, "0123456789abcdef0123456789abcdef", "source", 1024),
    );
}

test "directory artifact is written through a safe directory handle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "downloads", .default_dir);
    try tmp.dir.createDir(io, "downloads/source", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "downloads/source/file.txt", .data = "content" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    var download_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const download = try std.fmt.bufPrint(&download_buffer, "{s}/downloads", .{root_buffer[0..root_len]});

    const result = try prepare(
        std.testing.allocator,
        download,
        "0123456789abcdef0123456789abcdef",
        "source",
        1024,
    );
    defer std.testing.allocator.free(result.relative_path);
    try std.testing.expectEqualStrings(
        ".nzigbunny-artifacts/0123456789abcdef0123456789abcdef.zip",
        result.relative_path,
    );
    try std.testing.expect(result.size > 0);
}

test "a symlink inside the source tree is not followed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, "downloads", .default_dir);
    try tmp.dir.createDir(io, "downloads/source", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "downloads/source/real.txt", .data = "content" });
    try tmp.dir.writeFile(io, .{ .sub_path = "downloads/secret.txt", .data = "secret" });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buffer);
    const base = root_buffer[0..root_len];
    var secret_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const secret = try std.fmt.bufPrint(&secret_buffer, "{s}/downloads/secret.txt", .{base});
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buffer, "{s}/downloads/source/escape.txt", .{base});
    var secret_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    var link_z: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (c.symlink((try toZ(secret, &secret_z)).ptr, (try toZ(link, &link_z)).ptr) != 0)
        return error.TestSymlinkFailed;
    var download_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const download = try std.fmt.bufPrint(&download_buffer, "{s}/downloads", .{base});
    try std.testing.expectError(
        error.SymbolicLinkRejected,
        prepare(std.testing.allocator, download, "0123456789abcdef0123456789abcdef", "source", 1024),
    );
}
