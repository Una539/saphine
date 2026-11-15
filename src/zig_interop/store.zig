//! 管理 Zig 文件、声明索引、具名模块和资源，通过规范路径复用加载结果并发现传递依赖。
const std = @import("std");
const Ast = std.zig.Ast;
const Text = []const u8;

/// 将顶层声明名关联到 AST 节点和公开标记，供语义分析按需解析。
pub const Declaration = struct {
    node: Ast.Node.Index,
    public: bool,
};

/// 保存解析后的 Zig 文件及声明索引，结合配置和来源区分模块身份。
pub const File = struct {
    path: Text,
    source: [:0]const u8,
    tree: Ast,
    declarations: std.StringHashMapUnmanaged(Declaration) = .empty,
    config: Text,
    system: bool,
    embedded: bool = false,
    id: usize,
};

/// 保存具名模块入口、依赖映射及资源和链接选项，供导出与构建复用。
pub const Package = struct {
    root: Text,
    package_root: ?Text = null,
    imports: []const Import = &.{},
    resources: []const Text = &.{},
    libraries: []const Text = &.{},
    library_dirs: []const Text = &.{},
    libc: bool = false,
    all_named: bool = false,

    /// 将包内的导入名称映射到配置中的模块名称，允许模块使用本地别名。
    pub const Import = struct { name: Text, module: Text };
};

/// 缓存资源内容和所属包，以便连同依赖源码生成可搬移快照。
pub const Resource = struct { path: Text, data: Text, config: Text };

/// 保存单次编译的 Zig 依赖图，缓存内嵌标准库、运行库和读取失败的诊断。
pub const Store = struct {
    a: std.mem.Allocator,
    io: std.Io,
    named: std.StringHashMapUnmanaged(Package) = .empty,
    files: std.ArrayList(*File) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    std_root: ?Text = null,
    stdlib: ?*File = null,
    runtime: ?*File = null,
    failure: ?Failure = null,

    /// 保存 Zig 解析或依赖发现失败的源码位置，供主编译流程统一报告。
    pub const Failure = struct { path: Text, source: Text, at: usize, message: Text };

    /// 按标准库名称、.zig 后缀或 zig: 前缀识别由本模块处理的导入。
    pub fn isImport(name: Text) bool {
        return std.mem.eql(u8, name, "std") or std.mem.endsWith(u8, name, ".zig") or std.mem.startsWith(u8, name, "zig:");
    }

    /// 区分 Saphine 标准库、Zig 标准库、运行库和具名模块，否则按相对路径加载。
    pub fn resolveImport(self: *Store, importer: Text, name: Text) !*File {
        if (std.mem.eql(u8, name, "std")) return self.loadStdlib();
        if (std.mem.eql(u8, name, "zig:saphine_runtime")) return self.loadRuntime();
        if (std.mem.eql(u8, name, "zig:std")) {
            const root = self.std_root orelse return error.MissingZigStandardLibrary;
            return self.load(try std.fs.path.join(self.a, &.{ root, "std.zig" }), "std", true);
        }
        if (std.mem.startsWith(u8, name, "zig:module/")) {
            const module = name["zig:module/".len..];
            return self.load((self.named.get(module) orelse return error.UnknownZigModule).root, module, false);
        }
        if (std.mem.startsWith(u8, name, "zig:")) return error.UnknownZigModule;
        return self.load(try relative(self.a, importer, name), "", false);
    }

    /// 相对导入者文件目录规范化依赖路径，拒绝直接声明绝对路径。
    pub fn relative(a: std.mem.Allocator, importer: Text, path: Text) !Text {
        if (std.fs.path.isAbsolute(path)) return error.AbsoluteZigDependency;
        return std.fs.path.resolve(a, &.{ std.fs.path.dirname(importer) orelse ".", path });
    }

    /// 按真实路径和配置查缓存，否则读取源码、解析 Zig AST 并建立声明索引。
    pub fn load(self: *Store, path: Text, config: Text, system: bool) !*File {
        const dir = std.Io.Dir.cwd();
        const canonical = try dir.realPathFileAlloc(self.io, path, self.a);
        for (self.files.items) |file| {
            if (std.mem.eql(u8, canonical, file.path) and std.mem.eql(u8, config, file.config) and system == file.system) return file;
        }
        const bytes = try dir.readFileAlloc(self.io, canonical, self.a, .limited(32 * 1024 * 1024));
        const source = try self.a.dupeSentinel(u8, bytes, 0);
        const tree = try Ast.parse(self.a, source, .{});
        if (tree.errors.len != 0) {
            const parse_error = tree.errors[0];
            var message: std.Io.Writer.Allocating = .init(self.a);
            try tree.renderError(parse_error, &message.writer);
            self.failure = .{ .path = canonical, .source = source, .at = tree.tokenStart(parse_error.token), .message = try message.toOwnedSlice() };
            return error.InvalidZigSource;
        }
        return self.indexFile(canonical, source, tree, config, system, false);
    }

    /// 解析编译器内嵌的内存运行库并缓存，以同一模块身份供生成程序使用。
    fn loadRuntime(self: *Store) !*File {
        if (self.runtime) |file| return file;
        const source = @embedFile("../stdlib/memory.zig");
        const tree = try Ast.parse(self.a, source, .{});
        if (tree.errors.len != 0) return error.InvalidEmbeddedZigRuntime;
        const file = try self.indexFile("saphine/stdlib/memory.zig", source, tree, "", false, false);
        self.runtime = file;
        return file;
    }

    /// 解析并缓存内嵌标准库入口，标记其源码由后端直接嵌入而非单独导出。
    pub fn loadStdlib(self: *Store) !*File {
        if (self.stdlib) |file| return file;
        const source = @embedFile("../stdlib/root.zig");
        const tree = try Ast.parse(self.a, source, .{});
        if (tree.errors.len != 0) return error.InvalidEmbeddedZigStdlib;
        const file = try self.indexFile("saphine/stdlib/root.zig", source, tree, "", false, true);
        self.stdlib = file;
        return file;
    }

    /// 索引顶层函数和变量，解码标识符并拒绝重名声明，为文件分配模块编号。
    fn indexFile(self: *Store, path: Text, source: [:0]const u8, tree: Ast, config: Text, system: bool, embedded: bool) !*File {
        const file = try self.a.create(File);
        file.* = .{ .path = path, .source = source, .tree = tree, .config = config, .system = system, .embedded = embedded, .id = self.files.items.len };
        for (tree.rootDecls()) |node| {
            var buffer: [1]Ast.Node.Index = undefined;
            const token, const public = if (tree.fullFnProto(&buffer, node)) |proto|
                .{ proto.name_token orelse continue, proto.visib_token != null }
            else if (tree.fullVarDecl(node)) |decl|
                .{ decl.ast.mut_token + 1, decl.visib_token != null }
            else
                continue;
            const raw = tree.tokenSlice(token);
            const name = if (std.mem.startsWith(u8, raw, "@\"")) try std.zig.string_literal.parseAlloc(self.a, raw[1..]) else raw;
            if (file.declarations.contains(name)) {
                self.failure = .{ .path = path, .source = source, .at = tree.tokenStart(token), .message = "duplicate Zig declaration" };
                return error.InvalidZigSource;
            }
            try file.declarations.put(self.a, name, .{ .node = node, .public = public });
        }
        try self.files.append(self.a, file);
        return file;
    }

    /// 解析 Zig 内部 @import，应用具名依赖映射并对本地文件检查符号链接路径差异。
    pub fn importedFile(self: *Store, from: *File, name: Text) !*File {
        if (std.mem.eql(u8, name, "std")) return self.resolveImport(from.path, "zig:std");
        if (!from.system and std.mem.eql(u8, name, "saphine_runtime") and !self.named.contains(name))
            return self.loadRuntime();
        if (from.config.len != 0 and !from.system) {
            const config = self.named.get(from.config).?;
            if (config.all_named) {
                if (self.named.get(name)) |package| return self.load(package.root, name, false);
            } else for (config.imports) |dep| {
                if (!std.mem.eql(u8, dep.name, name)) continue;
                const package = self.named.get(dep.module) orelse return error.UnknownZigModule;
                return self.load(package.root, dep.module, false);
            }
        } else if (!from.system) {
            if (self.named.get(name)) |package| return self.load(package.root, name, false);
        }
        if (!std.mem.endsWith(u8, name, ".zig")) return error.UnknownZigModule;
        const path = try relative(self.a, from.path, name);
        const file = try self.load(path, from.config, from.system);
        if (!std.mem.eql(u8, file.path, path)) return error.ZigDependencySymlink;
        return file;
    }

    /// 检查是否加载了除内嵌标准库之外的 Zig 文件，以决定是否需要 Zig 验证。
    pub fn hasZigImports(self: *const Store) bool {
        return self.files.items.len > @as(usize, @intFromBool(self.stdlib != null));
    }

    /// 查找非系统且非内嵌文件，判断是否需要为输出程序打包依赖源码。
    pub fn hasExternalFiles(self: *const Store) bool {
        for (self.files.items) |file| {
            if (!file.embedded and !file.system) return true;
        }
        return false;
    }

    /// 加载配置入口与资源，迭代扫描新增文件的 @import 和 @embedFile，补全依赖图。
    pub fn discover(self: *Store) !void {
        var packages = self.named.iterator();
        while (packages.next()) |entry| {
            const package = entry.value_ptr.*;
            const module = entry.key_ptr.*;
            const root = try self.load(package.root, module, false);
            for (package.resources) |resource| {
                const package_root = package.package_root orelse std.fs.path.dirname(root.path).?;
                if (std.fs.path.isAbsolute(resource)) return error.AbsoluteZigDependency;
                try self.addResource(module, try std.fs.path.resolve(self.a, &.{ package_root, resource }));
            }
        }
        var index: usize = 0;
        while (index < self.files.items.len) : (index += 1) {
            const file = self.files.items[index];
            if (file.system or file.embedded) continue;
            for (0..file.tree.nodes.len) |raw| {
                const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
                const token = file.tree.nodeMainToken(node);
                if (file.tree.tokenTag(token) != .builtin) continue;
                const builtin = file.tree.tokenSlice(token);
                const importing = std.mem.eql(u8, builtin, "@import");
                if (!importing and !std.mem.eql(u8, builtin, "@embedFile")) continue;
                var buffer: [2]Ast.Node.Index = undefined;
                const args = file.tree.builtinCallParams(&buffer, node) orelse continue;
                if (args.len != 1 or file.tree.nodeTag(args[0]) != .string_literal) {
                    self.failure = .{ .path = file.path, .source = file.source, .at = file.tree.tokenStart(token), .message = "Zig dependency must use a literal path" };
                    return error.UnsupportedZigDependency;
                }
                self.discoverPath(file, importing, file.tree.tokenSlice(file.tree.nodeMainToken(args[0]))) catch |err| {
                    if (self.failure == null) self.failure = .{
                        .path = file.path,
                        .source = file.source,
                        .at = file.tree.tokenStart(token),
                        .message = try std.fmt.allocPrint(self.a, "cannot package Zig dependency: {s}", .{@errorName(err)}),
                    };
                    return err;
                };
            }
        }
    }

    /// 解码字面量路径后加载模块或资源，标准库和 builtin 交由 Zig 自身提供。
    fn discoverPath(self: *Store, file: *File, importing: bool, literal: Text) !void {
        const name = try std.zig.string_literal.parseAlloc(self.a, literal);
        if (importing) {
            if (std.mem.eql(u8, name, "std") or std.mem.eql(u8, name, "builtin")) return;
            _ = try self.importedFile(file, name);
            return;
        }
        try self.addResource(file.config, try relative(self.a, file.path, name));
    }

    /// 按路径和配置去重资源，拒绝符号链接路径差异并读取内容供导出使用。
    fn addResource(self: *Store, config: Text, path: Text) !void {
        for (self.resources.items) |resource| {
            if (std.mem.eql(u8, resource.path, path) and std.mem.eql(u8, resource.config, config)) return;
        }
        const canonical = try std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.a);
        if (!std.mem.eql(u8, canonical, path)) return error.ZigDependencySymlink;
        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, path, self.a, .limited(64 * 1024 * 1024));
        try self.resources.append(self.a, .{ .path = path, .data = data, .config = config });
    }
};
