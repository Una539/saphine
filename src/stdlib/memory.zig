//! 提供编译器和生成程序共用的 Heap、Arena、ARC 与追踪 GC，并实现复合值清理及托管视图保活。
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// 标记编译期分配接口，由语义分析将包含此接口的具体 manager 静态特化。
pub const Manager = struct {};

/// 构造只读对象观察约束，记录目标类型而不提供独立的运行时指针表示。
pub fn Ptr(comptime T: type) type {
    return struct {
        pub const Pointee = T;
    };
}

/// 包装调用方分配器，提供逐对象创建和显式销毁，不自动跟踪对象存活。
pub const Heap = struct {
    manager: Manager = .{},
    backing: Allocator,

    /// 使用页面分配器构造默认 Heap，复用指定底层分配器的初始化路径。
    pub fn new() Heap {
        return newWith(std.heap.page_allocator);
    }

    /// 保存指定分配器作为 Heap 的底层实现，不额外分配存储。
    pub fn newWith(backing: Allocator) Heap {
        return .{ .backing = backing };
    }

    /// 直接返回底层 Zig allocator，使 Heap 能用于标准 Zig 容器。
    pub fn allocator(self: Heap) Allocator {
        return self.backing;
    }

    /// 为目标类型分配一个对象并写入初值，分配失败向调用方返回错误。
    pub fn create(self: Heap, comptime T: type, value: T) Allocator.Error!*T {
        const result = try self.backing.create(T);
        result.* = value;
        return result;
    }

    /// 将对象交还底层分配器，不递归清理语言层字段或调用自定义析构。
    pub fn destroy(self: Heap, ptr: anytype) void {
        self.backing.destroy(ptr);
    }
};

/// 包装 Zig Arena 分配器，统一保存多次分配并支持批量重置和释放。
pub const Arena = struct {
    manager: Manager = .{},
    inner: std.heap.ArenaAllocator,
    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    /// 用 Heap 的 allocator 初始化 Arena，后续对象共享区域存储。
    pub fn new(heap: Heap) Arena {
        return .{ .inner = .init(heap.allocator()) };
    }

    /// 返回借用当前 Arena 的 allocator，使用期间 Arena 地址必须保持有效。
    pub fn allocator(self: *Arena) Allocator {
        return self.inner.allocator();
    }

    /// 通过 Arena allocator 创建带初值的对象，复用 Heap 的单对象初始化实现。
    pub fn create(self: *Arena, comptime T: type, value: T) Allocator.Error!*T {
        return Heap.newWith(self.allocator()).create(T, value);
    }

    /// 按指定容量保留模式重置区域，使此前分配的对象全部失效。
    pub fn reset(self: *Arena, mode: ResetMode) bool {
        return self.inner.reset(mode);
    }

    /// 释放区域全部存储并使 manager 本身失效，避免继续使用已释放的 Arena。
    pub fn deinit(self: *Arena) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

/// 构造原始分配块布局，在块头保存元数据，并在对齐载荷前存放可按字节读取的头指针。
fn RawBlock(comptime Metadata: type) type {
    return struct {
        const Self = @This();
        metadata: Metadata,
        size: usize,
        alignment: Alignment,

        /// 计算头部和载荷对齐，分配整块存储并写入回溯链接，溢出或分配失败时返回空值。
        fn alloc(backing: Allocator, len: usize, alignment: Alignment, metadata: Metadata, ret: usize) ?[*]u8 {
            const prefix = @sizeOf(Self) + @sizeOf(*Self);
            const rounded = std.math.add(usize, prefix, alignment.toByteUnits() - 1) catch return null;
            const offset = alignment.backward(rounded);
            const size = std.math.add(usize, offset, len) catch return null;
            const block_alignment = alignment.max(.of(Self));
            const raw = backing.rawAlloc(size, block_alignment, ret) orelse return null;
            const header: *Self = @ptrCast(@alignCast(raw));
            header.* = .{ .metadata = metadata, .size = size, .alignment = block_alignment };
            const link: *align(1) *Self = @ptrCast(raw + offset - @sizeOf(*Self));
            link.* = header;
            return raw + offset;
        }

        /// 读取载荷前的非对齐头指针，恢复原始块及其分配元数据。
        fn fromPayload(payload: [*]u8) *Self {
            const address = @intFromPtr(payload) - @sizeOf(*Self);
            const link: *align(1) *Self = @ptrFromInt(address);
            return link.*;
        }

        /// 使用块头保存的大小和对齐释放原始存储，而非只释放载荷切片。
        fn free(self: *Self, backing: Allocator, ret: usize) void {
            const raw: [*]u8 = @ptrCast(self);
            backing.rawFree(raw[0..self.size], self.alignment, ret);
        }
    };
}

/// 提供非原子引用计数分配，强引用归零时清理值，弱引用决定控制块的最终释放。
pub const Arc = struct {
    manager: Manager = .{},
    backing: Allocator,
    const Bytes = RawBlock(struct { backing: Allocator, strong: usize = 1 });

    /// 保存 Heap 的底层分配器，供引用计数对象与原始缓冲区使用。
    pub fn new(heap: Heap) Arc {
        return .{ .backing = heap.allocator() };
    }

    /// 构造带 ARC 原始块头的 Zig allocator，不支持原地扩容或重映射。
    pub fn allocator(self: *Arc) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocBytes,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = freeBytes,
        } };
    }

    /// 为 Zig 字节分配创建带分配器和强引用计数的块头，返回对齐载荷。
    fn allocBytes(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Arc = @ptrCast(@alignCast(context));
        return Bytes.alloc(self.backing, len, alignment, .{ .backing = self.backing }, ret);
    }

    /// 降低原始缓冲区强引用计数，归零时按块头记录释放完整分配。
    fn freeBytes(_: *anyopaque, bytes: []u8, _: Alignment, ret: usize) void {
        const block = Bytes.fromPayload(bytes.ptr);
        block.metadata.strong -= 1;
        if (block.metadata.strong == 0) block.free(block.metadata.backing, ret);
    }

    /// 分配引用计数控制块，保存初值与清理回调，返回拥有一个强引用的句柄。
    pub fn create(self: Arc, comptime T: type, value: T, drop: ?*const fn (*T) void) Allocator.Error!ArcPtr(T) {
        const box = try self.backing.create(ArcBox(T));
        box.* = .{ .backing = self.backing, .value = value, .drop = drop };
        return .{ .box = box };
    }
};

/// 为目标类型生成 ARC 控制块，保存强弱计数、载荷和可选的语言析构钩子。
fn ArcBox(comptime T: type) type {
    return struct {
        strong: usize = 1,
        weak: usize = 1,
        backing: Allocator,
        value: T,
        drop: ?*const fn (*T) void,
        hook: ?*const fn (?*anyopaque, *T) void = null,
        hook_context: ?*anyopaque = null,

        /// 减少控制块弱计数，所有弱引用及隐含弱引用都释放后销毁控制块。
        fn releaseWeak(box: *@This()) void {
            box.weak -= 1;
            if (box.weak == 0) box.backing.destroy(box);
        }
    };
}

/// 构造强引用句柄类型，通过共享控制块管理载荷寿命，不自动执行 Zig 局部变量析构。
pub fn ArcPtr(comptime T: type) type {
    return struct {
        pub const saphine_memory_kind: ValueKind = .arc;
        box: *ArcBox(T),

        /// 借用控制块中的载荷地址，不增加引用计数，调用方必须持有有效强引用。
        pub fn get(self: @This()) *T {
            return &self.box.value;
        }

        /// 增加强引用计数并返回共享同一控制块的句柄。
        pub fn retain(self: @This()) @This() {
            self.box.strong += 1;
            return self;
        }

        /// 释放一个强引用，归零后先执行析构钩子和字段清理，再释放隐含弱引用。
        pub fn release(self: @This()) void {
            const box = self.box;
            box.strong -= 1;
            if (box.strong == 0) {
                if (box.hook) |hook| hook(box.hook_context, &box.value);
                if (box.drop) |drop| drop(&box.value);
                box.releaseWeak();
            }
        }

        /// 增加弱引用计数并返回弱句柄，弱句柄本身不延长载荷寿命。
        pub fn weak(self: @This()) WeakPtr(T) {
            self.box.weak += 1;
            return .{ .box = self.box };
        }
    };
}

/// 构造弱引用句柄类型，只保留控制块，访问对象前必须升级为强引用。
pub fn WeakPtr(comptime T: type) type {
    return struct {
        pub const saphine_memory_kind: ValueKind = .weak;
        box: *ArcBox(T),

        /// 增加弱引用计数并复制句柄，不影响强引用和载荷寿命。
        pub fn retain(self: @This()) @This() {
            self.box.weak += 1;
            return self;
        }

        /// 释放一个弱引用，最后一个弱引用消失后回收控制块。
        pub fn release(self: @This()) void {
            self.box.releaseWeak();
        }

        /// 对象仍有强引用时增加计数并返回强句柄，已开始销毁时返回空值。
        pub fn upgrade(self: @This()) ?ArcPtr(T) {
            if (self.box.strong == 0) return null;
            return (ArcPtr(T){ .box = self.box }).retain();
        }
    };
}

/// 包装追踪收集器，默认共享进程级实例，也允许显式提供独立收集器。
pub const GC = struct {
    manager: Manager = .{},
    collector: *Collector,

    /// 返回共享收集器的轻量句柄，不创建新的收集器或分配堆。
    pub fn new() GC {
        return .{ .collector = &shared };
    }

    /// 返回收集器的原始字节分配接口，分配内容在显式 free 前保持固定存活。
    pub fn allocator(self: GC) Allocator {
        return self.collector.allocator();
    }

    /// 将对象初值和编译期追踪回调交给收集器，返回不自动登记根的 GC 句柄。
    pub fn create(self: GC, comptime T: type, value: T, comptime trace: ?*const fn (*Collector, *const T) void) Allocator.Error!GcPtr(T) {
        return self.collector.create(T, value, trace);
    }

    /// 对所持收集器执行一次显式标记清扫，保留可达及固定存活的对象。
    pub fn collect(self: GC) void {
        self.collector.collect();
    }

    /// 从 GC 指针头登记显式根，返回需由调用方释放的根句柄。
    pub fn root(self: GC, ptr: anytype) Allocator.Error!Collector.Root {
        return self.collector.root(ptr.header());
    }

    var shared: Collector = .{ .backing = std.heap.page_allocator };
};

/// 构造追踪 GC 对象句柄，保存控制块指针并暴露载荷与对象头，不执行引用计数。
pub fn GcPtr(comptime T: type) type {
    return struct {
        pub const saphine_memory_kind: ValueKind = .gc;
        box: *GcBox(T),

        /// 返回 GC 对象的载荷地址，对象存活必须由根或可达关系保证。
        pub fn get(self: @This()) *T {
            return &self.box.value;
        }

        /// 返回对象头，供收集器标记、显式根和托管视图保存对象身份。
        pub fn header(self: @This()) *Collector.Header {
            return &self.box.header;
        }
    };
}

/// 将通用 GC 对象头和具体类型载荷放在同一分配中，便于回调恢复具体对象。
fn GcBox(comptime T: type) type {
    return struct {
        header: Collector.Header,
        value: T,
    };
}

/// 使用显式根和栈帧扫描执行非移动标记清扫，以对象数量阈值触发自动收集。
pub const Collector = struct {
    const Self = @This();
    const Bytes = RawBlock(Header);
    /// 保存对象链表、待扫描链表和追踪／销毁回调，使不同载荷共享收集器。
    pub const Header = struct {
        next: ?*Header = null,
        pending: ?*Header = null,
        marked: bool = false,
        pinned: bool = false,
        trace: ?*const fn (*Self, *Header) void = null,
        destroy: *const fn (*Self, *Header) void,
    };

    /// 保存一组临时根的地址及扫描回调，按后进先出方式关联到收集器。
    pub const Frame = struct {
        previous: ?*Frame = null,
        context: *anyopaque,
        visit: *const fn (*Self, *anyopaque) void,

        /// 将当前帧压入根帧链表，扫描时由回调从 context 恢复具体值。
        pub fn push(frame: *Frame, collector: *Self) void {
            frame.previous = collector.frames;
            collector.frames = frame;
        }

        /// 校验当前帧为栈顶后恢复前一帧，防止根帧生命周期顺序错误。
        pub fn pop(frame: *Frame, collector: *Self) void {
            std.debug.assert(collector.frames == frame);
            collector.frames = frame.previous;
        }
    };

    /// 持有单个显式根记录，通过释放句柄从收集器根链表中移除对象。
    pub const Root = struct {
        collector: *Self,
        entry: *Entry,
        /// 将根对象头串成独立链表，避免依赖语言栈帧的存活时间。
        const Entry = struct { next: ?*Entry, object: *Header };

        /// 从根链表摘除记录并释放记录存储，不直接销毁目标对象。
        pub fn deinit(handle: *@This()) void {
            var link = &handle.collector.roots;
            while (link.* != handle.entry) link = &link.*.?.next;
            link.* = handle.entry.next;
            handle.collector.backing.destroy(handle.entry);
            handle.* = undefined;
        }
    };

    backing: Allocator,
    objects: ?*Header = null,
    pending: ?*Header = null,
    frames: ?*Frame = null,
    roots: ?*Root.Entry = null,
    allocated: usize = 0,
    threshold: usize = 256,

    /// 分配并链接显式根记录，返回可单独撤销该根的句柄。
    pub fn root(self: *Self, object: *Header) Allocator.Error!Root {
        const entry = try self.backing.create(Root.Entry);
        entry.* = .{ .next = self.roots, .object = object };
        self.roots = entry;
        return .{ .collector = self, .entry = entry };
    }

    /// 分配对象前检查数量阈值，达到阈值时先收集不可达对象。
    fn beforeAlloc(self: *Self) void {
        if (self.allocated >= self.threshold) self.collect();
    }

    /// 将完成初始化的对象加入对象链表并增加计数，避免扫描尚未初始化的载荷。
    fn publish(self: *Self, header: *Header) void {
        header.next = self.objects;
        self.objects = header;
        self.allocated += 1;
    }

    /// 暂时登记初值中的引用为根，必要时收集后分配对象，并安装类型专用的回调。
    pub fn create(self: *Self, comptime T: type, value: T, comptime trace: ?*const fn (*Self, *const T) void) Allocator.Error!GcPtr(T) {
        const Box = GcBox(T);
        // 为当前载荷类型适配通用对象头回调和分配前初值追踪回调。
        const Ops = struct {
            /// 从对象头恢复具体控制块，调用载荷类型提供的追踪函数。
            fn scan(collector: *Self, header: *Header) void {
                const box: *Box = @fieldParentPtr("header", header);
                trace.?(collector, &box.value);
            }

            /// 从通用对象头恢复分配块并交还底层分配器。
            fn destroy(collector: *Self, header: *Header) void {
                const box: *Box = @fieldParentPtr("header", header);
                collector.backing.destroy(box);
            }

            /// 从临时根上下文恢复对象初值，保护分配前收集期间引用的子对象。
            fn scanInput(collector: *Self, context: *anyopaque) void {
                const input: *const T = @ptrCast(@alignCast(context));
                trace.?(collector, input);
            }
        };
        var input = value;
        var frame: Frame = undefined;
        if (trace != null) {
            frame = .{ .context = &input, .visit = Ops.scanInput };
            frame.push(self);
        }
        defer if (trace != null) frame.pop(self);
        self.beforeAlloc();
        const box = try self.backing.create(Box);
        box.* = .{
            .header = .{ .trace = if (trace != null) Ops.scan else null, .destroy = Ops.destroy },
            .value = input,
        };
        self.publish(&box.header);
        return .{ .box = box };
    }

    /// 为未标记对象设置标记并加入待扫描链表，重复访问直接跳过以支持循环图。
    pub fn mark(self: *Self, object: *Header) void {
        if (object.marked) return;
        object.marked = true;
        object.pending = self.pending;
        self.pending = object;
    }

    /// 标记根帧、显式根和固定缓冲区的可达对象，清扫其余对象后按存活数量更新阈值。
    pub fn collect(self: *Self) void {
        var frame = self.frames;
        while (frame) |current| : (frame = current.previous) current.visit(self, current.context);
        var entry = self.roots;
        while (entry) |current| : (entry = current.next) self.mark(current.object);
        var object = self.objects;
        while (object) |current| : (object = current.next) {
            if (current.pinned) self.mark(current);
        }
        while (self.pending) |current| {
            self.pending = current.pending;
            current.pending = null;
            if (current.trace) |trace| trace(self, current);
        }
        var link = &self.objects;
        self.allocated = 0;
        while (link.*) |current| {
            if (current.marked) {
                current.marked = false;
                self.allocated += 1;
                link = &current.next;
            } else {
                link.* = current.next;
                current.destroy(self, current);
            }
        }
        self.threshold = @max(256, self.allocated *| 2);
    }

    /// 返回固定原始缓冲区的 Zig allocator，free 撤销固定标记，最终释放由收集完成。
    pub fn allocator(self: *Self) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocBytes,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = freeBytes,
        } };
    }

    /// 必要时先收集，再分配带 GC 头的固定缓冲区并发布到对象链表。
    fn allocBytes(context: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(context));
        self.beforeAlloc();
        const bytes = Bytes.alloc(self.backing, len, alignment, .{ .pinned = true, .destroy = destroyBytes }, ret) orelse return null;
        self.publish(&Bytes.fromPayload(bytes).metadata);
        return bytes;
    }

    /// 撤销原始缓冲区的固定存活标记，内存稍后由收集器统一回收。
    fn freeBytes(_: *anyopaque, bytes: []u8, _: Alignment, _: usize) void {
        Bytes.fromPayload(bytes.ptr).metadata.pinned = false;
    }

    /// 从 GC 对象头恢复原始字节块，按其保存的布局释放整个分配。
    fn destroyBytes(self: *Self, header: *Header) void {
        const block: *Bytes = @fieldParentPtr("metadata", header);
        block.free(self.backing, 0);
    }
};

/// 供已有单元测试检查 allocator 的动态容器和高对齐分配行为。
fn exerciseAllocator(allocator: Allocator) !void {
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(allocator);
    for (0..4096) |index| try list.append(allocator, @intCast(index));
    try std.testing.expectEqual(@as(u32, 4095), list.items[4095]);

    const aligned = try allocator.alignedAlloc(u8, .fromByteUnits(128), 19);
    defer allocator.free(aligned);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(aligned.ptr) % 128);
}

test "all four managers provide a Zig allocator" {
    const heap = Heap.newWith(std.testing.allocator);
    var arena = Arena.new(heap);
    defer arena.deinit();
    var arc = Arc.new(heap);
    var collector: Collector = .{ .backing = std.testing.allocator };
    defer collector.collect();
    const gc: GC = .{ .collector = &collector };

    try exerciseAllocator(heap.allocator());
    try exerciseAllocator(arena.allocator());
    try exerciseAllocator(arc.allocator());
    try exerciseAllocator(gc.allocator());

    const heap_object = try heap.create(u32, 11);
    defer heap.destroy(heap_object);
    const arena_object = try arena.create(u32, 22);
    try std.testing.expectEqual(@as(u32, 11), heap_object.*);
    try std.testing.expectEqual(@as(u32, 22), arena_object.*);
    try std.testing.expect(arena.reset(.retain_capacity));
}

test "ARC runs cleanup once and keeps a weak control block alive" {
    const Payload = struct {
        drops: *usize,
        fn drop(value: *@This()) void {
            value.drops.* += 1;
        }
    };
    var drops: usize = 0;
    const arc = Arc.new(Heap.newWith(std.testing.allocator));
    const first = try arc.create(Payload, .{ .drops = &drops }, Payload.drop);
    const second = first.retain();
    const weak = first.weak();
    const upgraded = weak.upgrade().?;
    upgraded.release();
    first.release();
    try std.testing.expectEqual(@as(usize, 0), drops);
    second.release();
    try std.testing.expectEqual(@as(usize, 1), drops);
    try std.testing.expect(weak.upgrade() == null);
    weak.release();
}

test "GC traces cycles and pins Zig allocations until free" {
    const Node = struct {
        next: ?GcPtr(@This()) = null,
        fn scan(collector: *Collector, node: *const @This()) void {
            if (node.next) |next| collector.mark(next.header());
        }
    };
    var collector: Collector = .{ .backing = std.testing.allocator };
    defer collector.collect();
    const gc: GC = .{ .collector = &collector };
    const first = try gc.create(Node, .{}, Node.scan);
    var root = try gc.root(first);
    const second = try gc.create(Node, .{ .next = first }, Node.scan);
    first.get().next = second;

    const bytes = try gc.allocator().alloc(u8, 5);
    bytes[0] = 42;
    gc.collect();
    try std.testing.expectEqual(@as(u8, 42), bytes[0]);
    try std.testing.expectEqual(@as(usize, 3), collector.allocated);

    root.deinit();
    gc.collect();
    try std.testing.expectEqual(@as(usize, 1), collector.allocated);
    gc.allocator().free(bytes);
    gc.collect();
    try std.testing.expectEqual(@as(usize, 0), collector.allocated);
}

test "GC keeps initialization input alive when allocation triggers collection" {
    const Parent = struct {
        child: GcPtr(u32),

        fn scan(collector: *Collector, parent: *const @This()) void {
            collector.mark(parent.child.header());
        }
    };
    var collector: Collector = .{ .backing = std.testing.allocator, .threshold = 1 };
    defer collector.collect();
    const child = try collector.create(u32, 53, null);
    const parent = try collector.create(Parent, .{ .child = child }, Parent.scan);
    try std.testing.expectEqual(@as(usize, 2), collector.allocated);
    try std.testing.expectEqual(@as(u32, 53), parent.get().child.get().*);
}

test "managers propagate allocator exhaustion" {
    const heap = Heap.newWith(std.testing.failing_allocator);
    var arena = Arena.new(heap);
    defer arena.deinit();
    const arc = Arc.new(heap);
    var collector: Collector = .{ .backing = std.testing.failing_allocator };
    const gc: GC = .{ .collector = &collector };

    try std.testing.expectError(error.OutOfMemory, heap.create(u32, 0));
    try std.testing.expectError(error.OutOfMemory, arena.create(u32, 0));
    try std.testing.expectError(error.OutOfMemory, arc.create(u32, 0, null));
    try std.testing.expectError(error.OutOfMemory, gc.create(u32, 0, null));
    try std.testing.expect(collector.objects == null);
}

/// 复制值后递归保留其中的 ARC、弱引用或 View，供编译器生成的聚合复制使用。
pub fn copyValue(value: anytype) @TypeOf(value) {
    var result = value;
    retainValue(&result);
    return result;
}

/// 按类型分类递归增加聚合值内部的引用，普通值和纯 GC 句柄无需增加计数。
fn retainValue(slot: anytype) void {
    switch (comptime valueKind(@TypeOf(slot.*))) {
        .arc, .weak, .view => _ = slot.retain(),
        .structure => {
            const info = @typeInfo(@TypeOf(slot.*)).@"struct";
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") retainValue(&@field(slot.*, name));
            }
        },
        .array => for (slot) |*element| retainValue(element),
        .optional => if (slot.*) |*payload| retainValue(payload),
        .tagged => switch (slot.*) {
            inline else => |*payload| retainValue(payload),
        },
        else => {},
    }
}

/// 递归释放当前有效字段、数组元素或载荷持有的引用，不回收普通值存储。
pub fn dropValue(slot: anytype) void {
    switch (comptime valueKind(@TypeOf(slot.*))) {
        .arc, .weak, .view => slot.release(),
        .structure => {
            const info = @typeInfo(@TypeOf(slot.*)).@"struct";
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") dropValue(&@field(slot.*, name));
            }
        },
        .array => for (slot) |*element| dropValue(element),
        .optional => if (slot.*) |*payload| dropValue(payload),
        .tagged => switch (slot.*) {
            inline else => |*payload| dropValue(payload),
        },
        else => {},
    }
}

/// 先替换目标值再清理旧值，确保新值已安装后才触发旧引用的析构。
pub fn replaceValue(target: anytype, value: @TypeOf(target.*)) void {
    var previous = target.*;
    target.* = value;
    dropValue(&previous);
}

/// 根据类型递归标记 GC 句柄及 View 所有者，跳过编译期字段和非追踪值。
pub fn traceValue(collector: *Collector, slot: anytype) void {
    switch (comptime valueKind(@TypeOf(slot.*))) {
        .gc => collector.mark(slot.header()),
        .view => if (slot.owner == .gc) collector.mark(slot.owner.gc),
        .structure => {
            const info = @typeInfo(@TypeOf(slot.*)).@"struct";
            inline for (info.field_names, info.field_attrs) |name, attrs| {
                if (!attrs.@"comptime") traceValue(collector, &@field(slot.*, name));
            }
        },
        .array => for (slot) |*element| traceValue(collector, element),
        .optional => if (slot.*) |*payload| traceValue(collector, payload),
        .tagged => switch (slot.*) {
            inline else => |*payload| traceValue(collector, payload),
        },
        else => {},
    }
}

/// 将值按托管标记或 Zig 类型类别分类，统一驱动复制、清理和追踪。
const ValueKind = enum { plain, arc, weak, gc, view, structure, array, optional, tagged };

/// 优先读取运行库句柄标记，否则按 Zig 反射区分聚合类型与普通值。
fn valueKind(comptime T: type) ValueKind {
    return switch (@typeInfo(T)) {
        .@"struct" => if (@hasDecl(T, "saphine_memory_kind")) T.saphine_memory_kind else .structure,
        .array => .array,
        .optional => .optional,
        .@"union" => |info| if (info.tag_type != null) .tagged else .plain,
        else => .plain,
    };
}

/// 为指定槽生成类型专用追踪回调，构造尚未压入收集器的根帧。
pub fn rootFrame(slot: anytype) Collector.Frame {
    const Pointer = @TypeOf(slot);
    return .{
        .context = slot,
        .visit = struct {
            /// 从擦除指针恢复根槽类型，递归扫描该槽当前保存的引用。
            fn scan(collector: *Collector, context: *anyopaque) void {
                const pointer: Pointer = @ptrCast(@alignCast(context));
                traceValue(collector, pointer);
            }
        }.scan,
    };
}

/// 将生成程序的局部根帧登记到共享 GC 收集器。
pub fn pushFrame(frame: *Collector.Frame) void {
    frame.push(GC.new().collector);
}

/// 从共享 GC 收集器撤销当前栈顶根帧，结束局部值保活。
pub fn popFrame(frame: *Collector.Frame) void {
    frame.pop(GC.new().collector);
}

/// 按值类型生成字段清理回调并创建 ARC 对象，分配失败时终止生成程序。
pub fn createArc(arc: Arc, value: anytype) ArcPtr(@TypeOf(value)) {
    const T = @TypeOf(value);
    return arc.create(T, value, struct {
        /// 将具体载荷的清理委托给递归值清理，实现聚合字段引用释放。
        fn drop(slot: *T) void {
            dropValue(slot);
        }
    }.drop) catch @panic("saphine: out of memory");
}

/// 在普通 ARC 对象上保存语言析构方法及环境，使强引用归零时先执行自定义钩子。
pub fn createArcWithHook(arc: Arc, value: anytype, hook: anytype) ArcPtr(@TypeOf(value)) {
    const result = createArc(arc, value);
    result.box.hook = hook.function;
    result.box.hook_context = hook.context;
    return result;
}

/// 按值类型生成递归追踪回调并创建 GC 对象，分配失败时终止生成程序。
pub fn createGc(gc: GC, value: anytype) GcPtr(@TypeOf(value)) {
    const T = @TypeOf(value);
    return gc.create(T, value, struct {
        /// 使用递归值追踪扫描具体载荷中的 GC 引用和托管视图。
        fn trace(collector: *Collector, slot: *const T) void {
            traceValue(collector, slot);
        }
    }.trace) catch @panic("saphine: out of memory");
}

pub const GcRoot = Collector.Root;

/// 为生成程序登记显式 GC 根，分配根记录失败时报告内存不足。
pub fn rootGc(gc: GC, value: anytype) Collector.Root {
    return gc.root(value) catch @panic("saphine: out of memory");
}

/// 擦除视图所有者的具体载荷类型，ARC 保存计数操作，GC 保存可追踪对象头。
pub const ViewOwner = union(enum) {
    arc: struct {
        box: *anyopaque,
        acquire: *const fn (*anyopaque) void,
        release: *const fn (*anyopaque) void,
    },
    gc: *Collector.Header,
};

/// 从托管句柄提取统一所有者，ARC 生成类型擦除计数回调，GC 直接使用对象头。
pub fn ownerOf(handle: anytype) ViewOwner {
    const Pointer = @TypeOf(handle);
    switch (comptime valueKind(Pointer)) {
        .view => return handle.owner,
        .gc => return .{ .gc = handle.header() },
        .arc => {
            // 将当前 ARC 句柄类型的计数操作适配为无类型所有者回调。
            const Erased = struct {
                /// 从擦除控制块指针恢复句柄，并增加一次强引用。
                fn acquire(box: *anyopaque) void {
                    const value: Pointer = .{ .box = @ptrCast(@alignCast(box)) };
                    _ = value.retain();
                }
                /// 从擦除控制块指针恢复句柄，并释放一次强引用。
                fn release(box: *anyopaque) void {
                    const value: Pointer = .{ .box = @ptrCast(@alignCast(box)) };
                    value.release();
                }
            };
            return .{ .arc = .{
                .box = handle.box,
                .acquire = Erased.acquire,
                .release = Erased.release,
            } };
        },
        else => @compileError("expected a managed owner"),
    }
}

/// 构造绑定方法载荷，将具体调用函数与擦除的接收者地址组合保存。
pub fn BoundMethod(comptime F: type) type {
    return struct {
        invoke: F,
        receiver: *anyopaque,
    };
}

/// 构造带所有者的派生值视图，使切片、地址或绑定方法在使用期间保活原对象。
pub fn View(comptime T: type) type {
    return struct {
        pub const saphine_memory_kind: ValueKind = .view;
        owner: ViewOwner,
        value: T,

        /// 调用绑定方法载荷，在普通参数之前补入接收者地址及所有者。
        pub fn call(self: @This(), args: anytype) @typeInfo(@typeInfo(@TypeOf(self.value.invoke)).pointer.child).@"fn".return_type.? {
            return @call(.auto, self.value.invoke, .{ self.value.receiver, self.owner } ++ args);
        }

        /// ARC 所有者增加强引用；GC 所有者通过根扫描保活，无需计数。
        pub fn retain(self: @This()) void {
            if (self.owner == .arc) self.owner.arc.acquire(self.owner.arc.box);
        }

        /// 释放 ARC 所有者引用，GC 所有者不做直接销毁。
        pub fn release(self: @This()) void {
            if (self.owner == .arc) self.owner.arc.release(self.owner.arc.box);
        }
    };
}

/// 将派生值和所有者组合为视图，并取得视图持有的一份所有权。
pub fn makeView(owner: ViewOwner, value: anytype) View(@TypeOf(value)) {
    const result: View(@TypeOf(value)) = .{ .owner = owner, .value = value };
    result.retain();
    return result;
}

/// 以无关字节作为载荷构造视图，仅用于保留所有者而不暴露对象内容。
pub fn pinOwner(owner: ViewOwner) View(u8) {
    return makeView(owner, @as(u8, 0));
}

test "ARC weak upgrades fail while the deinitializer is running" {
    const Payload = struct {
        observed: *?WeakPtr(@This()),
        expired: *bool,

        fn drop(value: *@This()) void {
            if (value.observed.*.?.upgrade()) |unexpected| {
                unexpected.release();
            } else {
                value.expired.* = true;
            }
        }
    };
    var observed: ?WeakPtr(Payload) = null;
    var expired = false;
    const arc = Arc.new(Heap.newWith(std.testing.allocator));
    const object = try arc.create(Payload, .{ .observed = &observed, .expired = &expired }, Payload.drop);
    observed = object.weak();
    defer observed.?.release();
    object.release();
    try std.testing.expect(expired);
}
