//! 将 Zig 依赖图转换为导出快照、模块参数和可重建清单，保留包内相对路径及资源。
const std = @import("std");
const Store = @import("store.zig").Store;
const ir = @import("../ir.zig");
const Text = []const u8;

/// 保存导出布局及工具链选项，统一规划依赖路径、构建参数和内容指纹。
pub const Artifact = struct {
    a: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    target: Text,
    optimize: Text,
    zig: Text,
    local_root: Text,
    dependency_dir: Text,
    requires_module_flags: bool,

    /// 计算本地依赖共同根目录及输出依赖目录，检查保留模块名并保存构建配置。
    pub fn init(store: *Store, entry: Text, output: Text, target: Text, optimize: Text, zig: Text) !Artifact {
        if (store.runtime != null and store.named.contains("saphine_runtime")) return error.ReservedZigRuntimeModule;
        var base = std.fs.path.dirname(entry) orelse return error.InvalidSourcePath;
        for (store.files.items) |file| {
            if (file == store.runtime or file.system or file.embedded or file.config.len != 0) continue;
            while (under(base, file.path) == null)
                base = std.fs.path.dirname(base) orelse return error.InvalidZigDependencyRoot;
        }
        const stem = std.fs.path.stem(std.fs.path.basename(output));
        return .{
            .a = store.a,
            .io = store.io,
            .store = store,
            .target = target,
            .zig = zig,
            .optimize = optimize,
            .local_root = base,
            .dependency_dir = try std.fmt.allocPrint(store.a, "{s}.deps", .{stem}),
            .requires_module_flags = store.runtime != null or store.named.count() != 0,
        };
    }

    /// 路径位于指定根目录内时返回相对部分，按路径分隔符检查而非单纯前缀匹配。
    fn under(root: Text, path: Text) ?Text {
        if (!std.mem.startsWith(u8, path, root) or path.len <= root.len) return null;
        if (std.fs.path.isSep(root[root.len - 1])) return path[root.len..];
        if (!std.fs.path.isSep(path[root.len])) return null;
        return path[root.len + 1 ..];
    }

    /// 按运行库、本地文件或配置包规划快照位置，拒绝落在所属根目录外的依赖。
    pub fn snapshotPath(self: Artifact, config: Text, path: Text) !Text {
        if (self.store.runtime) |runtime| {
            if (std.mem.eql(u8, path, runtime.path))
                return std.fs.path.join(self.a, &.{ self.dependency_dir, "runtime", "memory.zig" });
        }
        if (config.len == 0) {
            return std.fs.path.join(self.a, &.{ self.dependency_dir, "zig", under(self.local_root, path) orelse return error.ZigDependencyOutsideRoot });
        }
        const package = self.store.named.get(config) orelse return error.UnknownZigModule;
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, package.root, self.a);
        const base = package.package_root orelse std.fs.path.dirname(canonical) orelse return error.InvalidZigDependencyRoot;
        return std.fs.path.join(self.a, &.{ self.dependency_dir, "modules", config, under(base, path) orelse return error.ZigDependencyOutsideRoot });
    }

    /// 为需要直接引用的模块生成 IR 导入表，选择可读名称并消除名称冲突。
    pub fn imports(self: Artifact) ![]const ir.ForeignImport {
        var imports_list: std.ArrayList(ir.ForeignImport) = .empty;
        for (self.store.files.items) |file| {
            if (file.embedded) continue;
            const reference = if (file == self.store.runtime) "saphine_runtime" else if (file.system) blk: {
                const std_path = try std.fs.path.join(self.a, &.{ self.store.std_root.?, "std.zig" });
                if (!std.mem.eql(u8, file.path, std_path)) continue;
                break :blk "std";
            } else if (file.config.len != 0) blk: {
                const root = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.store.named.get(file.config).?.root, self.a);
                if (!std.mem.eql(u8, root, file.path)) continue;
                break :blk file.config;
            } else try self.snapshotPath(file.config, file.path);
            const preferred = if (file.system) "zig_std" else if (file.config.len != 0) file.config else std.fs.path.stem(file.path);
            var name = preferred;
            var collision: usize = 1;
            while (true) : (collision += 1) {
                for (imports_list.items) |previous| {
                    if (std.mem.eql(u8, previous.name, name)) break;
                } else break;
                name = try std.fmt.allocPrint(self.a, "{s}_{d}", .{ preferred, collision });
            }
            try imports_list.append(self.a, .{ .id = file.id, .name = name, .path = reference });
        }
        return imports_list.items;
    }

    /// 按导出目录和相对路径写入内容，先创建所需父目录。
    fn write(self: Artifact, directory: Text, relative: Text, bytes: Text) !void {
        const path = try std.fs.path.join(self.a, &.{ directory, relative });
        const dir = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(self.io, parent);
        try dir.writeFile(self.io, .{ .sub_path = path, .data = bytes });
    }

    /// 将非系统源码和所有已登记资源写到快照位置，保留运行库与包内布局。
    pub fn writeDependencies(self: Artifact, directory: Text) !void {
        for (self.store.files.items) |file| {
            if (!file.system and !file.embedded) try self.write(directory, try self.snapshotPath(file.config, file.path), file.source);
        }
        for (self.store.resources.items) |resource|
            try self.write(directory, try self.snapshotPath(resource.config, resource.path), resource.data);
    }

    /// 为一个 Zig 模块追加优化选项，并在非原生目标时追加目标三元组。
    fn moduleOptions(self: Artifact, argv: *std.ArrayList(Text)) !void {
        try argv.appendSlice(self.a, &.{ "-O", self.optimize });
        if (!std.mem.eql(u8, self.target, "native"))
            try argv.appendSlice(self.a, &.{ "-target", self.target });
    }

    /// 按稳定名称顺序注册根模块、运行库和具名依赖，同时加入模块映射及链接参数。
    pub fn appendModules(self: Artifact, argv: *std.ArrayList(Text), directory: Text, filename: Text) !void {
        try self.moduleOptions(argv);
        const input = try std.fs.path.join(self.a, &.{ directory, filename });
        if (!self.requires_module_flags) {
            try argv.append(self.a, input);
            return;
        }
        const names = try self.a.alloc(Text, self.store.named.count());
        var keys = self.store.named.keyIterator();
        for (names) |*name| name.* = keys.next().?.*;
        std.mem.sort(Text, names, {}, struct {
            /// 按模块名称字节序排序，避免哈希表遍历顺序改变构建参数。
            fn lessThan(_: void, a: Text, b: Text) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (names) |name| try argv.appendSlice(self.a, &.{ "--dep", name });
        if (self.store.runtime != null) try argv.appendSlice(self.a, &.{ "--dep", "saphine_runtime" });
        try argv.append(self.a, try std.fmt.allocPrint(self.a, "-Mroot={s}", .{input}));
        if (self.store.runtime) |runtime| {
            try self.moduleOptions(argv);
            const relative = try self.snapshotPath(runtime.config, runtime.path);
            const source = try std.fs.path.join(self.a, &.{ directory, relative });
            try argv.append(self.a, try std.fmt.allocPrint(self.a, "-Msaphine_runtime={s}", .{source}));
        }
        for (names) |name| {
            const path = try std.Io.Dir.cwd().realPathFileAlloc(self.io, self.store.named.get(name).?.root, self.a);
            const relative = try self.snapshotPath(name, path);
            const source = try std.fs.path.join(self.a, &.{ directory, relative });
            try self.moduleOptions(argv);
            const package = self.store.named.get(name).?;
            if (self.store.runtime != null) try argv.appendSlice(self.a, &.{ "--dep", "saphine_runtime" });
            if (package.all_named) {
                for (names) |dep| {
                    if (!std.mem.eql(u8, name, dep)) try argv.appendSlice(self.a, &.{ "--dep", dep });
                }
            } else for (package.imports) |dep| {
                try argv.appendSlice(self.a, &.{ "--dep", try std.fmt.allocPrint(self.a, "{s}={s}", .{ dep.name, dep.module }) });
            }
            if (package.libc) try argv.append(self.a, "-lc");
            for (package.libraries) |library| try argv.appendSlice(self.a, &.{ "-l", library });
            for (package.library_dirs) |path_to_library| {
                const snapshot = try self.snapshotPath(name, path_to_library);
                for (self.store.resources.items) |resource| {
                    if (std.mem.eql(u8, resource.config, name) and under(path_to_library, resource.path) != null) break;
                } else return error.ZigLibraryDirectoryHasNoPackagedResources;
                try argv.appendSlice(self.a, &.{ "-L", try std.fs.path.join(self.a, &.{ directory, snapshot }) });
            }
            try argv.append(self.a, try std.fmt.allocPrint(self.a, "-M{s}={s}", .{ name, source }));
        }
    }

    /// 将工具链、构建参数和排序后的源码资源一起计算 Blake3 指纹，以内容识别产物。
    pub fn contentKey(self: Artifact) ![32]u8 {
        const Blake3 = std.crypto.hash.Blake3;
        var hash = Blake3.init(.{});
        hashPart(&hash, "0.17.1");
        hashPart(&hash, self.zig);
        hashPart(&hash, self.target);
        hashPart(&hash, self.optimize);
        var argv: std.ArrayList(Text) = .empty;
        try self.appendModules(&argv, ".", "program.zig");
        for (argv.items) |arg| hashPart(&hash, arg);
        // 将源码和资源统一成路径与内容记录，用于稳定排序后计算指纹。
        const Input = struct { path: Text, bytes: Text };
        var inputs: std.ArrayList(Input) = .empty;
        for (self.store.files.items) |file| {
            const path = if (file.system or file.embedded) file.path else try self.snapshotPath(file.config, file.path);
            try inputs.append(self.a, .{ .path = path, .bytes = file.source });
        }
        for (self.store.resources.items) |resource| {
            try inputs.append(self.a, .{ .path = try self.snapshotPath(resource.config, resource.path), .bytes = resource.data });
        }
        std.mem.sort(Input, inputs.items, {}, struct {
            /// 按快照路径排序输入，使内容指纹不依赖依赖发现顺序。
            fn lessThan(_: void, a: Input, b: Input) bool {
                return std.mem.order(u8, a.path, b.path) == .lt;
            }
        }.lessThan);
        for (inputs.items) |input| {
            hashPart(&hash, input.path);
            hashPart(&hash, input.bytes);
        }
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return digest;
    }

    /// 先写入内容长度再写入字节，防止不同分段方式得到相同的拼接输入。
    fn hashPart(hash: *std.crypto.hash.Blake3, bytes: Text) void {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, bytes.len, .little);
        hash.update(&length);
        hash.update(bytes);
    }

    /// 导出含内容指纹的 JSON 清单及正确引用模块的 shell 构建脚本，转义所有固定参数。
    pub fn writeManifest(self: Artifact, directory: Text, filename: Text) !void {
        var argv: std.ArrayList(Text) = .empty;
        try argv.appendSlice(self.a, &.{ "zig", "build-exe" });
        try self.appendModules(&argv, ".", filename);
        const content_key = try self.contentKey();
        const contents = try std.json.Stringify.valueAlloc(self.a, .{
            .content_key = try std.fmt.allocPrint(self.a, "{x}", .{&content_key}),
            .version = @as(u32, 1),
            .zig_version = "0.17.1",
            .target = self.target,
            .optimize = self.optimize,
            .argv = argv.items,
        }, .{ .whitespace = .indent_2 });
        try self.write(directory, try std.fs.path.join(self.a, &.{ self.dependency_dir, "build.json" }), contents);
        var command: std.Io.Writer.Allocating = .init(self.a);
        try command.writer.writeAll("#!/bin/sh\nset -eu\ncd \"$(dirname \"$0\")/..\"\nzig=\"${SAPHINE_ZIG:-zig}\"\n[ \"$(\"$zig\" version)\" = 0.17.1 ] || { echo 'Zig 0.17.1 is required' >&2; exit 1; }\nexec \"$zig\"");
        for (argv.items[1..]) |argument| {
            try command.writer.writeAll(" '");
            for (argument) |byte| {
                if (byte == '\'') try command.writer.writeAll("'\\''") else try command.writer.writeByte(byte);
            }
            try command.writer.writeByte('\'');
        }
        try command.writer.writeAll(" \"$@\"\n");
        try self.write(directory, try std.fs.path.join(self.a, &.{ self.dependency_dir, "build.sh" }), command.written());
    }
};
