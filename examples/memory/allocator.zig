//! 为内存示例提供 Zig 容器和对象生命周期辅助调用，展示 allocator、ARC 和 GC 互操作。
const std = @import("std");
pub const Allocator = std.mem.Allocator;

/// 用传入 allocator 构造并释放动态数组，返回末项以展示分配器转换后的正常使用。
pub fn exercise(allocator: Allocator) u32 {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(allocator);
    for (0..1024) |index| list.append(allocator, @intCast(index)) catch @panic("out of memory");
    return list.items[1023];
}

const memory = @import("saphine_runtime");

/// 创建强弱句柄并逐步释放，确认剩余强引用保活对象且最终弱升级失败。
pub fn arcLifecycle(arc: memory.Arc) bool {
    const object = arc.create(u32, 31, null) catch @panic("out of memory");
    const weak = object.weak();
    defer weak.release();
    const retained = object.retain();
    object.release();
    const intact = retained.get().* == 31;
    retained.release();
    return intact and weak.upgrade() == null;
}

/// 创建自引用对象并登记根，检查收集时根保活，撤销根后允许循环对象回收。
pub fn gcLifecycle(gc: memory.GC) bool {
    // 用自引用节点展示追踪 GC 对循环对象的处理。
    const Node = struct {
        value: u32,
        next: ?memory.GcPtr(@This()) = null,

        /// 访问下一节点的对象头，将循环引用交给收集器去重标记。
        fn trace(collector: *memory.Collector, node: *const @This()) void {
            if (node.next) |next| collector.mark(next.header());
        }
    };
    const node = gc.create(Node, .{ .value = 37 }, Node.trace) catch @panic("out of memory");
    var root = gc.root(node) catch @panic("out of memory");
    node.get().next = node;
    gc.collect();
    const result = node.get().value == 37;
    root.deinit();
    gc.collect();
    return result;
}

/// 将下次自动收集阈值设置为当前对象数加指定分配次数，控制示例收集时机。
pub fn collectAfter(gc: memory.GC, allocations: usize) void {
    gc.collector.threshold = gc.collector.allocated + allocations;
}

/// 读取收集器登记的对象数量，供示例展示收集前后存活变化。
pub fn liveObjects(gc: memory.GC) usize {
    return gc.collector.allocated;
}
