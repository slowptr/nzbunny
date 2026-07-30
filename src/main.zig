const std = @import("std");
const app = @import("nzigbunny");

pub fn main(init: std.process.Init) !void {
    try app.run(init);
}
