const std = @import("std");

pub const config = @import("config.zig");
pub const database = @import("database.zig");
pub const artifact = @import("artifact.zig");
pub const worker = @import("worker.zig");
pub const paths = @import("paths.zig");
pub const web = @import("web.zig");

pub fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const cfg = config.load(allocator, init.io, init.minimal.environ) catch |err| {
        std.log.err("Configuration is not valid: {t}", .{err});
        return err;
    };
    var db = try database.Database.open(init.gpa, cfg.db_path);
    defer db.close();

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const download_root = try paths.resolveRoot(cfg.download_dir, &root_buffer);
    std.log.info("nzigbunny listens on port {d}", .{cfg.port});
    try web.serve(init.gpa, init.io, &db, cfg, download_root);
}

test {
    std.testing.refAllDecls(@This());
}
