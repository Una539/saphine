//! 将格式化后 Zig AST 的声明和调用范围关联回 Saphine 源码，支持导出映射与错误定位。
const std = @import("std");
const naming = @import("names.zig");
const ir = @import("ir.zig");
const Text = []const u8;

/// 记录生成代码字节范围及其源码位置，并附带符号、特化或调用点信息。
pub const Range = struct {
    generated_start: usize,
    generated_end: usize,
    source: naming.SourceSpan,
    symbol: ?naming.SymbolId = null,
    specialization: ?naming.SourceSpan = null,
    type_version: usize = 0,
    call_site: bool = false,
};

/// 通过生成名称匹配顶层符号，再识别外部调用标签，收集对应的生成代码范围。
pub fn collect(a: std.mem.Allocator, tree: std.zig.Ast, module: ir.Module, names: naming.NameTable) ![]const Range {
    var ranges: std.ArrayList(Range) = .empty;
    var symbols: std.StringHashMapUnmanaged(naming.Symbol) = .empty;
    for (module.symbols) |symbol| try symbols.put(a, names.get(symbol.id), symbol);
    for (tree.rootDecls()) |node| {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const name_token = if (tree.fullFnProto(&buffer, node)) |proto|
            proto.name_token orelse continue
        else if (tree.fullVarDecl(node)) |variable|
            variable.ast.mut_token + 1
        else
            continue;
        const spelling = tree.tokenSlice(name_token);
        const name = if (std.mem.startsWith(u8, spelling, "@\""))
            try std.zig.string_literal.parseAlloc(a, spelling[1..])
        else
            spelling;
        const symbol = symbols.get(name) orelse continue;
        const source = symbol.source orelse continue;
        const last = tree.lastToken(node);
        try ranges.append(a, .{
            .generated_start = tree.tokenStart(tree.firstToken(node)),
            .generated_end = tree.tokenStart(last) + tree.tokenSlice(last).len,
            .source = source,
            .symbol = symbol.id,
            .specialization = symbol.specialization,
            .type_version = symbol.version,
        });
    }
    for (0..tree.nodes.len) |raw| {
        const node: std.zig.Ast.Node.Index = @fromBackingInt(@intCast(raw));
        switch (tree.nodeTag(node)) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {},
            else => continue,
        }
        const first = tree.firstToken(node);
        const prefix = "zig_call_";
        const spelling = tree.tokenSlice(first);
        if (!std.mem.startsWith(u8, spelling, prefix)) continue;
        const index = std.fmt.parseInt(usize, spelling[prefix.len..], 10) catch continue;
        if (index >= module.call_sites.len) continue;
        const last = tree.lastToken(node);
        try ranges.append(a, .{
            .generated_start = tree.tokenStart(first),
            .generated_end = tree.tokenStart(last) + tree.tokenSlice(last).len,
            .source = module.call_sites[index],
            .call_site = true,
        });
    }
    return ranges.items;
}

/// 路径在基目录内时返回相对部分，否则回退到文件名以避免暴露无关目录。
pub fn relative(base: Text, path: Text) Text {
    if (std.mem.startsWith(u8, path, base) and path.len > base.len and std.fs.path.isSep(path[base.len]))
        return path[base.len + 1 ..];
    return std.fs.path.basename(path);
}

/// 将从一开始的行列换算为字节偏移，行列无效或超出源码长度时返回空值。
pub fn byteOffset(code: Text, line: usize, column: usize) ?usize {
    if (line == 0 or column == 0) return null;
    var start: usize = 0;
    for (1..line) |_| start = (std.mem.indexOfScalarPos(u8, code, start, '\n') orelse return null) + 1;
    if (column - 1 > code.len - start) return null;
    return start + column - 1;
}
