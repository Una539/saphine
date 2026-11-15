//! 命令行编译入口，串联模块加载、语义分析、Zig 生成及原生构建，并统一输出诊断。
const std = @import("std");
const syntax = @import("parser.zig");
const Analyzer = @import("semantic.zig").Analyzer;
const ir = @import("ir.zig");
const Loader = @import("module_loader.zig").Loader;

/// 启动命令处理并捕获错误，避免重复输出已报告诊断，失败时设置退出状态。
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.Reported)
            std.Io.File.stderr().writeStreamingAll(init.io, std.fmt.allocPrint(init.arena.allocator(), "saphine: {s}\n", .{@errorName(err)}) catch @panic("out of memory")) catch {};
        std.process.exit(1);
    };
}

/// 解析编译选项并执行选定流程，必要时暂存依赖、调用 Zig 并导出源码映射或程序。
fn run(init: std.process.Init) !void {
    var arena = @import("stdlib/memory.zig").Arena.new(.newWith(init.arena.allocator()));
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    const command = if (args.len >= 3) std.meta.stringToEnum(Command, args[1]) else null;
    if (command == null) return usage(init);
    const dir = std.Io.Dir.cwd();
    const zig = init.environ_map.get("SAPHINE_ZIG") orelse "zig";
    var store: ZigStore = .{ .a = a, .io = io };
    var output: ?[]const u8 = null;
    var target: []const u8 = "native";
    var optimize: std.builtin.OptimizeMode = .debug;
    var target_given = false;
    var package_config: ?[]const u8 = null;
    var optimize_given = false;
    var index: usize = 3;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return usage(init);
        const flag = args[index];
        const value = args[index + 1];
        if (same(flag, "-o") and output == null) {
            output = value;
        } else if (same(flag, "--target") and !target_given) {
            target = value;
            target_given = true;
        } else if (same(flag, "--optimize") and !optimize_given) {
            optimize = std.meta.stringToEnum(std.builtin.OptimizeMode, value) orelse
                (if (same(value, "Debug")) .debug else if (same(value, "ReleaseSafe")) .safe else if (same(value, "ReleaseFast")) .fast else if (same(value, "ReleaseSmall")) .small else return usage(init));
            optimize_given = true;
        } else if (same(flag, "--zig-config") and package_config == null) {
            package_config = value;
        } else if (same(flag, "--zig-module")) {
            const equal = std.mem.indexOfScalar(u8, value, '=') orelse return usage(init);
            const name = value[0..equal];
            if (!validModuleName(name) or equal + 1 == value.len) return usage(init);
            if (store.named.contains(name)) return error.DuplicateZigModule;
            try store.named.put(a, name, .{ .root = value[equal + 1 ..], .all_named = true });
        } else return usage(init);
    }
    if ((command.? == .check) != (output == null)) return usage(init);
    if (package_config) |path| try loadPackageConfig(&store, path);
    try checkVersion(init, zig);
    store.std_root = try stdRoot(init, zig);
    var loader: Loader = .{ .a = a, .io = io, .zig_store = &store };
    const entry = loader.loadTree(null, args[2]) catch |err| {
        if (loader.failure) |failure| {
            const entry_path = dir.realPathFileAlloc(io, args[2], a) catch null;
            const path = if (entry_path != null and std.mem.eql(u8, entry_path.?, failure.path)) args[2] else failure.path;
            writeDiagnostic(init, path, failure.source, failure.diagnostic);
            if (loader.foreign_import_failure) |site| {
                if (!same(site.path, failure.path)) writeDiagnostic(init, site.path, site.source, site.diagnostic);
            }
            return error.Reported;
        }
        try std.Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(a, "{s}: {s}\n", .{ args[2], @errorName(err) }));
        return error.Reported;
    };
    var diag: syntax.Diagnostic = .{};
    var analyzer: Analyzer = .{ .a = a, .diag = &diag, .zig_store = &store, .zig_backend = zig, .zig_target = target, .zig_optimize = @tagName(optimize) };
    const module = analyzer.analyzeModule(entry) catch {
        const failed = analyzer.pub_failure orelse entry;
        return report(init, if (failed == entry) args[2] else failed.path, failed.source, diag);
    };
    for (analyzer.warnings.items) |warning|
        writeDiagnosticWithSeverity(init, warning.path, warning.source, .{ .at = warning.at, .message = warning.message }, "warning");
    if (command.? == .check and !store.hasZigImports() and store.named.count() == 0 and !target_given and !optimize_given) return;
    store.discover() catch |err| {
        if (store.failure) |failure|
            return report(init, failure.path, failure.source, .{ .at = failure.at, .message = failure.message });
        return err;
    };
    const filename = if (command.? == .@"emit-zig") std.fs.path.basename(output.?) else "program.zig";
    const artifact = try Artifact.init(&store, entry.path, filename, target, @tagName(optimize), zig);
    const generated = try ir.emitZig(a, module, try artifact.imports());
    const code = try formatZig(init, generated.code);
    const formatted = try std.zig.Ast.parse(a, try a.dupeSentinel(u8, code, 0), .{});
    const ranges = try source_map.collect(a, formatted, module, generated.names);
    const has_bundle = store.hasExternalFiles() or store.named.count() != 0 or target_given or optimize_given;
    const staged = command.? != .@"emit-zig" or store.hasZigImports() or has_bundle;
    if (staged) {
        try dir.createDirPath(io, ".saphine-cache");
        var nonce: [12]u8 = undefined;
        try io.randomSecure(&nonce);
        const temp = try std.fmt.allocPrint(a, ".saphine-cache/{x}", .{&nonce});
        try dir.createDirPath(io, temp);
        defer dir.deleteTree(io, temp) catch {};
        try artifact.writeDependencies(temp);
        const input = try std.fs.path.join(a, &.{ temp, filename });
        try dir.writeFile(io, .{ .sub_path = input, .data = code });
        const staged_binary = if (command.? == .build)
            try std.fmt.allocPrint(a, "{s}/.saphine-output-{x}", .{ std.fs.path.dirname(output.?) orelse ".", &nonce })
        else
            "";
        defer if (command.? == .build) dir.deleteFile(io, staged_binary) catch {};
        const emit_bin = if (command.? == .build) try std.fmt.allocPrint(a, "-femit-bin={s}", .{staged_binary}) else "-fno-emit-bin";
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{
            zig,                  "build-exe",             "--color", "off", "--cache-dir", ".saphine-cache/local",
            "--global-cache-dir", ".saphine-cache/global", emit_bin,
        });
        try artifact.appendModules(&argv, temp, filename);
        const result = try std.process.run(a, io, .{ .argv = argv.items });
        try std.Io.File.stdout().writeStreamingAll(io, result.stdout);
        if (!succeeded(result)) return reportZig(init, artifact, temp, input, code, ranges, result.stderr);
        try std.Io.File.stderr().writeStreamingAll(io, result.stderr);
        if (command.? == .build) try dir.rename(staged_binary, dir, output.?, io);
    }
    if (command.? == .@"emit-zig") {
        const parent = std.fs.path.dirname(output.?) orelse ".";
        if (has_bundle) {
            try artifact.writeDependencies(parent);
            try artifact.writeManifest(parent, filename);
        }
        try dir.writeFile(io, .{ .sub_path = output.?, .data = code });
        const map_path = try std.fmt.allocPrint(a, "{s}.map.json", .{output.?});
        const map_ranges = try a.dupe(source_map.Range, ranges);
        const base = std.fs.path.dirname(entry.path) orelse ".";
        for (map_ranges) |*range| {
            range.source.path = source_map.relative(base, range.source.path);
            if (range.specialization) |*site| site.path = source_map.relative(base, site.path);
        }
        const json = try std.json.Stringify.valueAlloc(a, .{ .version = @as(u32, 1), .generated = filename, .mappings = map_ranges }, .{ .whitespace = .indent_2 });
        try dir.writeFile(io, .{ .sub_path = map_path, .data = json });
        if (has_bundle) {
            try std.Io.File.stderr().writeStreamingAll(io, try std.fmt.allocPrint(a, "Copy {s} with {s}. Rebuild with sh {s}/build.sh\n", .{ output.?, artifact.dependency_dir, try std.fs.path.join(a, &.{ parent, artifact.dependency_dir }) }));
        }
    }
}

const source_map = @import("source_map.zig");

/// 解析 Zig 报错位置并用源码映射关联原调用或声明，无法映射时保留生成代码诊断。
fn reportZig(init: std.process.Init, artifact: Artifact, directory: []const u8, input: []const u8, code: []const u8, ranges: []const source_map.Range, diagnostics: []const u8) error{Reported} {
    const a = init.arena.allocator();
    const stderr = std.Io.File.stderr();
    var lines = std.mem.splitScalar(u8, diagnostics, '\n');
    var mapped = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var rendered = line;
        for (artifact.store.files.items) |file| {
            if (file.system or file.embedded) continue;
            const snapshot = artifact.snapshotPath(file.config, file.path) catch continue;
            const staged = std.fs.path.join(a, &.{ directory, snapshot }) catch continue;
            if (std.mem.indexOf(u8, line, staged)) |index| {
                rendered = std.fmt.allocPrint(a, "{s}{s}{s}", .{ line[0..index], file.path, line[index + staged.len ..] }) catch line;
                break;
            }
        }
        stderr.writeStreamingAll(init.io, rendered) catch {};
        stderr.writeStreamingAll(init.io, "\n") catch {};
        if (mapped) continue;
        const index = std.mem.indexOf(u8, line, input) orelse continue;
        const location = line[index + input.len ..];
        if (location.len == 0 or location[0] != ':') continue;
        var parts = std.mem.splitScalar(u8, location[1..], ':');
        const row = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch continue;
        const column = std.fmt.parseInt(usize, parts.next() orelse continue, 10) catch continue;
        const offset = source_map.byteOffset(code, row, column) orelse continue;
        var best: ?source_map.Range = null;
        for (ranges) |range| {
            if (!range.call_site or offset < range.generated_start or offset >= range.generated_end) continue;
            if (best == null or range.generated_end - range.generated_start < best.?.generated_end - best.?.generated_start)
                best = range;
        }
        if (best) |range| {
            const source = std.Io.Dir.cwd().readFileAlloc(init.io, range.source.path, a, .limited(8 * 1024 * 1024)) catch continue;
            writeDiagnostic(init, range.source.path, source, .{ .at = range.source.start, .message = "Zig validation failed at this external call" });
            mapped = true;
        }
    }
    if (!mapped and std.mem.startsWith(u8, diagnostics, input))
        stderr.writeStreamingAll(init.io, "saphine: Zig reported an error in generated code\n") catch {};
    return error.Reported;
}

/// 枚举对外编译命令，用于参数校验及检查、导出和构建流程选择。
const Command = enum { check, @"emit-zig", build };
const ZigStore = @import("zig_interop/store.zig").Store;
const Package = @import("zig_interop/store.zig").Package;
const Artifact = @import("zig_interop/artifact.zig").Artifact;
const zig_version = "0.17.1";

/// 按字节比较命令参数和配置名称，避免切片地址影响结果。
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// 将命令用法写到标准错误，并标记该错误已报告。
fn usage(init: std.process.Init) error{Reported} {
    std.Io.File.stderr().writeStreamingAll(init.io, "Usage: saphine check <source> [options]\n" ++
        "       saphine emit-zig <source> -o <file.zig> [options]\n" ++
        "       saphine build <source> -o <executable> [options]\n" ++
        "Options: --target <triple> --optimize <mode> --zig-module <name=root.zig> --zig-config <path.json>\n") catch {};
    return error.Reported;
}

/// 拒绝空名、Zig 保留模块名及非字母数字下划线字符，约束具名模块配置。
fn validModuleName(name: []const u8) bool {
    if (name.len == 0 or same(name, "std") or same(name, "builtin") or same(name, "root")) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

/// 读取版本化 JSON 模块清单，按包根解析路径并核对模块名称、导入映射与依赖存在性。
fn loadPackageConfig(store: *ZigStore, path: []const u8) !void {
    const a = store.a;
    const dir = std.Io.Dir.cwd();
    const canonical = try dir.realPathFileAlloc(store.io, path, a);
    const base = std.fs.path.dirname(canonical) orelse return error.InvalidPackagePath;
    const json = try dir.readFileAlloc(store.io, canonical, a, .limited(1024 * 1024));
    // 用与 JSON 对应的局部结构解码模块选项，路径稍后相对配置文件规范化。
    const Config = struct {
        version: u32,
        modules: []const struct {
            name: []const u8,
            root: []const u8,
            package_root: []const u8 = ".",
            imports: []const Package.Import = &.{},
            resources: []const []const u8 = &.{},
            libraries: []const []const u8 = &.{},
            library_dirs: []const []const u8 = &.{},
            libc: bool = false,
        },
    };
    const config = try std.json.parseFromSliceLeaky(Config, a, json, .{});
    if (config.version != 1) return error.UnsupportedPackageVersion;
    for (config.modules) |module| {
        if (!validModuleName(module.name)) return error.InvalidZigModuleName;
        if (store.named.contains(module.name)) return error.DuplicateZigModule;
        const package_root = try std.fs.path.resolve(a, &.{ base, module.package_root });
        const root = try std.fs.path.resolve(a, &.{ package_root, module.root });
        const library_dirs = try a.alloc([]const u8, module.library_dirs.len);
        for (module.library_dirs, library_dirs) |relative, *absolute|
            absolute.* = try std.fs.path.resolve(a, &.{ package_root, relative });
        for (module.imports, 0..) |dep, index| {
            if (!validModuleName(dep.name)) return error.InvalidZigModuleName;
            for (module.imports[0..index]) |previous| {
                if (same(previous.name, dep.name)) return error.DuplicateZigModule;
            }
        }
        try store.named.put(a, module.name, .{
            .root = root,
            .package_root = package_root,
            .imports = module.imports,
            .resources = module.resources,
            .libraries = module.libraries,
            .library_dirs = library_dirs,
            .libc = module.libc,
        });
    }
    for (config.modules) |module| for (module.imports) |dep| {
        if (!store.named.contains(dep.module)) return error.UnknownZigModule;
    };
}

/// 仅将正常退出且状态码为零的子进程判定为成功。
fn succeeded(result: std.process.RunResult) bool {
    return result.term == .exited and result.term.exited == 0;
}

/// 执行 zig version 并精确核对项目所需版本，失败时显示实际版本和工具路径。
fn checkVersion(init: std.process.Init, zig: []const u8) !void {
    const a = init.arena.allocator();
    const result = try std.process.run(a, init.io, .{ .argv = &.{ zig, "version" } });
    const actual = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (succeeded(result) and same(actual, zig_version)) return;
    try std.Io.File.stderr().writeStreamingAll(init.io, try std.fmt.allocPrint(a, "saphine: expected Zig {s}, got '{s}' from {s}\n{s}", .{ zig_version, actual, zig, result.stderr }));
    return error.Reported;
}

/// 执行 zig env 并解析返回的 ZON 数据，取得当前工具链标准库目录。
fn stdRoot(init: std.process.Init, zig: []const u8) ![]const u8 {
    const a = init.arena.allocator();
    const result = try std.process.run(a, init.io, .{ .argv = &.{ zig, "env" } });
    if (!succeeded(result)) return error.ZigEnvironmentUnavailable;
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const environment = try std.zon.parse.fromSlice(struct { std_dir: []const u8 }, .{
        .gpa = a,
        .arena = a,
        .source = try a.dupeSentinel(u8, result.stdout, 0),
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    return environment.std_dir;
}

/// 将生成源码解析为 Zig AST 后重新渲染，语法错误按生成源码位置报告。
fn formatZig(init: std.process.Init, code: []const u8) ![]const u8 {
    const a = init.arena.allocator();
    const tree = try std.zig.Ast.parse(a, try a.dupeSentinel(u8, code, 0), .{});
    if (tree.errors.len != 0) {
        const diagnostic = tree.errors[0];
        var message: std.Io.Writer.Allocating = .init(a);
        try tree.renderError(diagnostic, &message.writer);
        return report(init, "<generated Zig>", code, .{ .at = tree.tokenStart(diagnostic.token), .message = message.written() });
    }
    return tree.renderAlloc(a);
}

/// 输出一个源码错误并返回已报告标记，阻止外层再输出通用错误。
fn report(init: std.process.Init, path: []const u8, source: []const u8, diag: syntax.Diagnostic) error{Reported} {
    writeDiagnostic(init, path, source, diag);
    return error.Reported;
}

/// 使用默认 error 严重级别输出源码诊断，复用统一的位置格式。
fn writeDiagnostic(init: std.process.Init, path: []const u8, source: []const u8, diag: syntax.Diagnostic) void {
    writeDiagnosticWithSeverity(init, path, source, diag, "error");
}

/// 从字节偏移计算行列，将错误或警告按文件、位置和消息写到标准错误。
fn writeDiagnosticWithSeverity(init: std.process.Init, path: []const u8, source: []const u8, diag: syntax.Diagnostic, severity: []const u8) void {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(source.len, diag.at)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else column += 1;
    }
    const message = std.fmt.allocPrint(init.arena.allocator(), "{s}:{d}:{d}: {s}: {s}\n", .{ path, line, column, severity, diag.message }) catch @panic("out of memory");
    std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
}
