const std = @import("std");
const c = @import("c");

pub const Colour = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub fn fromRgba(rgba: u32) Colour {
        return @bitCast(@byteSwap(rgba));
    }

    pub fn fromHsl(h: f32, s: f32, l: f32) Colour {
        const hue = @mod(h, 360.0);
        const chroma = (1 - @abs(2 * l - 1)) * s;
        const x = chroma * (1 - @abs(@mod(hue / 60.0, 2) - 1));
        const m = l - chroma / 2;
        const rgb1: @Vector(3, f32) = switch (@as(u32, @intFromFloat(hue / 60.0))) {
            0 => .{ chroma, x, 0 },
            1 => .{ x, chroma, 0 },
            2 => .{ 0, chroma, x },
            3 => .{ 0, x, chroma },
            4 => .{ x, 0, chroma },
            else => .{ chroma, 0, x },
        };
        const rgb = (rgb1 + @as(@Vector(3, f32), @splat(m))) * @as(@Vector(3, f32), @splat(255.0));
        return .{
            .r = @intFromFloat(rgb[0]),
            .g = @intFromFloat(rgb[1]),
            .b = @intFromFloat(rgb[2]),
        };
    }
};

pub const OctagonInfo = struct {
    centre: @Vector(2, f32),
    radius: f32,
    colour: Colour,

    const poly_indexes = [_]c_int{
        1, 2, 0,
        2, 3, 0,
        3, 7, 0,
        3, 4, 7,
        4, 6, 7,
        4, 5, 6,
    };

    const vert_cos_thetas: [8]f32 = blk: {
        var values: [8]f32 = undefined;
        for (0..8) |i| {
            const theta_i: f32 = @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
            values[i] = std.math.cos(theta_i);
        }
        break :blk values;
    };

    const vert_sin_thetas: [8]f32 = blk: {
        var values: [8]f32 = undefined;
        for (0..8) |i| {
            const theta_i: f32 = @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
            values[i] = std.math.sin(theta_i);
        }
        break :blk values;
    };
};

pub const RectInfo = struct {
    min: @Vector(2, f32),
    max: @Vector(2, f32),
    colour: Colour,
};

pub const RegularPolyInfo = struct {
    num_sides: u8,
    centre: @Vector(2, f32),
    radius: f32,
    colour: Colour,
};

pub const TextInfo = struct {
    colour: Colour,
    string: [:0]const u8,
    x: f32,
    y: f32,
};

pub const DrawCommand = union(enum) {
    octagon: OctagonInfo,
    rectangle: RectInfo,
    regular_poly: RegularPolyInfo,
    text: TextInfo,
};

pub const Request = union(enum) {
    click: @Vector(2, f32),
    pause: void,
    quit: void,
};

var window: *c.SDL_Window = undefined;
var renderer: *c.SDL_Renderer = undefined;
var vertices: std.ArrayList(c.SDL_Vertex) = undefined;
var indices: std.ArrayList(c_int) = undefined;
var prev_space_down: bool = false;

pub fn init(
    allocator: std.mem.Allocator,
    name: []const u8,
    win_width: u16,
    win_height: u16,
) !void {
    const sdl_base_flags = c.SDL_INIT_AUDIO | c.SDL_INIT_VIDEO;
    if (!c.SDL_Init(sdl_base_flags)) {
        c.SDL_Log("Could not initialise SDL video subsytem: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }
    window = c.SDL_CreateWindow(name.ptr, @intCast(win_width), @intCast(win_height), 0) orelse {
        c.SDL_Log("Could not create SDL window: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    renderer = c.SDL_CreateRenderer(window, null) orelse {
        c.SDL_Log("Could not create SDL renderer: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    };
    if (!c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND)) {
        c.SDL_Log("Could not set SDL renderer blend mode: %s\n", c.SDL_GetError());
        return error.SDLInitFailed;
    }

    vertices = try std.ArrayList(c.SDL_Vertex).initCapacity(allocator, 1_000_000);
    errdefer vertices.deinit(allocator);
    indices = try std.ArrayList(c_int).initCapacity(allocator, 3 * 1_000_000);
    errdefer indices.deinit(allocator);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    c.SDL_DestroyRenderer(renderer);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
    indices.deinit(allocator);
    vertices.deinit(allocator);
}

pub fn render(render_queue: []DrawCommand) !void {
    frameStart();
    for (render_queue) |cmd| {
        switch (cmd) {
            .octagon => queueOctagon(cmd.octagon),
            .rectangle => renderRectangle(cmd.rectangle),
            .regular_poly => try queueRegularPoly(cmd.regular_poly),
            .text => renderText(cmd.text),
        }
    }
    frameEnd();
}

fn flushGeometry() void {
    if (vertices.items.len == 0)
        return;
    _ = c.SDL_RenderGeometry(
        renderer,
        null,
        vertices.items.ptr,
        @intCast(vertices.items.len),
        indices.items.ptr,
        @intCast(indices.items.len),
    );
}

fn frameStart() void {
    vertices.clearRetainingCapacity();
    indices.clearRetainingCapacity();
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(renderer);
}

fn frameEnd() void {
    flushGeometry();
    _ = c.SDL_RenderPresent(renderer);
}

pub fn getRequests(req_buffer: []Request) []Request {
    var e: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&e)) {
        if (e.type == c.SDL_EVENT_QUIT) {
            req_buffer[0] = .{ .quit = {} };
            return req_buffer[0..1];
        }
    }
    var buff_index: usize = 0;
    // check keyboard input
    const key_states = c.SDL_GetKeyboardState(null);
    if (key_states[c.SDL_SCANCODE_ESCAPE]) {
        req_buffer[0] = .{ .quit = {} };
        return req_buffer[0..1];
    }
    const space_down = key_states[c.SDL_SCANCODE_SPACE];
    if (space_down and !prev_space_down) {
        req_buffer[buff_index] = .{ .pause = {} };
        buff_index += 1;
    }
    prev_space_down = space_down;
    // check mouse input
    var mouse_x: f32 = undefined;
    var mouse_y: f32 = undefined;
    const mb_flags = c.SDL_GetMouseState(&mouse_x, &mouse_y);
    if (mb_flags & 0b1 == 0b1) { // LMB down
        req_buffer[buff_index] = .{ .click = .{ mouse_x, mouse_y } };
        buff_index += 1;
    }
    return req_buffer[0..buff_index];
}

fn getSdlFRect(rect: RectInfo) c.SDL_FRect {
    var sdl_rect: c.SDL_FRect = undefined;
    const diff = rect.max - rect.min;
    sdl_rect.x = rect.min[0];
    sdl_rect.y = rect.max[1];
    sdl_rect.w = diff[0];
    sdl_rect.h = diff[1];
    return sdl_rect;
}

fn getSdlFColour(col: Colour) c.SDL_FColor {
    // NOTE: SDL_FColor channels are normalised floats in [0, 1].
    var sdl_col: c.SDL_FColor = undefined;
    sdl_col.r = @as(f32, @floatFromInt(col.r)) / 255.0;
    sdl_col.g = @as(f32, @floatFromInt(col.g)) / 255.0;
    sdl_col.b = @as(f32, @floatFromInt(col.b)) / 255.0;
    sdl_col.a = @as(f32, @floatFromInt(col.a)) / 255.0;
    return sdl_col;
}

fn queueOctagon(oct: OctagonInfo) void {
    const base: c_int = @intCast(vertices.items.len);
    for (0..8) |i| {
        var v: c.SDL_Vertex = undefined;
        v.position.x = oct.centre[0] + oct.radius * OctagonInfo.vert_cos_thetas[i];
        v.position.y = oct.centre[1] + oct.radius * OctagonInfo.vert_sin_thetas[i];
        v.color = getSdlFColour(oct.colour);
        vertices.appendAssumeCapacity(v);
    }
    for (OctagonInfo.poly_indexes) |i| {
        indices.appendAssumeCapacity(base + i);
    }
}

fn queueRegularPoly(p: RegularPolyInfo) !void {
    if (p.num_sides < 3) return error.InvalidNumberOfSides;
    const base: c_int = @intCast(vertices.items.len);
    const angle_inc = 2 * std.math.pi / @as(f32, @floatFromInt(p.num_sides));
    for (0..p.num_sides) |i| {
        var v: c.SDL_Vertex = undefined;
        const theta_i = @as(f32, @floatFromInt(i)) * angle_inc;
        v.position.x = p.centre[0] + p.radius * std.math.cos(theta_i);
        v.position.y = p.centre[1] + p.radius * std.math.sin(theta_i);
        v.color = getSdlFColour(p.colour);
        vertices.appendAssumeCapacity(v);
    }
    for (1..p.num_sides - 1) |i| {
        indices.appendAssumeCapacity(base + @as(c_int, @intCast(i + 1)));
        indices.appendAssumeCapacity(base + @as(c_int, @intCast(i)));
        indices.appendAssumeCapacity(base + 0);
    }
}

fn renderRectangle(rect: RectInfo) void {
    const col = rect.colour;
    const sdl_rect = getSdlFRect(rect);
    _ = c.SDL_SetRenderDrawColor(renderer, col.r, col.g, col.b, col.a);
    _ = c.SDL_RenderFillRect(renderer, &sdl_rect);
}

fn renderText(text: TextInfo) void {
    const col = text.colour;
    _ = c.SDL_SetRenderDrawColor(renderer, col.r, col.g, col.b, col.a);
    _ = c.SDL_RenderDebugText(renderer, text.x, text.y, text.string);
}
