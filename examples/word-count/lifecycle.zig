//! 比较四种内存策略的批量对象生命周期，以一致载荷和校验和衡量创建、访问及释放成本。
const std = @import("std");
const memory = @import("saphine_runtime");
const support = @import("support.zig");

const batch_size = 4096;
const cycles = 32_768;
/// 使用递增编号和低字节填充构造固定大小载荷，使各策略执行相同的初始化和读取。
const Payload = struct {
    id: u64,
    bytes: [56]u8,

    /// 保存编号并用其低字节填充有效载荷，生成可验证的对象内容。
    fn new(id: u64) Payload {
        return .{ .id = id, .bytes = @splat(@truncate(id)) };
    }
};

/// 读取编号与首字节并阻止优化器忽略对象访问，返回待累计校验值。
fn consume(payload: *const Payload) u64 {
    std.mem.doNotOptimizeAway(payload);
    return payload.id + payload.bytes[0];
}

/// 每批用 Heap 创建全部对象，访问后逐个显式销毁并累计校验和。
pub fn heapCycle() u64 {
    const heap = support.benchmarkHeap();
    var pointers: [batch_size]*Payload = undefined;
    var sum: u64 = 0;
    for (0..cycles) |cycle| {
        for (&pointers, 0..) |*pointer, index| {
            pointer.* = heap.create(Payload, .new(cycle * batch_size + index)) catch @panic("out of memory");
        }
        for (pointers) |pointer| {
            sum += consume(pointer);
            heap.destroy(pointer);
        }
    }
    return sum;
}

/// 每批用 Arena 创建和访问对象，再保留容量重置区域以批量释放。
pub fn arenaCycle() u64 {
    var arena = memory.Arena.new(support.benchmarkHeap());
    defer arena.deinit();
    var pointers: [batch_size]*Payload = undefined;
    var sum: u64 = 0;
    for (0..cycles) |cycle| {
        for (&pointers, 0..) |*pointer, index| {
            pointer.* = arena.create(Payload, .new(cycle * batch_size + index)) catch @panic("out of memory");
        }
        for (pointers) |pointer| sum += consume(pointer);
        if (!arena.reset(.retain_capacity)) @panic("out of memory");
    }
    return sum;
}

/// 每批创建 ARC 句柄，读取后逐个释放强引用，使载荷及控制块回收。
pub fn arcCycle() u64 {
    const arc = memory.Arc.new(support.benchmarkHeap());
    var pointers: [batch_size]memory.ArcPtr(Payload) = undefined;
    var sum: u64 = 0;
    for (0..cycles) |cycle| {
        for (&pointers, 0..) |*pointer, index| {
            pointer.* = arc.create(Payload, .new(cycle * batch_size + index), null) catch @panic("out of memory");
        }
        for (pointers) |pointer| {
            sum += consume(pointer.get());
            pointer.release();
        }
    }
    return sum;
}

/// 用根帧保护批内对象，撤销根后显式收集并检查对象数量归零，返回累计校验和。
pub fn gcCycle() u64 {
    const gc = support.benchmarkGc();
    var sum: u64 = 0;
    for (0..cycles) |cycle| {
        {
            var pointers: [batch_size]?memory.GcPtr(Payload) = @splat(null);
            var frame = memory.rootFrame(&pointers);
            frame.push(gc.collector);
            defer frame.pop(gc.collector);
            for (&pointers, 0..) |*pointer, index| {
                pointer.* = gc.create(Payload, .new(cycle * batch_size + index), null) catch @panic("out of memory");
            }
            for (pointers) |pointer| sum += consume(pointer.?.get());
        }
        gc.collect();
        if (gc.collector.allocated != 0) @panic("temporary objects remain live after collection");
    }
    return sum;
}
