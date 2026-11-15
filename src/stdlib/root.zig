//! 提供生成程序使用的标准库入口，保存进程 IO 与参数并封装输出、文件和字节串操作。
const __saphine_zig_std = @import("std");

pub const memory = @import("saphine_runtime");

var process_io: __saphine_zig_std.Io = undefined;
var process_args: __saphine_zig_std.process.Args = undefined;

/// 从生成的程序入口保存 IO 和参数，供不显式接收上下文的标准库接口使用。
fn initProcess(init: __saphine_zig_std.process.Init) void {
    process_io = init.io;
    process_args = init.minimal.args;
}

/// 包装分配器创建的进程参数迭代器，返回切片借用其存储，使用后需释放。
pub const Arguments = struct {
    iterator: __saphine_zig_std.process.Args.Iterator,

    /// 前移并返回下一个参数，切片仅在迭代器释放前有效。
    pub fn next(self: *Arguments) ?[]const u8 {
        return self.iterator.next();
    }

    /// 释放底层参数迭代器占用的存储，使先前返回的参数切片失效。
    pub fn deinit(self: *Arguments) void {
        self.iterator.deinit();
    }
};

/// 使用调用方分配器创建参数迭代器并跳过可执行文件名，失败时报告错误并退出。
pub fn arguments(__saphine_allocator: __saphine_zig_std.mem.Allocator) Arguments {
    var iterator = process_args.iterateAllocator(__saphine_allocator) catch
        fatal("could not read process arguments");
    _ = iterator.skip();
    return .{ .iterator = iterator };
}

/// 用指定分配器一次读取文件，失败返回空值；成功的缓冲区需用同一分配器释放。
pub fn readFile(__saphine_allocator: __saphine_zig_std.mem.Allocator, path: []const u8) ?[]u8 {
    return __saphine_zig_std.Io.Dir.cwd().readFileAlloc(
        process_io,
        path,
        __saphine_allocator,
        .unlimited,
    ) catch null;
}

/// 通过调用方提供的原分配器释放字节缓冲区，不另外管理其生命周期。
pub fn freeBytes(__saphine_allocator: __saphine_zig_std.mem.Allocator, buffer: []u8) void {
    __saphine_allocator.free(buffer);
}

/// 从指定字节位置起查找下一次匹配，返回从零开始的偏移，起点越界时返回空值。
pub fn find(haystack: []const u8, needle: []const u8, start: usize) ?usize {
    if (start > haystack.len) return null;
    return __saphine_zig_std.mem.findPos(u8, haystack, start, needle);
}

/// 使用已保存的进程 IO 将字节串写到标准输出，不自动添加换行。
pub fn write(text: []const u8) void {
    writeFormatted(process_io, __saphine_zig_std.Io.File.stdout(), "{s}", text);
}

/// 将 usize 按十进制写到标准输出，复用缓冲格式化输出实现。
pub fn writeNumber(value: usize) void {
    writeFormatted(process_io, __saphine_zig_std.Io.File.stdout(), "{d}", value);
}

/// 将错误消息交给统一终止函数，输出到标准错误并以状态码 1 退出。
pub fn fail(message: []const u8) void {
    fatal(message);
}

/// 写出带换行的错误消息后终止进程，不将错误返回到语言层。
fn fatal(message: []const u8) noreturn {
    writeFormatted(process_io, __saphine_zig_std.Io.File.stderr(), "{s}\n", message);
    __saphine_zig_std.process.exit(1);
}

/// 接收编译器提供的 IO 和编译期格式，将一个值写到标准输出。
pub fn print(context: __saphine_zig_std.Io, comptime format: []const u8, value: anytype) void {
    writeFormatted(context, __saphine_zig_std.Io.File.stdout(), format, value);
}

/// 使用栈上缓冲区格式化写入文件并刷新，输出失败时触发明确的 panic。
fn writeFormatted(io: __saphine_zig_std.Io, file: __saphine_zig_std.Io.File, comptime format: []const u8, value: anytype) void {
    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    writer.interface.print(format, .{value}) catch @panic("output write failed");
    writer.interface.flush() catch @panic("output flush failed");
}
