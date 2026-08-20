const std = @import("std");
const ZCoreError = @import("error.zig").ZCoreError;
const data = @import("data.zig");

pub fn codec_value(comptime value: anytype) ![]const u8 {
    const value_type = @TypeOf(value);
    if (!data.is_datatype(value_type)) {
        return ZCoreError.InvalidValueType;
    }
    // TODO: implement codec_value for all primitive datatype and a index for primitive data
    return std.fmt.allocPrint(std.heap.page_allocator, "{}", .{value});
}
