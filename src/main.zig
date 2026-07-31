const std = @import("std");
const app = @import("nzbunny");

pub fn main(init: std.process.Init) !void {
    try app.run(init);
}
