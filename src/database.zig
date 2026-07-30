const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const Status = enum {
    pending,
    submitting,
    processing,
    finalizing,
    complete,
    failed,
    expired,

    pub fn publicName(self: Status) []const u8 {
        return switch (self) {
            .pending => "PENDING",
            .submitting, .processing, .finalizing => "PROCESSING",
            .complete => "COMPLETE",
            .failed => "FAILED",
            .expired => "EXPIRED",
        };
    }
};

pub const Job = struct {
    id: []const u8,
    filename: []const u8,
    content: []const u8,
    status: Status,
    sab_name: []const u8,
    nzo_id: []const u8,
    download_path: []const u8,
    artifact_path: []const u8,
    artifact_size: u64,
    download_token: []const u8,
    fail_reason: []const u8,
    created_at: i64,
    updated_at: i64,
    expires_at: ?i64,

    pub fn deinit(self: Job, allocator: std.mem.Allocator) void {
        freeText(allocator, self.id);
        freeText(allocator, self.filename);
        freeText(allocator, self.content);
        freeText(allocator, self.sab_name);
        freeText(allocator, self.nzo_id);
        freeText(allocator, self.download_path);
        freeText(allocator, self.artifact_path);
        freeText(allocator, self.download_token);
        freeText(allocator, self.fail_reason);
    }
};

pub const Database = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);
        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
        if (c.sqlite3_open_v2(zpath.ptr, &handle, flags, null) != c.SQLITE_OK) {
            if (handle) |db| _ = c.sqlite3_close(db);
            return error.DatabaseOpenFailed;
        }
        const db = handle.?;
        errdefer _ = c.sqlite3_close(db);
        try initialize(db);
        return .{ .handle = db, .allocator = allocator };
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn ready(self: *Database, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, "SELECT 1", -1, &stmt, null) != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);
        return c.sqlite3_step(stmt) == c.SQLITE_ROW;
    }

    pub fn create(self: *Database, io: std.Io, filename: []const u8, content: []const u8, now: i64) ![]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.createLocked(io, filename, content, now);
    }

    pub fn createIfCapacity(
        self: *Database,
        io: std.Io,
        filename: []const u8,
        content: []const u8,
        now: i64,
        max_active: u32,
    ) !?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try exec(self.handle, "BEGIN IMMEDIATE;");
        errdefer exec(self.handle, "ROLLBACK;") catch |err|
            std.log.err("SQLite admission rollback failed: {t}", .{err});
        const active = active: {
            const count_stmt = try prepare(self.handle, "SELECT count(*) FROM jobs WHERE status IN ('PENDING','SUBMITTING','PROCESSING','FINALIZING')");
            defer _ = c.sqlite3_finalize(count_stmt);
            if (c.sqlite3_step(count_stmt) != c.SQLITE_ROW) return error.DatabaseReadFailed;
            break :active c.sqlite3_column_int64(count_stmt, 0);
        };
        if (active >= max_active) {
            try exec(self.handle, "COMMIT;");
            return null;
        }
        const id = try self.createLocked(io, filename, content, now);
        errdefer self.allocator.free(id);
        try exec(self.handle, "COMMIT;");
        return id;
    }

    fn createLocked(self: *Database, io: std.Io, filename: []const u8, content: []const u8, now: i64) ![]const u8 {
        var random: [16]u8 = undefined;
        io.random(&random);
        const id = try self.allocator.alloc(u8, 32);
        errdefer self.allocator.free(id);
        _ = std.fmt.bufPrint(id, "{x}", .{random}) catch unreachable;
        const sab_name = try std.fmt.allocPrint(self.allocator, "nzigbunny-{s}", .{id});
        defer self.allocator.free(sab_name);

        const stmt = try prepare(self.handle,
            \\INSERT INTO jobs
            \\(id, filename, content, status, sab_name, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, 'PENDING', ?4, ?5, ?5)
        );
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        bindText(stmt, 2, filename);
        _ = c.sqlite3_bind_blob(stmt, 3, content.ptr, @intCast(content.len), null);
        bindText(stmt, 4, sab_name);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return id;
    }

    pub fn get(self: *Database, io: std.Io, id: []const u8) !?Job {
        return self.getWith(io, "id", id);
    }

    pub fn getByToken(self: *Database, io: std.Io, token: []const u8) !?Job {
        return self.getWith(io, "download_token", token);
    }

    pub fn listWork(self: *Database, io: std.Io) ![]Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "SELECT id,filename,content,status,sab_name,nzo_id,download_path,artifact_path," ++
            "artifact_size,download_token,fail_reason,created_at,updated_at,expires_at FROM jobs " ++
            "WHERE status IN ('PENDING','SUBMITTING','PROCESSING','FINALIZING') ORDER BY created_at");
        defer _ = c.sqlite3_finalize(stmt);
        var result: std.ArrayList(Job) = .empty;
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try result.append(self.allocator, try scan(self.allocator, stmt)),
            c.SQLITE_DONE => return result.toOwnedSlice(self.allocator),
            else => return error.DatabaseReadFailed,
        };
    }

    pub fn listCleanup(
        self: *Database,
        io: std.Io,
        now: i64,
        failed_before: i64,
        submission_before: i64,
        processing_before: i64,
    ) ![]Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "SELECT id,filename,content,status,sab_name,nzo_id,download_path,artifact_path," ++
            "artifact_size,download_token,fail_reason,created_at,updated_at,expires_at FROM jobs " ++
            "WHERE (status='COMPLETE' AND expires_at<=?1) OR " ++
            "(status='FAILED' AND updated_at<=?2) OR " ++
            "(status IN ('PENDING','SUBMITTING') AND created_at<=?3) OR " ++
            "(status IN ('PROCESSING','FINALIZING') AND created_at<=?4) OR " ++
            "(status='EXPIRED' AND updated_at<=?5)");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now);
        _ = c.sqlite3_bind_int64(stmt, 2, failed_before);
        _ = c.sqlite3_bind_int64(stmt, 3, submission_before);
        _ = c.sqlite3_bind_int64(stmt, 4, processing_before);
        _ = c.sqlite3_bind_int64(stmt, 5, now - 1800);
        var result: std.ArrayList(Job) = .empty;
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try result.append(self.allocator, try scan(self.allocator, stmt)),
            c.SQLITE_DONE => return result.toOwnedSlice(self.allocator),
            else => return error.DatabaseReadFailed,
        };
    }

    fn getWith(self: *Database, io: std.Io, comptime field: []const u8, value: []const u8) !?Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "SELECT id,filename,content,status,sab_name,nzo_id,download_path,artifact_path," ++
            "artifact_size,download_token,fail_reason,created_at,updated_at,expires_at FROM jobs WHERE " ++ field ++ "=?1");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, value);
        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return error.DatabaseReadFailed;
        return try scan(self.allocator, stmt);
    }

    pub fn claimPending(self: *Database, io: std.Io, id: []const u8, now: i64) !bool {
        return self.casStatus(io, id, "PENDING", "SUBMITTING", now);
    }

    pub fn resumeSubmitting(self: *Database, io: std.Io, id: []const u8, nzo_id: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='PROCESSING',nzo_id=?1,content=NULL,updated_at=?2 WHERE id=?3 AND status='SUBMITTING'");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, nzo_id);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        bindText(stmt, 3, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn beginFinalizing(self: *Database, io: std.Io, id: []const u8, download_path: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='FINALIZING',download_path=?1,updated_at=?2 WHERE id=?3 AND status='PROCESSING'");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, download_path);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        bindText(stmt, 3, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn complete(self: *Database, io: std.Io, id: []const u8, artifact_path: []const u8, size: u64, token: []const u8, expires: i64, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='COMPLETE',artifact_path=?1,artifact_size=?2,download_token=?3," ++
            "expires_at=?4,updated_at=?5 WHERE id=?6 AND status='FINALIZING'");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, artifact_path);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(size));
        bindText(stmt, 3, token);
        _ = c.sqlite3_bind_int64(stmt, 4, expires);
        _ = c.sqlite3_bind_int64(stmt, 5, now);
        bindText(stmt, 6, id);
        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_CONSTRAINT) return error.DuplicateToken;
        if (result != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn fail(self: *Database, io: std.Io, id: []const u8, reason: []const u8, now: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='FAILED',fail_reason=?1,content=NULL,updated_at=?2 WHERE id=?3 AND status NOT IN ('COMPLETE','EXPIRED')");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, reason);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        bindText(stmt, 3, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
    }

    pub fn retryPending(self: *Database, io: std.Io, id: []const u8, now: i64) !bool {
        return self.casStatus(io, id, "SUBMITTING", "PENDING", now);
    }

    pub fn markExpired(self: *Database, io: std.Io, id: []const u8, expected: Status, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='EXPIRED',content=NULL,download_path=NULL,artifact_path=NULL," ++
            "artifact_size=0,fail_reason='The download expired.',updated_at=?1 WHERE id=?2 AND status=?3");
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_int64(stmt, 1, now);
        bindText(stmt, 2, id);
        bindText(stmt, 3, statusName(expected));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn purgeExpired(self: *Database, io: std.Io, id: []const u8, before: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "DELETE FROM jobs WHERE id=?1 AND status='EXPIRED' AND updated_at<=?2");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, id);
        _ = c.sqlite3_bind_int64(stmt, 2, before);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
    }

    fn casStatus(self: *Database, io: std.Io, id: []const u8, from: []const u8, to: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status=?1,updated_at=?2 WHERE id=?3 AND status=?4");
        defer _ = c.sqlite3_finalize(stmt);
        bindText(stmt, 1, to);
        _ = c.sqlite3_bind_int64(stmt, 2, now);
        bindText(stmt, 3, id);
        bindText(stmt, 4, from);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.DatabaseWriteFailed;
        return c.sqlite3_changes(self.handle) == 1;
    }
};

fn initialize(db: *c.sqlite3) !void {
    try exec(db, "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;");
    const has_jobs = try tableExists(db, "jobs");
    const has_meta = try tableExists(db, "nzigbunny_schema");
    if (has_jobs and !has_meta) return error.LegacyGoSchemaDetected;
    try exec(db,
        \\BEGIN IMMEDIATE;
        \\CREATE TABLE IF NOT EXISTS nzigbunny_schema (
        \\  version INTEGER NOT NULL
        \\);
        \\INSERT INTO nzigbunny_schema(version)
        \\SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM nzigbunny_schema);
        \\CREATE TABLE IF NOT EXISTS jobs (
        \\  id TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  content BLOB,
        \\  status TEXT NOT NULL CHECK(status IN ('PENDING','SUBMITTING','PROCESSING','FINALIZING','COMPLETE','FAILED','EXPIRED')),
        \\  sab_name TEXT NOT NULL UNIQUE,
        \\  nzo_id TEXT,
        \\  download_path TEXT,
        \\  artifact_path TEXT,
        \\  artifact_size INTEGER NOT NULL DEFAULT 0 CHECK(artifact_size>=0),
        \\  download_token TEXT UNIQUE,
        \\  fail_reason TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  expires_at INTEGER
        \\);
        \\CREATE INDEX IF NOT EXISTS jobs_status_idx ON jobs(status);
        \\CREATE INDEX IF NOT EXISTS jobs_expiry_idx ON jobs(expires_at);
        \\COMMIT;
    );
    const stmt = try prepare(db, "SELECT version FROM nzigbunny_schema LIMIT 1");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_int(stmt, 0) != 1) return error.UnsupportedSchemaVersion;
}

fn tableExists(db: *c.sqlite3, name: []const u8) !bool {
    const stmt = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
    defer _ = c.sqlite3_finalize(stmt);
    bindText(stmt, 1, name);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.DatabaseReadFailed,
    };
}

fn prepare(db: *c.sqlite3, sql: [*:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return error.DatabasePrepareFailed;
    return stmt.?;
}

fn exec(db: *c.sqlite3, sql: [*:0]const u8) !void {
    var message: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql, null, null, &message) != c.SQLITE_OK) {
        if (message != null) c.sqlite3_free(message);
        return error.DatabaseSchemaFailed;
    }
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), null);
}

fn text(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return allocator.dupe(u8, ptr[0..len]);
}

fn scan(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Job {
    const status = parseStatus(borrowedText(stmt, 3)) orelse return error.InvalidStoredStatus;
    const artifact_size = c.sqlite3_column_int64(stmt, 8);
    if (artifact_size < 0) return error.InvalidStoredArtifactSize;
    return .{
        .id = try text(allocator, stmt, 0),
        .filename = try text(allocator, stmt, 1),
        .content = blk: {
            const ptr = c.sqlite3_column_blob(stmt, 2) orelse break :blk "";
            const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
            break :blk try allocator.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]);
        },
        .status = status,
        .sab_name = try text(allocator, stmt, 4),
        .nzo_id = try text(allocator, stmt, 5),
        .download_path = try text(allocator, stmt, 6),
        .artifact_path = try text(allocator, stmt, 7),
        .artifact_size = @intCast(artifact_size),
        .download_token = try text(allocator, stmt, 9),
        .fail_reason = try text(allocator, stmt, 10),
        .created_at = c.sqlite3_column_int64(stmt, 11),
        .updated_at = c.sqlite3_column_int64(stmt, 12),
        .expires_at = if (c.sqlite3_column_type(stmt, 13) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 13),
    };
}

fn borrowedText(stmt: *c.sqlite3_stmt, column: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return ptr[0..len];
}

fn freeText(allocator: std.mem.Allocator, value: []const u8) void {
    if (value.len != 0) allocator.free(value);
}

fn parseStatus(value: []const u8) ?Status {
    const map = std.StaticStringMap(Status).initComptime(.{
        .{ "PENDING", .pending },
        .{ "SUBMITTING", .submitting },
        .{ "PROCESSING", .processing },
        .{ "FINALIZING", .finalizing },
        .{ "COMPLETE", .complete },
        .{ "FAILED", .failed },
        .{ "EXPIRED", .expired },
    });
    return map.get(value);
}

fn statusName(status: Status) []const u8 {
    return switch (status) {
        .pending => "PENDING",
        .submitting => "SUBMITTING",
        .processing => "PROCESSING",
        .finalizing => "FINALIZING",
        .complete => "COMPLETE",
        .failed => "FAILED",
        .expired => "EXPIRED",
    };
}

test "internal states map to public processing" {
    try std.testing.expectEqualStrings("PROCESSING", Status.submitting.publicName());
    try std.testing.expectEqualStrings("PROCESSING", Status.finalizing.publicName());
    try std.testing.expectEqualStrings("COMPLETE", Status.complete.publicName());
}

test "SQLite job transitions use compare and set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/jobs.db", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(db_path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try Database.open(arena.allocator(), db_path);
    defer db.close();
    const io = std.testing.io;
    const id = try db.create(io, "sample.nzb", "<nzb/>", 100);
    const pending = (try db.get(io, id)).?;
    try std.testing.expectEqual(Status.pending, pending.status);
    try std.testing.expect((try db.createIfCapacity(io, "second.nzb", "<nzb/>", 100, 1)) == null);
    try std.testing.expect(try db.claimPending(io, id, 101));
    try std.testing.expect(!try db.claimPending(io, id, 102));
    try std.testing.expect(try db.resumeSubmitting(io, id, "SAB-ID", 103));
    try std.testing.expect(try db.beginFinalizing(io, id, "output", 104));
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(try db.complete(io, id, "artifact.zip", 42, token, 200, 105));
    const complete_job = (try db.getByToken(io, token)).?;
    try std.testing.expectEqual(Status.complete, complete_job.status);
    try std.testing.expectEqual(@as(u64, 42), complete_job.artifact_size);
    try std.testing.expect(!try db.complete(io, id, "other.zip", 1, token, 200, 106));
}
