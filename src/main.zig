const std = @import("std");
const zgrid = @import("zgrid");
const physics = @import("physics.zig");
const sdl = @import("sdl.zig");
const timer = std.Io.Clock.awake;
const Timestamp = std.Io.Timestamp;
const DrawList = std.ArrayList(sdl.DrawCommand);
const State = physics.State;
const Vec2f = physics.Vec2f;
const disp_width = 1920;
const disp_height = 1080;
const num_balls = 100_000;
const mean_radius = 2.0;
const sdev_radius = 0.2;
const exit_frame = 0;
const spawn_rate = 200;
const target_frame_time_us = 16_667;
const text_col = sdl.Colour.fromRgba(0xFFFFFFCC);

var ball_cols: [num_balls]sdl.Colour = undefined;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var request_buf: [8]sdl.Request = undefined;
    var draw_a = try DrawList.initCapacity(arena, num_balls + 8);
    defer draw_a.deinit(arena);
    var draw_b = try DrawList.initCapacity(arena, num_balls + 8);
    defer draw_b.deinit(arena);

    const max_verts = num_balls * 8 + 128;
    try sdl.init(arena, max_verts, "zgrid-demo", disp_width, disp_height);
    defer sdl.deinit(arena);
    const state_workers: u16 = @max(1, @as(u16, @truncate(try std.Thread.getCpuCount() -| 1)));
    var state = try State.init(arena, .{ disp_width, disp_height }, num_balls, state_workers);
    defer state.deinit(arena);
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    var frame_times: FrameTimes = .{};
    var ft_str: [:0]const u8 = "---";
    var ft_buf: [16]u8 = undefined;
    var last_frame_end = timer.now(io);
    var paused = false;
    var quit = false;
    var frame: usize = 0;

    while (!quit) {
        // 1. get input
        for (sdl.getRequests(&request_buf)) |request| {
            switch (request) {
                .click => |pos| {
                    if (state.explosion == null) {
                        state.explosion = .{ .boundary = .{ .centre = pos, .radius = 1.0 } };
                    }
                },
                .pause => paused = !paused,
                .quit => quit = true,
            }
        }

        // 2. begin updating state
        var update_future = io.async(update, .{ io, &state, random, paused, &draw_b });
        defer update_future.cancel(io) catch {};

        // 3. render draw_a
        draw_a.appendAssumeCapacity(
            .{ .text = .{ .colour = text_col, .string = ft_str, .x = 4, .y = 4 } },
        );
        try sdl.render(draw_a.items);

        // 4. complete updating state and write to draw_b
        try update_future.await(io);
        std.mem.swap(DrawList, &draw_a, &draw_b);

        // 5. frame timing and pacing
        const frame_us: i64 = @intCast(Timestamp.durationTo(last_frame_end, timer.now(io)).toMicroseconds());
        frame_times.addSample(@intCast(frame_us));
        if (frame_us < target_frame_time_us) {
            try io.sleep(.fromMicroseconds(target_frame_time_us - frame_us), timer);
        }
        ft_str = try frame_times.getAverageStr(&ft_buf, "us", 16);
        if (exit_frame > 0 and frame >= exit_frame) break;
        last_frame_end = timer.now(io);
        frame += 1;
    }
}

// updates the state and translates it to a sequence of draw commands
fn update(io: std.Io, state: *State, random: std.Random, paused: bool, draw_list: *DrawList) !void {
    if (!paused) {
        // update the state
        if (state.explosion) |*expl| {
            expl.lifetime -= 1;
            if (expl.lifetime == 0) state.explosion = null;
        }
        if (state.balls_spawned < num_balls) {
            const h = 360 * @as(f32, @floatFromInt(state.balls_spawned)) / num_balls;
            const colour = sdl.Colour.fromHsl(h, 0.6, 0.6);
            const count = @min(spawn_rate, state.balls.len - state.balls_spawned);
            const x_max: f32 = state.world_size[0];
            for (0..count) |i| {
                const radius = mean_radius + sdev_radius * random.floatNorm(f32);
                const angle = std.math.pi * (0.5 + 0.1 * random.floatNorm(f32));
                const x_off = @as(f32, @floatFromInt(i + 1)) * x_max / @as(f32, @floatFromInt(spawn_rate + 1));
                const d = Vec2f{ mean_radius * std.math.cos(angle), mean_radius * std.math.sin(angle) };
                const c = Vec2f{ x_off, radius };
                const b = zgrid.Ball2f{ .centre = c, .radius = radius };
                const index = state.addBall(b, c - d) orelse return;
                ball_cols[index] = colour;
            }
        }
        try state.step(io);
    }
    // translate to draw commands
    draw_list.clearRetainingCapacity();
    for (state.balls[0..state.balls_spawned], ball_cols[0..state.balls_spawned]) |ball, colour| {
        draw_list.appendAssumeCapacity(.{
            .octagon = .{ .colour = colour, .centre = ball.centre, .radius = ball.radius },
        });
    }
    if (state.explosion) |explosion| {
        const age = physics.expl_lifetime - explosion.lifetime;
        const r: u32 = 0xFF000000;
        const g: u32 = 0x00FF0000 - age * 0x00010000;
        const b: u32 = 0x0000FF00 - age * 0x00000200;
        const a: u32 = 0x000000FF - age * 8;
        draw_list.appendAssumeCapacity(.{
            .regular_poly = .{
                .num_sides = 24,
                .colour = sdl.Colour.fromRgba(r + g + b + a),
                .centre = explosion.boundary.centre,
                .radius = explosion.boundary.radius,
            },
        });
    }
}

const FrameTimes = struct {
    times: [size]i32 = @splat(0),
    index: u16 = 0,
    stored: u16 = 0,
    const Self = @This();
    const size = 1024;

    pub fn addSample(self: *Self, sample: i32) void {
        self.times[self.index] = sample;
        self.index = (self.index + 1) % size;
        self.stored = @min(size, self.stored + 1);
    }

    pub fn getAverage(self: *const Self, n: u16) i64 {
        if (self.stored == 0) return 0;
        const samples = std.math.clamp(n, 1, self.stored);
        var sum: i64 = 0;
        for (0..samples) |i| {
            const idx = (self.index + size - i - 1) % size;
            sum += self.times[idx];
        }
        return @divTrunc(sum, @as(i64, samples));
    }

    pub fn getAverageStr(self: *const Self, buf: []u8, units: []const u8, n: u16) ![:0]u8 {
        const avg = self.getAverage(n);
        return try std.fmt.bufPrintSentinel(buf, "{d} {s}", .{ avg, units }, 0);
    }
};
