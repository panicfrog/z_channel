const std = @import("std");

pub fn hello() []const u8 {
    return "hello from z_core";
}

test "hello" {
    try std.testing.expectEqualStrings("hello from z_core", hello());
}
