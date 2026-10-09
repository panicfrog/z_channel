const std = @import("std");
const ZCoreError = @import("error.zig").ZCoreError;
const data = @import("data.zig");

pub const ir_schema = @import("ir_schema.zig");

test {
    _ = data;
    _ = ir_schema;
}

pub fn hello() []const u8 {
    return "hello from z_core";
}

pub fn codec_value(comptime value: anytype) ![]const u8 {
    const value_type = @TypeOf(value);
    if (!data.is_datatype(value_type)) {
        return ZCoreError.InvalidValueType;
    }
    // TODO: implement codec_value for all primitive datatype and a index for primitive data
    return std.fmt.allocPrint(std.heap.page_allocator, "{}", .{value});
}
