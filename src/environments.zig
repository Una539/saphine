//! 扫描 IR 推导函数所需上下文，通过调用关系迭代到稳定，并收集变量使用和函数取址信息。
const std = @import("std");
const ir = @import("ir.zig");

/// 区分无上下文、已知结构上下文和类型擦除上下文，合并不一致结构时退化为擦除表示。
pub const Environment = union(enum) {
    none,
    typed: usize,
    erased,

    /// 合并一个结构编号；多个不同结构共用上下文时改用类型擦除表示。
    fn include(self: *Environment, shape: usize) void {
        switch (self.*) {
            .none => self.* = .{ .typed = shape },
            .typed => |previous| if (previous != shape) {
                self.* = .erased;
            },
            .erased => {},
        }
    }
};

pub const Table = std.AutoHashMapUnmanaged(usize, Environment);
const Addresses = std.AutoHashMapUnmanaged(usize, void);

/// 初始化各函数环境并反复扫描调用和对象引用，直到所有环境要求不再变化。
pub fn analyze(a: std.mem.Allocator, functions: []const ir.Function) !Table {
    var table: Table = .empty;
    for (functions) |function| {
        try table.put(a, function.id, if (function.initializes) |shape| .{ .typed = shape } else .none);
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (functions) |function| {
            const previous = table.get(function.id).?;
            var query: ContextQuery = .{ .table = table, .environment = previous };
            scan(function.body, &query);
            if (std.meta.eql(previous, query.environment)) continue;
            table.getPtr(function.id).?.* = query.environment;
            changed = true;
        }
    }
    return table;
}

/// 递归扫描函数体的表达式，判断是否引用指定局部变量名称。
pub fn usesVariable(body: []const ir.Stmt, name: []const u8) bool {
    var query: Variable = .{ .name = name };
    scan(body, &query);
    return query.used;
}

/// 遍历函数体与启动语句，收集被取地址的函数编号，供后端生成适配器。
pub fn collectAddresses(a: std.mem.Allocator, module: ir.Module) !Addresses {
    var query: AddressQuery = .{ .a = a };
    for (module.functions) |function| scan(function.body, &query);
    scan(module.startup, &query);
    if (query.failed) return error.OutOfMemory;
    return query.addresses;
}

/// 累积函数地址集合及分配失败状态，使通用扫描器不必返回错误联合。
const AddressQuery = struct {
    a: std.mem.Allocator,
    addresses: Addresses = .empty,
    failed: bool = false,
};

/// 保存当前函数环境和其他函数的环境表，用于传播调用所需的上下文。
const ContextQuery = struct { table: Table, environment: Environment };

/// 保存待查变量名及是否命中的结果，由通用扫描过程更新。
const Variable = struct { name: []const u8, used: bool = false };

/// 借助 Zig 类型反射遍历 IR 容器，对不同查询处理上下文、函数地址或变量引用。
fn scan(value: anytype, query: anytype) void {
    const T = @TypeOf(value);
    if (T == ir.Type) return;
    if (T == ir.Expr) {
        if (@TypeOf(query) == *ContextQuery) switch (value) {
            .forward_context => {
                query.environment = .erased;
                return;
            },
            .module_object => |shape| {
                query.environment.include(shape);
                return;
            },
            .call => |call| {
                switch (call.target) {
                    .direct => |id| if ((query.table.get(id) orelse .erased) != .none) scan(call.context, query),
                    .indirect => |target| scan(target, query),
                }
                scan(call.args, query);
                return;
            },
            .function_address => |address| {
                if ((query.table.get(address.id) orelse .erased) != .none) scan(address.context, query);
                return;
            },
            else => {},
        };
        if (@TypeOf(query) == *AddressQuery and value == .function_address)
            query.addresses.put(query.a, value.function_address.id, {}) catch {
                query.failed = true;
            };
        if (@TypeOf(query) == *Variable and value == .variable and std.mem.eql(u8, query.name, value.variable))
            query.used = true;
    }
    switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.child == u8) return;
            switch (pointer.size) {
                .one => scan(value.*, query),
                .slice => for (value) |element| scan(element, query),
                else => {},
            }
        },
        .optional => if (value) |element| scan(element, query),
        .@"struct" => |info| inline for (info.field_names) |field| {
            scan(@field(value, field), query);
        },
        .@"union" => |info| if (info.tag_type != null) switch (value) {
            inline else => |element| scan(element, query),
        },
        else => {},
    }
}
