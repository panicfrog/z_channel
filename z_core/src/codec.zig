const ZCoreError = @import("error.zig").ZCoreError;
const data = @import("data.zig");
const std = @import("std");

const MAGIC_NUMBER = "ZC";
const VERSION = 1;

pub fn encode(value: anytype, init: std.process.Init) ![]const u8 {
    const value_type = @TypeOf(value);
    if (!data.is_datatype(value_type)) {
        return ZCoreError.InvalidValueType;
    }

    const id = data.get_id(value) orelse blk: {
        const io = init.io;
        const rng_impl: std.Random.IoSource = .{ .io = io };
        const secureRand = rng_impl.interface();
        break :blk secureRand.int(u16);
    };
    const Layout = extern struct { margic_number: [2]u8, version: [1]u8, id: u16 };
    var buf: [4]u8 = @splat(0);
    const layout = std.mem.bytesAsValue(Layout, buf[0..4]);
    layout.* = .{ .margic_number = MAGIC_NUMBER, .version = VERSION, .id = id };
    return buf;
}
