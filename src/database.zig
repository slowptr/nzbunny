const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

const job_fields = "status,download_path,artifact_path,artifact_size,download_token,fail_reason,created_at,updated_at,expires_at,finalize_attempts,finalize_next_at,finalize_lease_until,finalize_lease_token FROM jobs";
const job_projection = "SELECT id,filename,NULL," ++ job_fields;

pub const Status = enum {
    pending,
    processing,
    finalizing,
    complete,
    failed,
    expired,

    pub fn publicName(self: Status) []const u8 {
        return switch (self) {
            .pending => "PENDING",
            .processing, .finalizing => "PROCESSING",
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
    download_path: []const u8,
    artifact_path: []const u8,
    artifact_size: u64,
    download_token: []const u8,
    fail_reason: []const u8,
    created_at: i64,
    updated_at: i64,
    expires_at: ?i64,
    finalize_attempts: u32 = 0,
    finalize_next_at: ?i64 = null,
    finalize_lease_until: ?i64 = null,
    finalize_lease_token: []const u8 = "",

    pub fn deinit(self: Job, allocator: std.mem.Allocator) void {
        freeText(allocator, self.id);
        freeText(allocator, self.filename);
        freeText(allocator, self.content);
        freeText(allocator, self.download_path);
        freeText(allocator, self.artifact_path);
        freeText(allocator, self.download_token);
        freeText(allocator, self.fail_reason);
        freeText(allocator, self.finalize_lease_token);
    }
};

pub const Database = struct {
    handle: *c.sqlite3,
    allocator: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const zpath = try allocator.dupeZ(u8, path);
        defer allocator.free(zpath);
        // A read-write SQLite connection can checkpoint WAL on close even if
        // no DDL ran. Inspect existing metadata through a read-only connection
        // first so rejected versions cannot change the main database at all.
        if (!std.mem.eql(u8, path, ":memory:")) try preflightSchema(zpath);
        const db = try openHandle(zpath);
        errdefer _ = c.sqlite3_close(db);
        try initialize(db);
        return .{ .handle = db, .allocator = allocator };
    }

    pub fn close(self: *Database) void {
        _ = c.sqlite3_close(self.handle);
    }

    pub fn maintain(self: *Database, io: std.Io) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try exec(self.handle,
            \\PRAGMA wal_checkpoint(PASSIVE);
            \\PRAGMA incremental_vacuum(256);
            \\PRAGMA optimize;
        );
    }

    pub fn ready(self: *Database, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, "SELECT id FROM jobs LIMIT 1", -1, &stmt, null) != c.SQLITE_OK) return false;
        defer _ = c.sqlite3_finalize(stmt);
        const result = c.sqlite3_step(stmt);
        return result == c.SQLITE_ROW or result == c.SQLITE_DONE;
    }

    pub fn hasCapacity(self: *Database, io: std.Io, max_active: u32) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return (try activeCount(self.handle)) < max_active;
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
        const db = self.handle;
        try exec(db, "BEGIN IMMEDIATE;");
        errdefer exec(db, "ROLLBACK;") catch |err|
            std.log.err("SQLite admission rollback failed: {t}", .{err});
        if (try activeCount(db) >= max_active) {
            try exec(db, "COMMIT;");
            return null;
        }
        const id = try self.insertJob(db, io, filename, content, now);
        errdefer self.allocator.free(id);
        try exec(db, "COMMIT;");
        return id;
    }

    fn insertJob(
        self: *Database,
        db: *c.sqlite3,
        io: std.Io,
        filename: []const u8,
        content: []const u8,
        now: i64,
    ) ![]const u8 {
        var random: [16]u8 = undefined;
        io.random(&random);
        const id = try self.allocator.alloc(u8, 32);
        errdefer self.allocator.free(id);
        _ = std.fmt.bufPrint(id, "{x}", .{random}) catch unreachable;
        const stmt = try prepare(db,
            \\INSERT INTO jobs
            \\(id, filename, content, status, created_at, updated_at)
            \\VALUES (?1, ?2, ?3, 'PENDING', ?4, ?4)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindText(stmt, 2, filename);
        const blob_ptr: ?*const anyopaque = if (content.len == 0) "" else content.ptr;
        if (c.sqlite3_bind_blob64(stmt, 3, blob_ptr, content.len, null) != c.SQLITE_OK)
            return error.DatabaseBindFailed;
        try bindInt64(stmt, 4, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return id;
    }

    pub fn get(self: *Database, io: std.Io, id: []const u8) !?Job {
        return self.getWith(io, "id", id, false);
    }

    pub fn getWithContent(self: *Database, io: std.Io, id: []const u8) !?Job {
        return self.getWith(io, "id", id, true);
    }

    pub fn getByToken(self: *Database, io: std.Io, token: []const u8) !?Job {
        return self.getWith(io, "download_token", token, false);
    }

    pub fn listWork(self: *Database, io: std.Io) ![]Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, job_projection ++ " " ++
            "WHERE status IN ('PENDING','PROCESSING','FINALIZING') ORDER BY created_at,rowid");
        defer _ = c.sqlite3_finalize(stmt);
        var result: std.ArrayList(Job) = .empty;
        errdefer {
            for (result.items) |job| job.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                const job = try scan(self.allocator, stmt);
                errdefer job.deinit(self.allocator);
                try result.append(self.allocator, job);
            },
            c.SQLITE_DONE => return result.toOwnedSlice(self.allocator),
            else => return databaseError(self.handle),
        };
    }

    pub fn listCleanup(
        self: *Database,
        io: std.Io,
        now: i64,
        failed_before: i64,
        expired_before: i64,
    ) ![]Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, job_projection ++ " " ++
            "WHERE (status='COMPLETE' AND expires_at<=?1) OR " ++
            "(status='FAILED' AND updated_at<=?2) OR " ++
            "(status='EXPIRED' AND updated_at<=?3)");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now);
        try bindInt64(stmt, 2, failed_before);
        try bindInt64(stmt, 3, expired_before);
        var result: std.ArrayList(Job) = .empty;
        errdefer {
            for (result.items) |job| job.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                const job = try scan(self.allocator, stmt);
                errdefer job.deinit(self.allocator);
                try result.append(self.allocator, job);
            },
            c.SQLITE_DONE => return result.toOwnedSlice(self.allocator),
            else => return databaseError(self.handle),
        };
    }

    fn getWith(
        self: *Database,
        io: std.Io,
        comptime field: []const u8,
        value: []const u8,
        comptime include_content: bool,
    ) !?Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const content = if (include_content) "content" else "NULL";
        const stmt = try prepare(self.handle, "SELECT id,filename," ++ content ++ "," ++ job_fields ++ " WHERE " ++ field ++ "=?1");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, value);
        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_DONE) return null;
        if (result != c.SQLITE_ROW) return databaseError(self.handle);
        return try scan(self.allocator, stmt);
    }

    pub fn beginProcessing(self: *Database, io: std.Io, id: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='PROCESSING',updated_at=?1 WHERE id=?2 AND status='PENDING'");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now);
        try bindText(stmt, 2, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn beginFinalizing(self: *Database, io: std.Io, id: []const u8, download_path: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='FINALIZING',content=NULL,download_path=?1,updated_at=?2 WHERE id=?3 AND status='PROCESSING'");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, download_path);
        try bindInt64(stmt, 2, now);
        try bindText(stmt, 3, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn tryClaimFinalizing(
        self: *Database,
        io: std.Io,
        id: []const u8,
        now: i64,
        lease_duration: i64,
    ) !?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var token_buf: [32]u8 = undefined;
        var random: [16]u8 = undefined;
        io.random(&random);
        _ = std.fmt.bufPrint(&token_buf, "{x}", .{random}) catch unreachable;
        const lease_until = std.math.add(i64, now, lease_duration) catch return error.InvalidLeaseDuration;
        // All fallible allocations precede the persistent ownership transfer.
        const owned_token = try self.allocator.dupe(u8, &token_buf);
        errdefer self.allocator.free(owned_token);
        const stmt = try prepare(self.handle,
            \\UPDATE jobs SET finalize_attempts=finalize_attempts+1,
            \\finalize_lease_until=?1, finalize_lease_token=?2,
            \\finalize_next_at=NULL, updated_at=?3
            \\WHERE id=?4 AND status='FINALIZING'
            \\AND (finalize_lease_until IS NULL OR finalize_lease_until <= ?3)
            \\AND (finalize_next_at IS NULL OR finalize_next_at <= ?3)
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, lease_until);
        try bindText(stmt, 2, token_buf[0..]);
        try bindInt64(stmt, 3, now);
        try bindText(stmt, 4, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        if (c.sqlite3_changes(self.handle) == 0) {
            self.allocator.free(owned_token);
            return null;
        }
        return owned_token;
    }

    pub fn releaseFinalizing(self: *Database, io: std.Io, id: []const u8, token: []const u8, retry_after: i64, now: i64, refund_attempt: bool) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle,
            \\UPDATE jobs SET finalize_lease_until=NULL, finalize_lease_token=NULL,
            \\finalize_next_at=?1, updated_at=?2, finalize_attempts=max(0,finalize_attempts-?5)
            \\WHERE id=?3 AND status='FINALIZING' AND finalize_lease_token=?4
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, retry_after);
        try bindInt64(stmt, 2, now);
        try bindText(stmt, 3, id);
        try bindText(stmt, 4, token);
        try bindInt64(stmt, 5, @intFromBool(refund_attempt));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
    }

    pub fn renewLease(self: *Database, io: std.Io, id: []const u8, token: []const u8, new_lease_until: i64, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle,
            \\UPDATE jobs SET finalize_lease_until=?1, updated_at=?2
            \\WHERE id=?3 AND status='FINALIZING' AND finalize_lease_token=?4
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, new_lease_until);
        try bindInt64(stmt, 2, now);
        try bindText(stmt, 3, id);
        try bindText(stmt, 4, token);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn completeWithToken(
        self: *Database,
        io: std.Io,
        id: []const u8,
        lease_token: []const u8,
        artifact_path: []const u8,
        size: u64,
        download_token: []const u8,
        expires: i64,
        now: i64,
    ) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='COMPLETE',artifact_path=?1,artifact_size=?2,download_token=?3," ++
            "expires_at=?4,updated_at=?5,finalize_lease_until=NULL,finalize_lease_token=NULL " ++
            "WHERE id=?6 AND status='FINALIZING' AND finalize_lease_token=?7");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, artifact_path);
        try bindInt64(stmt, 2, @intCast(size));
        try bindText(stmt, 3, download_token);
        try bindInt64(stmt, 4, expires);
        try bindInt64(stmt, 5, now);
        try bindText(stmt, 6, id);
        try bindText(stmt, 7, lease_token);
        const result = c.sqlite3_step(stmt);
        if (result == c.SQLITE_CONSTRAINT and c.sqlite3_extended_errcode(self.handle) == c.SQLITE_CONSTRAINT_UNIQUE) return error.DuplicateToken;
        if (result != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn failFinalizing(self: *Database, io: std.Io, id: []const u8, lease_token: []const u8, reason: []const u8, now: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle,
            \\UPDATE jobs SET status='FAILED',fail_reason=?1,content=NULL,
            \\finalize_lease_until=NULL,finalize_lease_token=NULL,updated_at=?2
            \\WHERE id=?3 AND status='FINALIZING' AND finalize_lease_token=?4
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, reason);
        try bindInt64(stmt, 2, now);
        try bindText(stmt, 3, id);
        try bindText(stmt, 4, lease_token);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
    }

    pub fn reclaimAllFinalizingLeases(self: *Database, io: std.Io, now: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle,
            \\UPDATE jobs SET finalize_lease_until=NULL, finalize_lease_token=NULL, updated_at=?1, finalize_attempts=max(0,finalize_attempts-1)
            \\WHERE status='FINALIZING' AND finalize_lease_until IS NOT NULL
        );
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
    }

    pub fn fail(self: *Database, io: std.Io, id: []const u8, expected: Status, reason: []const u8, now: i64) !bool {
        if (expected != .pending and expected != .processing) return error.InvalidFailureTransition;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='FAILED',fail_reason=?1,content=NULL,updated_at=?2 WHERE id=?3 AND status=?4");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, reason);
        try bindInt64(stmt, 2, now);
        try bindText(stmt, 3, id);
        try bindText(stmt, 4, statusName(expected));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn retryProcessing(self: *Database, io: std.Io, id: []const u8, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='PENDING',updated_at=?1 WHERE id=?2 AND status='PROCESSING' AND content IS NOT NULL");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now);
        try bindText(stmt, 2, id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub const QueueSnapshot = struct { pending: i64, processing: i64, finalizing: i64, oldest_pending: ?i64 };

    pub fn queueSnapshot(self: *Database, io: std.Io) !QueueSnapshot {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "SELECT coalesce(sum(status='PENDING'),0),coalesce(sum(status='PROCESSING'),0)," ++
            "coalesce(sum(status='FINALIZING'),0),min(CASE WHEN status='PENDING' THEN created_at END) FROM jobs");
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return databaseError(self.handle);
        return .{
            .pending = c.sqlite3_column_int64(stmt, 0),
            .processing = c.sqlite3_column_int64(stmt, 1),
            .finalizing = c.sqlite3_column_int64(stmt, 2),
            .oldest_pending = if (c.sqlite3_column_type(stmt, 3) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 3),
        };
    }

    pub fn failProcessingOnStartup(self: *Database, io: std.Io, now: i64) ![]Job {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const db = self.handle;
        try exec(db, "BEGIN IMMEDIATE;");
        errdefer exec(db, "ROLLBACK;") catch |err|
            std.log.err("SQLite startup rollback failed: {t}", .{err});
        const select = try prepare(db, job_projection ++ " WHERE status='PROCESSING'");
        defer _ = c.sqlite3_finalize(select);
        var result: std.ArrayList(Job) = .empty;
        errdefer {
            for (result.items) |job| job.deinit(self.allocator);
            result.deinit(self.allocator);
        }
        while (true) switch (c.sqlite3_step(select)) {
            c.SQLITE_ROW => {
                const job = try scan(self.allocator, select);
                errdefer job.deinit(self.allocator);
                try result.append(self.allocator, job);
            },
            c.SQLITE_DONE => break,
            else => return databaseError(self.handle),
        };
        const update = try prepare(db, "UPDATE jobs SET status='FAILED',content=NULL,fail_reason='Download was interrupted; upload the NZB again.',updated_at=?1 WHERE status='PROCESSING'");
        defer _ = c.sqlite3_finalize(update);
        try bindInt64(update, 1, now);
        if (c.sqlite3_step(update) != c.SQLITE_DONE) return databaseError(self.handle);
        try exec(db, "COMMIT;");
        return result.toOwnedSlice(self.allocator);
    }

    pub fn markExpired(self: *Database, io: std.Io, id: []const u8, expected: Status, now: i64) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "UPDATE jobs SET status='EXPIRED',content=NULL,download_path=NULL,artifact_path=NULL," ++
            "artifact_size=0,fail_reason='The download expired.',updated_at=?1 WHERE id=?2 AND status=?3");
        defer _ = c.sqlite3_finalize(stmt);
        try bindInt64(stmt, 1, now);
        try bindText(stmt, 2, id);
        try bindText(stmt, 3, statusName(expected));
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
        return c.sqlite3_changes(self.handle) == 1;
    }

    pub fn purgeFailed(self: *Database, io: std.Io, id: []const u8, before: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "DELETE FROM jobs WHERE id=?1 AND status='FAILED' AND updated_at<=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindInt64(stmt, 2, before);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
    }

    pub fn purgeExpired(self: *Database, io: std.Io, id: []const u8, before: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const stmt = try prepare(self.handle, "DELETE FROM jobs WHERE id=?1 AND status='EXPIRED' AND updated_at<=?2");
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, id);
        try bindInt64(stmt, 2, before);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return databaseError(self.handle);
    }
};

fn openHandle(path: [:0]const u8) !*c.sqlite3 {
    var handle: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX;
    if (c.sqlite3_open_v2(path.ptr, &handle, flags, null) != c.SQLITE_OK) {
        if (handle) |db| _ = c.sqlite3_close(db);
        return error.DatabaseOpenFailed;
    }
    const db = handle.?;
    errdefer _ = c.sqlite3_close(db);
    try exec(db,
        \\PRAGMA synchronous=FULL;
        \\PRAGMA foreign_keys=ON;
        \\PRAGMA trusted_schema=OFF;
        \\PRAGMA busy_timeout=5000;
        \\PRAGMA wal_autocheckpoint=256;
        \\PRAGMA journal_size_limit=16777216;
    );
    return db;
}

fn activeCount(db: *c.sqlite3) !i64 {
    const stmt = try prepare(db, "SELECT count(*) FROM jobs WHERE status IN ('PENDING','PROCESSING','FINALIZING')");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.DatabaseReadFailed;
    return c.sqlite3_column_int64(stmt, 0);
}

fn preflightSchema(path: [:0]const u8) !void {
    var handle: ?*c.sqlite3 = null;
    const result = c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null);
    defer if (handle) |db| {
        _ = c.sqlite3_close(db);
    };
    if (result == c.SQLITE_CANTOPEN) return; // normal open reports errors or creates a missing file
    if (result != c.SQLITE_OK) return error.DatabaseOpenFailed;
    try exec(handle.?, "PRAGMA trusted_schema=OFF;");
    _ = try schemaVersion(handle.?);
}

fn schemaVersion(db: *c.sqlite3) !?i64 {
    const has_jobs = try tableExists(db, "jobs");
    const has_meta = try tableExists(db, "nzbunny_schema");
    if (has_jobs and !has_meta) return error.LegacyGoSchemaDetected;
    if (!has_meta) return null;
    if (!has_jobs) return error.UnsupportedSchemaVersion;
    const stmt = try prepare(db, "SELECT version FROM nzbunny_schema");
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt) != c.SQLITE_ROW or c.sqlite3_column_type(stmt, 0) != c.SQLITE_INTEGER)
        return error.UnsupportedSchemaVersion;
    const version = c.sqlite3_column_int64(stmt, 0);
    if (version < 1 or version > 3 or c.sqlite3_step(stmt) != c.SQLITE_DONE)
        return error.UnsupportedSchemaVersion;
    return version;
}

fn initialize(db: *c.sqlite3) !void {
    if (try schemaVersion(db)) |version| {
        if (version == 1) try migrateV1ToV2(db);
        if (version <= 2) try migrateV2ToV3(db);
        try exec(db, "PRAGMA journal_mode=WAL;");
        return;
    }
    try exec(db, "PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=WAL;");
    try exec(db,
        \\BEGIN IMMEDIATE;
        \\CREATE TABLE IF NOT EXISTS nzbunny_schema (
        \\  version INTEGER NOT NULL
        \\);
        \\INSERT INTO nzbunny_schema(version)
        \\SELECT 3 WHERE NOT EXISTS (SELECT 1 FROM nzbunny_schema);
        \\CREATE TABLE IF NOT EXISTS jobs (
        \\  id TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  content BLOB,
        \\  status TEXT NOT NULL CHECK(status IN ('PENDING','PROCESSING','FINALIZING','COMPLETE','FAILED','EXPIRED')),
        \\  download_path TEXT,
        \\  artifact_path TEXT,
        \\  artifact_size INTEGER NOT NULL DEFAULT 0 CHECK(artifact_size>=0),
        \\  download_token TEXT UNIQUE,
        \\  fail_reason TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  expires_at INTEGER,
        \\  finalize_attempts INTEGER NOT NULL DEFAULT 0,
        \\  finalize_next_at INTEGER,
        \\  finalize_lease_until INTEGER,
        \\  finalize_lease_token TEXT
        \\);
        \\CREATE INDEX IF NOT EXISTS jobs_status_idx ON jobs(status);
        \\CREATE INDEX IF NOT EXISTS jobs_status_created_idx ON jobs(status, created_at);
        \\CREATE INDEX IF NOT EXISTS jobs_status_updated_idx ON jobs(status, updated_at);
        \\CREATE INDEX IF NOT EXISTS jobs_expiry_idx ON jobs(expires_at);
        \\COMMIT;
    );
}

fn migrateV1ToV2(db: *c.sqlite3) !void {
    try exec(db,
        \\BEGIN IMMEDIATE;
        \\ALTER TABLE jobs RENAME TO jobs_v1;
        \\CREATE TABLE jobs (
        \\  id TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  content BLOB,
        \\  status TEXT NOT NULL CHECK(status IN ('PENDING','PROCESSING','FINALIZING','COMPLETE','FAILED','EXPIRED')),
        \\  download_path TEXT,
        \\  artifact_path TEXT,
        \\  artifact_size INTEGER NOT NULL DEFAULT 0 CHECK(artifact_size>=0),
        \\  download_token TEXT UNIQUE,
        \\  fail_reason TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  expires_at INTEGER
        \\);
        \\INSERT INTO jobs(id,filename,content,status,download_path,artifact_path,artifact_size,download_token,fail_reason,created_at,updated_at,expires_at)
        \\SELECT id,filename,content,status,download_path,artifact_path,artifact_size,download_token,fail_reason,created_at,updated_at,expires_at
        \\FROM jobs_v1 WHERE status IN ('PENDING','FINALIZING','COMPLETE','FAILED','EXPIRED');
        \\INSERT INTO jobs(id,filename,content,status,download_path,artifact_path,artifact_size,download_token,fail_reason,created_at,updated_at,expires_at)
        \\SELECT id,filename,NULL,'FAILED',NULL,artifact_path,artifact_size,download_token,
        \\  'Download was interrupted by the downloader upgrade; upload the NZB again.',
        \\  created_at,updated_at,expires_at
        \\FROM jobs_v1 WHERE status IN ('SUBMITTING','PROCESSING');
        \\DROP TABLE jobs_v1;
        \\DELETE FROM nzbunny_schema;
        \\INSERT INTO nzbunny_schema(version) VALUES (2);
        \\CREATE INDEX IF NOT EXISTS jobs_status_idx ON jobs(status);
        \\CREATE INDEX IF NOT EXISTS jobs_status_created_idx ON jobs(status, created_at);
        \\CREATE INDEX IF NOT EXISTS jobs_status_updated_idx ON jobs(status, updated_at);
        \\CREATE INDEX IF NOT EXISTS jobs_expiry_idx ON jobs(expires_at);
        \\COMMIT;
    );
}

fn migrateV2ToV3(db: *c.sqlite3) !void {
    try exec(db,
        \\BEGIN IMMEDIATE;
        \\ALTER TABLE jobs ADD COLUMN finalize_attempts INTEGER NOT NULL DEFAULT 0;
        \\ALTER TABLE jobs ADD COLUMN finalize_next_at INTEGER;
        \\ALTER TABLE jobs ADD COLUMN finalize_lease_until INTEGER;
        \\ALTER TABLE jobs ADD COLUMN finalize_lease_token TEXT;
        \\CREATE INDEX IF NOT EXISTS jobs_status_created_idx ON jobs(status, created_at);
        \\CREATE INDEX IF NOT EXISTS jobs_status_updated_idx ON jobs(status, updated_at);
        \\UPDATE nzbunny_schema SET version = 3;
        \\COMMIT;
    );
}

fn tableExists(db: *c.sqlite3, name: []const u8) !bool {
    const stmt = try prepare(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1");
    defer _ = c.sqlite3_finalize(stmt);
    try bindText(stmt, 1, name);
    return switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => true,
        c.SQLITE_DONE => false,
        else => error.DatabaseReadFailed,
    };
}

fn prepare(db: *c.sqlite3, sql: [*:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &stmt, null) != c.SQLITE_OK) return databaseError(db);
    return stmt.?;
}

fn exec(db: *c.sqlite3, sql: [*:0]const u8) !void {
    var message: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql, null, null, &message) != c.SQLITE_OK) {
        if (message != null) {
            std.log.err("SQLite exec failed: {s}", .{std.mem.span(message)});
            c.sqlite3_free(message);
        }
        return databaseError(db);
    }
}

fn bindText(stmt: *c.sqlite3_stmt, index: c_int, value: []const u8) !void {
    const ptr: [*c]const u8 = if (value.len == 0) "" else value.ptr;
    if (c.sqlite3_bind_text(stmt, index, ptr, @intCast(value.len), null) != c.SQLITE_OK)
        return error.DatabaseBindFailed;
}

fn bindInt64(stmt: *c.sqlite3_stmt, index: c_int, value: i64) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != c.SQLITE_OK)
        return error.DatabaseBindFailed;
}

fn text(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, column: c_int) ![]const u8 {
    const ptr = c.sqlite3_column_text(stmt, column) orelse return "";
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, column));
    return allocator.dupe(u8, ptr[0..len]);
}

fn scan(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !Job {
    const status = parseStatus(borrowedText(stmt, 3)) orelse return error.InvalidStoredStatus;
    const artifact_size = c.sqlite3_column_int64(stmt, 6);
    if (artifact_size < 0) return error.InvalidStoredArtifactSize;
    const finalize_attempts = std.math.cast(u32, c.sqlite3_column_int64(stmt, 12)) orelse return error.InvalidStoredStatus;
    var job: Job = .{
        .id = "",
        .filename = "",
        .content = "",
        .status = status,
        .download_path = "",
        .artifact_path = "",
        .artifact_size = @intCast(artifact_size),
        .download_token = "",
        .fail_reason = "",
        .created_at = c.sqlite3_column_int64(stmt, 9),
        .updated_at = c.sqlite3_column_int64(stmt, 10),
        .expires_at = if (c.sqlite3_column_type(stmt, 11) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 11),
        .finalize_attempts = finalize_attempts,
        .finalize_next_at = if (c.sqlite3_column_type(stmt, 13) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 13),
        .finalize_lease_until = if (c.sqlite3_column_type(stmt, 14) == c.SQLITE_NULL) null else c.sqlite3_column_int64(stmt, 14),
        .finalize_lease_token = "",
    };
    errdefer job.deinit(allocator);
    job.id = try text(allocator, stmt, 0);
    job.filename = try text(allocator, stmt, 1);
    job.content = blk: {
        const ptr = c.sqlite3_column_blob(stmt, 2) orelse break :blk "";
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
        break :blk try allocator.dupe(u8, @as([*]const u8, @ptrCast(ptr))[0..len]);
    };
    job.download_path = try text(allocator, stmt, 4);
    job.artifact_path = try text(allocator, stmt, 5);
    job.download_token = try text(allocator, stmt, 7);
    job.fail_reason = try text(allocator, stmt, 8);
    job.finalize_lease_token = try text(allocator, stmt, 15);
    return job;
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
        .processing => "PROCESSING",
        .finalizing => "FINALIZING",
        .complete => "COMPLETE",
        .failed => "FAILED",
        .expired => "EXPIRED",
    };
}

test "internal states map to public processing" {
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
    try std.testing.expect(try db.hasCapacity(io, 1));
    const id = (try db.createIfCapacity(io, "sample.nzb", "<nzb/>", 100, 1)).?;
    try std.testing.expect(!try db.hasCapacity(io, 1));
    const pending = (try db.get(io, id)).?;
    try std.testing.expectEqual(Status.pending, pending.status);
    try std.testing.expectEqual(@as(usize, 0), pending.content.len);
    const pending_with_content = (try db.getWithContent(io, id)).?;
    try std.testing.expectEqualStrings("<nzb/>", pending_with_content.content);
    try std.testing.expect((try db.createIfCapacity(io, "second.nzb", "<nzb/>", 100, 1)) == null);
    try std.testing.expect(try db.beginProcessing(io, id, 101));
    try std.testing.expect(!try db.beginProcessing(io, id, 102));
    try std.testing.expect(try db.beginFinalizing(io, id, "output", 104));
    _ = (try db.tryClaimFinalizing(io, id, 104, 60)).?;
    try std.testing.expect((try db.tryClaimFinalizing(io, id, 105, 60)) == null);
    try db.reclaimAllFinalizingLeases(io, 105);
    const lease_token = (try db.tryClaimFinalizing(io, id, 105, 60)).?;
    const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(try db.completeWithToken(io, id, lease_token, "artifact.zip", 42, token, 200, 105));
    const complete_job = (try db.getByToken(io, token)).?;
    try std.testing.expectEqual(Status.complete, complete_job.status);
    try std.testing.expectEqual(@as(u64, 42), complete_job.artifact_size);
    try std.testing.expect(!try db.completeWithToken(io, id, lease_token, "other.zip", 1, token, 200, 106));
}

test "schema version 1 migration converts in-flight jobs and preserves completed jobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const db_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/v1.db", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(db_path);

    const zpath = try std.heap.page_allocator.dupeZ(u8, db_path);
    defer std.heap.page_allocator.free(zpath);
    var handle: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(zpath.ptr, &handle, flags, null));
    const raw_db = handle.?;
    defer _ = c.sqlite3_close(raw_db);

    try exec(raw_db,
        \\CREATE TABLE nzbunny_schema (version INTEGER NOT NULL);
        \\INSERT INTO nzbunny_schema VALUES (1);
        \\CREATE TABLE jobs (
        \\  id TEXT PRIMARY KEY,
        \\  filename TEXT NOT NULL,
        \\  content BLOB,
        \\  status TEXT NOT NULL,
        \\  download_path TEXT,
        \\  artifact_path TEXT,
        \\  artifact_size INTEGER NOT NULL DEFAULT 0,
        \\  download_token TEXT UNIQUE,
        \\  fail_reason TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  expires_at INTEGER,
        \\  sab_name TEXT,
        \\  nzo_id TEXT
        \\);
        \\INSERT INTO jobs VALUES ('j1', 'a.nzb', 'data', 'PENDING', NULL, NULL, 0, NULL, NULL, 100, 100, NULL, 'sab1', 'nzo1');
        \\INSERT INTO jobs VALUES ('j2', 'b.nzb', NULL, 'PROCESSING', 'dl2', NULL, 0, NULL, NULL, 100, 100, NULL, 'sab2', 'nzo2');
        \\INSERT INTO jobs VALUES ('j3', 'c.nzb', NULL, 'SUBMITTING', NULL, NULL, 0, NULL, NULL, 100, 100, NULL, 'sab3', 'nzo3');
        \\INSERT INTO jobs VALUES ('j4', 'd.nzb', NULL, 'COMPLETE', 'dl4', 'art4.zip', 10, 'tok4', NULL, 100, 100, 500, 'sab4', 'nzo4');
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var db = try Database.open(arena.allocator(), db_path);
    defer db.close();
    const io = std.testing.io;

    const j1 = (try db.get(io, "j1")).?;
    try std.testing.expectEqual(Status.pending, j1.status);

    const j2 = (try db.get(io, "j2")).?;
    try std.testing.expectEqual(Status.failed, j2.status);
    try std.testing.expectEqualStrings("Download was interrupted by the downloader upgrade; upload the NZB again.", j2.fail_reason);

    const j3 = (try db.get(io, "j3")).?;
    try std.testing.expectEqual(Status.failed, j3.status);

    const j4 = (try db.getByToken(io, "tok4")).?;
    try std.testing.expectEqual(Status.complete, j4.status);
    try std.testing.expectEqualStrings("art4.zip", j4.artifact_path);
}

fn databaseError(db: *c.sqlite3) anyerror {
    const code = c.sqlite3_errcode(db);
    std.log.err("SQLite operation failed (code {d}, extended {d}): {s}", .{ code, c.sqlite3_extended_errcode(db), std.mem.span(c.sqlite3_errmsg(db)) });
    return switch (code) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_FULL => error.DatabaseFull,
        c.SQLITE_READONLY => error.DatabaseReadOnly,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => error.DatabaseCorrupt,
        c.SQLITE_CONSTRAINT => error.DatabaseConstraint,
        c.SQLITE_IOERR => error.DatabaseIOFailed,
        c.SQLITE_NOMEM => error.OutOfMemory,
        else => error.DatabaseOperationFailed,
    };
}

test "listing work releases scanned jobs when allocation fails" {
    const io = std.testing.io;
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const id = (try db.createIfCapacity(io, "allocation.nzb", "<nzb/>", 1, 2)).?;
    defer std.testing.allocator.free(id);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, listWorkWithAllocator, .{ &db, io });
}

fn listWorkWithAllocator(allocator: std.mem.Allocator, db: *Database, io: std.Io) !void {
    const original = db.allocator;
    db.allocator = allocator;
    defer db.allocator = original;
    const jobs = try db.listWork(io);
    defer allocator.free(jobs);
    defer for (jobs) |job| job.deinit(allocator);
}

test "stale transitions cannot change a newer owner's job" {
    const io = std.testing.io;
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const id = (try db.createIfCapacity(io, "state.nzb", "<nzb/>", 1, 1)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expect(try db.beginProcessing(io, id, 2));
    try std.testing.expect(!try db.fail(io, id, .pending, "stale parser", 3));
    try std.testing.expect(try db.retryProcessing(io, id, 3));
    const retry = (try db.getWithContent(io, id)).?;
    defer retry.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<nzb/>", retry.content);
    try std.testing.expect(try db.beginProcessing(io, id, 4));
    try std.testing.expect(try db.beginFinalizing(io, id, "source", 5));
    try std.testing.expect(!try db.retryProcessing(io, id, 6));
    try std.testing.expect(!try db.fail(io, id, .processing, "stale downloader", 6));
    try std.testing.expectError(error.InvalidFailureTransition, db.fail(io, id, .finalizing, "no token", 6));
    const old = (try db.tryClaimFinalizing(io, id, 6, 1)).?;
    defer std.testing.allocator.free(old);
    const current = (try db.tryClaimFinalizing(io, id, 8, 60)).?;
    defer std.testing.allocator.free(current);
    try std.testing.expect(!try db.renewLease(io, id, old, 100, 9));
    try std.testing.expect(!try db.completeWithToken(io, id, old, "wrong.bin", 1, "wrong", 100, 9));
    try db.releaseFinalizing(io, id, old, 10, 9, true);
    try db.failFinalizing(io, id, old, "stale finalizer", 9);
    const job = (try db.getWithContent(io, id)).?;
    defer job.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.finalizing, job.status);
    try std.testing.expectEqualStrings(current, job.finalize_lease_token);
    try std.testing.expectEqual(@as(u32, 2), job.finalize_attempts);
    try std.testing.expectEqual(@as(usize, 0), job.content.len);
    try std.testing.expect(try db.completeWithToken(io, id, current, "right.bin", 1, "right", 100, 9));
}

test "allocation failure cannot consume a finalizing lease or attempt" {
    const io = std.testing.io;
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const id = (try db.createIfCapacity(io, "allocation.nzb", "<nzb/>", 1, 1)).?;
    defer std.testing.allocator.free(id);
    try std.testing.expect(try db.beginProcessing(io, id, 2));
    try std.testing.expect(try db.beginFinalizing(io, id, "source", 3));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    db.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, db.tryClaimFinalizing(io, id, 4, 60));
    db.allocator = std.testing.allocator;
    const job = (try db.get(io, id)).?;
    defer job.deinit(std.testing.allocator);
    try std.testing.expect(job.finalize_lease_until == null);
    try std.testing.expectEqual(@as(u32, 0), job.finalize_attempts);
    const token = (try db.tryClaimFinalizing(io, id, 4, 60)).?;
    defer std.testing.allocator.free(token);
    try db.releaseFinalizing(io, id, token, 5, 4, true);
    const deferred = (try db.get(io, id)).?;
    defer deferred.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0), deferred.finalize_attempts);
    try std.testing.expect((try db.tryClaimFinalizing(io, id, 4, 60)) == null);
}

test "unsupported metadata is rejected before schema mutation" {
    for ([_][]const u8{ "99", "0", "3),(3" }) |version| {
        var db = try Database.open(std.testing.allocator, ":memory:");
        defer db.close();
        try exec(db.handle, "DROP INDEX jobs_expiry_idx; DELETE FROM nzbunny_schema;");
        const sql = try std.fmt.allocPrintSentinel(std.testing.allocator, "INSERT INTO nzbunny_schema VALUES ({s})", .{version}, 0);
        defer std.testing.allocator.free(sql);
        try exec(db.handle, sql);
        try std.testing.expectError(error.UnsupportedSchemaVersion, initialize(db.handle));
        const stmt = try prepare(db.handle, "SELECT count(*) FROM sqlite_master WHERE name='jobs_expiry_idx'");
        defer _ = c.sqlite3_finalize(stmt);
        try std.testing.expectEqual(c.SQLITE_ROW, c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
    }
}

test "queue snapshots and equal-second FIFO preserve insertion order" {
    const io = std.testing.io;
    var db = try Database.open(std.testing.allocator, ":memory:");
    defer db.close();
    const empty = try db.queueSnapshot(io);
    try std.testing.expectEqual(@as(i64, 0), empty.pending);
    try std.testing.expect(empty.oldest_pending == null);
    const first = (try db.createIfCapacity(io, "first.nzb", "<nzb/>", 100, 2)).?;
    defer std.testing.allocator.free(first);
    const second = (try db.createIfCapacity(io, "second.nzb", "<nzb/>", 100, 2)).?;
    defer std.testing.allocator.free(second);
    const jobs = try db.listWork(io);
    defer db.allocator.free(jobs);
    defer for (jobs) |job| job.deinit(db.allocator);
    try std.testing.expectEqualStrings(first, jobs[0].id);
    try std.testing.expectEqualStrings(second, jobs[1].id);
    try std.testing.expect(try db.beginProcessing(io, first, 101));
    const snapshot = try db.queueSnapshot(io);
    try std.testing.expectEqual(@as(i64, 1), snapshot.pending);
    try std.testing.expectEqual(@as(i64, 1), snapshot.processing);
    try std.testing.expectEqual(@as(i64, 0), snapshot.finalizing);
    try std.testing.expectEqual(@as(?i64, 100), snapshot.oldest_pending);
}
