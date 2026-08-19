const std = @import("std");

pub const ZCoreError = error{
    InvalidValueType,
};

pub fn codec_value(comptime value: anytype) ![]const u8 {
    const value_type = @TypeOf(value);
    if (!is_datatype(value_type)) {
        return ZCoreError.InvalidValueType;
    }
    // TODO: implement codec_value for all primitive datatype and a index for primitive data
    return std.fmt.allocPrint(std.heap.page_allocator, "{}", .{value});
}

// only string bool int float null is considered primitive datatype
pub fn is_primitive_datatype(comptime value_type: type) bool {
    const info = @typeInfo(value_type);
    switch (info) {
        .bool, .int, .float, .null => return true,
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
        .bool, .int, .float, .null => return true,
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
