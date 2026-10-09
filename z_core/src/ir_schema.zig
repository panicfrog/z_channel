const std = @import("std");
const data = @import("data.zig");
const z_error = @import("error.zig");

pub const IR = union(enum) {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    bool,
    string,
    object: struct { data: std.AutoHashMap([]u8, IR) },
    array: struct { data: []const IR },
    optional: struct { data: *const IR },

    /// 从 Zig 类型构建 IR 描述。仅处理可静态映射的类型；
    /// struct / enum / tagged union 暂无对应 IR 节点，返回 InvalidValueType。
    pub fn build(comptime data_type: type) z_error.ZCoreError!IR {
        if (!data.is_datatype(data_type)) {
            return z_error.ZCoreError.InvalidValueType;
        }
        return switch (@typeInfo(data_type)) {
            .int => |i| blk: {
                const tag: ?[]const u8 = switch (i.bits) {
                    8 => if (i.signedness == .signed) "i8" else "u8",
                    16 => if (i.signedness == .signed) "i16" else "u16",
                    32 => if (i.signedness == .signed) "i32" else "u32",
                    64 => if (i.signedness == .signed) "i64" else "u64",
                    else => null,
                };
                if (tag == null) break :blk z_error.ZCoreError.InvalidValueType;
                break :blk @unionInit(IR, tag.?, {});
            },
            .float => |f| blk: {
                const tag: ?[]const u8 = switch (f.bits) {
                    32 => "f32",
                    64 => "f64",
                    else => null,
                };
                if (tag == null) break :blk z_error.ZCoreError.InvalidValueType;
                break :blk @unionInit(IR, tag.?, {});
            },
            .bool => IR{ .bool = {} },
            .pointer => blk: {
                if (isString(data_type)) break :blk IR{ .string = {} };
                // TODO: 数组指针、非字符串 slice（映射到 .array）
                break :blk z_error.ZCoreError.InvalidValueType;
            },
            .optional => |o| blk: {
                const child = try IR.build(o.child);
                break :blk IR{ .optional = .{ .data = &child } };
            },
            .array => |arr| blk: {
                const child = try IR.build(arr.child);
                break :blk IR{ .array = .{ .data = &[_]IR{child} } };
            },
            // struct / enum / tagged union / null 暂无对应 IR 节点
            else => z_error.ZCoreError.InvalidValueType,
        };
    }
};

pub fn isString(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const ptr = info.pointer;
    if (ptr.size == .slice) {
        return ptr.child == u8;
    }
    if (ptr.size == .one) {
        const child_info = @typeInfo(ptr.child);
        if (child_info == .array) {
            return child_info.array.child == u8;
        }
    }
    return false;
}

test "IR.build primitive types" {
    comptime {
        try std.testing.expectEqual(IR.u8, try IR.build(u8));
        try std.testing.expectEqual(IR.i8, try IR.build(i8));
        try std.testing.expectEqual(IR.u64, try IR.build(u64));
        try std.testing.expectEqual(IR.f32, try IR.build(f32));
        try std.testing.expectEqual(IR.f64, try IR.build(f64));
        try std.testing.expectEqual(IR.bool, try IR.build(bool));
    }
}

test "IR.build composite types" {
    comptime {
        // 字符串字面量 *const [5:0]u8
        try std.testing.expectEqual(IR.string, try IR.build(@TypeOf("hello")));
        // slice 字符串
        try std.testing.expectEqual(IR.string, try IR.build([]const u8));
        // optional
        const opt = try IR.build(?i32);
        try std.testing.expect(opt == .optional);
        try std.testing.expectEqual(IR.i32, opt.optional.data.*);
        // 数组：元素 IR 装在 data 切片里
        const arr = try IR.build([5]f32);
        try std.testing.expect(arr == .array);
        try std.testing.expectEqual(IR.f32, arr.array.data[0]);
    }
}

test "IR.build rejects unsupported types" {
    comptime {
        const MyStruct = struct { a: i32 };
        try std.testing.expectError(z_error.ZCoreError.InvalidValueType, IR.build(MyStruct));
        const MyFunction = fn (i32) i32;
        try std.testing.expectError(z_error.ZCoreError.InvalidValueType, IR.build(MyFunction));
    }
}

test "isString" {
    comptime {
        try std.testing.expect(isString([]const u8));
        try std.testing.expect(isString([]u8));
        try std.testing.expect(isString(@TypeOf("hello")));
        try std.testing.expect(!isString([]const i32));
        try std.testing.expect(!isString(u8));
        try std.testing.expect(!isString(*i32));
    }
}
