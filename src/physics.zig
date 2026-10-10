const std = @import("std");
const zgrid = @import("zgrid");
const Allocator = std.mem.Allocator;
const ClientId = u24;
const PairIndex = u32;
const SquareTree = zgrid.SquareTree(zgrid.Indexer2f(.Morton256, 8), Ball2f, ClientId);
pub const Ball2f = zgrid.Ball2f;
pub const Vec2f = @Vector(2, f32);
pub const expl_lifetime = 7;
pub const substeps = 7;

const expl_speed = 6.0;
const expl_growth: f32 = expl_speed / @as(f32, substeps);
const expl_max_overlaps = 8_192;
const gravity: Vec2f = .{ 0, 300 };
const max_push = 2.0;
const response_coef: f32 = 0.65;
const wall_damping: f32 = 0.8;
const speed_limit_ratio: f32 = 0.499;
const sub_dt: f32 = 0.016667 / @as(f32, substeps);

const no_pair = std.math.maxInt(PairIndex);
const pairs_per_task = 16_384;
const strips_per_bg_worker = 4;

pub const Explosion = struct {
    boundary: Ball2f,
    lifetime: u32 = expl_lifetime,
};

pub const State = struct {
    world_size: Vec2f,
    balls: []Ball2f,
    prev_centres: []Vec2f,
    ball_indexes: []ClientId,
    ball_count: usize = 0,
    max_ball_radius: f32 = 0,
    explosion: ?Explosion = null,
    tree: SquareTree,
    expl_buf: [expl_max_overlaps][2]ClientId = undefined,
    overlap_buf: [][2]ClientId,
    pair_next: []PairIndex,
    strip_heads: []PairIndex,
    num_strips: usize,
    worker_count: usize,
    strip_scale: f32,
    strip_width: f32,

    pub fn init(
        allocator: Allocator,
        world_size: Vec2f,
        max_balls: u32,
        max_workers: u16,
    ) !State {
        if (max_balls > @as(u32, std.math.maxInt(ClientId))) return error.CapacityTooLarge;
        var tree = try SquareTree.init(allocator, .{ 0, 0 }, world_size, max_balls, max_workers);
        errdefer tree.deinit(allocator);
        const balls = try allocator.alloc(Ball2f, max_balls);
        errdefer allocator.free(balls);
        const prev_centres = try allocator.alloc(Vec2f, max_balls);
        errdefer allocator.free(prev_centres);
        const ball_indexes = try allocator.alloc(ClientId, max_balls);
        errdefer allocator.free(ball_indexes);
        const overlaps = try allocator.alloc([2]ClientId, 8 * @as(usize, max_balls));
        errdefer allocator.free(overlaps);
        const pair_next = try allocator.alloc(PairIndex, overlaps.len);
        errdefer allocator.free(pair_next);
        const background_workers: usize = max_workers;
        const worker_count = background_workers + 1;
        const num_strips = strips_per_bg_worker * background_workers;
        const strip_heads = try allocator.alloc(PairIndex, worker_count * num_strips);
        const strips: f32 = @floatFromInt(num_strips);
        return .{
            .world_size = world_size,
            .balls = balls,
            .prev_centres = prev_centres,
            .ball_indexes = ball_indexes,
            .tree = tree,
            .overlap_buf = overlaps,
            .pair_next = pair_next,
            .strip_heads = strip_heads,
            .num_strips = num_strips,
            .worker_count = worker_count,
            .strip_scale = strips / world_size[0],
            .strip_width = if (num_strips == 0) 0 else world_size[0] / strips,
        };
    }

    pub fn deinit(self: *State, allocator: Allocator) void {
        self.tree.deinit(allocator);
        allocator.free(self.balls);
        allocator.free(self.prev_centres);
        allocator.free(self.ball_indexes);
        allocator.free(self.overlap_buf);
        allocator.free(self.pair_next);
        allocator.free(self.strip_heads);
    }

    pub fn addBall(self: *State, ball: Ball2f, prev_centre: Vec2f) ?usize {
        if (self.ball_count >= self.balls.len) return null;
        const i = self.ball_count;
        self.balls[i] = ball;
        self.prev_centres[i] = prev_centre;
        self.ball_indexes[i] = @intCast(i);
        self.max_ball_radius = @max(self.max_ball_radius, ball.radius);
        self.ball_count += 1;
        return i;
    }

    pub fn step(self: *State, io: std.Io) !void {
        for (0..substeps) |_| {
            self.integrate();
            self.tree.clear();
            try self.tree.add(self.balls[0..self.ball_count], self.ball_indexes[0..self.ball_count]);
            try self.tree.buildParallel(io);

            if (self.explosion) |*explosion| {
                explosion.boundary.radius += expl_growth;
                const hits = try self.tree.findExtOverlapsSingle(&self.expl_buf, 0, explosion.boundary);
                const expl_radius = explosion.boundary.radius;
                for (hits) |pair| {
                    const ball = &self.balls[pair[1]];
                    const d = @as(Vec2f, ball.centre) - explosion.boundary.centre;
                    const dist_sq = @reduce(.Add, d * d);
                    const r_sum = ball.radius + expl_radius;
                    if (dist_sq >= r_sum * r_sum or dist_sq < 1e-8) continue;
                    const r_sq = ball.radius * ball.radius;
                    const dist = @sqrt(dist_sq);
                    const push = (r_sum - dist) * response_coef * (2 * r_sq / expl_radius);
                    ball.translate(d * @as(Vec2f, @splat(@min(max_push, push) / dist)));
                }
            }

            const overlaps = try self.tree.findSelfOverlapsParallel(io, self.overlap_buf);
            try self.resolve(io, overlaps);
        }
    }

    fn integrate(self: *State) void {
        const accel = gravity * @as(Vec2f, @splat(sub_dt * sub_dt));
        const world_size = self.world_size;
        for (self.balls[0..self.ball_count], self.prev_centres[0..self.ball_count]) |*ball, *prev| {
            const radius = ball.radius;
            const last_centre: Vec2f = ball.centre;
            var disp = last_centre - prev.* + accel;
            const speed_limit = speed_limit_ratio * radius;
            const disp_sq = @reduce(.Add, disp * disp);
            if (disp_sq > speed_limit * speed_limit) {
                disp *= @as(Vec2f, @splat(speed_limit / @sqrt(disp_sq)));
            }
            var centre = last_centre + disp;
            const hit_x = centre[0] < radius or centre[0] > world_size[0] - radius;
            const hit_y = centre[1] < radius or centre[1] > world_size[1] - radius;
            if (!hit_x and !hit_y) {
                ball.centre = centre;
                prev.* = last_centre;
                continue;
            }

            var velocity = centre - last_centre;
            inline for (0..2) |axis| {
                if (centre[axis] < radius) {
                    centre[axis] = radius;
                    velocity[axis] = -velocity[axis];
                    velocity[1 - axis] *= wall_damping;
                } else if (centre[axis] > world_size[axis] - radius) {
                    centre[axis] = world_size[axis] - radius;
                    velocity[axis] = -velocity[axis];
                    velocity[1 - axis] *= wall_damping;
                }
            }
            ball.centre = centre;
            prev.* = centre - velocity;
        }
    }

    fn resolve(self: *State, io: std.Io, overlaps: []const [2]ClientId) !void {
        if (overlaps.len == 0) return;
        const num_workers = @min(self.worker_count, (overlaps.len + pairs_per_task - 1) / pairs_per_task);
        const heads = self.strip_heads[0 .. num_workers * self.num_strips];
        @memset(heads, no_pair);
        var bucket_group: std.Io.Group = .init;
        errdefer bucket_group.cancel(io);
        for (0..num_workers - 1) |worker| {
            bucket_group.async(io, bucketOverlapRange, .{ self, overlaps, heads, worker, num_workers });
        }
        try self.bucketOverlapRange(overlaps, heads, num_workers - 1, num_workers);
        try bucket_group.await(io);

        for (0..2) |parity| {
            const task_count = @min(self.worker_count, (self.num_strips + 1 - parity) / 2);
            var next_strip: std.atomic.Value(usize) = .init(parity);
            var group: std.Io.Group = .init;
            errdefer group.cancel(io);
            for (0..task_count - 1) |_| {
                group.async(io, resolveOverlapStrips, .{ self, overlaps, heads, &next_strip });
            }
            try self.resolveOverlapStrips(overlaps, heads, &next_strip);
            try group.await(io);
        }
    }

    fn bucketOverlapRange(
        self: *State,
        overlaps: []const [2]ClientId,
        strip_heads: []PairIndex,
        worker: usize,
        worker_count: usize,
    ) std.Io.Cancelable!void {
        const start = overlaps.len * worker / worker_count;
        const end = overlaps.len * (worker + 1) / worker_count;
        const heads = strip_heads[worker * self.num_strips ..][0..self.num_strips];
        const balls = self.balls;
        const pair_next = self.pair_next;
        const strip_scale = self.strip_scale;
        const last_strip = self.num_strips - 1;
        const max_x = @max(0, self.world_size[0] - 1);
        for (overlaps[start..end], start..) |pair, pair_index| {
            const midpoint_x = (balls[pair[0]].centre[0] + balls[pair[1]].centre[0]) * 0.5;
            const clamped_x = @max(0.0, @min(max_x, midpoint_x));
            const strip = @min(last_strip, @as(usize, @intFromFloat(clamped_x * strip_scale)));
            pair_next[pair_index] = heads[strip];
            heads[strip] = @intCast(pair_index);
        }
    }

    fn resolveOverlapStrips(
        self: *State,
        overlaps: []const [2]ClientId,
        strip_heads: []const PairIndex,
        next_strip: *std.atomic.Value(usize),
    ) std.Io.Cancelable!void {
        const balls = self.balls;
        const pair_next = self.pair_next;
        const num_strips = self.num_strips;
        while (true) {
            const strip = next_strip.fetchAdd(2, .monotonic);
            if (strip >= num_strips) return;
            var head_offset = strip_heads.len - num_strips + strip;
            while (true) {
                var pair_index = strip_heads[head_offset];
                while (pair_index != no_pair) {
                    const pair = overlaps[pair_index];
                    resolvePair(balls, pair[0], pair[1]);
                    pair_index = pair_next[pair_index];
                }
                if (head_offset < num_strips) break;
                head_offset -= num_strips;
            }
        }
    }

    fn resolvePair(balls: []Ball2f, i: ClientId, j: ClientId) void {
        const a = &balls[i];
        const b = &balls[j];
        const d = @as(Vec2f, b.centre) - @as(Vec2f, a.centre);
        const dist_sq = @reduce(.Add, d * d);
        const r_sum = a.radius + b.radius;
        if (dist_sq >= r_sum * r_sum or dist_sq < 1e-8) return;
        const dist = @sqrt(dist_sq);
        const m_a = a.radius * a.radius;
        const m_b = b.radius * b.radius;
        const c_scale = @min(max_push, (r_sum - dist) * response_coef) / (dist * (m_a + m_b));
        const c = d * @as(Vec2f, @splat(c_scale));
        a.translate(-c * @as(Vec2f, @splat(m_b)));
        b.translate(c * @as(Vec2f, @splat(m_a)));
    }
};
