const std = @import("std");
const zgrid = @import("zgrid");

pub fn main(init: std.process.Init) !void {
    _ = init.arena;
    const my_ball = zgrid.Ball2f{ .centre = .{ 0, 0 }, .radius = 1.0 };
    std.debug.print("my ball = {any}.\n", .{my_ball});
}
