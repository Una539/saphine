//! 在程序的模块配置下生成临时 Zig 查询，通过带随机标记的编译诊断传回类型元数据。
const std = @import("std");
const Artifact = @import("artifact.zig").Artifact;
const Text = []const u8;

/// 打包相同依赖并编译类型查询，将反射结果经十六进制诊断解码返回，退出时清理临时目录。
pub fn describeType(artifact: Artifact, declarations: Text, expression: Text) !Text {
    const a = artifact.a;
    const io = artifact.io;
    const dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, ".saphine-cache");
    var nonce: [12]u8 = undefined;
    try io.randomSecure(&nonce);
    const temp = try std.fmt.allocPrint(a, ".saphine-cache/query-{x}", .{&nonce});
    try dir.createDirPath(io, temp);
    defer dir.deleteTree(io, temp) catch {};
    try artifact.writeDependencies(temp);

    const prefix = try std.fmt.allocPrint(a, "saphine-query-v1-{x}:", .{&nonce});
    const code = try std.fmt.allocPrint(a,
        \\{s}
        \\{s}
        \\const query_type = {s};
        \\comptime {{
        \\    const name = saphineDescribeType(query_type);
        \\    const digits = "0123456789abcdef";
        \\    var encoded: [name.len * 2]u8 = undefined;
        \\    for (name, 0..) |byte, index| {{
        \\        encoded[index * 2] = digits[byte >> 4];
        \\        encoded[index * 2 + 1] = digits[byte & 15];
        \\    }}
        \\    @compileError("{s}" ++ encoded);
        \\}}
        \\pub fn main() void {{}}
        \\
    , .{ declarations, @embedFile("query_reflection.zig"), expression, prefix });
    const filename = "query.zig";
    const input = try std.fs.path.join(a, &.{ temp, filename });
    try dir.writeFile(io, .{ .sub_path = input, .data = code });
    var argv: std.ArrayList(Text) = .empty;
    try argv.appendSlice(a, &.{ artifact.zig, "build-exe", "-fno-emit-bin", "--color", "off", "--cache-dir", ".saphine-cache/local", "--global-cache-dir", ".saphine-cache/global" });
    try artifact.appendModules(&argv, temp, filename);
    const result = try std.process.run(a, io, .{ .argv = argv.items });
    if (result.term != .exited or result.term.exited == 0) return error.InvalidQueryResponse;
    const before_error = std.mem.indexOf(u8, code, "    @compileError(").?;
    const line = std.mem.count(u8, code[0..before_error], "\n") + 1;
    const expected = try std.fmt.allocPrint(a, "{s}:{d}:5: error: {s}", .{ input, line, prefix });
    var lines = std.mem.splitScalar(u8, result.stderr, '\n');
    var response: ?Text = null;
    while (lines.next()) |diagnostic| {
        if (std.mem.startsWith(u8, diagnostic, expected)) {
            if (response != null) return error.InvalidQueryResponse;
            const hex = diagnostic[expected.len..];
            if (hex.len == 0 or hex.len % 2 != 0) return error.InvalidQueryResponse;
            response = try std.fmt.hexToBytes(try a.alloc(u8, hex.len / 2), hex);
        } else if (std.mem.indexOf(u8, diagnostic, ": error: ") != null) {
            return error.ZigQueryFailed;
        }
    }
    return response orelse error.InvalidQueryResponse;
}
