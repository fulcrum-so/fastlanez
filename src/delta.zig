pub fn Delta(comptime FastLanes: type) type {
    const FL = FastLanes;

    return FL.pairwise(struct {
        pub inline fn encode(prev: FL.MM, next: FL.MM) FL.MM {
            return next -% prev;
        }

        pub inline fn decode(prev: FL.MM, next: FL.MM) FL.MM {
            return prev +% next;
        }
    });
}

test "fastlanez delta" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const arange = @import("helper.zig").arange;

    const T = u16;
    const FL = fl.FastLanez(T, .{});

    const base = [_]T{0} ** (1024 / @bitSizeOf(T));
    const input = arange(T, 1024);
    const tinput = FL.transpose(input);

    var actual: [1024]T = undefined;
    Delta(FL).encode(&base, &tinput, &actual);
    std.mem.doNotOptimizeAway(actual);

    // actual = FL.untranspose(actual);

    // for (0..1024) |i| {
    //     // Since fastlanes processes based on 16 blocks, we expect a zero delta every 1024 / 16 = 64 elements.
    //     if (i % @bitSizeOf(T) == 0) {
    //         try std.testing.expectEqual(i, actual[i]);
    //     } else {
    //         try std.testing.expectEqual(1, actual[i]);
    //     }
    // }
}

test "fastlanez delta bench" {
    const std = @import("std");
    const fl = @import("fastlanes.zig");
    const Bench = @import("bench.zig").Bench;
    const arange = @import("helper.zig").arange;

    const T = u16;
    const FL = fl.FastLanez(T, .{});

    try Bench("delta encode", .{}).bench(struct {
        const base = [_]T{0} ** (1024 / @bitSizeOf(T));
        const input = arange(T, 1024);
        const tinput = FL.transpose(input);

        pub fn run(_: @This()) void {
            var output: [1024]T = undefined;
            Delta(FL).encode(&base, &tinput, &output);
            std.mem.doNotOptimizeAway(output);
        }
    });

    try Bench("delta decode", .{}).bench(struct {
        const base = [_]T{0} ** (1024 / @bitSizeOf(T));
        const input: [1024]T = .{1} ** 1024;

        pub fn run(_: @This()) void {
            var output: [1024]T = undefined;
            Delta(FL).encode(&base, &input, &output);
            std.mem.doNotOptimizeAway(output);
        }
    });
}
