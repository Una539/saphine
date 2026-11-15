//! 嵌入独立 Zig 类型查询程序，在编译期遍历类型关系并输出可解析的文本元数据。
const query_std = @import("std");

/// 使用定长类型表和输出缓冲区为类型去重编号，并逐项记录类型属性和引用关系。
const Query = struct {
    types: [256]type = undefined,
    len: usize = 0,
    output: [16384]u8 = undefined,
    used: usize = 0,

    /// 在编译期将文本追加到固定缓冲区，容量不足时报告明确的编译错误。
    fn write(comptime self: *Query, comptime text: []const u8) void {
        if (text.len > self.output.len - self.used) @compileError("saphine query metadata exceeds 16 KiB");
        @memcpy(self.output[self.used..][0..text.len], text);
        self.used += text.len;
    }

    /// 按 Zig 类型身份查找或分配编号，使递归类型引用能复用已有记录。
    fn id(comptime self: *Query, comptime T: type) usize {
        for (self.types[0..self.len], 0..) |other, index| {
            if (other == T) return index;
        }
        if (self.len == self.types.len) @compileError("saphine query exceeds 256 types");
        self.types[self.len] = T;
        self.len += 1;
        return self.len - 1;
    }

    /// 输出指向子类型的编号，同时将尚未见过的子类型加入待描述集合。
    fn edge(comptime self: *Query, comptime T: type) void {
        self.write(query_std.fmt.comptimePrint(" {d}", .{self.id(T)}));
    }

    /// 按 @typeInfo 输出一种类型的类别、子类型和受支持属性，不展开无关反射数据。
    fn describe(comptime self: *Query, comptime T: type) void {
        const info = @typeInfo(T);
        self.write(@tagName(info));
        switch (info) {
            .int, .float => self.write(" " ++ @typeName(T)),
            .pointer => |ptr| {
                self.edge(ptr.child);
                self.write(" " ++ @tagName(ptr.size));
                self.write(if (ptr.attrs.@"const") " const" else " mutable");
                if (ptr.attrs.@"volatile" or ptr.attrs.@"allowzero" or (ptr.attrs.@"addrspace" orelse .generic) != .generic or (ptr.attrs.@"align" != null and ptr.attrs.@"align".? != @alignOf(ptr.child)) or ptr.sentinel_ptr != null)
                    self.write(" qualified");
            },
            .array => |array| {
                self.edge(array.child);
                self.write(query_std.fmt.comptimePrint(" {d}", .{array.len}));
                if (array.sentinel_ptr != null) self.write(" sentinel");
            },
            .optional => |optional| self.edge(optional.child),
            .error_union => |result| {
                self.edge(result.error_set);
                self.edge(result.payload);
            },
            .@"struct" => |container| {
                self.write(" " ++ @typeName(T));
                for (container.field_names, container.field_types, container.field_attrs) |name, field, attrs| {
                    self.write(" " ++ name);
                    self.edge(field);
                    self.write(if (attrs.@"comptime") " comptime" else if (attrs.default_value_ptr != null) " default" else " required");
                }
            },
            .@"union" => |container| {
                self.write(" " ++ @typeName(T));
                for (container.field_types) |field| self.edge(field);
            },
            .@"enum", .@"opaque", .error_set => self.write(" " ++ @typeName(T)),
            else => {},
        }
        self.write("\n");
    }
};

/// 从目标类型开始迭代描述新增类型，返回完整关系表并提高编译期分支额度。
fn saphineDescribeType(comptime T: type) []const u8 {
    @setEvalBranchQuota(100000);
    var query: Query = .{};
    _ = query.id(T);
    var index: usize = 0;
    while (index < query.len) : (index += 1) query.describe(query.types[index]);
    return query.output[0..query.used];
}
