//! 实现持久化位图哈希前缀树，通过路径复制保留旧快照，并用完整键处理哈希碰撞。
const std = @import("std");

/// 创建使用 Wyhash 的名称映射类型；更新返回新根，旧版本仍可继续查找。
pub fn Hamt(comptime V: type) type {
    return HamtWithHasher(V, wyhash);
}

/// 对名称使用固定种子的 Wyhash，生成分支选择所需的 64 位哈希。
fn wyhash(key: []const u8) u64 {
    return std.hash.Wyhash.hash(0, key);
}

/// 创建自定义哈希的持久化映射，逐层使用位图索引分支，完整碰撞保存在桶中。
pub fn HamtWithHasher(comptime V: type, comptime hash: fn ([]const u8) u64) type {
    return struct {
        const Self = @This();
        /// 保存完整键和值，使碰撞桶能够按名称而非哈希区分成员。
        const Entry = struct { key: []const u8, value: V };
        /// 节点为碰撞桶或位图分支，分支仅保存存在的子节点以减少空槽。
        const Node = union(enum) {
            bucket: []const Entry,
            branch: struct { bitmap: u32, children: []const *const Node },
        };
        root: ?*const Node = null,

        /// 取当前深度的五个哈希位，生成对应分支的位图掩码。
        fn bit(h: u64, depth: u8) u32 {
            return @as(u32, 1) << @as(u5, @intCast((h >> @as(u6, @intCast(depth * 5))) & 31));
        }
        /// 使用调用方分配器保存不可变节点，供新旧树共享引用。
        fn node(a: std.mem.Allocator, value: Node) *const Node {
            const p = a.create(Node) catch @panic("out of memory");
            p.* = value;
            return p;
        }
        /// 按哈希逐层定位分支，抵达桶后比较完整键并返回匹配值。
        pub fn get(self: Self, key: []const u8) ?V {
            var p = self.root orelse return null;
            const h = hash(key);
            var depth: u8 = 0;
            while (true) switch (p.*) {
                .bucket => |entries| {
                    for (entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
                    return null;
                },
                .branch => |b| {
                    const mask = bit(h, depth);
                    if (b.bitmap & mask == 0) return null;
                    p = b.children[@popCount(b.bitmap & (mask - 1))];
                    depth += 1;
                },
            };
        }
        /// 路径复制插入或替换键值，并返回持有新根的映射而不修改原树。
        pub fn put(self: Self, a: std.mem.Allocator, key: []const u8, value: V) Self {
            return .{ .root = insert(a, self.root, .{ .key = key, .value = value }, hash(key), 0) };
        }
        /// 递归复制受影响节点，按需拆分桶，哈希耗尽或完全碰撞时保留碰撞桶。
        fn insert(a: std.mem.Allocator, old: ?*const Node, entry: Entry, h: u64, depth: u8) *const Node {
            const p = old orelse {
                const entries = a.alloc(Entry, 1) catch @panic("out of memory");
                entries[0] = entry;
                return node(a, .{ .bucket = entries });
            };
            switch (p.*) {
                .bucket => |entries| {
                    for (entries, 0..) |e, i| if (std.mem.eql(u8, e.key, entry.key)) {
                        const copy = a.dupe(Entry, entries) catch @panic("out of memory");
                        copy[i] = entry;
                        return node(a, .{ .bucket = copy });
                    };
                    if (depth == 13 or hash(entries[0].key) == h) {
                        const copy = a.alloc(Entry, entries.len + 1) catch @panic("out of memory");
                        @memcpy(copy[0..entries.len], entries);
                        copy[entries.len] = entry;
                        return node(a, .{ .bucket = copy });
                    }
                    var branch = node(a, .{ .branch = .{ .bitmap = 0, .children = &.{} } });
                    for (entries) |e| branch = insert(a, branch, e, hash(e.key), depth);
                    return insert(a, branch, entry, h, depth);
                },
                .branch => |b| {
                    const mask = bit(h, depth);
                    const i = @popCount(b.bitmap & (mask - 1));
                    const exists = b.bitmap & mask != 0;
                    const children = a.alloc(*const Node, b.children.len + @as(usize, if (exists) 0 else 1)) catch @panic("out of memory");
                    @memcpy(children[0..i], b.children[0..i]);
                    children[i] = insert(a, if (exists) b.children[i] else null, entry, h, depth + 1);
                    @memcpy(children[i + 1 ..], b.children[i + @as(usize, if (exists) 1 else 0) ..]);
                    return node(a, .{ .branch = .{ .bitmap = b.bitmap | mask, .children = children } });
                },
            }
        }
    };
}

test "persistent trie branches and snapshots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var trie: Hamt(usize) = .{};
    for (0..1000) |i| {
        const key = try std.fmt.allocPrint(a, "member{d}", .{i});
        trie = trie.put(a, key, i);
    }
    const old = trie;
    trie = trie.put(a, "member42", 9999);
    try std.testing.expectEqual(@as(?usize, 42), old.get("member42"));
    try std.testing.expectEqual(@as(?usize, 9999), trie.get("member42"));
    for (0..1000) |i| {
        const key = try std.fmt.allocPrint(a, "member{d}", .{i});
        try std.testing.expectEqual(@as(?usize, i), old.get(key));
    }
    try std.testing.expectEqual(@as(?usize, null), trie.get("absent"));
}

/// 为已有碰撞用例生成固定哈希，覆盖完整碰撞及最高有效位的分支差异。
fn collisionHash(key: []const u8) u64 {
    return switch (key[0]) {
        'a', 'b' => 0,
        'c' => @as(u64, 1) << 60,
        'd' => @as(u64, 1) << 63,
        else => 31,
    };
}

test "full collisions, final hash nibble, bucket splitting and replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var trie: HamtWithHasher(usize, collisionHash) = .{};
    trie = trie.put(a, "a", 1);
    trie = trie.put(a, "b", 2);
    const collision = trie;
    trie = trie.put(a, "c", 3);
    trie = trie.put(a, "d", 4);
    trie = trie.put(a, "e", 5);
    const before = trie;
    trie = trie.put(a, "b", 20);
    try std.testing.expectEqual(@as(?usize, 1), trie.get("a"));
    try std.testing.expectEqual(@as(?usize, 20), trie.get("b"));
    try std.testing.expectEqual(@as(?usize, 3), trie.get("c"));
    try std.testing.expectEqual(@as(?usize, 4), trie.get("d"));
    try std.testing.expectEqual(@as(?usize, 5), trie.get("e"));
    try std.testing.expectEqual(@as(?usize, 2), before.get("b"));
    try std.testing.expectEqual(@as(?usize, 2), collision.get("b"));
    try std.testing.expectEqual(@as(?usize, null), collision.get("c"));
    try std.testing.expectEqual(@as(?usize, null), trie.get("absent"));
}
