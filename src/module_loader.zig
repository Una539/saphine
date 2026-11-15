//! 加载并缓存 Saphine 文件图，解析相对导入与循环关系，再把文件规范化为结构体 AST。
const std = @import("std");
const ZigStore = @import("zig_interop/store.zig").Store;
const syntax = @import("parser.zig");

/// 保存已解析文件、规范化容器和导入关系，供同一次编译的多个导入位置共享。
pub const Module = struct {
    path: []const u8,
    source: []const u8,
    statements: []syntax.Stmt,
    container: *syntax.Expr,
    active: bool = false,

    embedded_imports: []EmbeddedImport = &.{},
    imports_loaded: bool = false,

    /// 将 use 类型表达式关联到已加载的 Saphine 或 Zig 模块，供语义阶段直接定位。
    pub const EmbeddedImport = struct {
        expression: *const syntax.Expr,
        module: union(enum) { lang: *Module, zig: *@import("zig_interop/store.zig").File },
    };
};

/// 将文件语句映射为普通结构体成员，保留声明及初始化顺序以复用统一容器语义。
pub fn normalizeFile(a: std.mem.Allocator, statements: []syntax.Stmt) !*syntax.Expr {
    const container = try a.create(syntax.Expr);
    var fields: std.ArrayList(syntax.Field) = .empty;
    for (statements) |*statement| {
        const placeholder: syntax.Token = .{ .tag = .name, .text = "", .at = statement.at };
        const field: syntax.Field = switch (statement.data) {
            .use => |use| .{ .name = use.name, .ty = use.ty, .embedded = true, .visibility = use.visibility },
            .visibility_redeclaration => |declaration| .{ .name = placeholder, .ty = declaration.path, .embedded = false, .visibility = declaration.visibility, .redeclaration = true },
            .binding => |binding| .{ .name = binding.name, .ty = binding.value, .embedded = false, .declaration = statement },
            else => .{ .name = placeholder, .ty = container, .embedded = false, .declaration = statement },
        };
        try fields.append(a, field);
    }
    container.* = .{ .at = 0, .data = .{ .structure = try fields.toOwnedSlice(a) } };
    return container;
}

/// 保存单次编译的文件缓存和导入栈，源码及 AST 随调用方分配器存活，不提供并发保护。
pub const Loader = struct {
    a: std.mem.Allocator,
    io: std.Io,
    zig_store: ?*ZigStore = null,
    modules: std.StringHashMapUnmanaged(*Module) = .empty,
    /// Set on parse failure; path and source remain valid for the loader's lifetime.
    failure: ?Failure = null,
    foreign_import_failure: ?Failure = null,
    active_stack: std.ArrayList(*Module) = .empty,

    /// 保存负责本次加载失败的文件、源码及诊断，允许调用方准确显示导入错误。
    pub const Failure = struct {
        path: []const u8,
        source: []const u8,
        diagnostic: syntax.Diagnostic,
    };

    /// 从入口或导入者目录解析文件；无扩展名时同时尝试 .saph 与 mod.saph，拒绝歧义。
    pub fn load(self: *Loader, importer: ?*const Module, request: []const u8) !*Module {
        self.failure = null;
        const module = self.loadImpl(importer, request) catch |err| {
            if (self.failure == null) self.failure = .{
                .path = if (importer) |m| m.path else request,
                .source = if (importer) |m| m.source else "",
                .diagnostic = .{ .message = try self.importMessage(request, err) },
            };
            return err;
        };
        return module;
    }

    /// 选择显式文件或目录入口并规范化路径，复用缓存，否则读取和解析源码。
    fn loadImpl(self: *Loader, importer: ?*const Module, request: []const u8) !*Module {
        if (request.len == 0 or std.mem.indexOfScalar(u8, request, 0) != null) return error.InvalidModulePath;
        const base = if (importer) |m| std.fs.path.dirname(m.path) orelse return error.InvalidModulePath else ".";
        const path = try std.fs.path.resolve(self.a, &.{ base, request });
        // Inspect the request before resolve removes a trailing separator.
        const directory_request = std.fs.path.isSep(request[request.len - 1]) or
            std.mem.eql(u8, std.fs.path.basename(request), ".") or
            std.mem.eql(u8, std.fs.path.basename(request), "..");
        const resolved = if (directory_request)
            try self.existingFile(try std.fs.path.join(self.a, &.{ path, "mod.saph" }))
        else if (std.fs.path.extension(path).len != 0) blk: {
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound, error.NotDir => return error.ModuleNotFound,
                else => return err,
            };
            break :blk try self.existingFile(if (stat.kind == .directory)
                try std.fs.path.join(self.a, &.{ path, "mod.saph" })
            else
                path);
        } else blk: {
            const file = try std.fmt.allocPrint(self.a, "{s}.saph", .{path});
            const mod = try std.fs.path.join(self.a, &.{ path, "mod.saph" });
            const first = try self.optionalFile(file);
            const second = try self.optionalFile(mod);
            if (first != null and second != null) return error.AmbiguousModule;
            break :blk first orelse second orelse return error.ModuleNotFound;
        };
        if (self.modules.get(resolved)) |cached| {
            if (cached.active) {
                self.failure = .{
                    .path = if (importer) |m| m.path else resolved,
                    .source = if (importer) |m| m.source else cached.source,
                    .diagnostic = .{ .message = try self.cycleMessage(cached) },
                };
                return error.ImportCycle;
            }
            return cached;
        }
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, resolved, self.a, .limited(8 * 1024 * 1024));
        var diag: syntax.Diagnostic = .{};
        var parser: syntax.Parser = .{ .a = self.a, .diag = &diag, .lexer = .{ .a = self.a, .source = source, .diag = &diag } };
        const statements = parser.parse() catch |err| {
            self.failure = .{ .path = resolved, .source = source, .diagnostic = diag };
            return err;
        };
        const module = try self.a.create(Module);
        module.* = .{ .path = resolved, .source = source, .statements = statements, .container = try normalizeFile(self.a, statements) };
        try self.modules.put(self.a, resolved, module);
        return module;
    }

    /// 加载根文件及完整导入图，按源码顺序关联缓存模块，并保留失败的责任文件。
    pub fn loadTree(self: *Loader, importer: ?*const Module, request: []const u8) !*Module {
        const module = try self.load(importer, request);
        try self.loadImports(module);
        return module;
    }

    /// 扫描模块的全部导入，只有完整扫描成功后发布结果，避免留下部分导入状态。
    fn loadImports(self: *Loader, module: *Module) !void {
        if (module.imports_loaded) return;
        try self.begin(module);
        defer self.end(module);
        // Publish import lists only after the complete scan succeeds, so retries
        // never observe partial results from an earlier failed traversal.
        var embedded: std.ArrayList(Module.EmbeddedImport) = .empty;
        try self.scanExpr(module, module.container, &embedded);
        module.embedded_imports = try embedded.toOwnedSlice(self.a);
        module.imports_loaded = true;
    }

    /// 递归扫描语句中的类型、表达式和嵌套块，发现其中的文件嵌入。
    fn scanStatements(self: *Loader, module: *Module, statements: []syntax.Stmt, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        for (statements) |stmt| switch (stmt.data) {
            .binding => |b| {
                if (b.ty) |ty| try self.scanExpr(module, ty, imports);
                try self.scanExpr(module, b.value, imports);
            },
            .visibility_redeclaration => |v| try self.scanExpr(module, v.path, imports),
            .assign => |v| {
                try self.scanExpr(module, v.left, imports);
                try self.scanExpr(module, v.right, imports);
            },
            .ret => |v| if (v) |e| try self.scanExpr(module, e, imports),
            .expr, .defer_expr, .using => |e| try self.scanExpr(module, e, imports),
            .block => |body| try self.scanStatements(module, body, imports),
            .conditional => |v| try self.scanIf(module, v, imports),
            .matching => |v| try self.scanMatch(module, v, imports),
            .loop => |v| {
                try self.scanExpr(module, v.condition, imports);
                try self.scanStatements(module, v.body, imports);
            },
            .for_each => |v| {
                try self.scanExpr(module, v.items, imports);
                try self.scanStatements(module, v.body, imports);
            },
            .use => |v| try self.scanUse(module, v.ty, imports),
            .loop_exit => {},
        };
    }

    /// 对字符串 use 解码路径并加载相应语言或 Zig 模块，其他形式继续扫描表达式。
    fn scanUse(self: *Loader, module: *Module, ty: *syntax.Expr, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        if (ty.data != .string) return self.scanExpr(module, ty, imports);
        const path = try self.importString(module, ty.data.string, ty.at);
        if (ZigStore.isImport(path)) {
            const store = self.zig_store orelse return error.MissingZigStore;
            const child = store.resolveImport(module.path, path) catch |err| {
                self.foreign_import_failure = .{
                    .path = module.path,
                    .source = module.source,
                    .diagnostic = .{ .at = ty.at, .message = "while importing this Zig module" },
                };
                self.failure = if (store.failure) |failure| .{
                    .path = failure.path,
                    .source = failure.source,
                    .diagnostic = .{ .at = failure.at, .message = failure.message },
                } else .{
                    .path = module.path,
                    .source = module.source,
                    .diagnostic = .{ .at = ty.at, .message = try std.fmt.allocPrint(self.a, "cannot import Zig module '{s}': {s}", .{ path, @errorName(err) }) },
                };
                return err;
            };
            try imports.append(self.a, .{ .expression = ty, .module = .{ .zig = child } });
            return;
        }
        const child = try self.loadAt(module, path, ty.at);
        try self.loadImports(child);
        try imports.append(self.a, .{ .expression = ty, .module = .{ .lang = child } });
    }

    /// 扫描分支体与可选尾值，收集两处可能出现的嵌入导入。
    fn scanBranch(self: *Loader, module: *Module, branch: syntax.Branch, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        try self.scanStatements(module, branch.body, imports);
        if (branch.tail) |tail| try self.scanExpr(module, tail, imports);
    }

    /// 扫描条件及所有分支，不在加载阶段按运行时条件裁剪依赖。
    fn scanIf(self: *Loader, module: *Module, value: syntax.If, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        try self.scanExpr(module, value.condition, imports);
        try self.scanBranch(module, value.yes, imports);
        if (value.no) |no| try self.scanBranch(module, no, imports);
    }

    /// 扫描匹配主体和全部分支，将其中的嵌入模块纳入文件图。
    fn scanMatch(self: *Loader, module: *Module, value: syntax.Match, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        try self.scanExpr(module, value.subject, imports);
        for (value.arms) |arm| try self.scanBranch(module, arm.branch, imports);
    }

    /// 遍历表达式的子节点，重点处理结构体嵌入、函数体及复合类型中的导入。
    fn scanExpr(self: *Loader, module: *Module, expr: *syntax.Expr, imports: *std.ArrayList(Module.EmbeddedImport)) anyerror!void {
        switch (expr.data) {
            .structure => |fields| for (fields) |field| {
                if (field.declaration) |declaration| {
                    try self.scanStatements(module, @as(*[1]syntax.Stmt, declaration), imports);
                } else if (field.embedded) {
                    try self.scanUse(module, field.ty, imports);
                } else try self.scanExpr(module, field.ty, imports);
            },
            .unary => |v| try self.scanExpr(module, v.operand, imports),
            .binary => |v| {
                try self.scanExpr(module, v.left, imports);
                try self.scanExpr(module, v.right, imports);
            },
            .member => |v| try self.scanExpr(module, v.base, imports),
            .call => |v| {
                try self.scanExpr(module, v.callee, imports);
                for (v.args) |arg| try self.scanExpr(module, arg, imports);
            },
            .object => |v| {
                if (v.ty) |ty| try self.scanExpr(module, ty, imports);
                for (v.fields) |field| try self.scanExpr(module, field.value, imports);
            },
            .enumeration => |variants| for (variants) |variant| {
                if (variant.ty) |ty| try self.scanExpr(module, ty, imports);
            },
            .matching => |v| try self.scanMatch(module, v, imports),
            .function => |v| {
                for (v.params) |param| try self.scanExpr(module, param.ty, imports);
                try self.scanExpr(module, v.result, imports);
                if (v.body) |body| try self.scanStatements(module, body, imports);
            },
            .slice => |v| try self.scanExpr(module, v.element, imports),
            .array_type => |v| {
                try self.scanExpr(module, v.length, imports);
                try self.scanExpr(module, v.element, imports);
            },
            .array_init => |v| {
                if (v.ty) |ty| try self.scanExpr(module, ty, imports);
                for (v.elements) |element| try self.scanExpr(module, element, imports);
            },
            .index => |v| {
                try self.scanExpr(module, v.base, imports);
                try self.scanExpr(module, v.index, imports);
            },
            .subslice => |v| {
                try self.scanExpr(module, v.base, imports);
                try self.scanExpr(module, v.start, imports);
                if (v.end) |end_expr| try self.scanExpr(module, end_expr, imports);
            },
            .conditional => |v| try self.scanIf(module, v, imports),
            .name, .number, .string => {},
        }
    }

    /// 检查并解码导入字符串，拒绝无效 UTF-8、转义及 NUL 字节并记录源码位置。
    fn importString(self: *Loader, module: *const Module, raw: []const u8, at: usize) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (!std.unicode.utf8ValidateSlice(raw)) {
            self.failure = .{ .path = module.path, .source = module.source, .diagnostic = .{ .at = at, .message = "string literal must be UTF-8" } };
            return error.InvalidSource;
        }
        var i: usize = 1;
        while (i < raw.len - 1) : (i += 1) {
            var byte = raw[i];
            if (byte == '\\') {
                i += 1;
                byte = switch (raw[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\', '"' => raw[i],
                    else => {
                        self.failure = .{ .path = module.path, .source = module.source, .diagnostic = .{ .at = at + i, .message = "unsupported string escape" } };
                        return error.InvalidSource;
                    },
                };
            }
            if (byte == 0) {
                self.failure = .{ .path = module.path, .source = module.source, .diagnostic = .{ .at = at + i, .message = "module path contains a NUL byte" } };
                return error.InvalidSource;
            }
            try out.append(self.a, byte);
        }
        return out.toOwnedSlice(self.a);
    }

    /// 将模块压入活动导入栈，重复进入活动模块时生成完整循环路径诊断。
    pub fn begin(self: *Loader, module: *Module) !void {
        if (module.active) {
            self.failure = .{ .path = module.path, .source = module.source, .diagnostic = .{ .message = try self.cycleMessage(module) } };
            return error.ImportCycle;
        }
        try self.active_stack.append(self.a, module);
        module.active = true;
    }

    /// 清除模块活动标记并从导入栈移除，与成功的 begin 成对使用。
    pub fn end(self: *Loader, module: *Module) void {
        std.debug.assert(module.active);
        module.active = false;
        for (self.active_stack.items, 0..) |item, i| {
            if (item == module) {
                _ = self.active_stack.orderedRemove(i);
                break;
            }
        }
    }

    /// 在指定导入位置加载子模块，将属于导入者的错误定位到该 use 表达式。
    fn loadAt(self: *Loader, module: *Module, path: []const u8, at: usize) !*Module {
        return self.load(module, path) catch |err| {
            if (self.failure) |*failure| {
                if (std.mem.eql(u8, failure.path, module.path)) failure.diagnostic.at = at;
            }
            return err;
        };
    }

    /// 拼接活动导入栈与重复模块路径，生成可阅读的循环导入链。
    fn cycleMessage(self: *Loader, module: *Module) ![]const u8 {
        var message: std.ArrayList(u8) = .empty;
        try message.appendSlice(self.a, "import cycle: ");
        for (self.active_stack.items) |item| {
            try message.appendSlice(self.a, item.path);
            try message.appendSlice(self.a, " -> ");
        }
        try message.appendSlice(self.a, module.path);
        return message.toOwnedSlice(self.a);
    }

    /// 将路径选择及文件读取错误翻译为带请求路径的导入诊断。
    fn importMessage(self: *Loader, request: []const u8, err: anyerror) ![]const u8 {
        const reason = switch (err) {
            error.InvalidModulePath => "module path must be nonempty and contain no NUL bytes",
            error.ModuleNotFound => "module file not found (use a file extension or a trailing '/' to select explicitly)",
            error.AmbiguousModule => "both <path>.saph and <path>/mod.saph exist; specify the file or directory explicitly",
            error.AccessDenied => "permission denied while reading module",
            error.OutOfMemory => "not enough memory to load module",
            else => "unable to read module file",
        };
        return std.fmt.allocPrint(self.a, "cannot import '{s}': {s}", .{ request, reason });
    }

    /// 要求候选路径存在且为文件，否则将缺失情况转换为模块未找到错误。
    fn existingFile(self: *Loader, path: []const u8) ![]const u8 {
        return (try self.optionalFile(path)) orelse error.ModuleNotFound;
    }

    /// 查询候选文件并规范化真实路径，不存在时返回空值，其他文件系统错误继续上抛。
    fn optionalFile(self: *Loader, path: []const u8) !?[]const u8 {
        const dir = std.Io.Dir.cwd();
        const stat = dir.statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return null,
            else => return err,
        };
        if (stat.kind != .file) return null;
        return try dir.realPathFileAlloc(self.io, path, self.a);
    }
};

test "relative resolution, caching, cycles and ambiguity" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg");
    try tmp.dir.writeFile(io, .{ .sub_path = "root.saph", .data = "const root = 1;" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/mod.saph", .data = "const item = 2;" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root_path = try tmp.dir.realPathFileAlloc(io, "root.saph", a);
    var loader: Loader = .{ .a = a, .io = io };
    const root = try loader.load(null, root_path);
    const child = try loader.load(root, "pkg");
    try std.testing.expectEqual(child, try loader.load(root, "pkg/mod.saph"));
    try loader.begin(root);
    defer loader.end(root);
    try loader.begin(child);
    defer loader.end(child);
    try std.testing.expectError(error.ImportCycle, loader.load(child, "../root"));
    try std.testing.expectError(error.ModuleNotFound, loader.load(root, "missing"));
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg.saph", .data = "" });
    try std.testing.expectError(error.AmbiguousModule, loader.load(root, "pkg"));
}

test "parse failure retains source and diagnostic and can be retried" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.saph", .data = "@" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try tmp.dir.realPathFileAlloc(io, "bad.saph", a);
    var loader: Loader = .{ .a = a, .io = io };
    try std.testing.expectError(error.InvalidSource, loader.load(null, path));
    try std.testing.expectEqualStrings("@", loader.failure.?.source);
    try std.testing.expect(loader.failure.?.diagnostic.message.len > 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.saph", .data = "const x = 1;" });
    _ = try loader.load(null, path);
    try std.testing.expect(loader.failure == null);
}
