# ZigPack：零拷贝跨语言二进制序列化格式

> **状态**：设计草稿，待技术评审
> **版本**：v0.3（性能修订：字符串去间接层、槽序声明顺序、View 缓存 pool 基址、uniform 数组 32B 对齐）
> **作者**：待填写
> **日期**：2026-08-14

---

## 目录

1. [背景与目标](#1-背景与目标)
2. [核心约束](#2-核心约束)
3. [整体架构](#3-整体架构)
4. [二进制格式规范](#4-二进制格式规范)
5. [值编码策略](#5-值编码策略)
6. [Zig comptime 代码生成](#6-zig-comptime-代码生成)
7. [跨语言访问器生成](#7-跨语言访问器生成)
8. [SIMD 优化策略](#8-simd-优化策略)
9. [模块结构](#9-模块结构)
10. [设计决策汇总](#10-设计决策汇总)
11. [与同类方案对比](#11-与同类方案对比)
12. [待评审问题](#12-待评审问题)

---

## 1. 背景与目标

### 问题

现有跨语言数据交换方案存在性能或易用性权衡：

| 方案 | 问题 |
|---|---|
| JSON（文本） | 解析慢，内存占用大，数值精度损失 |
| Protobuf / MessagePack | 需要完整反序列化拷贝，访问前必须解码 |
| FlatBuffers | 格式复杂，IDL 独立维护，与语言生态割裂 |
| 共享内存（手写） | 每次都要重新定义布局，缺乏类型安全 |

### 目标

设计一个名为 **ZigPack** 的底层库，实现：

1. **零拷贝读取**：数据序列化后直接通过指针传递，无需反序列化
2. **跨语言 FFI**：Zig、Swift、Kotlin、TypeScript 通过生成的访问器直接读取同一块内存
3. **类型安全**：Schema 在 Zig 原生 struct 中定义，各语言访问器由编译期自动生成
4. **高性能**：充分利用 CPU 缓存友好布局与自动 SIMD 向量化
5. **JSON 兼容类型系统**：支持 null、bool、int、float、string、array、object/map

---

## 2. 核心约束

- **不可变数据**：序列化后的 buffer 为只读，不支持原地修改
- **最多一次拷贝**：buffer 从 Zig 传递给其他语言运行时时允许最多一次内存拷贝，之后只读
- **纯相对偏移**：buffer 内部不含任何绝对指针，可 mmap、可落盘、可网络传输
- **Schema 驱动**：主路径（schema-typed）的所有字段偏移在编译期确定，无运行时查找开销
- **可选动态路径**：提供类 JSON 的动态类型（ZValue tape），用于非 schema 场景

---

## 3. 整体架构

```
┌──────────────────────────────────────────────────────────────┐
│                       开发时（构建期）                        │
│                                                              │
│  Person struct (Zig)                                         │
│       │                                                      │
│       ▼ std.meta.fields() — comptime                         │
│  LayoutMeta（字段分组、偏移计算、VOT 索引）                  │
│       │                                                      │
│       ├──▶ Writer（序列化器，comptime 生成）                 │
│       ├──▶ View（零拷贝访问器，comptime 生成）               │
│       └──▶ SchemaDescriptor（构建产物）                      │
│                │                                             │
│                ▼ codegen 构建步骤（Zig 可执行文件）           │
│           PersonView.swift / PersonView.kt                   │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│                         运行时                               │
│                                                              │
│  writer.write(person) ──▶ []const u8 buffer                  │
│                                                              │
│  ┌── FFI ──────────────────────────────────────────────┐    │
│  │  传递：(ptr: *anyopaque, len: usize)  ← 唯一允许的拷贝 │   │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  Zig View.init(buf)    ──▶ view.id()      单条 load 指令     │
│  Swift PersonView(buf) ──▶ view.id        单条 load 指令     │
│  Kotlin PersonView(buf)──▶ view.id        JIT inline load    │
└──────────────────────────────────────────────────────────────┘
```

---

## 4. 二进制格式规范

### 4.1 Buffer 总体结构

```
Offset  大小   内容
──────  ─────  ──────────────────────────────────────
0       16B    Buffer Header（固定，位置无关的元数据）
16      var    String Pool（8B 对齐）
?       var    Root Struct 或 ZValue Tape（8B 对齐）
```

所有偏移均为相对于 `buf[0]` 的字节偏移量（u32，最大支持 4GiB buffer）。

---

### 4.2 Buffer Header（16 字节）

```
Offset  大小  字段             说明
──────  ────  ──────────────   ───────────────────────────────
0       4B    magic            0x5A504B31（"ZPK1"）版本魔数
4       1B    version          当前 = 1
5       1B    flags            bit0: has_string_pool
                               bit1: has_value_tape（动态路径）
                               bit2: little_endian（当前始终为 1）
                               bit3: schema_typed（主路径标志）
6       2B    reserved         必须为 0
8       4B    string_pool_off  Buffer Header 到 String Pool 起点的偏移
12      4B    root_off         Buffer Header 到 Root Struct/Tape 起点的偏移
```

---

### 4.3 String Pool

**设计动机**：结构化数据中字符串高度重复（字段名、枚举值、固定标签）；集中存储便于去重；NUL 结尾与 C FFI（Swift `String(cString:)`、Kotlin `NewStringUTF`）直接兼容。

```
Offset  大小                内容
──────  ──────────────────  ──────────────────────────────────
0       4B                  pool_byte_len（字符串数据区总字节数）
4       4B                  string_count（仅 debug / 内省用）
8       pool_byte_len B     pool_data[]：紧密排列的 NUL 结尾 UTF-8 字符串
```

**字符串偏移（string_off）**：值槽中**直接**存储该字符串在 `pool_data` 内的字节偏移（u32），没有中间索引层。访问路径为一次 load：

```
string_off → pool_data[string_off]   （pool_data 基址由 View.init 缓存，见 6.4）
```

写入端 `StringInterner` 按插入顺序向 pool_data 追加字符串，偏移在插入时即确定（= 追加前的 pool_data 长度），因此写入值槽的偏移就是最终偏移，**无需序列化收尾 fixup**。

> v0.1–v0.2 曾使用 handle → index[] → pool_data 两级间接。该间接层在读取端零收益（去重发生在写入端），却使每次字符串访问多一次依赖 load，且 index[] 每字符串多耗 4B。v0.3 移除。

---

### 4.4 Schema-Typed Struct 布局

```
Offset  大小                        内容
──────  ─────────────────────────   ─────────────────────────────────────
0       8B                          Struct Header
                                      field_count_fixed: u16
                                      field_count_var:   u16
                                      schema_name_hash:  u32（fnv32a，debug 用）
8       field_count_fixed × 8B      Fixed Section（固定字段槽位区）
?       field_count_var × 4B        Variable Offset Table（VOT）
?       (pad to 8B)
?       variable data               内联的嵌套 struct / array 数据
```

> **关于 `schema_name_hash`**：从 16 位改为 32 位（FNV-32a of type name），仅用于 debug / 运行时 assert，**不作为安全校验**（碰撞概率 ~1/4B，校验严格性不足；如需严格校验应比较完整 type name 字符串）。32 位相比 16 位碰撞概率下降 65536 倍，误报率在调试场景可接受。

---

#### 字段分组规则（comptime 自动执行）

字段被分为两组：

**Fixed 组**（每个字段或每个打包槽占 8B）：

```
可进入 Fixed 组的字段类型：
  u64、i64、f64                          → 每字段独占一个 8B 槽
  u32、i32、f32、string_off              → 每字段独占一个 8B 槽（低4B存值，高4B=0）
  u16、i16、u8、i8、bool（非 optional）  → sub-word 类型，若干个共享一个 8B 槽（见 Step 2）
  ?u32、?i32、?f32、?string_off、?u16、?i16、?u8、?i8、?bool
                                         → optional 的 non-full-width 类型，
                                           独占一个 8B 槽（bit 63 做 null 标记，见 Step 3）

禁止进入 Fixed 组（必须进入 Variable 组）：
  ?u64、?i64、?f64                → full-width optional，8B 槽内无空余位置存 null 标记
  []T（任意 slice）               → 可变长度
  T（嵌套 struct）                → 可变长度
```

**Variable 组**（每字段在 VOT 中占一个 4B 相对偏移，`0xFFFF_FFFF` = null）：

```
嵌套 struct（包括 ?T 形式的 optional 嵌套 struct）
[]T（slice / array）
?u64、?i64、?f64（因 null 标记问题降级至此）
```

---

#### Fixed 组内的槽位分配规则

Fixed 组按以下规则排列，**所有决定在 comptime 完成，运行时无开销**：

**Step 1：独占槽字段分配（保持声明顺序）**

独占槽字段（`u64/i64/f64`、`u32/i32/f32/string_off` 及全部 non-full-width optional）按**声明顺序**依次分配 8B 槽，低位存值，高位补零。

理由：8B 等步长槽位下所有槽自然 8B 对齐，按类型大小排序没有任何对齐收益；保持声明顺序把 cache-line 局部性的控制权交给 schema 作者——高频字段排在前面即可挤进同一条 cache line（64B = 8 个槽），这是本设计缓存友好性的直接控制点。

**Step 2：sub-word 字段打包（仅非 optional）**

所有**非 optional** 的 `u16/i16/u8/i8/bool` 字段，在独占槽字段之后，按声明顺序**贪心装箱**进 8B 槽：

- 每个槽可容纳的字节位置：`byte 0..7`（共 8 字节）
- 按 **对齐边界** 将字段放入当前槽：u16 放 2B 对齐位置，u8/bool 放任意字节位置
- 当前槽装不下时，开启新槽
- **optional sub-word 字段不参与装箱**，一律独占 8B 槽、bit 63 做 null 标记（见 Step 3）——同一槽内多个 optional 无法共用 bit 63，必须独占
- 每个字段的字节偏移（相对所在槽起点）由 comptime 计算并记录在 FieldMeta 中

**Step 3：optional null 标记**

- non-full-width optional（`?u32`、`?u16`、`?u8`、`?bool` 等）：**bit 63 = 1** 表示 null，其余位存实际值。此方案对这些类型安全，因为：
  - `?u32`：低 32 位存值，bit 63 为 null 标记，中间 31 位置零，无冲突
  - `?u16/u8/bool`：值更小，高位空间更充裕
- full-width optional（`?u64`、`?i64`、`?f64`）：**降级至 Variable 组**，VOT 条目 = `0xFFFF_FFFF` 表示 null，有值时指向一个内联的 8B 数据块

---

#### sub-word 打包示例

Schema 片段：`active: bool, age: u8, score_int: u16, code: u8`

comptime 装箱过程：

```
槽 N（8B）:
  byte 0: active（bool，1B）
  byte 1: age（u8，1B）
  byte 2-3: score_int（u16，2B 对齐，放 byte2）
  byte 4: code（u8，1B）
  byte 5-7: 补零
```

访问 `age`：`*(u8*)(buf + struct_base + slot_N_offset + 1)` — 单条 load。
访问 `score_int`：`*(u16*)(buf + struct_base + slot_N_offset + 2)` — 单条 load。

所有字节偏移均为 comptime 常量，codegen 直接将偏移硬编码进访问器。

---

### 4.5 示例：Person struct 布局

Schema 定义：

```zig
const Person = struct {
    id:      u64,          // u64，独占槽
    score:   f32,          // f32，独占槽
    name:    []const u8,   // string，独占槽（string_off = u32，直接 pool 偏移）
    age:     u8,           // sub-word
    active:  bool,         // sub-word
    tags:    [][]const u8, // variable
    address: Address,      // variable（嵌套 struct）
    uid:     ?u64,         // optional full-width → variable
};
```

**comptime 分组结果**：

```
独占槽（Step 1，声明顺序）：
  id      → u64，槽 0
  score   → f32，槽 1（低4B，高4B=0）
  name    → string_off u32，槽 2（低4B，高4B=0）

sub-word 打包（Step 2，贪心装箱，仅非 optional）：
  age(u8) + active(bool) → 槽 3 的 byte0 + byte1，其余补零

Variable 组（VOT）：
  VOT[0] → tags
  VOT[1] → address
  VOT[2] → uid（?u64，full-width optional，0xFFFF_FFFF = null）
```

**内存布局**：

```
Offset  大小   内容
──────  ─────  ────────────────────────────────────────────────────
0       8B     Struct Header（field_count_fixed=4, field_count_var=3, schema_name_hash）
8       8B     Fixed 槽 0：id（u64，8B）
16      8B     Fixed 槽 1：score（f32，低4B；高4B = 0）
24      8B     Fixed 槽 2：name（string_off u32，低4B；高4B = 0）
32      8B     Fixed 槽 3：[byte0=age][byte1=active][byte2-7=0]
40      4B     VOT[0]：tags 相对本 struct 头的偏移
44      4B     VOT[1]：address 相对本 struct 头的偏移
48      4B     VOT[2]：uid 相对本 struct 头的偏移（0xFFFF_FFFF = null）
52      4B     (pad to 8B)
56      ?      tags array 数据（inline）
?       ?      address struct 数据（inline）
?       8B     uid 数据块（内联的 u64，仅当 VOT[2] ≠ 0xFFFF_FFFF 时存在）
```

**访问示例**：

```
// person.age — 单条 load（byte 偏移为 comptime 常量）
age = *(u8*)(buf + struct_base + 32 + 0)

// person.active — 单条 load
active = *(u8*)(buf + struct_base + 32 + 1) != 0

// person.score — 单条 load
score = *(f32*)(buf + struct_base + 16)

// person.name — 一次 load 得到 pool 偏移（pool_data 基址由 View 缓存）
str_ptr = pool_data + *(u32*)(buf + struct_base + 24)

// person.uid（?u64）— 读 VOT，判空，再读值
uid_vot = *(u32*)(buf + struct_base + 48)
if uid_vot == 0xFFFF_FFFF → null
else → *(u64*)(buf + struct_base + uid_vot)

// person.address.street — VOT + 固定槽 + 一次 load
addr_off   = *(u32*)(buf + struct_base + 44)
street_off = *(u32*)(buf + struct_base + addr_off + STREET_SLOT_OFFSET)
str_ptr    = pool_data + street_off
```

全程无分配，无哈希查找，无类型断言。所有偏移均为 comptime 常量。

---

### 4.6 Array 布局

```
Offset  大小                内容
──────  ──────────────────  ──────────────────────────────────
0       4B                  element_count: u32
4       2B                  element_type: u16（TypeTag 枚举值）
6       2B                  flags: u16（bit0: uniform）

[uniform scalar path，如 []f32、[]i64]
8       24B padding                数据区固定起始于数组头 +32（见下）
32      element_count × sizeof(T)  紧密排列的原始数据（32B 对齐）

[non-uniform / struct array path]
8       element_count × 4B          offset_table[]（各元素相对数组头偏移）
?       element data[]              各元素 inline struct 数据
```

**uniform 数组的 32B 对齐**：writer 将 uniform 数组头放置在 32B 相对对齐的位置（buffer 基地址的 32B 对齐由 allocator 保证，见 8），数据区固定从数组头 +32 开始——偏移是常量，访问器无需运行时计算；SIMD 循环可使用 aligned load，无 cache-line split。代价是每个 uniform 数组固定 24B padding（性能优先于体积的取舍）。

**uniform 标志的意义**：标记为 uniform 的数组，其数据区是一段连续的同类型标量，访问器直接返回对应 Zig/C/Swift slice，调用方可以直接 SIMD 处理，无任何 per-element 开销。

---

## 5. 值编码策略

### 5.1 动态值（ZValue Tape，可选路径）

用于非 schema 的动态 JSON-like 数据。每个值固定 8 字节：

```
Bits 63..56   Bits 55..32   Bits 31..0
┌───────────┬─────────────┬──────────────┐
│  TYPE_TAG │   AUX/LEN   │   PAYLOAD    │
│  (8 bits) │  (24 bits)  │  (32 bits)   │
└───────────┴─────────────┴──────────────┘
```

TYPE_TAG 值定义：

```
0x00  Null
0x01  False  / 0x02  True
0x12  Int32（payload = i32 值）
0x13  Int64（下一个 8B 存 i64 值，共 16B）
0x14..0x17  UInt 系列
0x20  Float32（payload = f32 bits）
0x21  Float64（下一个 8B 存 f64 值，共 16B）
0x30  String（payload = pool_data 内偏移 u32）
0x40  Array（payload = 相对 tape 起点的偏移）
0x50  Object（payload = 相对 tape 起点的偏移）
```

Int64 和 Float64 占用连续两个 8B 槽（共 16B），类型标签始终在首个槽，便于线性扫描时 O(1) 跳过。

### 5.2 Schema-Typed 固定槽（不存类型标签）

Schema-typed 路径的固定槽不存储类型标签，类型在 comptime 已知。每个固定字段的访问器编译为特定类型的单条 load，完全消除运行时类型检查分支。

---

## 6. Zig comptime 代码生成

### 6.1 核心 API

```zig
// 消费侧用法
const PersonSchema = ZigPack.schema(Person);

// 序列化（发生一次）
var writer = PersonSchema.Writer.init(allocator);
const buf: []const u8 = try writer.write(person_value);

// 零拷贝读取（Zig 侧）
const view = PersonSchema.View.init(buf);
const id     = view.id();        // 单条 load，comptime 偏移
const name   = view.name();      // 返回 []const u8 slice，指向 string pool，无拷贝
const addr   = view.address();   // 返回 View(Address)，两条 load，无拷贝
const tags   = view.tags();      // 返回 ArrayView，无拷贝

// 跨语言 FFI 传递（唯一一次拷贝）
const ptr: *anyopaque = buf.ptr;
const len: usize      = buf.len;
```

### 6.2 comptime 布局计算

```zig
// 伪代码展示 comptime 信息流
fn computeLayout(comptime T: type) LayoutMeta {
    comptime {
        const fields = std.meta.fields(T);  // comptime-only 操作

        // 1. 分组：fixed（标量 + string_off）vs variable（slice、嵌套 struct）
        // 2. fixed 组：独占槽字段按声明顺序分配 8B 槽；sub-word 字段贪心装箱
        // 3. variable 组：按定义顺序分配 vot_index
        // 4. 计算 vot_start_offset = 8 + field_count_fixed * 8
        // 5. 返回 []FieldMeta（comptime 常量数组）
    }
}
```

`std.meta.fields(T)` 在 comptime 返回 `[]const std.builtin.Type.StructField`。整个布局计算过程在编译期完成，运行时无任何开销。

### 6.3 Writer（序列化器）生成

```zig
fn generateWriter(comptime T: type) type {
    const Layout = computeLayout(T);
    return struct {
        buf:          std.ArrayList(u8),
        string_pool:  StringInterner,   // 写入时对字符串去重；intern() 返回该字符串
                                       // 在 pool_data 中的最终偏移（插入时确定，无需 fixup）

        pub fn write(self: *@This(), value: T) ![]const u8 {
            // comptime inline for：编译器为每个字段展开代码，无循环
            inline for (Layout.fixed_fields) |fm| {
                const v = @field(value, fm.name);
                try self.writeFixedSlot(fm.byte_offset, v);
            }
            inline for (Layout.variable_fields) |fm| {
                const v = @field(value, fm.name);
                const rel_off = self.buf.items.len - self.struct_start;
                try self.writeVotEntry(fm.vot_index, @intCast(u32, rel_off));
                try self.writeChild(v);
            }
        }
    };
}
```

`inline for` 强制 LLVM 为每个字段特化代码，消除运行时分支和虚函数调用。

### 6.4 View（零拷贝访问器）生成

```zig
fn generateView(comptime T: type) type {
    const Layout = computeLayout(T);
    return struct {
        buf:  [*]const u8,   // 裸指针，不拥有数据
        base: u32,           // 本 struct 在 buffer 中的起点偏移
        pool: u32,           // pool_data 基址偏移（init 时从 header 读取一次并缓存）

        // comptime 为每个 fixed 字段生成一个访问函数
        // 例如 id() → @as(u64, @bitCast(buf[base + 8 ..][0..8].*))
        // 编译为：mov rax, [rdi + base_const + 8]  （单条指令）

        // 字符串字段：1 次 load 得到 pool 偏移，pool 基址已缓存，无拷贝
        // pub fn name(self: @This()) []const u8 { ... }

        // 嵌套 struct：返回子 View，2 条 load，无拷贝
        pub fn address(self: @This()) generateView(Address) {
            const child_off = readU32(self.buf, self.base + Layout.vot_start + 4 * 1);
            return generateView(Address){ .buf = self.buf, .base = self.base + child_off, .pool = self.pool };
        }

        // Uniform array：返回 []const f32 slice，调用方直接 SIMD 处理
        pub fn scores(self: @This()) []const f32 {
            const arr_off = readU32(self.buf, self.base + Layout.vot_start + 4 * 0);
            const arr_ptr = self.buf + self.base + arr_off;
            const count   = readU32(arr_ptr, 0);
            // 数据区固定位于数组头 +32（32B 对齐，见 4.6）
            return @as([*]const f32, @ptrCast(@alignCast(arr_ptr + 32)))[0..count];
        }
    };
}
```

View 类型仅包含三个字段（指针 + struct 偏移 + pool 基址），按值传递开销极低；缓存 pool 基址使每次字符串访问省去一次 header load。

---

## 7. 跨语言访问器生成

### 7.1 生成流程

```
Zig 构建步骤（b.addRunArtifact）
  输入：SchemaDescriptor（comptime 导出的 JSON 文件）
  输出：PersonView.swift、PersonView.kt、PersonView.ts

SchemaDescriptor 内容：
  type_name、schema_name_hash、field_count_fixed、vot_start
  每个字段：name、type_tag、byte_offset 或 vot_index、nullable
```

### 7.2 Swift 访问器（示例）

```swift
// AUTO-GENERATED — do not edit
// Source schema: Person (schema_name_hash: 0x9C3F1A2B)

import Foundation

public struct PersonView {
    private let buf: UnsafeRawBufferPointer
    private let base: Int
    private let poolData: Int   // pool_data 基址，init 时算好并缓存

    public init(_ buffer: UnsafeRawBufferPointer, base: Int = 0) {
        self.buf = buffer
        self.base = base
        let poolOff = Int(buffer.load(fromByteOffset: 8, as: UInt32.self))
        self.poolData = poolOff + 8
    }

    // Fixed field: id (u64) at base+8
    public var id: UInt64 {
        buf.load(fromByteOffset: base + 8, as: UInt64.self)
        // 编译为：ldr x0, [x0, #8]（单条 ARM64 指令）
    }

    // Fixed field: age (u8) at base+32, byte 0
    public var age: UInt8 {
        buf.load(fromByteOffset: base + 32, as: UInt8.self)
    }

    // Fixed field: score (f32) at base+16
    public var score: Float {
        Float(bitPattern: buf.load(fromByteOffset: base + 16, as: UInt32.self))
    }

    // Fixed field: name (string) at base+24 — 一次 load + 一次拷贝
    public var name: String {
        let strOff = buf.load(fromByteOffset: base + 24, as: UInt32.self)
        return String(cString: buf.baseAddress!.advanced(by: poolData + Int(strOff)))
        // 注：String(cString:) 在此处发生一次拷贝（Swift 内存安全要求）
    }

    // Variable field: address (nested struct) — VOT index 1
    public var address: AddressView {
        let childOff = buf.load(fromByteOffset: base + VOT_START + 4, as: UInt32.self)
        return AddressView(buf, base: base + Int(childOff))
    }

    // Variable field: uid (optional u64) — VOT index 2，0xFFFF_FFFF = null
    public var uid: UInt64? {
        let off = buf.load(fromByteOffset: base + VOT_START + 8, as: UInt32.self)
        guard off != 0xFFFF_FFFF else { return nil }
        return buf.load(fromByteOffset: base + Int(off), as: UInt64.self)
    }

    private static let VOT_START = 40  // 由 codegen 填入
}
```

### 7.3 Kotlin 访问器（示例）

使用 `java.nio.ByteBuffer`（direct/off-heap）：GC 不管理 buffer 内存，无 GC 压力。

```kotlin
// AUTO-GENERATED — do not edit
// Source schema: Person (schema_name_hash: 0x9C3F1A2B)

class PersonView(private val buf: java.nio.ByteBuffer, private val base: Int = 0) {

    // pool_data 基址，构造时算好并缓存
    private val poolData: Int

    init {
        buf.order(java.nio.ByteOrder.LITTLE_ENDIAN)
        poolData = buf.getInt(8) + 8
    }

    // Fixed field: id (u64) at base+8
    val id: Long get() = buf.getLong(base + 8)
    // JIT 内联后等价于单条 native load 指令

    // Fixed field: age (u8) at base+32
    val age: Int get() = buf.get(base + 32).toInt() and 0xFF

    // Fixed field: score (f32) at base+16
    val score: Float get() = java.lang.Float.intBitsToFloat(buf.getInt(base + 16))

    // Variable field: uid (optional u64) — VOT index 2，0xFFFF_FFFF = null
    val uid: Long? get() {
        val off = buf.getInt(base + VOT_START + 8)
        if (off == -1) return null   // 0xFFFF_FFFF
        return buf.getLong(base + off)
    }

    // Variable field: address — VOT index 1
    val address: AddressView get() {
        val off = buf.getInt(base + VOT_START + 4)
        return AddressView(buf, base + off)
        // AddressView 对象在 JVM 堆分配，但字段数据仍在 off-heap buffer
    }

    companion object {
        private const val VOT_START = 8 + 4 * 8  // 由 codegen 填入
    }
}
```

### 7.4 各语言字段访问开销对比

```
语言        标量字段          字符串字段              嵌套 struct
────────    ─────────────     ────────────────────    ─────────────────
Zig         1 load            1 load（无拷贝）         2 load + 子base
Swift       1 load            1 load + 1 copy         2 load
Kotlin      1 JIT load        1 JIT load + 1 copy     2 JIT load + 1 alloc
TypeScript  DataView.getXxx   TextDecoder + copy      递归调用
```

字符串是唯一必然发生拷贝的数据类型（Swift 内存安全、JVM 堆模型要求）。所有标量字段和嵌套结构均可真正零拷贝访问。

---

## 8. SIMD 优化策略

ZigPack 在以下四个位置利用 SIMD：

### 8.1 写入时：字符串去重（String Interning）

写入字符串时需要在 String Pool 中查找是否已存在相同字符串。Pool 的 `pool_data` 区是紧密排列的 NUL 结尾字符串序列，可用 SIMD 加速边界检测：

```zig
// Stage 1：用 16-wide NUL 扫描找到所有字符串边界
const Vec = @Vector(16, u8);
const nul_vec: Vec = @splat(0);
// 每次处理 16B，检测 NUL 位置，记录字符串起点
// 等效于 simdjson Stage 1 的 structural character detection

// Stage 2：对候选字符串做 16-wide 向量比较
// needle.len <= 16 时：单次 VPCMPEQB + PMOVMSKB 完成比较
```

### 8.2 读取时：Uniform Array 的 SIMD 处理

Uniform scalar array 的 `scores()` 访问器直接返回 `[]const f32` slice。调用方的 `inline for` 循环由 Zig/LLVM 自动向量化：

```zig
// 调用方代码（用户写的）
const arr = view.scores();
var sum: f32 = 0;
for (arr) |v| sum += v;
// LLVM 自动生成 AVX2 VADDPS（每次处理 8 个 f32）
// 前提：buffer 基地址 32B 对齐（allocator 硬性保证），
//       uniform 数组数据区 32B 相对对齐（见 4.6），可用 aligned load
```

### 8.3 读取时：动态对象字段查找

动态（ZValue tape）路径中，在大型 object 中按名查找字段时，同样用 Stage1/Stage2 两阶段 SIMD 扫描 String Pool。Schema-typed 路径不需要此优化（偏移全部为 comptime 常量）。

### 8.4 Buffer 跨语言传递时的 memcpy

当 buffer 需要跨进程或网络传输时，连续内存布局保证了一次大块 `memcpy`（而非分散拷贝），触发 x86 `REP MOVSB` / ARM64 `LD1-ST1` 向量化路径，接近内存带宽上限。

### 对齐要求

- Buffer allocator 统一保证 **32B 对齐**（v0.3 起为硬性要求）：这是 uniform 数组数据区 32B 相对对齐的前提，同时覆盖所有字段的自然对齐需求
- Uniform 数组数据区固定从数组头 +32 开始（见 4.6），SIMD 循环无 cache-line split
- 若外语侧 FFI 只能保证 8B 对齐（如 JVM direct ByteBuffer），uniform 数组退化为 unaligned load（现代 CPU 上惩罚很小），标量路径不受影响

---

## 9. 模块结构

```
z_channel/
├── z_core/src/
│   ├── root.zig           对外重导出
│   ├── format.zig         常量：magic、TypeTag 枚举、Header struct
│   ├── layout.zig         comptime 布局计算（FieldMeta、computeLayout）
│   ├── writer.zig         comptime Writer 生成（序列化器）
│   ├── view.zig           comptime View 生成（零拷贝访问器）
│   ├── string_pool.zig    StringInterner（写）+ StringPoolView（读）
│   ├── array.zig          ArrayWriter + ArrayView
│   ├── value.zig          ZValue 动态 tape（可选路径）
│   └── simd.zig           SIMD 辅助函数（NUL 扫描、向量比较）
│
├── z_lib/src/
│   ├── root.zig           公共 API：ZigPack.schema()、ZigPack.dynamic()
│   └── codegen/
│       ├── descriptor.zig SchemaDescriptor 类型 + comptime 导出
│       ├── swift_gen.zig  Swift 访问器代码生成器
│       └── kotlin_gen.zig Kotlin 访问器代码生成器
│
└── example/src/
    └── main.zig           使用示例：定义 schema → 序列化 → 零拷贝读取
```

构建流程：

```
build.zig.zon 声明 workspace
  → z_core（无外部依赖）
  → z_lib（依赖 z_core）
  → example（依赖 z_lib）

z_lib/build.zig 添加构建步骤：
  b.addRunArtifact(codegen_exe)  → 生成 Swift/Kotlin 访问器源文件
  （仅当 SchemaDescriptor 哈希变化时重新生成）
```

---

## 10. 设计决策汇总

| 决策 | 选择 | 理由 |
|---|---|---|
| 偏移方式 | 纯相对偏移（u32） | Position-independent，可 mmap / 落盘 / 跨进程 |
| 字符串存储 | 集中 String Pool + u32 直接偏移 | 去重、NUL 结尾与 C FFI 兼容、单次 load 访问（无 index 间接层，v0.3 移除） |
| 固定字段布局 | comptime 计算偏移，8B 等步长槽，保持声明顺序 | O(1) 单 load；声明顺序让 schema 作者控制 cache line 局部性（8B 等步长下按大小排序无对齐收益） |
| sub-word 打包 | 贪心装箱进 8B 槽，按对齐边界排列 | 节省空间的同时保持 comptime 可计算的确定性偏移 |
| optional null 标记（≤32 位类型） | bit 63 of 8B slot | 无额外 bitmap，单次 AND+branch，不影响值精度 |
| optional null 标记（u64/i64/f64） | 降级至 Variable 组，VOT = 0xFFFF_FFFF | bit 63 被值本身占满，无空余位，必须外置 null 标记 |
| schema_name_hash | u32 FNV-32a hash，仅供 debug assert | 16 位碰撞率过高；u32 降至可接受；不作安全校验 |
| 可变字段导航 | Variable Offset Table (VOT) | O(1) 定位，VOT 本身 comptime 已知 |
| 数组格式 | uniform/non-uniform 双路径 | uniform 路径支持直接 SIMD slice |
| uniform 数组对齐 | 数据区固定 32B 对齐（数组头 +32） | SIMD aligned load 无 cache-line split；代价 ≤24B/数组 padding（性能优先于体积） |
| 访问器上下文 | View{buf, base, pool} 三字 | init 缓存 pool 基址，每次字符串访问省一次 header load |
| 动态类型 | 可选 ZValue tape | 仅在需要动态 JSON-like 数据时引入，主路径无开销 |
| **Schema 演化** | **v1 不支持（有意识取舍）** | **见下文说明** |
| Schema 定义 | Zig 原生 struct + comptime | 无 IDL 文件，类型系统统一，无阻抗失配 |
| 外语代码生成 | 构建时 codegen（Zig 可执行文件） | IDE 友好（有类型、有补全），无运行时反射开销 |
| Swift 实现方式 | UnsafeRawBufferPointer + Macro | 与 Swift 类型系统融合，访问器代码简洁 |
| Kotlin 实现方式 | ByteBuffer（direct/off-heap） | 无 GC 压力，JIT 可 inline 为单条 load |

### Schema 演化的立场

ZigPack v1 **不支持**在同一 buffer 格式内进行 schema 演化（新增/删除/重排字段）。这是一个**有意识的取舍**，不是遗漏：

- 所有字段偏移在 comptime 固化，任何 schema 变更都会导致二进制不兼容
- 收益：每个字段访问是真正的单条 load，无 vtable 跳转，无 presence 检查
- 代价：生产者和消费者必须使用完全相同的 schema 版本
- **适用场景**：同一代码库内不同语言组件（共享同一套 schema 定义，统一编译部署）；短生命周期的进程间消息（消息不落盘）
- **不适用场景**：需要长期落盘存储、需要滚动升级（不同版本客户端同时存在）

如未来需要演化能力，可在 v2 引入可选的 FlatBuffers 风格 vtable（`field_present_bitmap` + 间接寻址），作为独立的 schema mode，不影响 v1 的零开销路径。

---

## 11. 与同类方案对比

| 特性 | ZigPack | Protobuf | FlatBuffers | Cap'n Proto | MessagePack |
|---|---|---|---|---|---|
| 零拷贝读取 | ✅ | ❌（需解码） | ✅ | ✅ | ❌（需解码） |
| Schema 在语言原生定义 | ✅（Zig struct） | ❌（.proto IDL） | ❌（.fbs IDL） | ❌（.capnp IDL） | ❌（无 schema） |
| 跨语言 FFI | ✅ | ✅（库支持） | ✅ | ✅ | ✅ |
| 字符串去重 | ✅（String Pool） | ❌ | ❌ | ❌ | ❌ |
| 自动 SIMD 数组 | ✅（uniform slice） | ❌ | 部分 | ❌ | ❌ |
| 运行时字段查找 | ❌（comptime 偏移） | N/A | ❌（vtable） | ❌（偏移表） | N/A |
| 编译期代码生成 | ✅（comptime） | ✅（protoc） | ✅（flatc） | ✅（capnpc） | ❌ |
| buffer 大小上限 | 4GiB（u32 偏移） | 无（流式） | 4GiB | 4GiB | 无 |

主要差异化：ZigPack 的 schema 直接在 Zig struct 中定义（无独立 IDL 文件），comptime 生成访问器与 Zig 类型系统无缝融合，同时通过 String Pool 提供跨字段的字符串去重能力。

---

## 12. 待评审问题

以下问题需要在技术评审中确认：

1. **字节序**：当前设计假设 little-endian（flags bit2 标记）。是否需要支持 big-endian 目标？如需支持，建议序列化时统一为 little-endian（与主流平台一致），读端在 big-endian 机器上做 byteswap，开销仅在读取时发生。

2. **u32 偏移上限（4GiB）**：是否有超过 4GiB 的单个 buffer 需求？如有，需改为 u64 偏移，代价是 VOT 条目和 string handle 各扩大一倍（每个从 4B 变为 8B）。

3. **嵌套 struct 内联 vs 引用**：当前设计将嵌套 struct 数据内联在父 struct 的 variable data 区。如果同一 Address 对象被多个 Person 引用，会产生重复数据。是否需要支持引用语义（VOT 条目指向 buffer 内任意位置而非仅父 struct 内部）？这会允许去重，但会增加指针追踪层数。

4. **String Pool 构建的内存使用**：序列化时 StringInterner 需要临时哈希表存储所有已见字符串。对于大量小对象的批量序列化，此哈希表的内存峰值是否可接受？是否需要提供"禁用去重"的快速路径选项？

5. **对齐保证与外语传递**：v0.3 起 allocator 需保证 **32B 对齐**（硬性要求）。通过 FFI 传递给外语时，需外语侧不把 buffer 复制到低对齐内存（JVM direct ByteBuffer 通常只保证 8/16B；Swift 手动分配可达 32B）。若外语侧只能保证 8B，uniform 数组 SIMD 退化为 unaligned load（现代 CPU 惩罚很小），标量路径不受影响。此降级策略是否可接受？

6. **TypeScript 路径**：`DataView` 的字段访问开销比原生高约 3-5 倍。是否考虑提供 WASM 桥接选项（由 Zig 编译到 WASM，通过 `wasm-bindgen` 风格 glue 暴露给 JS），以在 TS 侧获得接近原生的性能？

7. **动态路径（ZValue tape）的优先级**：是否有在 v1 中支持动态路径的具体使用场景？如无，建议推迟到 v2，保持 v1 范围专注于 schema-typed 路径。

---

## 13. 变更记录

| 版本 | 修改内容 |
|---|---|
| v0.1 | 初稿 |
| v0.2 | 修正 optional u64/f64 编码（降级至 Variable 组）；统一 sub-word 字段打包规则为贪心装箱；struct_id 从 u16 改为 u32 FNV-32a 并明确仅供 debug；明确 schema 演化为有意识的 v1 边界；更新 4.5 示例使其与规则一致 |
| v0.3 | 性能修订（原则：性能 > 体积）：字符串去 index 间接层（值槽直接存 pool 偏移，访问 2 load → 1 load，省 index[] 区）；fixed 槽保持声明顺序（作者控制 cache line 局部性，替代按大小排序）；View 增加缓存 pool 基址；uniform 数组数据区固定 32B 对齐（数组头 +32，allocator 硬性 32B 对齐）；sub-word optional 明确独占槽（消除 Step 2 与 Step 3 的矛盾）；Swift/Kotlin 示例与 4.5 对齐（score 非 optional、age 返回类型、补 uid 访问器） |

---

*文档结束。如需修改或补充，请在评审中提出。*
