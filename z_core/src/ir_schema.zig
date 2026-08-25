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
    array: struct { data: []IR },
    optional: struct { data: IR },

    pub fn build(data_type: type) !IR {
        const info = @typeInfo(data_type);
        if (!data.is_datatype(data_type)) {
            return z_error.ZCoreError.InvalidValueType;
        }
        return switch (info) {
            .int => |i| {
                return switch (.{ i.bits, i.signedness }) {
                    .{ 8, .unsigned } => IR.u8,
                    .{ 8, .signed } => IR.i8,
                    .{ 16, .unsigned } => IR.u16,
                    .{ 16, .signed } => IR.i16,
                    .{ 32, .unsigned } => IR.u32,
                    .{ 32, .signed } => IR.i32,
                    .{ 64, .unsigned } => IR.u64,
                    .{ 64, .signed } => IR.i64,
                    else => z_error.ZCoreError.InvalidValueType,
                };
            },
            .float => |f| {
                return switch (f.bits) {
                    32 => IR.f32,
                    64 => IR.f64,
                    else => z_error.ZCoreError.InvalidValueType,
                };
            },
            .bool => IR.bool,
            .pointer => {
                if (isString(data_type)) {
                    return .string;
                } else {
                    return z_error.ZCoreError.InvalidValueType;
                }
                // TODO: 数组指针
            },
            .optional => |o| {
                return .optional{ .data = IR.build(o.child) };
            },
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
            return child_info.Array.child == u8;
        }
    }
    return false;
}
