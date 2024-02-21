pub fn repeat(comptime T: type, comptime v: T, comptime n: comptime_int) [n]T {
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(v);
    }
    return result;
}

pub fn arange(comptime T: type, comptime n: comptime_int) [n]T {
    const std = @import("std");
    var result: [n]T = undefined;
    for (0..n) |i| {
        result[i] = @intCast(i % std.math.maxInt(T));
    }
    return result;
}
