//! 提供词频示例共用的分块分词、计数排序和基准分配器，使语言入口与 Zig 对照共享算法。
const std = @import("std");
const Allocator = std.mem.Allocator;
const block_size = 32 * 1024;
const separators = " \t\r\n";

/// 保存文件分块读取状态，跨块单词暂存于 spill，返回切片只在下次迭代前有效。
pub const Words = struct {
    allocator: Allocator,
    file: std.Io.File,
    buffer: []u8 = &.{},
    length: usize = 0,
    cursor: usize = 0,
    offset: u64 = 0,
    spill: std.ArrayList(u8) = .empty,
    failed: bool = false,

    /// 释放跨块和读入缓冲区并关闭文件，结束分词迭代器生命周期。
    pub fn deinit(self: *Words) void {
        self.spill.deinit(self.allocator);
        self.allocator.free(self.buffer);
        self.file.close(io());
    }

    /// 重新分配固定大小缓冲区并按文件偏移读取，失败时设置状态供入口统一报告。
    fn refill(self: *Words) bool {
        self.allocator.free(self.buffer);
        self.buffer = &.{};
        self.cursor = 0;
        self.length = 0;
        self.buffer = self.allocator.alloc(u8, block_size) catch {
            self.failed = true;
            return false;
        };
        const length = self.file.readPositionalAll(io(), self.buffer, self.offset) catch {
            self.failed = true;
            return false;
        };
        self.length = length;
        self.offset += length;
        return length != 0;
    }

    /// 按空白分隔扫描下一单词，必要时拼接跨块片段；返回切片借用内部缓冲区。
    pub fn next(self: *Words) ?[]const u8 {
        self.spill.clearRetainingCapacity();
        while (true) {
            if (self.cursor == self.length and !self.refill()) {
                return if (self.failed or self.spill.items.len == 0) null else self.spill.items;
            }
            const rest = self.buffer[self.cursor..self.length];
            const end = std.mem.findAny(u8, rest, separators) orelse rest.len;
            const word = rest[0..end];
            self.cursor += end;
            if (end < rest.len) {
                self.cursor += 1;
                if (self.spill.items.len != 0) {
                    if (!self.append(word)) return null;
                    return self.spill.items;
                }
                if (word.len != 0) return word;
            } else if (!self.append(word)) return null;
        }
    }

    /// 将单词片段追加到跨块缓冲区，分配失败时标记迭代器失败。
    fn append(self: *Words, bytes: []const u8) bool {
        self.spill.appendSlice(self.allocator, bytes) catch {
            self.failed = true;
            return false;
        };
        return true;
    }
};

/// 打开文件并绑定调用方分配器，读取缓冲区延迟到首次迭代时分配。
pub fn openWords(allocator: Allocator, path: []const u8) ?Words {
    const file = std.Io.Dir.cwd().openFile(io(), path, .{}) catch return null;
    return .{ .allocator = allocator, .file = file };
}

/// 使用自有单词副本作为哈希键计数，并通过排序键列表输出稳定结果。
pub const Counter = struct {
    allocator: Allocator,
    counts: std.StringHashMapUnmanaged(u64) = .empty,

    /// 已知单词直接增加计数，新单词复制键后插入，失败时回收未采用的副本。
    pub fn add(self: *Counter, word: []const u8) bool {
        if (self.counts.getPtr(word)) |count| {
            count.* += 1;
            return true;
        }
        const key = self.allocator.dupe(u8, word) catch return false;
        self.counts.putNoClobber(self.allocator, key, 1) catch {
            self.allocator.free(key);
            return false;
        };
        return true;
    }

    /// 收集并按字节序排序单词，将单词及计数写到缓冲标准输出并刷新。
    pub fn output(self: *Counter) bool {
        const keys = self.allocator.alloc([]const u8, self.counts.count()) catch return false;
        defer self.allocator.free(keys);
        var iterator = self.counts.keyIterator();
        for (keys) |*key| key.* = iterator.next().?.*;
        std.mem.sort([]const u8, keys, {}, lessThan);

        var buffer: [4096]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io(), &buffer);
        for (keys) |key| writer.interface.print("{s} {d}\n", .{ key, self.counts.get(key).? }) catch return false;
        writer.interface.flush() catch return false;
        return true;
    }

    /// 先释放所有自有单词键，再释放哈希表容量。
    pub fn deinit(self: *Counter) void {
        var keys = self.counts.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.counts.deinit(self.allocator);
    }
};

/// 创建空词频表并保存指定分配器，实际存储随单词插入增长。
pub fn newCounter(allocator: Allocator) Counter {
    return .{ .allocator = allocator };
}

/// 按字节比较参数文本，供 Saphine 入口选择模式与命令。
pub fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 以单词字节序比较排序键，使不同哈希表遍历顺序产生相同输出。
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// 返回全局单线程 IO，供未显式传入进程上下文的示例辅助接口使用。
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const memory = @import("saphine_runtime");
var benchmark_collector: memory.Collector = .{ .backing = std.heap.smp_allocator };

/// 使用 SMP allocator 构造 Heap，使跨语言实验的 Zig 与 Saphine 分配底层一致。
pub fn benchmarkHeap() memory.Heap {
    return memory.Heap.newWith(std.heap.smp_allocator);
}

/// 返回使用 SMP allocator 的独立基准收集器句柄，避免借用默认页面分配堆。
pub fn benchmarkGc() memory.GC {
    return .{ .collector = &benchmark_collector };
}
