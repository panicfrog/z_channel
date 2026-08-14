# ZigPack：零拷贝跨语言二进制序列化格式

> **状态**：设计草稿，待技术评审
> **版本**：v0.5.1（正确性修订：对齐判定改用 struct_buf 绝对偏移、optional 零扩展位编码；格式优化：数组数据区统一 +8、uniform 大数组头落 32k+24；表述收紧：Writer 四阶段、外语双构造器）
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

**pool_data 起点固定为 Pool 头 +8**（跳过 `pool_byte_len` 4B + `string_count` 4B）。View.init 缓存的基址即 `poolData = string_pool_off + 8`，与 6.4 / 7.2 的示例代码一致。

**字符串偏移（string_off）**：值槽中**直接**存储该字符串在 `pool_data` 内的字节偏移（u32），没有中间索引层。访问路径为一次 load：

```
string_off → pool_data[string_off]   （pool_data 基址由 View.init 缓存，见 6.4）
```

写入端 `StringInterner` 按插入顺序向 pool_data 追加字符串，偏移在插入时即确定（= 追加前的 pool_data 长度），因此写入值槽的偏移就是最终偏移，**无需序列化收尾 fixup**。成立前提是 pool_data 独立于其在 buffer 中的最终位置构建（所有偏移相对 pool_data 自身起点），Writer 的写入顺序见 6.3。

**string_count 的取舍**：v0.3 移除 index[] 后，string_count 不再参与读取路径。**决策：保留**，但用途明确限定为两类，均不在热路径上：(a) **debug 构建下的完整性校验**——线性扫描 pool_data 数出的字符串数应与之相等（大 pool 场景扫描成本不可忽视，故仅在 debug 构建执行，release 不做）；(b) **内省/工具场景**——遍历 pool 内字符串本身就需要线性扫描 NUL 边界，string_count 提供"应扫到几个"的终止校验。

> v0.1–v0.2 曾使用 handle → index[] → pool_data 两级间接。该间接层在读取端零收益（去重发生在写入端），却使每次字符串访问多一次依赖 load，且 index[] 每字符串多耗 4B。v0.3 移除。

---

### 4.4 Schema-Typed Struct 布局

```
Offset  大小                        内容
──────  ─────────────────────────   ─────────────────────────────────────
0       8B                          Struct Header
                                      slot_count_fixed:  u16（Fixed Section 槽位数，非字段数）
                                      field_count_var:   u16
                                      schema_name_hash:  u32（fnv32a，debug 用）
8       slot_count_fixed × 8B      Fixed Section（固定字段槽位区）
?       field_count_var × 4B        Variable Offset Table（VOT）
?       (padding)                   ← 派生结果，非独立规则（见下）
?       variable data               内联的嵌套 struct / array 数据
```

> **关于 `schema_name_hash`**：从 16 位改为 32 位（FNV-32a of type name），仅用于 debug / 运行时 assert，**不作为安全校验**（碰撞概率 ~1/4B，校验严格性不足；如需严格校验应比较完整 type name 字符串）。32 位相比 16 位碰撞概率下降 65536 倍，误报率在调试场景可接受。

> **VOT 偏移基准**：所有 VOT 条目均为**相对本 struct 头**（Struct Header 起点，即访问代码中的 `struct_base`）的 u32 字节偏移，**不是**相对 buffer 头。所有语言的访问统一为 `buf + struct_base + vot_entry`（嵌套 struct 的子 base 同理由父 base + VOT 条目得出）。`0xFFFF_FFFF` 保留为 null 哨兵，不占用偏移空间（buffer 上限 4GiB，实际可达偏移 < 0xFFFF_FFFF）。

> **slot_count_fixed 语义**：Struct Header 中的 `slot_count_fixed` 是 **Fixed Section 的 8B 槽位数**，不是 fixed 字段数——sub-word 打包后多个字段共享一个槽，两者可能不相等（如 4.5 中 fixed 字段 5 个、槽位 4 个）。`vot_start = 8 + slot_count_fixed * 8` 仅在槽位语义下成立。运行时读取路径不使用该值（vot_start 是 comptime 常量），仅用于 debug / 布局校验。

> **子对象落位的对齐规则（唯一一条 padding 规则）**：本规则适用于 struct 段中**所有子对象**，不限于 struct 的 variable 字段：
>
> | 子对象 | 出现位置 | 对齐需求 |
> |---|---|---|
> | 嵌套 struct | 父 struct 的 variable data 区 | 8B |
> | full-width optional 数据块（`?u64/?i64/?f64`） | 父 struct 的 variable data 区 | 8B |
> | 数组（数组头） | 父 struct 的 variable data 区 | 见 4.6（uniform 大数组 `32k+24`，其余 8B） |
> | **数组元素（non-uniform 路径的子 struct）** | **数组 offset_table 之后的元素区** | **8B** |
>
> writer 在追加每个子对象前插入 padding；引用该子对象的条目（父 struct 的 VOT 条目 / 数组的 offset_table 条目）指向 padding **之后**的起点。
>
> **⚠ 对齐判定必须基于 struct 段缓冲（struct_buf）内的绝对偏移，而不是相对本 struct 头（或本数组头）的偏移。** 原因：struct_buf 偏移 0 对应最终 buffer 的 `root_off`，而组装规则保证 `root_off ≡ 0 (mod 32)`（见 6.3），因此 `struct_buf_offset ≡ 0 (mod k)` ⟹ 该位置在最终 buffer 中也 kB 对齐（k ∈ {8, 32}）。而 VOT / offset_table 条目只是相对增量，其自身不保证是 8 或 32 的倍数，**子对象的 base 因此不继承父对象的对齐等级**。
>
> 反例（说明为何不能用相对偏移判定）：`root_off = 32`，`address` 子 struct 的 VOT 条目 = 8 ⟹ `address` base = 40。若其内部 uniform 数组头"相对 address 头"对齐到 32（即 base+32 = 72），则 72 mod 32 = 8，在最终 buffer 中**并未 32B 对齐**。
>
> 结论：**对齐判定用 struct_buf 绝对位置，引用条目只记录相对增量**（`rel_off = child_struct_buf_offset − parent_start`）。这条规则同时覆盖 8B 与 32B 两种需求，且对任意嵌套深度、任意嵌套种类（struct 套 struct、struct 套数组、数组套 struct）成立。

> **布局图中 `(padding)` 行的性质**：它是上述规则在**第一个子对象**上的实例，**不是独立规则**。此外当 `field_count_var` 为奇数时，VOT 区（4B 步长）末尾会自然产生 4B 空隙，被该 padding 吸收。实现者只需实现上面这一条对齐逻辑。

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

以下字段各自独占一个 8B 槽，**统一按声明顺序**依次分配（低位存值，高位补零）：

- `u64 / i64 / f64`
- `u32 / i32 / f32 / string_off`
- 全部 non-full-width optional：`?u32`、`?i32`、`?f32`、`?string_off`、`?u16`、`?i16`、`?u8`、`?i8`、`?bool`

**optional sub-word（`?u8`、`?bool` 等）视同独占槽字段，在本步骤按声明顺序与其他独占槽字段混合分配，不进入 Step 2 的装箱。**

理由：8B 等步长槽位下所有槽自然 8B 对齐，按类型大小排序没有任何对齐收益；保持声明顺序把 cache-line 局部性的控制权交给 schema 作者——高频字段排在前面即可挤进同一条 cache line（64B = 8 个槽），这是本设计缓存友好性的直接控制点。

**Step 2：sub-word 字段打包（仅非 optional）**

所有**非 optional** 的 `u16/i16/u8/i8/bool` 字段，在独占槽字段之后，按声明顺序**贪心装箱**进 8B 槽：

- 每个槽可容纳的字节位置：`byte 0..7`（共 8 字节）
- 按 **对齐边界** 将字段放入当前槽：u16 放 2B 对齐位置，u8/bool 放任意字节位置
- 当前槽装不下时，开启新槽
- optional sub-word 字段**不参与装箱**（已在 Step 1 独占槽分配，bit 63 做 null 标记，见 Step 3）——同一槽内多个 optional 无法共用 bit 63，必须独占
- 每个字段的字节偏移（相对所在槽起点）由 comptime 计算并记录在 FieldMeta 中

**Step 3：optional null 标记**

non-full-width optional（`?u32`、`?i32`、`?f32`、`?string_off`、`?u16`、`?i16`、`?u8`、`?i8`、`?bool`）使用 8B 槽的 **bit 63** 作为 null 标记。位编码规则如下，**无二义、统一覆盖上述全部类型**：

```
非 null：把值的位模式【零扩展】到低 N 位（N = 8/16/32），
         bit N..63 全部为 0（含 bit 63）。
         ⚠ 严禁符号扩展 —— 负数符号扩展会填满高 32 位并误置 bit 63，
           直接破坏 null 语义。
         例：?i32 = -1  →  slot = 0x0000_0000_FFFF_FFFF
                          （不是 0xFFFF_FFFF_FFFF_FFFF）

null   ：bit 63 = 1，其余位全 0（slot = 0x8000_0000_0000_0000）。

解码  ：测 bit 63；为 0 则截断到该字段位宽，再 bitcast 到字段类型
         —— 符号扩展由 bitcast 自然产生，与槽位无关。
         例：?i32 → @as(i32, @bitCast(@as(u32, @truncate(slot))))
```

> **实现陷阱**：writer 若"自然地"写成 `@as(u64, @bitCast(@as(i64, value)))`，`?i32 = -1` 会被写成全 1，读回时被误判为 null。必须先转成同宽无符号类型再零扩展：`@as(u64, @as(u32, @bitCast(value)))`。

- full-width optional（`?u64`、`?i64`、`?f64`）：**降级至 Variable 组，数据块动态分配**——null 时**不写入任何数据块**，VOT 条目 = `0xFFFF_FFFF`；非 null 时在 variable data 区按字段声明顺序追加一个 8B 数据块，VOT 条目指向它。不存在静态保留槽：静态保留会使 VOT 条目永远非 `0xFFFF_FFFF`，与 null 哨兵语义冲突，故明确排除。

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
0       8B     Struct Header（slot_count_fixed=4：fixed 字段 5 个、槽位 4 个；field_count_var=3；schema_name_hash）
8       8B     Fixed 槽 0：id（u64，8B）
16      8B     Fixed 槽 1：score（f32，低4B；高4B = 0）
24      8B     Fixed 槽 2：name（string_off u32，低4B；高4B = 0）
32      8B     Fixed 槽 3：[byte0=age][byte1=active][byte2-7=0]
40      4B     VOT[0]：tags 相对本 struct 头的偏移
44      4B     VOT[1]：address 相对本 struct 头的偏移
48      4B     VOT[2]：uid 相对本 struct 头的偏移（0xFFFF_FFFF = null）
52      4B     (padding：VOT 条目数为奇数时的自然空隙 + 首个子对象的对齐 padding)
56      ?      tags uniform string array（element_type=String，数据区在数组头 +8，见 4.6）
?       ?      address struct 数据（inline，8B 对齐）
?       8B     uid 数据块（内联的 u64，动态分配：仅当 VOT[2] ≠ 0xFFFF_FFFF 时存在，null 时整个数据块不写入）
```

> 上表的 `56` 同时满足两种落位要求：`56 mod 8 = 0`（小数组的 8B 需求）且 `56 mod 32 = 24`（大数组的 `32k+24` 需求）。因此**本例中 tags 无论元素多少，数组头都落在 56，VOT[0] 恰好不变**——这是"3 个 VOT 条目 + 4B 空隙"凑出的巧合，不是普遍规律。一般布局下大数组会被推后，VOT[0] 相应变大（最多 +31B），读取端无感。

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
6       2B                  flags: u16（bit0: uniform，bit1: data_32b_aligned）

[uniform scalar path，如 []f32、[]i64]
8       element_count × sizeof(T)   紧密排列的原始数据

[uniform string path，如 [][]const u8]
8       element_count × 4B          紧密排列的 string_off（u32），element_type = String

[non-uniform / struct array path]
8       element_count × 4B          offset_table[]（各元素相对数组头偏移）
?       element data[]              各元素 inline struct 数据（每元素 8B 落位，见 4.4）
```

**数据区永远位于数组头 +8**——uniform 路径的裸元素区、non-uniform 路径的 offset_table 都从 +8 开始。访问器无分支、偏移恒为 comptime 常量，三条路径共用同一条寻址公式。

**字符串数组的归类**：`[][]const u8` 等**字符串数组走 uniform 路径**——每个元素是 4B 的 `string_off`，本质上是 `sizeof(T) = 4` 的 uniform 数组（element_type 取 TypeTag 的 String 值，见 5.1），元素紧密连续、无 per-element 头。访问器可返回 `[]const u32` 偏移视图（调用方逐个解引用），也可提供惰性字符串迭代器。嵌套 struct 数组走 non-uniform 路径（元素是完整的子 struct，需 offset table 定位）。

> **字符串数组做 SIMD 对齐为何有意义**：String Pool 做了去重，因此**字符串相等 ⟺ string_off 相等**。`tags.contains(s)` 可退化为：先 `intern(s)` 得到 u32 偏移，再对 `[]const u32` 做 SIMD 相等比较（AVX2 一次比 8 个），完全不触碰 pool_data。这使 uniform string array 的向量化有真实业务语义，对齐收益成立。

---

#### 数组头的落位规则（writer 职责）

writer 决定数组头在 struct 段缓冲中的落位，**判定基于 struct_buf 绝对偏移**（见 4.4 对齐规则）：

```
【仅 uniform 路径】（element_type 为标量或 String，元素宽度 sizeof(elem) 有定义）
  若 element_count × sizeof(elem) ≥ 32：
      数组头对齐到 32k + 24  →  数据区（头 +8）起于 32(k+1)，天然 32B 对齐
      置 flags bit1 = 1
  否则（小数组）：
      数组头对齐到 8B        →  仅保证元素自然对齐
      置 flags bit1 = 0

【non-uniform 路径】（struct 数组）
  数组头一律对齐到 8B，flags bit1 = 0
```

> **non-uniform 数组为何不做 32B 对齐**：其元素是变长子 struct，逐个通过 offset_table 定位后按字段访问，**不存在整块 SIMD 消费**，对齐无收益；且 `sizeof(elem)` 对变长 struct 无定义，上述判定式本身不适用。数组头 8B 对齐即可满足 offset_table（u32）与元素区的对齐需求。元素区中每个子 struct 的 8B 落位由 4.4 的统一规则负责。

数组头恰好占 8B（count 4B + type 2B + flags 2B），因此把**头**放在 `32k+24` 就能让**数据区**落在 32B 边界，且访问器偏移仍是常量 `+8`——**内部 padding 为 0**。

> v0.4 曾采用"数组头 ≡ 0 (mod 32)、数据区 = 头 +32"，头内固定浪费 24B。新方案在完全相同的访问代码下消除了这 24B，每数组开销从 ≤55B 降到 ≤31B（仅前导对齐 padding）。

> **小数组为何豁免**：`count × sizeof < 32` 的数组填不满一个 AVX2 向量，32B 对齐无收益，反而会插入最多 31B padding 把数据推离父 struct、拉长跨 cache line 的距离。小数组只要 8B 对齐。

对齐成立的完整条件链：

```
buffer 基地址 32B 对齐                       ← allocator 硬性保证（见 8）
  → 组装时 Pool 段末尾补齐，root_off ≡ 0 (mod 32)   ← 见 6.3
  → struct_buf 偏移 0 映射到 root_off
  ⟹ struct_buf 绝对偏移 ≡ 0 (mod 32) 的位置，在最终 buffer 中 32B 对齐
  → writer 使数组头落在 struct_buf 绝对偏移 ≡ 24 (mod 32)
  → 数据区（头 +8）在最终 buffer 中 32B 对齐            ✔ 任意嵌套深度成立
```

VOT 条目指向 padding 之后的数组头，读取端永远看不到 padding。

---

#### 访问器的对齐处理

访问器返回**元素自然对齐**的 slice（`[]const f32` → align 4），**不做 `@alignCast(32)`**：

- LLVM 会发 `vmovups`（unaligned move）。在 Haswell+ / Apple Silicon 上，unaligned 指令访问**已对齐**数据与 aligned 指令吞吐完全相同
- 真正的性能收益是**避免 cache-line split**，这由 writer 的对齐保证提供，与指令选择无关
- 不 `@alignCast` 也就避免了"外语侧 buffer 只有 8B 对齐时 UB"的风险

`flags bit1: data_32b_aligned` 仅记录 writer 是否做了对齐，**供 debug / 内省使用，读路径不读取它**。

**uniform 标志（bit0）的意义**：标记为 uniform 的数组，其数据区是一段连续的同类型标量，访问器直接返回对应 Zig/C/Swift slice，调用方可以直接 SIMD 处理，无任何 per-element 开销。

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
        // 4. 计算 vot_start_offset = 8 + slot_count_fixed * 8（槽数，非字段数）
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
        struct_buf: std.ArrayList(u8),  // struct 段（临时缓冲，见下方"两段式"）
        pool:       StringInterner,     // pool 段（独立构建）；intern() 返回该字符串
                                        // 在 pool_data 中的最终偏移（插入时确定，无需 fixup）

        /// 序列化一个 struct，返回其在 struct_buf 中的起点（供父级算相对偏移）
        fn writeStruct(self: *@This(), comptime S: type, value: S) !usize {
            const L = computeLayout(S);
            // ── 阶段 1：RESERVE ──
            const struct_start = self.struct_buf.items.len;
            try self.struct_buf.appendNTimes(0, L.header_and_body_size);
            // header_and_body_size = 8 + slot_count_fixed*8 + field_count_var*4

            // ── 阶段 2a：HEADER（全部字段为 comptime 常量）──
            self.pokeHeader(struct_start, .{
                .slot_count_fixed = L.slot_count_fixed,
                .field_count_var  = L.field_count_var,
                .schema_name_hash = L.schema_name_hash,
            });

            // ── 阶段 2b：FIXED（定点回填，非 append）──
            inline for (L.fixed_fields) |fm| {
                const v = @field(value, fm.name);
                // 字符串字段：先 intern 拿到 string_off 再写槽
                self.pokeSlot(struct_start + fm.slot_offset, fm, v);
            }

            // ── 阶段 3：VARIABLE（append 数据 + 定点回填 VOT）──
            inline for (L.variable_fields) |fm| {
                const v = @field(value, fm.name);
                if (fm.is_optional and v == null) {
                    self.pokeVot(struct_start, L.vot_start, fm.vot_index, 0xFFFF_FFFF);
                    continue;
                }
                // a. 按子对象对齐需求 append padding
                //    ⚠ 判定基于 struct_buf 绝对偏移，不是相对 struct_start（见 4.4）
                try self.padTo(fm.childAlignSpec(v));
                // b. 相对增量
                const rel_off = self.struct_buf.items.len - struct_start;
                // c. 定点回填 VOT 槽
                self.pokeVot(struct_start, L.vot_start, fm.vot_index, @intCast(rel_off));
                // d. 递归序列化子对象（嵌套 struct 从阶段 1 重新开始）
                try self.writeChild(v);
            }
            return struct_start;
        }
    };
}
```

`inline for` 强制 LLVM 为每个字段特化代码，消除运行时分支和虚函数调用。

**四阶段（reserve-then-backfill）**：VOT 条目位于固定区、子对象数据追加在尾部，两者写入顺序天然相反。做法是**先一次性预留 Header + Fixed Section + VOT 的全部字节，再定点回填**：

```
1. RESERVE  — struct_start = struct_buf.len
              append (8 + slot_count_fixed*8 + field_count_var*4) 个零字节

2. HEADER   — 写入 struct_buf.items[struct_start .. +8]：
              slot_count_fixed / field_count_var / schema_name_hash
              （三者全部是 comptime 常量，一次 8B 写入）

3. FIXED    — 对每个 fixed 字段，随机写入
              struct_buf.items[struct_start + slot_offset ..]

4. VARIABLE — 按声明顺序，对每个 variable 字段：
              a. append 对齐 padding（判定基于 struct_buf 绝对偏移）
              b. rel_off = struct_buf.len − struct_start
              c. 随机写入 struct_buf.items[struct_start + vot_start + 4*vot_index]
                 （null 的 full-width optional 写 0xFFFF_FFFF 并跳过 d）
              d. 递归序列化子对象（从步骤 1 重新开始）
```

关键点：`struct_buf` 必须支持对**已 append 区域**的随机写（`ArrayList(u8).items[i]` 直接可写）。这不是"边算边填"的复杂 fixup 链，而是**预留 + 定点回填**，全程单次遍历，无二次扫描。`padTo` 承担步骤 4a，`pokeVot` 承担步骤 4c。数组的序列化同构：RESERVE 数组头 + offset_table → 写头（count/type/flags）→ 逐元素按 4.4 对齐落位并回填 offset_table 条目。

**Writer 写入顺序（两段式）**：最终 buffer 布局是 Header → String Pool → Root Struct，但字符串只有在遍历 struct 时才会被发现（Pool 无法先写完），因此 Writer 采用两段式构建：

1. **struct 段**：将 root struct（含全部嵌套数据）序列化到独立的临时缓冲。期间每遇到字符串就调用 `StringInterner.intern()`，把返回的最终偏移直接写入值槽——偏移相对 pool_data 自身起点，与 struct 段最终摆放位置无关，**struct 段无任何 fixup**。
2. **pool 段**：String Pool 始终在独立的 pool_data 缓冲中增量构建（intern 时追加，偏移即时确定），与 struct 段并行推进。
3. **组装**：全部字段写完后，按 Header(16B) + Pool + struct 段输出最终 buffer，回填 Header：`string_pool_off = 16`，`root_off = 16 + pool_total_len`。组装时 struct 段发生一次 memcpy（序列化的一次性成本，可接受）。

> **root_off 的 32B 补齐**：struct 段内的所有对齐（含 uniform 数组的对齐 padding）都是按 **struct 段内绝对偏移**计算的，而 struct 段在最终 buffer 中位于 `root_off = 16 + pool_total_len`，pool 长度不定。因此组装时必须在 Pool 段末尾补齐 padding（最多 31B），使 `root_off ≡ 0 (mod 32)`——这样 struct 段内的绝对偏移与最终 buffer 偏移**同余于 32**，段内计算的对齐在最终 buffer 中原样生效，struct 段本身无需感知自己的落位。这也是 4.4 "用绝对偏移判定对齐"能成立的唯一依据。

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
            // 数据区固定位于数组头 +8（见 4.6）。只按元素自然对齐做 ptrCast，
            // 不 @alignCast(32)：writer 已保证大数组数据区 32B 对齐，
            // LLVM 发 vmovups 在已对齐数据上与 aligned load 同吞吐。
            const p: [*]align(@alignOf(f32)) const u8 = @alignCast(arr_ptr + 8);
            return @as([*]const f32, @ptrCast(p))[0..count];
        }
    };
}
```

View 类型仅包含三个字段（指针 + struct 偏移 + pool 基址），按值传递开销极低；缓存 pool 基址使每次字符串访问省去一次 header load。

**单一 pool 不变量**：一个 buffer 有且仅有一个 String Pool，buffer 内所有 string_off 都指向它。格式不存在跨 buffer 引用——全部偏移在 buffer 内闭合，子 struct 只能通过父 struct 的 VOT 定位，不存在"从独立 buffer 拼入的子 struct"。因此 `.pool` 沿 View 链直接传递是定义内安全，子 View 永远不需要重新读 Header。若未来支持单 buffer 多顶层对象，它们仍共享同一 pool，传递规则不变。

---

## 7. 跨语言访问器生成

### 7.1 生成流程

```
Zig 构建步骤（b.addRunArtifact）
  输入：SchemaDescriptor（comptime 导出的 JSON 文件）
  输出：PersonView.swift、PersonView.kt、PersonView.ts

SchemaDescriptor 内容：
  type_name、schema_name_hash、slot_count_fixed、vot_start
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

    /// Root 入口：从 Header 读一次 root_off 与 pool 基址
    public init(_ buffer: UnsafeRawBufferPointer) {
        self.buf      = buffer
        self.base     = Int(buffer.load(fromByteOffset: 12, as: UInt32.self))      // root_off
        self.poolData = Int(buffer.load(fromByteOffset:  8, as: UInt32.self)) + 8  // pool_data
    }

    /// 嵌套入口：base 与 poolData 沿 View 链传递，不重读 Header
    internal init(_ buffer: UnsafeRawBufferPointer, base: Int, poolData: Int) {
        self.buf = buffer
        self.base = base
        self.poolData = poolData
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
        let childOff = buf.load(fromByteOffset: base + Self.VOT_START + 4, as: UInt32.self)
        return AddressView(buf, base: base + Int(childOff), poolData: poolData)  // ← 显式传递 pool
    }

    // Variable field: uid (optional u64) — VOT index 2，0xFFFF_FFFF = null
    public var uid: UInt64? {
        let off = buf.load(fromByteOffset: base + Self.VOT_START + 8, as: UInt32.self)
        guard off != 0xFFFF_FFFF else { return nil }
        return buf.load(fromByteOffset: base + Int(off), as: UInt64.self)
    }

    private static let VOT_START = 40  // = 8 + slot_count_fixed(=4) * 8，由 codegen 填入
}
```

> **双构造器模式对所有语言统一**：public root 构造器从 Header 读 `root_off`（偏移 12）与 `pool_data`（偏移 8 的值 +8）；internal 嵌套构造器接收 `(buf, base, poolData)`，与 Zig 侧 `View{buf, base, pool}` 三字段一一对应。**嵌套 View 必须显式传递 `poolData`**（单一 pool 不变量保证其安全，见 6.4），不得重读 Header，也不得用 `base = 0` 默认值——root struct 位于 `root_off` 而非 0。

### 7.3 Kotlin 访问器（示例）

使用 `java.nio.ByteBuffer`（direct/off-heap）：GC 不管理 buffer 内存，无 GC 压力。

```kotlin
// AUTO-GENERATED — do not edit
// Source schema: Person (schema_name_hash: 0x9C3F1A2B)

class PersonView internal constructor(
    private val buf: java.nio.ByteBuffer,
    private val base: Int,
    private val poolData: Int,          // pool_data 基址，沿 View 链传递
) {

    // Fixed field: id (u64) at base+8
    val id: Long get() = buf.getLong(base + 8)
    // JIT 内联后等价于单条 native load 指令

    // Fixed field: age (u8) at base+32
    val age: Int get() = buf.get(base + 32).toInt() and 0xFF

    // Fixed field: score (f32) at base+16
    val score: Float get() = java.lang.Float.intBitsToFloat(buf.getInt(base + 16))

    // Fixed field: name (string) at base+24 — 1 次 load 得到 pool 偏移 + 1 次拷贝
    val name: String get() {
        val strOff = poolData + buf.getInt(base + 24)
        // pool_data 是紧密排列的 NUL 结尾 UTF-8，需先定长度（ByteBuffer 无 strlen）
        var end = strOff
        while (buf.get(end) != 0.toByte()) end++
        val bytes = ByteArray(end - strOff)
        // absolute get 不改 position，View 保持无状态可重入
        (buf.duplicate() as java.nio.ByteBuffer).position(strOff).get(bytes)
        return String(bytes, Charsets.UTF_8)
    }

    // Variable field: uid (optional u64) — VOT index 2，0xFFFF_FFFF = null
    val uid: Long? get() {
        val off = buf.getInt(base + VOT_START + 8)
        if (off == -1) return null   // 0xFFFF_FFFF
        return buf.getLong(base + off)
    }

    // Variable field: address — VOT index 1
    val address: AddressView get() {
        val off = buf.getInt(base + VOT_START + 4)
        return AddressView(buf, base + off, poolData)   // ← 显式传递 pool
        // AddressView 对象在 JVM 堆分配，但字段数据仍在 off-heap buffer
    }

    companion object {
        // = 8 + slot_count_fixed(=4) * 8（注意是槽位数 4，不是 fixed 字段数 5），由 codegen 填入
        private const val VOT_START = 8 + 4 * 8

        /** Root 工厂：从 Header 读一次 root_off 与 pool 基址 */
        fun of(buf: java.nio.ByteBuffer): PersonView {
            buf.order(java.nio.ByteOrder.LITTLE_ENDIAN)
            val rootOff  = buf.getInt(12)      // root_off
            val poolData = buf.getInt(8) + 8   // pool_data
            return PersonView(buf, rootOff, poolData)
        }
    }
}
```

> **Kotlin 字符串的额外成本**：`ByteBuffer` 没有 `strlen`，NUL 边界必须逐字节扫描（上例的 `while` 循环），因此 Kotlin 的字符串访问是 **1 次 load + 一次 O(len) 扫描 + 1 次拷贝**，比 Swift 的 `String(cString:)`（内部走 native `strlen`）更贵。若剖析显示字符串访问是热点，可选优化：
> - 在 String Pool 中为每个字符串额外存 4B 长度前缀（格式变更，需权衡体积与 C FFI 兼容性）
> - 走 JNI/Panama（`java.lang.foreign`）直接调 native 侧解码，绕开逐字节扫描
> - 缓存已解码的 `String`（但会破坏 View 的零状态性质）
>
> v1 采用上面的朴素实现——短字符串（多数场景）下扫描开销远小于 `String` 对象分配本身。

### 7.4 各语言字段访问开销对比

```
语言        标量字段          字符串字段                        嵌套 struct
────────    ─────────────     ──────────────────────────────    ─────────────────
Zig         1 load            1 load（无拷贝，直接切 pool）      2 load + 子base
Swift       1 load            1 load + native strlen + 1 copy   2 load
Kotlin      1 JIT load        1 JIT load + 逐字节扫描 + 1 copy   2 JIT load + 1 alloc
TypeScript  DataView.getXxx   TextDecoder + copy                递归调用
```

字符串是唯一必然发生拷贝的数据类型（Swift 内存安全、JVM 堆模型要求）。所有标量字段和嵌套结构均可真正零拷贝访问。Kotlin 因 `ByteBuffer` 无 `strlen`，NUL 边界需自行扫描，是各语言中字符串访问最贵的一档（见 7.3 注释）。

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
//       大 uniform 数组数据区 32B 对齐（writer 把数组头放在 32k+24，见 4.6）
// 注：slice 只声明元素自然对齐，LLVM 发 vmovups；收益来自避免
//     cache-line split，而非指令选择——在 Haswell+ / Apple Silicon 上
//     unaligned 指令访问已对齐数据与 aligned 指令同吞吐。
```

### 8.3 读取时：动态对象字段查找

动态（ZValue tape）路径中，在大型 object 中按名查找字段时，同样用 Stage1/Stage2 两阶段 SIMD 扫描 String Pool。Schema-typed 路径不需要此优化（偏移全部为 comptime 常量）。

### 8.4 Buffer 跨语言传递时的 memcpy

当 buffer 需要跨进程或网络传输时，连续内存布局保证了一次大块 `memcpy`（而非分散拷贝），触发 x86 `REP MOVSB` / ARM64 `LD1-ST1` 向量化路径，接近内存带宽上限。

### 对齐要求

- Buffer allocator 统一保证 **32B 对齐**（v0.3 起为硬性要求）：这是 uniform 数组数据区 32B 对齐的前提，同时覆盖所有字段的自然对齐需求
- Uniform 数组数据区固定从**数组头 +8** 开始；`count × sizeof ≥ 32` 时 writer 把数组头放在 struct_buf 绝对偏移 `32k+24`，使数据区落在 32B 边界，SIMD 循环无 cache-line split（见 4.6）
- 访问器不做 `@alignCast(32)`，只声明元素自然对齐。因此若外语侧 FFI 只能保证 8B 对齐（如 JVM direct ByteBuffer），**不构成 UB**，仅退化为可能的 cache-line split（现代 CPU 上惩罚很小），标量路径完全不受影响

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
| optional null 标记（≤32 位类型） | bit 63 of 8B slot，值**零扩展**（严禁符号扩展） | 无额外 bitmap，单次 AND+branch，不影响值精度；零扩展规则消除负数误置 bit 63 的陷阱 |
| optional null 标记（u64/i64/f64） | 降级至 Variable 组，VOT = 0xFFFF_FFFF | bit 63 被值本身占满，无空余位，必须外置 null 标记 |
| 可变字段导航 | Variable Offset Table (VOT) | O(1) 定位，VOT 本身 comptime 已知 |
| 对齐判定基准 | struct_buf **绝对偏移**（VOT 只记相对增量） | 相对本 struct 头判定在嵌套场景下会失效（VOT 条目不保证是 32 的倍数） |
| 数组格式 | uniform（标量/字符串）/ non-uniform（struct）路径 | uniform 路径支持直接 SIMD slice；字符串数组视作 4B 元素的 uniform 数组（pool 去重 ⟹ 比较 string_off 即可 SIMD 判等） |
| 数组数据区位置 | 恒定在数组头 +8（三条路径统一） | 访问器无分支、偏移为 comptime 常量 |
| uniform 数组对齐 | 大数组头落在 32k+24（数据区 32B 对齐）；`count×sizeof < 32` 豁免为 8B | 消除 v0.4 头内固定 24B 浪费，开销降至 ≤31B/数组；小数组填不满向量，强制对齐反而拉长 cache line 距离 |
| 访问器上下文 | View{buf, base, pool} 三字 | init 缓存 pool 基址，每次字符串访问省一次 header load |
| 外语 View 构造 | 双构造器（public root 读 Header / internal 嵌套接收 poolData） | root 位于 root_off 而非 0；pool 沿 View 链传递，嵌套不重读 Header |
| schema_name_hash | u32 FNV-32a hash，仅供 debug assert | 16 位碰撞率过高；u32 降至可接受；不作安全校验 |
| Writer 机制 | reserve-then-backfill 四阶段 | VOT 在固定区、子对象在尾部，预留后定点回填即可单次遍历完成，无 fixup 链 |
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

2. **u32 偏移上限（4GiB）**：是否有超过 4GiB 的单个 buffer 需求？如有，需改为 u64 偏移，代价是 VOT 条目、数组 offset_table 条目、以及固定槽内的 `string_off` 各扩大一倍（4B → 8B）；`string_off` 扩到 8B 后会占满整个槽，`?string_off` 将失去 bit 63，需一并降级到 Variable 组。

3. **嵌套 struct 内联 vs 引用**：当前设计将嵌套 struct 数据内联在父 struct 的 variable data 区。如果同一 Address 对象被多个 Person 引用，会产生重复数据。是否需要支持引用语义（VOT 条目指向 buffer 内任意位置而非仅父 struct 内部）？这会允许去重，但会增加指针追踪层数。

4. **String Pool 构建的内存使用**：序列化时 StringInterner 需要临时哈希表存储所有已见字符串。对于大量小对象的批量序列化，此哈希表的内存峰值是否可接受？是否需要提供"禁用去重"的快速路径选项？

5. **对齐保证与外语传递**：v0.3 起 allocator 需保证 **32B 对齐**（硬性要求）。通过 FFI 传递给外语时，需外语侧不把 buffer 复制到低对齐内存（JVM direct ByteBuffer 通常只保证 8/16B；Swift 手动分配可达 32B）。由于 v0.5 起访问器不做 `@alignCast(32)`（只声明元素自然对齐），低对齐**不构成 UB**，仅可能产生 cache-line split（现代 CPU 惩罚很小），标量路径不受影响。此降级策略是否可接受？

6. **TypeScript 路径**：`DataView` 的字段访问开销比原生高约 3-5 倍。是否考虑提供 WASM 桥接选项（由 Zig 编译到 WASM，通过 `wasm-bindgen` 风格 glue 暴露给 JS），以在 TS 侧获得接近原生的性能？

7. **动态路径（ZValue tape）的优先级**：是否有在 v1 中支持动态路径的具体使用场景？如无，建议推迟到 v2，保持 v1 范围专注于 schema-typed 路径。

---

## 13. 变更记录

| 版本 | 修改内容 |
|---|---|
| v0.1 | 初稿 |
| v0.2 | 修正 optional u64/f64 编码（降级至 Variable 组）；统一 sub-word 字段打包规则为贪心装箱；struct_id 从 u16 改为 u32 FNV-32a 并明确仅供 debug；明确 schema 演化为有意识的 v1 边界；更新 4.5 示例使其与规则一致 |
| v0.3 | 性能修订（原则：性能 > 体积）：字符串去 index 间接层（值槽直接存 pool 偏移，访问 2 load → 1 load，省 index[] 区）；fixed 槽保持声明顺序（作者控制 cache line 局部性，替代按大小排序）；View 增加缓存 pool 基址；uniform 数组数据区固定 32B 对齐（数组头 +32，allocator 硬性 32B 对齐）；sub-word optional 明确独占槽（消除 Step 2 与 Step 3 的矛盾）；Swift/Kotlin 示例与 4.5 对齐（score 非 optional、age 返回类型、补 uid 访问器） |
| v0.3.1 | 评审澄清（格式不变）：4.3 明确 pool_data 起点为 Pool 头 +8 并决策保留 string_count（仅 debug/校验）；4.4 显式声明 VOT 偏移基准为本 struct 头；optional sub-word 归入 Step 1 按声明顺序分配；full-width optional 数据块明确为动态分配（排除静态保留）；4.6 明确 uniform 数组 32B 对齐中 writer 的填充职责；6.3 补充 Writer 两段式写入顺序及组装时 root_off 的 32B 补齐 |
| v0.4 | 评审修订：Struct Header 的 field_count_fixed 更名为 slot_count_fixed 并明确槽位语义（vot_start 公式仅槽位语义下成立）；4.6 新增 uniform string 路径（[][]const u8 = 4B string_off 元素的 uniform 数组）；4.4 新增 variable data 区对齐规则（子对象 8B 对齐落位，保证所有 struct base 为 8 的倍数）；6.3 伪代码重写为两段式模型；6.4 明确单一 pool 不变量；string_count 用途限定为 debug 构建校验与内省 |
| v0.5 | **正确性修订**：① 修复嵌套 struct 内 uniform 数组的 32B 对齐失效 bug——对齐判定改为基于 struct_buf **绝对偏移**（VOT 仅记录相对增量），v0.4 的"相对本 struct 头对齐"在嵌套场景下不成立（VOT 条目只保证 8B）；② 4.4 Step 3 新增 optional 位编码规则，明确值须**零扩展**、**严禁符号扩展**（否则 `?i32 = -1` 会误置 bit 63 被读成 null）。**格式优化**：③ 数组数据区统一为数组头 +8（三条路径一致），大数组头改落在 `32k+24` 使数据区天然 32B 对齐，消除 v0.4 头内固定 24B 浪费（每数组开销 ≤55B → ≤31B），`count×sizeof < 32` 的小数组豁免为 8B 对齐；④ 访问器改为只声明元素自然对齐、不 `@alignCast(32)`，消除外语侧低对齐 UB 风险；flags bit1 记录对齐状态但仅供 debug。**表述收紧**：⑤ 合并 VOT `pad to 8B` 与子对象对齐为唯一一条规则（前者标注为派生结果）；⑥ 6.3 明确 Writer 的 reserve-then-backfill 阶段划分并重写伪代码；⑦ Swift/Kotlin 改为双构造器（public root 从 Header 读 root_off，internal 嵌套显式接收 poolData），修正 `base = 0` 与漏传 pool 两个 bug |
| v0.5.1 | 评审补漏：① 4.4 对齐规则扩展为覆盖**所有子对象**（含 non-uniform 数组的元素区子 struct），以表格形式列出各类子对象的对齐需求；② 4.6 落位规则明确**仅 uniform 路径**适用 `32k+24`，non-uniform 一律 8B（元素逐个访问无整块 SIMD，且 `sizeof(elem)` 对变长 struct 无定义）；③ 6.3 三阶段补为**四阶段**，新增 HEADER 阶段（slot_count_fixed / field_count_var / schema_name_hash 此前无人写入），并补充数组序列化同构说明；④ 修正 4.5 注释——本例 `56` 同时满足 8B 与 `32k+24`，大小数组落点相同属巧合，非普遍规律；⑤ §12 问题 2 措辞更新（"string handle" → `string_off`，并补充 u64 偏移会使 `?string_off` 失去 bit 63 的连带影响）；⑥ 7.3 补 Kotlin `name` 访问器与 NUL 扫描成本说明，7.4 表同步细化 |

---

*文档结束。如需修改或补充，请在评审中提出。*
