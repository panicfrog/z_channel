const std = @import("std");

const Value = union(enum) {
    u8: struct { index: u16 },
    u16: struct { index: u16 },
    u32: struct { index: u16 },
    u64: struct { index: u16 },
    i8: struct { index: u16 },
    i16: struct { index: u16 },
    i32: struct { index: u16 },
    i64: struct { index: u16 },
    f32: struct { index: u16 },
    f64: struct { index: u16 },
    bool: struct { index: u16 },
    string: struct { index: u16, length: u16 },
    object: struct { index: u16, length: u16, data: std.AutoHashMap([]u8, Value) },
    array: struct { index: u16, length: u16, data: []Value },
    optional: struct { index: u16, data: ?Value },

    fn get_index(self: Value) u16 {
        switch (self) {
            inline else => |v| return v.index,
        }
    }

    fn get_length(self: Value) u16 {
        switch (self) {
            .u8 => return 1,
            .u16 => return 2,
            .u32 => return 4,
            .u64 => return 8,
            .i8 => return 1,
            .i16 => return 2,
            .i32 => return 4,
            .i64 => return 8,
            .f32 => return 4,
            .f64 => return 8,
            .bool => return 1,
            .string,
            .object,
            .array,
            => |s| {
                return s.length;
            },
            .optional => |o| {
                return o.data.?.get_length() orelse 1;
            },
        }
    }
};
