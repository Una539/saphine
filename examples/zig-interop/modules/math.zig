//! 汇集外部结构体、泛型、回调和资源示例，共享 counter 以展示 Zig 模块的状态身份。
const helper = @import("parts/helper.zig");
pub var counter: i32 = 0;
const hidden: i32 = 3;

/// 具有默认字段与可写、只读接收者方法的外部结构体，供语言侧构造和调用。
pub const Point = struct {
    x: i32,
    y: i32 = 1,
    /// 通过可写接收者累加横坐标，用于展示语言侧自动取址。
    pub fn bump(self: *@This(), amount: i32) void {
        self.x += amount;
    }
    /// 通过只读接收者读取两字段并求和，不修改实例。
    pub fn sum(self: *const @This()) i32 {
        return self.x + self.y;
    }
};
pub const Alias = Point;
/// 字段布局与 Point 相同但声明身份不同，用于展示外部类型按身份区分。
pub const Other = struct { x: i32, y: i32 = 1 };
/// 提供全部带默认值的字段，允许语言侧省略字段构造嵌入对象。
pub const Defaults = struct { count: i32 = 3 };
pub const Errors = error{Bad};
pub const Result = Errors!i32;
pub const Maybe = ?i32;
/// 提供简单 Zig 枚举，供语言侧构造变体并进行模式匹配。
pub const Color = enum { red, blue };
/// 以可空自指针表示链节点，展示递归外部类型的身份保持。
pub const Link = struct { next: ?*@This() = null };
/// 根据编译期类型生成载荷与自链接结构，供类型工厂查询使用。
pub fn Factory(comptime T: type) type {
    return struct { value: T, next: ?*@This() = null };
}
/// 从泛型结构体读取指定类型载荷，展示依赖 comptime 参数的函数签名。
pub fn extract(comptime T: type, value: Factory(T)) T {
    return value.value;
}
/// 调用 C 约定的整数回调，展示语言函数到外部函数指针的适配。
pub fn runCallback(callback: *const fn (i32) callconv(.c) i32, x: i32) i32 {
    return callback(x);
}
/// 返回零终止字节串切片，展示哨兵信息在互操作类型中保留。
pub fn sentinel() [:0]const u8 {
    return "sentinel";
}

/// 通过 @embedFile 取得资源长度，使依赖打包包含非源码文件。
pub fn resourceLength() usize {
    return @embedFile("parts/resource.txt").len;
}
/// 增加共享计数器并以子模块常量参与加法，展示模块状态和相对依赖。
pub fn add(amount: i32) i32 {
    counter += 1;
    return helper.value + amount;
}
/// 增加共享计数器并返回带默认字段的 Point，用于观察返回对象求值次数。
pub fn make() Point {
    counter += 1;
    return .{ .x = 8 };
}
/// 只接受整数类别的泛型值，非整数实例在 Zig 编译期报告错误。
pub fn requireInteger(value: anytype) @TypeOf(value) {
    if (@typeInfo(@TypeOf(value)) != .int) @compileError("integer required");
    return value;
}
/// 以显式 comptime 类型约束参数并原样返回，展示简单泛型调用。
pub fn echo(comptime T: type, value: T) T {
    return value;
}
/// 根据编译期整数选择 i32 或 bool，构造依赖参数的返回类型。
fn Pick(comptime n: usize) type {
    return if (n == 1) i32 else bool;
}
/// 按编译期参数返回不同类型常量，展示需要求出具体结果类型的调用。
pub fn query(comptime n: usize) Pick(n) {
    return if (n == 1) 5 else false;
}
/// 保留原有的延迟编译报错声明；只有分析该函数体时才产生外部错误。
pub fn broken() i32 {
    @compileError("foreign body failed");
}
