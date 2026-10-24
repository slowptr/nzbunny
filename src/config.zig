const std = @import("std");

pub const Config = struct {
    nntp_host: []const u8,
    nntp_user: []const u8,
    nntp_pass: []const u8,
    nntp_ca_file: []const u8,
    download_dir: []const u8,
    db_path: []const u8,
    trusted_proxy_cidrs: []const u8,
    nntp_port: u16,
    nntp_connections: u32,
    port: u16,
    retention_seconds: i64,
    cleanup_seconds: u32,
    poll_seconds: u32,
    nntp_timeout_seconds: u32,
    download_timeout_seconds: u32,
    http_header_seconds: u32,
    http_request_seconds: u32,
    shutdown_seconds: u32,
    max_artifact_bytes: u64,
    max_upload_bytes: u64,
    max_work_bytes: u64,
    max_storage_bytes: u64,
    min_free_bytes: u64,
    max_upload_memory_bytes: u64,
    max_active_jobs: u32,
    max_connections: u32,
    uploads_per_minute: u32,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        allocator.free(self.nntp_host);
        allocator.free(self.nntp_user);
        allocator.free(self.nntp_pass);
        allocator.free(self.nntp_ca_file);
        allocator.free(self.download_dir);
        allocator.free(self.db_path);
        allocator.free(self.trusted_proxy_cidrs);
    }
};

const Defaults = struct {
    const db_path = "nzbunny.db";
    const trusted_proxy_cidrs = "";
    const nntp_port = "563";
    const nntp_connections = "4";
    const nntp_timeout = "30s";
    const download_timeout = "2h";
    const port = "1337";
    const retention_ttl = "15m";
    const cleanup_interval = "30s";
    const poll_interval = "10s";
    const http_header_timeout = "15s";
    const http_request_timeout = "5m";
    const shutdown_timeout = "5s";
    const max_artifact_bytes = "209715200";
    const max_upload_bytes = "2097152";
    const max_work_bytes = "1073741824";
    const max_storage_bytes = "4294967296";
    const min_free_bytes = "67108864";
    const max_upload_memory_bytes = "67108864";
    const max_active_jobs = "32";
    const max_connections = "128";
    const uploads_per_minute = "20";
};

pub const max_nntp_connections = 16;
const max_upload_bytes = 64 * 1024 * 1024;
const max_retention_seconds = 365 * 86400;

pub fn load(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !Config {
    var env = try environ.createMap(allocator);
    defer env.deinit();
    loadDotEnv(allocator, io, &env) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return loadFromMap(allocator, &env);
}

fn loadFromMap(allocator: std.mem.Allocator, env: *const std.process.Environ.Map) !Config {
    const nntp_host = value(env, "NNTP_HOST", "");
    const nntp_user = value(env, "NNTP_USER", "");
    const nntp_pass = value(env, "NNTP_PASS", "");
    const nntp_ca_file = value(env, "NNTP_CA_FILE", "");
    const download_dir = value(env, "DOWNLOAD_DIR", "");
    if (nntp_host.len == 0) return error.MissingNntpHost;
    if (nntp_user.len == 0) return error.MissingNntpUser;
    if (nntp_pass.len == 0) return error.MissingNntpPassword;
    if (download_dir.len == 0) return error.MissingDownloadDirectory;
    try validateNntpValue(nntp_host);
    try validateNntpValue(nntp_user);
    try validateNntpValue(nntp_pass);
    try validateNntpValue(nntp_ca_file);

    const trusted_proxy_cidrs = value(env, "TRUSTED_PROXY_CIDRS", Defaults.trusted_proxy_cidrs);
    try validateCidrs(trusted_proxy_cidrs);
    const nntp_connections = try positiveInt(u32, value(env, "NNTP_CONNECTIONS", Defaults.nntp_connections));
    if (nntp_connections > max_nntp_connections) return error.InvalidNntpConnections;
    const nntp_port = try positiveInt(u16, value(env, "NNTP_PORT", Defaults.nntp_port));
    const port = try positiveInt(u16, value(env, "PORT", Defaults.port));
    const retention_seconds = try retentionDuration(value(env, "RETENTION_TTL", Defaults.retention_ttl));
    const cleanup_seconds = try shortDuration(value(env, "CLEANUP_INTERVAL", Defaults.cleanup_interval));
    const poll_seconds = try shortDuration(value(env, "POLL_INTERVAL", Defaults.poll_interval));
    const nntp_timeout_seconds = try shortDuration(value(env, "NNTP_TIMEOUT", Defaults.nntp_timeout));
    const download_timeout_seconds = try shortDuration(value(env, "DOWNLOAD_TIMEOUT", Defaults.download_timeout));
    const http_header_seconds = try shortDuration(value(env, "HTTP_HEADER_TIMEOUT", Defaults.http_header_timeout));
    const http_request_seconds = try shortDuration(value(env, "HTTP_REQUEST_TIMEOUT", Defaults.http_request_timeout));
    const max_artifact_bytes_val = try positiveInt(u64, value(env, "MAX_ARTIFACT_BYTES", Defaults.max_artifact_bytes));
    const max_upload_bytes_val = try uploadBytes(value(env, "MAX_UPLOAD_BYTES", Defaults.max_upload_bytes));
    const max_active_jobs = try positiveInt(u32, value(env, "MAX_ACTIVE_JOBS", Defaults.max_active_jobs));
    const max_connections = try positiveInt(u32, value(env, "MAX_CONNECTIONS", Defaults.max_connections));
    const uploads_per_minute = try positiveInt(u32, value(env, "UPLOADS_PER_MINUTE", Defaults.uploads_per_minute));

    const owned_host = try allocator.dupe(u8, nntp_host);
    errdefer allocator.free(owned_host);
    const owned_user = try allocator.dupe(u8, nntp_user);
    errdefer allocator.free(owned_user);
    const owned_pass = try allocator.dupe(u8, nntp_pass);
    errdefer allocator.free(owned_pass);
    const owned_ca = try allocator.dupe(u8, nntp_ca_file);
    errdefer allocator.free(owned_ca);
    const owned_dir = try allocator.dupe(u8, download_dir);
    errdefer allocator.free(owned_dir);
    const owned_db = try allocator.dupe(u8, value(env, "DB_PATH", Defaults.db_path));
    errdefer allocator.free(owned_db);
    const owned_cidrs = try allocator.dupe(u8, trusted_proxy_cidrs);
    errdefer allocator.free(owned_cidrs);

    return .{
        .nntp_host = owned_host,
        .nntp_user = owned_user,
        .nntp_pass = owned_pass,
        .nntp_ca_file = owned_ca,
        .download_dir = owned_dir,
        .db_path = owned_db,
        .trusted_proxy_cidrs = owned_cidrs,
        .nntp_port = nntp_port,
        .nntp_connections = nntp_connections,
        .port = port,
        .retention_seconds = retention_seconds,
        .cleanup_seconds = cleanup_seconds,
        .poll_seconds = poll_seconds,
        .nntp_timeout_seconds = nntp_timeout_seconds,
        .download_timeout_seconds = download_timeout_seconds,
        .http_header_seconds = http_header_seconds,
        .http_request_seconds = http_request_seconds,
        .shutdown_seconds = try shortDuration(value(env, "SHUTDOWN_TIMEOUT", Defaults.shutdown_timeout)),
        .max_artifact_bytes = max_artifact_bytes_val,
        .max_upload_bytes = max_upload_bytes_val,
        .max_work_bytes = try positiveInt(u64, value(env, "MAX_WORK_BYTES", Defaults.max_work_bytes)),
        .max_storage_bytes = try positiveInt(u64, value(env, "MAX_STORAGE_BYTES", Defaults.max_storage_bytes)),
        .min_free_bytes = try positiveInt(u64, value(env, "MIN_FREE_BYTES", Defaults.min_free_bytes)),
        .max_upload_memory_bytes = try positiveInt(u64, value(env, "MAX_UPLOAD_MEMORY_BYTES", Defaults.max_upload_memory_bytes)),
        .max_active_jobs = max_active_jobs,
        .max_connections = max_connections,
        .uploads_per_minute = uploads_per_minute,
    };
}

fn validateNntpValue(text: []const u8) !void {
    for (text) |byte| {
        if (byte <= 0x20 or byte == 0x7f) return error.InvalidNntpConfigurationValue;
    }
}

pub const Cidr = struct {
    address: std.Io.net.IpAddress,
    prefix: u8,
};

pub fn parseCidr(raw: []const u8) !Cidr {
    const value_text_trimmed = std.mem.trim(u8, raw, " \t");
    if (value_text_trimmed.len == 0) return error.InvalidTrustedProxyCidr;
    const slash = std.mem.findScalar(u8, value_text_trimmed, '/') orelse return error.InvalidTrustedProxyCidr;
    const address = std.Io.net.IpAddress.parse(value_text_trimmed[0..slash], 0) catch
        return error.InvalidTrustedProxyCidr;
    const prefix = std.fmt.parseInt(u8, value_text_trimmed[slash + 1 ..], 10) catch
        return error.InvalidTrustedProxyCidr;
    switch (address) {
        .ip4 => if (prefix > 32) return error.InvalidTrustedProxyCidr,
        .ip6 => if (prefix > 128) return error.InvalidTrustedProxyCidr,
    }
    return .{ .address = address, .prefix = prefix };
}

fn validateCidrs(value_text: []const u8) !void {
    if (value_text.len == 0) return;
    var values = std.mem.splitScalar(u8, value_text, ',');
    while (values.next()) |raw| {
        _ = try parseCidr(raw);
    }
}

fn loadDotEnv(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, ".env", allocator, .limited(64 * 1024));
    defer allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const equal = std.mem.findScalar(u8, line, '=') orelse return error.InvalidDotEnvLine;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        var item = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (key.len == 0) return error.InvalidDotEnvLine;
        if (item.len >= 2 and ((item[0] == '"' and item[item.len - 1] == '"') or
            (item[0] == '\'' and item[item.len - 1] == '\''))) item = item[1 .. item.len - 1];
        if (!env.contains(key)) try env.put(key, item);
    }
}

fn value(env: *const std.process.Environ.Map, key: []const u8, default: []const u8) []const u8 {
    return env.get(key) orelse default;
}

fn positiveInt(comptime T: type, text: []const u8) !T {
    const number = std.fmt.parseInt(T, text, 10) catch return error.InvalidInteger;
    if (number == 0) return error.InvalidInteger;
    return number;
}

pub fn duration(text: []const u8) !i64 {
    if (text.len < 2) return error.InvalidDuration;
    const unit = text[text.len - 1];
    const multiplier: i64 = switch (unit) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return error.InvalidDuration,
    };
    const count = std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return error.InvalidDuration;
    if (count <= 0 or count > @divTrunc(std.math.maxInt(i64), multiplier)) return error.InvalidDuration;
    return count * multiplier;
}

fn shortDuration(text: []const u8) !u32 {
    return std.math.cast(u32, try duration(text)) orelse error.InvalidDuration;
}

fn retentionDuration(text: []const u8) !i64 {
    const seconds = try duration(text);
    if (seconds > max_retention_seconds) return error.RetentionTtlTooLarge;
    return seconds;
}

fn uploadBytes(text: []const u8) !u64 {
    const bytes = try positiveInt(u64, text);
    if (bytes > max_upload_bytes) return error.MaximumUploadBytesTooLarge;
    return bytes;
}

test "duration parser rejects silent fallbacks" {
    try std.testing.expectEqual(@as(i64, 900), try duration("15m"));
    try std.testing.expectError(error.InvalidDuration, duration("15"));
    try std.testing.expectError(error.InvalidDuration, duration("0s"));
    try std.testing.expectError(error.InvalidDuration, duration("bad"));
    try std.testing.expectError(error.InvalidDuration, shortDuration("50000d"));
    try std.testing.expectError(error.RetentionTtlTooLarge, retentionDuration("366d"));
    try std.testing.expectError(error.MaximumUploadBytesTooLarge, uploadBytes("18446744073709551615"));
}

test "NNTP configuration rejects unsafe control bytes and connection range" {
    try std.testing.expectError(error.InvalidNntpConfigurationValue, validateNntpValue("bad\nhost"));
    try std.testing.expectError(error.InvalidNntpConfigurationValue, validateNntpValue("user name"));
    try std.testing.expectError(error.InvalidNntpConfigurationValue, validateNntpValue("user\tname"));
    try std.testing.expectError(error.InvalidNntpConfigurationValue, validateNntpValue("user\x7fname"));
    try validateNntpValue("provider.example");

    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("NNTP_HOST", "news.example.com");
    try map.put("NNTP_USER", "alice");
    try map.put("NNTP_PASS", "secret");
    try map.put("DOWNLOAD_DIR", "/downloads");
    const cfg = try loadFromMap(std.testing.allocator, &map);
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("news.example.com", cfg.nntp_host);
    try std.testing.expectEqual(@as(u16, 563), cfg.nntp_port);
}
