const std = @import("std");

pub const config = @import("config.zig");
pub const database = @import("database.zig");
pub const artifact = @import("artifact.zig");
pub const download = @import("download.zig");
pub const nntp = @import("nntp.zig");
pub const nzb = @import("nzb.zig");
pub const yenc = @import("yenc.zig");
pub const worker = @import("worker.zig");
pub const paths = @import("paths.zig");
pub const shutdown = @import("shutdown.zig");
pub const repair = @import("repair.zig");
pub const runtime = @import("runtime.zig");
pub const ownership = @import("ownership.zig");
pub const finalizer = @import("finalizer.zig");
pub const failure = @import("failure.zig");
pub const budget = @import("budget.zig");
pub const storage = @import("storage.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const http = @import("http.zig");
pub const pages = @import("pages.zig");
pub const multipart = @import("multipart.zig");
pub const rate_limit = @import("rate_limit.zig");
pub const web = @import("web.zig");

pub fn run(init: std.process.Init) !void {
    nzb.initParser();
    const cfg = config.load(init.gpa, init.io, init.minimal.environ) catch |err| {
        std.log.err("Configuration is not valid: {t}", .{err});
        return err;
    };
    defer cfg.deinit(init.gpa);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const download_root = try paths.resolveRoot(cfg.download_dir, &root_buffer);
    const root_z = try init.gpa.dupeZ(u8, download_root);
    defer init.gpa.free(root_z);
    const root_lock = try ownership.Lock.acquire(root_z, true);
    defer root_lock.deinit();
    const db_z = try init.gpa.dupeZ(u8, cfg.db_path);
    defer init.gpa.free(db_z);
    const db_lock = try ownership.Lock.acquire(db_z, false);
    defer db_lock.deinit();
    var state = runtime.AppState.init(cfg, download_root);
    shutdown.installSignalHandlers(&state.shutdown);
    defer shutdown.uninstallSignalHandlers();
    var db = try database.Database.open(init.gpa, cfg.db_path);
    defer db.close();

    var ca_store = try nntp.CaStore.load(init.gpa, init.io, cfg.nntp_ca_file);
    defer ca_store.deinit(init.gpa);
    try worker.startup(init.io, &db, download_root);
    std.log.info("nzbunny listens on port {d}", .{cfg.port});
    try web.serve(init.gpa, init.io, &db, cfg, download_root, &ca_store, &state);
}

test {
    std.testing.refAllDecls(@This());
}
