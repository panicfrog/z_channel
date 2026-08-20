const std = @import("std");
// only string bool int float null is considered primitive datatype
pub fn is_primitive_datatype(comptime value_type: type) bool {
    const info = @typeInfo(value_type);
    switch (info) {
        .int => |i| {
            // 暂时只支持 8. 16. 32. 64 位的类型
            if (i.bits != 8 and i.bits != 16 and i.bits != 32 and i.bits != 64) {
                return false;
            } else {
                return true;
            }
        },
        .float => |f| {
            // 暂时只支持 32. 64 位的类型
            if (f.bits != 32 and f.bits != 64) {
                return false;
            } else {
                return true;
            }
        },
        .bool, .null => return true,
        .pointer => |ptr| {
            if (ptr.size == .slice or ptr.size == .one) {
                return is_primitive_datatype(ptr.child);
            } else {
                return false;
            }
        },
        .array => |arr| {
            return arr.child == u8;
        },
        else => return false,
    }
}

pub fn is_datatype(comptime value_type: type) bool {
    const info = @typeInfo(value_type);
    switch (info) {
        .int => |i| {
            // 暂时只支持 8. 16. 32. 64 位的类型
            if (i.bits != 8 and i.bits != 16 and i.bits != 32 and i.bits != 64) {
                return false;
            } else {
                return true;
            }
        },
        .float => |f| {
            // 暂时只支持 32. 64 位的类型
            if (f.bits != 32 and f.bits != 64) {
                return false;
            } else {
                return true;
            }
        },
        .bool, .null => return true,
        .pointer => |ptr| {
            if (ptr.size == .slice or ptr.size == .one) {
                return is_datatype(ptr.child);
            } else {
                return false;
            }
        },
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (!is_datatype(field.type)) {
                    return false;
                }
            } else {
                return true;
            }
        },
        .array => |arr| {
            return is_datatype(arr.child);
        },
        .@"enum" => return true,
        .@"union" => |tu| {
            inline for (tu.fields) |field| {
                if (field.type == @TypeOf(null) or !is_datatype(field.type)) {
                    return false;
                }
            } else {
                return true;
            }
        },
        .optional => |opt| {
            return is_datatype(opt.child);
        },
        else => return false,
    }
}
// | 2B   | 2B    | 2B          | 2B     |
// | type | count | start_index | length |
// 1. null | 0 | 0 | 0 |
// 2. array | count | start_index | length |
// 3. some_single | 1 | start_index | length |
// null: 0, array: 1, some_single: 2
pub const DynamicDataIndex = union(enum) {
    null,
    array: struct {
        count: u16,
        start_index: u16,
        length: u16,
    },
    some_single: struct {
        start_index: u16,
        length: u16,
    },

    const Layout = extern struct {
        type_id: u16,
        count: u16,
        start_index: u16,
        length: u16,
    };

    pub fn data_encode(self: DynamicDataIndex) [64]u8 {
        var buf: [64]u8 = @splat(0);
        const header = std.mem.bytesAsValue(Layout, buf[0..8]);

        switch (self) {
            .null => {},
            .array => |arr| {
                header.* = .{
                    .type_id = 1,
                    .count = arr.count,
                    .start_index = arr.start_index,
                    .length = arr.length,
                };
            },
            .some_single => |single| {
                header.* = .{
                    .type_id = 2,
                    .count = 0,
                    .start_index = single.start_index,
                    .length = single.length,
                };
            },
        }
        return buf;
    }
};

test "comptime is_primitive_datatype" {
    comptime {
        // 1. bool
        const a = true;
        try std.testing.expect(is_primitive_datatype(@TypeOf(a)));
        // 2. int
        const b = @as(i32, 5);
        try std.testing.expect(is_primitive_datatype(@TypeOf(b)));
        // 3. float
        const c = @as(f64, 3.14);
        try std.testing.expect(is_primitive_datatype(@TypeOf(c)));
        // 4. null
        const d = null;
        try std.testing.expect(is_primitive_datatype(@TypeOf(d)));
        // 5. string
        const e = "hello";
        try std.testing.expect(is_primitive_datatype(@TypeOf(e)));
        // 6. pointer
        const f = &a;
        try std.testing.expect(is_primitive_datatype(@TypeOf(f)));
    }
}

test "comptime is_datatype" {
    comptime {
        // 1. bool
        const a = true;
        try std.testing.expect(is_datatype(@TypeOf(a)));
        // 2. int
        const b = @as(i32, 5);
        try std.testing.expect(is_datatype(@TypeOf(b)));
        // 3. float
        const c = @as(f64, 3.14);
        try std.testing.expect(is_datatype(@TypeOf(c)));
        // 4. null
        const d = null;
        try std.testing.expect(is_datatype(@TypeOf(d)));
        // 5. string
        const e = "hello";
        try std.testing.expect(is_datatype(@TypeOf(e)));
        // 6. pointer
        const f = &a;
        try std.testing.expect(is_datatype(@TypeOf(f)));
        // 7. enum
        const MyEnum = enum {
            A,
            B,
        };
        try std.testing.expect(is_datatype(MyEnum));
        // 8. tagged union
        const MyUnion = union(enum) {
            A: i32,
            B: struct {
                x: f64,
                y: f64,
            },
        };
        try std.testing.expect(is_datatype(MyUnion));
        // 9. struct
        const MyStruct = struct {
            a: i32,
            b: f64,
        };
        try std.testing.expect(is_datatype(MyStruct));
        // 10. array
        const MyArray = [5]i32;
        try std.testing.expect(is_datatype(MyArray));
        // 11. optional
        const MyOptional = ?i32;
        try std.testing.expect(is_datatype(MyOptional));

        // 12. non-datatype: function
        const helpers = struct {
            fn sub(x: i32, y: i32) i32 {
                return x - y;
            }
        };
        const MyFunction = @TypeOf(helpers.sub);
        try std.testing.expect(!is_datatype(MyFunction));
    }
}

test "DynamicDataIndex encode" {
    comptime {
        // 当前测试基于小端字节序，确保在小端系统上运行测试。目前使用macos系统
        var index: DynamicDataIndex = .null;
        var buf = index.data_encode();
        try std.testing.expectEqual(buf[0..8].*, [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 });

        index = .{ .array = .{ .count = 5, .start_index = 10, .length = 20 } };
        buf = index.data_encode();
        try std.testing.expectEqual(buf[0..8].*, [_]u8{ 1, 0, 5, 0, 10, 0, 20, 0 });

        index = .{ .some_single = .{ .start_index = 15, .length = 25 } };
        buf = index.data_encode();
        try std.testing.expectEqual(buf[0..8].*, [_]u8{ 2, 0, 0, 0, 15, 0, 25, 0 });

        // 测试超过 255 的值，验证大小端字节序
        // 256 = 0x0100, 512 = 0x0200, 1000 = 0x03E8, 65535 = 0xFFFF
        index = .{ .array = .{ .count = 256, .start_index = 512, .length = 1000 } };
        buf = index.data_encode();
        try std.testing.expectEqual(buf[0..8].*, [_]u8{ 1, 0, 0, 1, 0, 2, 0xe8, 0x03 });

        index = .{ .some_single = .{ .start_index = 65535, .length = 300 } };
        buf = index.data_encode();
        // 65535 = 0xFFFF -> [0xFF, 0xFF], 300 = 0x012C -> [0x2C, 0x01]
        try std.testing.expectEqual(buf[0..8].*, [_]u8{ 2, 0, 0, 0, 0xff, 0xff, 0x2c, 0x01 });
    }
}
