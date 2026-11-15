//! Zig 原生性能对照入口，复用词频和对象生命周期实现，按命令参数选择工作负载。
const std = @import("std");
const support = @import("support.zig");
const lifecycle = @import("lifecycle.zig");

/// 解析 words 或 lifecycle 参数，输出排序词频或生命周期校验和，并释放相关资源。
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and support.equal(args[1], "lifecycle")) {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try writer.interface.print("{d}\n", .{lifecycle.heapCycle()});
        try writer.interface.flush();
        return;
    }
    if (args.len != 3 or !support.equal(args[1], "words")) return error.InvalidArguments;
    const allocator = std.heap.smp_allocator;
    var words = support.openWords(allocator, args[2]) orelse return error.OpenFailed;
    defer words.deinit();
    var counts = support.newCounter(allocator);
    defer counts.deinit();
    while (words.next()) |word| {
        if (!counts.add(word)) return error.OutOfMemory;
    }
    if (words.failed or !counts.output()) return error.WordCountFailed;
}
