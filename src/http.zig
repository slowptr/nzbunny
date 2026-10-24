const std = @import("std");
const Config = @import("config.zig").Config;
const Database = @import("database.zig").Database;
const shutdown = @import("shutdown.zig");
const worker = @import("worker.zig");
const AppState = @import("runtime.zig").AppState;
const nntp = @import("nntp.zig");
const RateLimiter = @import("rate_limit.zig").RateLimiter;

pub const Handler = *const fn (*std.http.Server.Request, *Context, std.Io.net.IpAddress, []const u8, std.mem.Allocator) anyerror!void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *Database,
    cfg: Config,
    root: []const u8,
    root_dir: std.Io.Dir,
    ca_store: *nntp.CaStore,
    connections: std.Io.Semaphore,
    limiter: RateLimiter,
    state: *AppState,
    handler: Handler,
    streams_mutex: std.Io.Mutex = .init,
    streams: std.AutoHashMapUnmanaged(std.posix.fd_t, std.Io.net.Stream) = .empty,
};

pub fn serve(allocator: std.mem.Allocator, io: std.Io, db: *Database, cfg: Config, root: []const u8, ca_store: *nntp.CaStore, state: *AppState, handler: Handler) !void {
    const address = try std.Io.net.IpAddress.parse("0.0.0.0", cfg.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    defer state.shutdown.requested.store(true, .release);
    const root_dir = try std.Io.Dir.openDirAbsolute(io, root, .{ .follow_symlinks = false });
    defer root_dir.close(io);
    var context = Context{
        .allocator = allocator,
        .io = io,
        .db = db,
        .cfg = cfg,
        .root = root,
        .root_dir = root_dir,
        .ca_store = ca_store,
        .connections = .{ .permits = cfg.max_connections },
        .limiter = .{},
        .state = state,
        .handler = handler,
    };
    defer context.streams.deinit(allocator);
    io.random(std.mem.asBytes(&context.limiter.seed));
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.async(io, worker.run, .{ allocator, io, db, cfg, context.root, ca_store, state });
    var watcher_group: std.Io.Group = .init;
    defer watcher_group.cancel(io);
    try watcher_group.concurrent(io, shutdownWatcher, .{ io, &listener, &context });
    defer {
        state.shutdown.requested.store(true, .release);
        closeStreams(&context);
        group.cancel(io);
    }
    while (!state.shutdown.requested.load(.acquire)) {
        try context.connections.wait(io);
        if (state.shutdown.requested.load(.acquire)) {
            context.connections.post(io);
            break;
        }
        const stream = listener.accept(io) catch |err| {
            context.connections.post(io);
            if (state.shutdown.requested.load(.acquire)) break;
            std.log.warn("Accept failed: {t}", .{err});
            continue;
        };
        context.streams_mutex.lockUncancelable(io);
        if (state.shutdown.requested.load(.acquire)) {
            context.streams_mutex.unlock(io);
            stream.close(io);
            context.connections.post(io);
            break;
        }
        context.streams.put(allocator, stream.socket.handle, stream) catch |err| {
            context.streams_mutex.unlock(io);
            stream.close(io);
            context.connections.post(io);
            return err;
        };
        context.streams_mutex.unlock(io);
        group.async(io, accept, .{ &context, stream });
    }
    group.await(io) catch {};
}

fn shutdownWatcher(io: std.Io, listener: *std.Io.net.Server, context: *Context) std.Io.Cancelable!void {
    while (!context.state.shutdown.requested.load(.acquire))
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
    const stream: std.Io.net.Stream = .{ .socket = listener.socket };
    stream.shutdown(io, .both) catch {};
    closeStreams(context);
    context.connections.post(io);
    try std.Io.sleep(io, .fromSeconds(context.cfg.shutdown_seconds), .awake);
    std.log.err("Shutdown deadline exceeded; unfinished jobs will recover at the next start.", .{});
    std.process.exit(1);
}

fn closeStreams(context: *Context) void {
    context.streams_mutex.lockUncancelable(context.io);
    defer context.streams_mutex.unlock(context.io);
    var streams = context.streams.valueIterator();
    while (streams.next()) |active| active.shutdown(context.io, .both) catch {};
}

fn accept(context: *Context, stream: std.Io.net.Stream) void {
    defer context.connections.post(context.io);
    defer stream.close(context.io);
    defer {
        context.streams_mutex.lockUncancelable(context.io);
        _ = context.streams.remove(stream.socket.handle);
        context.streams_mutex.unlock(context.io);
    }
    var peer_buffer: [64]u8 = undefined;
    var peer_writer = std.Io.Writer.fixed(&peer_buffer);
    var peer_address = stream.socket.address;
    peer_address.setPort(0);
    peer_address.format(&peer_writer) catch return;
    const peer = peer_writer.buffered();
    var receive_buffer: [32 * 1024]u8 = undefined;
    var send_buffer: [16 * 1024]u8 = undefined;
    var conn_reader = stream.reader(context.io, &receive_buffer);
    var conn_writer = stream.writer(context.io, &send_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    while (server.reader.state == .ready and !context.state.shutdown.requested.load(.acquire)) {
        var request = blk: {
            var header_timeout: std.Io.Group = .init;
            defer header_timeout.cancel(context.io);
            header_timeout.concurrent(context.io, shutdownAfter, .{
                stream,
                context.io,
                context.cfg.http_header_seconds,
            }) catch return;
            break :blk server.receiveHead() catch return;
        };
        var arena = std.heap.ArenaAllocator.init(context.allocator);
        defer arena.deinit();
        {
            var request_timeout: std.Io.Group = .init;
            defer request_timeout.cancel(context.io);
            request_timeout.concurrent(context.io, shutdownAfter, .{
                stream,
                context.io,
                context.cfg.http_request_seconds,
            }) catch return;
            context.handler(&request, context, peer_address, peer, arena.allocator()) catch |err| {
                std.log.err("Request failed: {t}", .{err});
                return;
            };
        }
    }
}

fn shutdownAfter(stream: std.Io.net.Stream, io: std.Io, seconds: u32) std.Io.Cancelable!void {
    try std.Io.sleep(io, .fromSeconds(seconds), .awake);
    stream.shutdown(io, .both) catch |err|
        std.log.debug("Timed out connection shutdown failed: {t}", .{err});
}
