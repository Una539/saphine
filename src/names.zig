//! 为 IR 符号分配可读且无冲突的 Zig 名称，并保存声明及特化的源码关联信息。
const std = @import("std");

pub const SymbolId = usize;
pub const LocalId = usize;
/// 使用文件路径、字节范围和行列描述源码位置，供诊断与源码映射共用。
pub const SourceSpan = struct { path: []const u8, start: usize, end: usize, line: usize = 1, column: usize = 1 };

/// 保存符号身份、首选名称、所属对象和类型版本，支持生成代码命名及追溯。
pub const Symbol = struct {
    id: SymbolId,
    name: []const u8,
    owner: []const u8 = "",
    source: ?SourceSpan = null,
    specialization: ?SourceSpan = null,
    version: usize = 0,
};

/// 建立符号编号到输出名称的映射，优先保留原名，再对冲突名称追加所属对象和编号。
pub const NameTable = struct {
    names: std.AutoHashMapUnmanaged(SymbolId, []const u8) = .empty,

    /// 先保留无冲突名称，再分配其余名称，同时避开局部名称与后端保留名称。
    pub fn init(a: std.mem.Allocator, symbols: []const Symbol, locals: []const []const u8) !NameTable {
        var table: NameTable = .{};
        var counts: std.StringHashMapUnmanaged(usize) = .empty;
        for (symbols) |symbol| {
            const entry = try counts.getOrPut(a, symbol.name);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += 1;
        }
        var used: std.StringHashMapUnmanaged(void) = .empty;
        for (locals) |name| try used.put(a, name, {});
        // Reserve all preferred spellings before resolving collisions.
        for (symbols) |symbol| {
            if (counts.get(symbol.name).? == 1 and !reserved(symbol.name) and !used.contains(symbol.name)) {
                try table.names.put(a, symbol.id, symbol.name);
                try used.put(a, symbol.name, {});
            }
        }
        for (symbols) |symbol| {
            if (table.names.contains(symbol.id)) continue;
            const prefix = if (symbol.owner.len == 0 or reserved(symbol.owner)) "lang" else symbol.owner;
            const base = try std.fmt.allocPrint(a, "{s}__{s}", .{ prefix, symbol.name });
            var candidate: []const u8 = base;
            var version: usize = 1;
            while (used.contains(candidate)) : (version += 1)
                candidate = try std.fmt.allocPrint(a, "{s}__{d}", .{ base, version });
            try used.put(a, candidate, {});
            try table.names.put(a, symbol.id, candidate);
        }
        return table;
    }

    /// 按已登记符号编号取出最终名称，调用前必须完成名称分配。
    pub fn get(self: NameTable, id: SymbolId) []const u8 {
        return self.names.get(id).?;
    }

    /// 检查固定后端名称和内部名称前缀，防止用户符号遮蔽生成代码设施。
    fn reserved(name: []const u8) bool {
        const builtins = [_][]const u8{ "main", "std", "io", "lang_std", "keep", "Closure", "makeRange", "arithmetic" };
        for (builtins) |builtin| if (std.mem.eql(u8, name, builtin)) return true;
        return std.mem.startsWith(u8, name, "__saphine_");
    }
};
