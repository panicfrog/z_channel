const std = @import("std");
const z_lib = @import("z_lib");

pub fn main() !void {
    var buf: [64]u8 = undefined;
    std.debug.print("{s}\n", .{z_lib.hello(&buf)});
}
