//! 将 Zig 标准库的字节前缀比较封装为可从 Saphine 直接调用的普通函数。
const std = @import("std");

/// 委托 std.mem.startsWith 比较字节串前缀，不分配存储或要求零终止。
pub fn startsWith(bytes: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, bytes, prefix);
}
