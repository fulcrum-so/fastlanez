// We always operate on vectors of 1024 elements.
// Elements may be 8, 16, 32, or 64 bits wide. Known as T.
// 1024 / T is the number of SIMD lanes, known as S.

pub fn FastLanez(comptime E: type, comptime ISA: type) type {
    @setEvalBranchQuota(4096);

    // Generate the shuffle mask using the 04261537 order.
    const ORDER = .{ 0, 4, 2, 6, 1, 5, 3, 7 };

    const transpose_mask: [1024]i32 = blk: {
        var mask: [1024]i32 = undefined;
        var mask_idx = 0;
        for (0..8) |row| {
            for (ORDER) |o| {
                for (0..16) |i| {
                    mask[mask_idx] = (i * 64) + (o * 8) + row;
                    mask_idx += 1;
                }
            }
        }
        break :blk mask;
    };

    const untranspose_mask: [1024]i32 = blk: {
        var mask: [1024]i32 = undefined;
        for (0..1024) |i| {
            mask[transpose_mask[i]] = i;
        }
        break :blk mask;
    };

    return struct {
        const T = @bitSizeOf(E);
        const S = 1024 / T;
        const FLMM1024 = [1024]E;
        const FLLane = [S]E;
        const FLBase = [16]E;
        const Vec = @Vector(1024, E);

        const Lane = ISA.Lane;
        const LaneWidth = ISA.Width / T;
        const Lanes = 1024 / ISA.Width;
        const LaneOffset = 128 / LaneWidth;

        /// Returns a function that operates pair-wise on FLMM1024 vectors by tranposing.
        inline fn fold(comptime op: fn (Lane, Lane) Lane) fn (FLBase, FLMM1024, *FLMM1024) void {
            const impl = struct {
                pub fn fl_fold(base: FLBase, in: FLMM1024, out: *FLMM1024) void {
                    @setEvalBranchQuota(8192);

                    // TODO(ngates): should we use ISA.load instead of bitcasting?
                    const base_lanes: [16 / LaneWidth]Lane = @bitCast(base);
                    const in_lanes: [T * Lanes]Lane = @bitCast(in);
                    const out_lanes: *[T * Lanes]Lane = @alignCast(@ptrCast(out));
                    const std = @import("std");

                    // for (in_lanes, 0..) |lane, i| {
                    //     std.debug.print("{} {any}\n", .{ i, lane });
                    // }
                    std.debug.print("T: {}, Lanes: {}, LaneWidth: {}, LaneOffset: {}, ISA.Width: {}\n", .{ T, Lanes, LaneWidth, LaneOffset, ISA.Width });

                    // const tile_height_in_elems = 8;
                    const tile_width_in_elems = 16;
                    const tile_width_in_lanes = tile_width_in_elems / ISA.LaneWidth;

                    const row_width_in_elems = 8 * tile_width_in_elems;
                    const row_width_in_lanes = row_width_in_elems / ISA.LaneWidth;

                    // The ordering places 1024 elements into 8x16 tiles.
                    // Each ISA lane covers some number of elements based on its implementation, the LaneWidth.
                    // Our job is to iterate over the tranposed ordering in a way that applies SIMD operations
                    // over adjacent elements in the original ordering.

                    // First, loop over however many lanes fit across each tile width.
                    inline for (0..tile_width_in_lanes) |l| {
                        // Each lane shifts everything along by 1
                        const lane_offset = l;
                        var base_lane: Lane = base_lanes[l];

                        // Next, iterate over the 8 tranposed tiles according to the ordering.
                        inline for (ORDER) |o| {
                            const order_offset = o * tile_width_in_lanes;

                            // Finally, we iterate over the rows of the tile.
                            inline for (0..8) |row| {
                                const row_offset = row * row_width_in_lanes;

                                const offset = lane_offset + order_offset + row_offset;

                                const result = op(base_lane, in_lanes[offset]);
                                out_lanes[offset] = result;
                                base_lane = in_lanes[offset];
                            }
                        }
                    }
                }
            };

            return impl.fl_fold;
        }

        /// Shuffle the input vector into the unified transpose order.
        pub fn transpose(vec: FLMM1024) FLMM1024 {
            return @shuffle(E, @as(Vec, vec), @as(Vec, vec), transpose_mask);
        }

        /// Unshuffle the input vector from the unified transpose order.
        pub fn untranspose(vec: FLMM1024) FLMM1024 {
            return @shuffle(E, @as(Vec, vec), @as(Vec, vec), untranspose_mask);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(vec: FLMM1024, n: anytype, mask: FLMM1024) FLMM1024 {
            // TODO(ngates): can we make this more efficient?
            const nVec: FLMM1024 = @splat(n);
            return (vec & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(vec: FLMM1024, n: anytype, mask: FLMM1024) FLMM1024 {
            const nVec: FLMM1024 = @splat(n);
            return (vec & (mask << nVec)) >> @intCast(nVec);
        }
    };
}

/// A FastLanez ISA implemented using 64-bit unsigned integers.
pub fn FastLanez_U64(comptime T: type) type {
    return struct {
        const Width = 64;
        const Lane = u64;

        inline fn load(elems: *const [Width]T) Lane {
            return @bitCast(elems.*);
        }

        inline fn store(lane: Lane, elems: *[Width]T) void {
            elems.* = @bitCast(lane);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(lane: Lane, n: anytype, mask: Lane) Lane {
            // TODO(ngates): can we make this more efficient?
            const nVec: Lane = @splat(n);
            return (lane & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(lane: Lane, n: anytype, mask: Lane) Lane {
            const nVec: Lane = @splat(n);
            return (lane & (mask << nVec)) >> @intCast(nVec);
        }

        pub fn subtract(a: Lane, b: Lane) Lane {
            const a_vec: @Vector(64 / @bitSizeOf(T), T) = @bitCast(a);
            const b_vec: @Vector(64 / @bitSizeOf(T), T) = @bitCast(b);
            return @bitCast(a_vec - b_vec);
        }
    };
}

/// A FastLanez ISA implemented using Zig SIMD 1024-bit vectors.
pub fn FastLanez_SIMD(comptime T: type, comptime W: comptime_int) type {
    return struct {
        const Width = W;
        const LaneWidth = W / @bitSizeOf(T);
        const Lane = @Vector(LaneWidth, T);

        inline fn load(elems: *const [LaneWidth]T) Lane {
            return @bitCast(elems.*);
        }

        inline fn store(lane: Lane, elems: *[LaneWidth]T) void {
            elems.* = @bitCast(lane);
        }

        inline fn shuffle(lane: Lane, mask: [LaneWidth]i32) Lane {
            const mask_vec: @Vector(LaneWidth, i32) = @bitCast(mask);
            return @shuffle(T, lane, lane, mask_vec);
        }

        // forall T−bit lanes i in REG return (i & MASK) << N
        inline fn and_lshift(lane: Lane, n: anytype, mask: Lane) Lane {
            // TODO(ngates): can we make this more efficient?
            const nVec: Lane = @splat(n);
            return (lane & mask) << @intCast(nVec);
        }

        // forall T−bit lanes i in REG return (i & (MASK << N)) >> N
        inline fn and_rshift(lane: Lane, n: anytype, mask: Lane) Lane {
            const nVec: Lane = @splat(n);
            return (lane & (mask << nVec)) >> @intCast(nVec);
        }

        inline fn subtract(a: Lane, b: Lane) Lane {
            return a - b;
        }
    };
}

pub fn Delta(comptime T: type) type {
    const ISA = FastLanez_SIMD(T, 32);

    return struct {
        pub const FL = FastLanez(T, ISA);
        pub const FLMM1024 = FL.FLMM1024;

        pub fn encode(base: FL.FLBase, in: FLMM1024, out: *FLMM1024) void {
            const tin = FL.transpose(in);
            return FL.fold(delta)(base, tin, out);
        }

        fn delta(acc: FL.Lane, value: FL.Lane) FL.Lane {
            return ISA.subtract(value, acc);
        }
    };
}

// test "fastlanez simd isa" {
//     const std = @import("std");
//     const T = u32;
//     const FL = FastLanez_SIMD(T);

//     const expected = arange(T);
//     const vec = FL.load(&expected);

//     var actual: [FL_WIDTH]T = undefined;
//     FL.store(vec, &actual);

//     try std.testing.expectEqual(expected, actual);
// }

test "fastlanez transpose" {
    const std = @import("std");
    const T = u32;
    const ISA = FastLanez_SIMD(T, 64);
    const FL = FastLanez(T, ISA);

    const input: FL.FLMM1024 = arange(T, 1024);
    const transposed = FL.transpose(input);

    try std.testing.expectEqual(transposed[0], 0);
    try std.testing.expectEqual(transposed[1], 64);
    try std.testing.expectEqual(transposed[2], 128);
    try std.testing.expectEqual(transposed[16], 32);
    try std.testing.expectEqual(transposed[1017], 639);
    try std.testing.expectEqual(transposed[1023], 1023);
}

test "fastlanez delta" {
    const std = @import("std");
    const T = u32;
    const Codec = Delta(T);

    const base = [_]T{0} ** 16;
    const input = arange(T, 1024);

    var actual: [1024]T = undefined;
    Codec.encode(base, input, &actual);

    actual = Codec.FL.untranspose(actual);

    for (0..1024) |i| {
        // Since fastlanes processes based on 16 blocks, we expect a zero delta every 1024 / 16 = 64 elements.
        if (i % 64 == 0) {
            try std.testing.expectEqual(i, actual[i]);
        } else {
            try std.testing.expectEqual(1, actual[i]);
        }
    }
}

fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i);
    }
    return result;
}
