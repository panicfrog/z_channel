const std = @import("std");
const z_core = @import("z_core");

pub fn hello(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf, "hello from z_lib, and {s}", .{z_core.hello()}) catch unreachable;
}

test "hello" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello from z_lib, and hello from z_core", hello(&buf));
}
