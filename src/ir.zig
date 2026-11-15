//! 定义类型化中间表示并生成 Zig 源码，结合符号命名、函数环境分析及运行库表达程序行为。
const std = @import("std");
const environments = @import("environments.zig");
const naming = @import("names.zig");
const Text = []const u8;

/// 列举后端支持的基础类型，数值类型连续排列以供语义阶段判定类别。
pub const Primitive = enum { i8, i16, i32, i64, i128, u8, u16, u32, u64, u128, usize, f16, f32, f64, f128, bool, void, type, bytes };
/// 区分托管句柄及只读指针接口，以选择对应运行库类型和生成规则。
pub const ManagedKind = enum { ArcPtr, WeakPtr, GcPtr, View, Ptr };
/// 表示可生成的类型，语言容器使用编号，复合类型递归引用子类型。
pub const Type = union(enum) {
    erased_context,
    managed: struct { kind: ManagedKind, child: *const Type, module: usize },
    primitive: Primitive,

    structure: usize,
    foreign: ForeignRef,
    queried: *const Expr,
    foreign_pointer: struct { child: *const Type, is_const: bool, size: std.lang.Type.Pointer.Size = .one, sentinel: ?i128 = null },
    optional: *const Type,
    error_union: struct { errors: *const Type, payload: *const Type },
    enumeration: usize,
    array: struct { length: usize, element: *const Type, sentinel: ?i128 = null },
    slice: struct { element: *const Type, is_const: bool, sentinel: ?i128 = null },
    pointer: usize,
    function: struct { params: []const Type, result: *const Type },
    zig_callback: struct { params: []const Type, result: *const Type, c_abi: bool },
};
/// 将存储名称关联到 IR 类型，用于字段、全局变量、参数和局部变量。
pub const Slot = struct { name: Text, ty: Type };
/// 保存结构体编号和有序字段，后端另行添加对象上下文字段。
pub const Layout = struct { id: usize, fields: []const Slot };
/// 保存变体名称及可选载荷类型，空载荷在 Zig 中输出为 void。
pub const EnumVariant = struct { name: Text, ty: ?Type };
/// 将枚举编号关联到变体布局，后端以带标签联合表示。
pub const EnumLayout = struct { id: usize, variants: []const EnumVariant };
/// 枚举基础算术及位运算，生成时由统一运算辅助函数选择 Zig 操作。
pub const Operation = enum { add, sub, mul, div, rem, bit_and, bit_or, bit_xor, shl, shr };
/// 区分比较与短路逻辑操作，供布尔表达式输出对应 Zig 运算符。
pub const Predicate = enum { eq, ne, lt, le, gt, ge, logical_and, logical_or };
/// 保存分支语句和可选结果，用标签块表达带结果的控制流。
pub const Branch = struct { body: []const Stmt, value: ?*const Expr = null, label: usize = 0 };
/// 组合条件与两个分支，既可作为语句也可作为有值表达式生成。
pub const Conditional = struct { test_expr: *const Expr, yes: Branch, no: ?Branch };
/// 将变体名或默认模式关联到分支及可选载荷绑定。
pub const MatchArm = struct { name: ?Text, binding: ?Text, branch: Branch };
/// 保存已检查的匹配结构，按主体类别选择 switch 或 optional／错误捕获形式。
pub const Match = struct {
    subject: *const Expr,
    arms: []const MatchArm,
    kind: enum { native, foreign_enum, optional, error_union } = .native,
};
pub const stdlib_module = std.math.maxInt(usize);
/// 保存已类型检查的字段初始化表达式，供对象构造顺序使用。
pub const Initializer = struct { name: Text, value: *const Expr };
/// 用模块编号和递归父引用表达外部声明路径，避免混入绝对文件名。
pub const ForeignRef = struct { module: usize, name: Text, parent: ?*const ForeignRef = null };
/// 关联外部模块编号、输出别名和导入路径，供后端解析外部引用。
pub const ForeignImport = struct { id: usize, name: Text, path: Text };

/// 表示已解析名称和类型的表达式，包括直接调用、上下文、托管操作及外部引用。
pub const Expr = union(enum) {
    foreign_ref: ForeignRef,
    callback_address: usize,
    zig_indirect: struct { function: *const Expr, args: []const *const Expr },
    foreign_field: struct { base: *const Expr, name: Text },
    foreign_object: struct { ty: Type, fields: []const Initializer },
    type_of: *const Expr,
    field_type: struct { ref_type: *const Expr, name: Text },
    foreign_variant: struct { ty: Type, name: Text, payload: ?*const Expr },
    typed_value: struct { ty: Type, value: *const Expr },
    optional_none: Type,
    unwrap_allocation: *const Expr,
    managed_get: *const Expr,
    preserve_result: struct { slot: Text, value: *const Expr, id: usize },
    bound_method: struct {
        module: usize,
        receiver: *const Expr,
        receiver_type: Type,
        owner: *const Expr,
        params: []const Slot,
        result: Type,
        call: *const Expr,
    },
    managed_method: struct { receiver: *const Expr, name: Text },
    managed_scope: struct { body: []const Stmt, result: *const Expr, id: usize },
    type_value: Type,
    builtin: Text,
    error_value: Text,
    foreign_call: struct { target: ForeignRef, args: []const *const Expr, site: ?usize = null },

    variable: Text,

    bound: struct { name: Text, value: *const Expr, result: *const Expr, serial: usize },

    module_object: usize,
    module_cast: struct { shape: usize, context: *const Expr },
    null_context,
    forward_context,

    object_context: *const Expr,

    range: Range,
    boolean: bool,
    number: struct { ty: Primitive, canonical: Text },
    bytes: Text,
    array_init: struct { ty: Type, elements: []const *const Expr },
    index: struct { base: *const Expr, index: *const Expr },
    subslice: struct { base: *const Expr, start: *const Expr, end: ?*const Expr },
    length: *const Expr,
    field: struct { base: *const Expr, name: Text },
    address: *const Expr,
    dereference: *const Expr,
    negate: *const Expr,
    logical_not: *const Expr,
    bit_not: *const Expr,
    predicate: struct { op: Predicate, left: *const Expr, right: *const Expr },
    conditional: Conditional,
    matching: Match,
    enum_init: struct { id: usize, name: Text, payload: ?*const Expr },
    object: struct { shape: usize, fields: []const Initializer, context: ?*const Expr = null, initializer: ?usize = null, temporary: usize = 0 },
    arithmetic: struct { op: Operation, left: *const Expr, right: *const Expr },
    function_address: struct { id: usize, context: ?*const Expr = null },
    call: struct {
        target: union(enum) { direct: usize, indirect: *const Expr },
        args: []const *const Expr,
        context: ?*const Expr = null,
    },
};
/// 保存编译期确定的整数区间及长度，生成固定长度数组。
pub const Range = struct { start: i32, end: i32, length: usize };
/// 保存循环元素、生成索引名和被遍历表达式，供 for 语句生成使用。
pub const Iteration = struct { name: Text, index_name: Text, items: *const Expr, body: []const Stmt };
/// 表示类型检查后的语句，并显式区分普通存储操作和托管清理、跟踪操作。
pub const Stmt = union(enum) {
    local: struct { slot: Slot, mutable: bool, value: *const Expr },
    managed_local: struct { slot: Slot, value: *const Expr, module: usize, id: usize, drop: bool, trace: bool },
    managed_assign: struct { target: *const Expr, value: *const Expr, module: usize },
    managed_guard: struct { target: *const Expr, module: usize, id: usize, trace: bool, drop: bool },
    assign: struct { target: *const Expr, value: *const Expr, initialize: bool = false },
    ret: ?*const Expr,
    expr: *const Expr,
    defer_expr: *const Expr,
    block: []const Stmt,
    loop: struct { condition: *const Expr, body: []const Stmt, first: ?usize },
    for_each: Iteration,
    loop_exit: enum { stop, next },
    conditional: Conditional,
    matching: Match,
};
/// 保存特化函数签名和语句体，并标明初始化对象编号或外部调用约定。
pub const Function = struct { id: usize, params: []const Slot, result: Type, body: []const Stmt, initializes: ?usize = null, c_abi: bool = false };
/// 汇总一次分析得到的布局、存储、函数和入口信息，作为 Zig 生成器的完整输入。
pub const Module = struct {
    layouts: []const Layout,
    enums: []const EnumLayout,
    globals: []const Slot,
    startup: []const Stmt,
    functions: []const Function,
    entry: usize,
    symbols: []const naming.Symbol = &.{},
    call_sites: []const naming.SourceSpan = &.{},
    local_spellings: []const Text = &.{},
    entry_context: ?*const Expr = null,
};

const Writer = std.Io.Writer;

/// 保存名称映射、导入和函数上下文信息，通过递归输出 IR 生成 Zig 源码。
const Emitter = struct {
    names: naming.NameTable,
    imports: []const ForeignImport = &.{},
    environments: environments.Table = .empty,
    current_environment: environments.Environment = .erased,
    closure_adapters: std.AutoHashMapUnmanaged(usize, void) = .empty,

    /// 按目标函数环境要求省略、擦除或转换上下文参数，已匹配的结构上下文可直接复用。
    fn emitContext(self: Emitter, w: *Writer, id: usize, expr: ?*const Expr) Writer.Error!void {
        switch (self.environments.get(id) orelse .erased) {
            .none => {},
            .erased => {
                if (expr) |context| try self.emitExpr(w, context) else try w.writeAll("null");
                try w.writeAll(", ");
            },
            .typed => |shape| {
                if (expr) |context| {
                    if (context.* == .address and context.address.* == .module_object and self.current_environment == .typed and self.current_environment.typed == shape) {
                        try w.writeAll("__saphine_context, ");
                        return;
                    }
                }
                try w.print("@as(*{f}, @ptrCast(@alignCast(@as(?*anyopaque, ", .{std.zig.fmtId(self.names.get(shape))});
                if (expr) |context| try self.emitExpr(w, context) else try w.writeAll("null");
                try w.writeAll(").?))), ");
            },
        }
    }

    /// 按模块编号查找生成代码的导入别名，缺失时返回可辨识的占位名称。
    fn importName(self: Emitter, module: usize) Text {
        for (self.imports) |import| if (import.id == module) return import.name;
        return "__saphine_unavailable_module";
    }

    /// 递归输出 Zig 类型，语言函数值使用上下文包装，外部类型保留原引用身份。
    fn emitType(self: Emitter, w: *Writer, ty: Type) Writer.Error!void {
        switch (ty) {
            .erased_context => try w.writeAll("?*anyopaque"),
            .managed => |ptr| {
                try self.emitForeignRef(w, .{ .module = ptr.module, .name = @tagName(ptr.kind) });
                try w.writeByte('(');
                if (ptr.kind == .View and ptr.child.* == .function) {
                    const func = ptr.child.function;
                    try self.emitForeignRef(w, .{ .module = ptr.module, .name = "BoundMethod" });
                    try w.writeAll("(*const fn (*anyopaque, ");
                    try self.emitForeignRef(w, .{ .module = ptr.module, .name = "ViewOwner" });
                    for (func.params) |param| {
                        try w.writeAll(", ");
                        try self.emitType(w, param);
                    }
                    try w.writeAll(") ");
                    try self.emitType(w, func.result.*);
                    try w.writeByte(')');
                } else try self.emitType(w, ptr.child.*);
                try w.writeByte(')');
            },
            .primitive => |p| try w.writeAll(if (p == .bytes) "[]const u8" else @tagName(p)),

            .array => |array| {
                try w.print("[{d}", .{array.length});
                if (array.sentinel) |sentinel| try w.print(":{d}", .{sentinel});
                try w.writeByte(']');
                try self.emitType(w, array.element.*);
            },
            .slice => |slice| {
                try w.writeByte('[');
                if (slice.sentinel) |sentinel| try w.print(":{d}", .{sentinel});
                try w.writeByte(']');
                if (slice.is_const) try w.writeAll("const ");
                try self.emitType(w, slice.element.*);
            },
            .foreign => |reference| try self.emitForeignRef(w, reference),
            .queried => |expression| try self.emitExpr(w, expression),
            .foreign_pointer => |ptr| {
                switch (ptr.size) {
                    .one => try w.writeByte('*'),
                    .c => try w.writeAll("[*c]"),
                    .many => {
                        try w.writeAll("[*");
                        if (ptr.sentinel) |sentinel| try w.print(":{d}", .{sentinel});
                        try w.writeByte(']');
                    },
                    .slice => unreachable,
                }
                if (ptr.is_const) try w.writeAll("const ");
                try self.emitType(w, ptr.child.*);
            },
            .optional => |child| {
                try w.writeByte('?');
                try self.emitType(w, child.*);
            },
            .error_union => |result| {
                try self.emitType(w, result.errors.*);
                try w.writeByte('!');
                try self.emitType(w, result.payload.*);
            },
            .structure => |id| try w.print("{f}", .{std.zig.fmtId(self.names.get(id))}),
            .enumeration => |id| try w.print("{f}", .{std.zig.fmtId(self.names.get(id))}),
            .pointer => |id| try w.print("*{f}", .{std.zig.fmtId(self.names.get(id))}),
            .zig_callback => |f| {
                try w.writeAll("*const fn(");
                for (f.params, 0..) |param, index| {
                    if (index != 0) try w.writeAll(", ");
                    try self.emitType(w, param);
                }
                try w.writeAll(if (f.c_abi) ") callconv(.c) " else ") ");
                try self.emitType(w, f.result.*);
            },
            .function => |f| {
                try w.writeAll("Closure(*const fn (?*anyopaque, ");
                for (f.params) |p| {
                    try self.emitType(w, p);
                    try w.writeAll(", ");
                }
                try w.writeAll(") ");
                try self.emitType(w, f.result.*);
                try w.writeByte(')');
            },
        }
    }

    /// 为不能直接承接成员或调用后缀的表达式补括号，维持生成代码的优先级。
    fn emitPostfixBase(self: Emitter, w: *Writer, expr: *const Expr) Writer.Error!void {
        switch (expr.*) {
            .variable, .builtin, .foreign_ref, .foreign_field, .foreign_call, .field, .index, .subslice, .length => try self.emitExpr(w, expr),
            else => {
                try w.writeByte('(');
                try self.emitExpr(w, expr);
                try w.writeByte(')');
            },
        }
    }

    /// 按 IR 标签递归输出表达式，必要时生成标签块、临时绑定和运行库调用。
    fn emitExpr(self: Emitter, w: *Writer, expr: *const Expr) Writer.Error!void {
        switch (expr.*) {
            .foreign_ref => |reference| try self.emitForeignRef(w, reference),
            .callback_address => |id| try w.print("&{f}", .{std.zig.fmtId(self.names.get(id))}),
            .zig_indirect => |call| {
                try self.emitPostfixBase(w, call.function);
                try w.writeByte('(');
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try w.writeAll(", ");
                    try self.emitExpr(w, arg);
                }
                try w.writeByte(')');
            },
            .foreign_field => |field| {
                try self.emitPostfixBase(w, field.base);
                try w.print(".{f}", .{std.zig.fmtId(field.name)});
            },
            .foreign_object => |obj| {
                try self.emitType(w, obj.ty);
                try w.writeAll("{");
                for (obj.fields) |field| {
                    try w.print(".{f} = ", .{std.zig.fmtId(field.name)});
                    try self.emitExpr(w, field.value);
                    try w.writeAll(", ");
                }
                try w.writeByte('}');
            },
            .foreign_variant => |variant| {
                if (variant.payload) |payload| {
                    try self.emitType(w, variant.ty);
                    try w.print("{{ .{f} = ", .{std.zig.fmtId(variant.name)});
                    try self.emitExpr(w, payload);
                    try w.writeAll(" }");
                } else if (variant.ty == .foreign) {
                    try self.emitType(w, variant.ty);
                    try w.print(".{f}", .{std.zig.fmtId(variant.name)});
                }
            },
            .typed_value => |value| {
                try w.writeAll("@as(");
                try self.emitType(w, value.ty);
                try w.writeAll(", ");
                try self.emitExpr(w, value.value);
                try w.writeByte(')');
            },
            .field_type => |field| {
                try w.writeAll("@FieldType(");
                try self.emitExpr(w, field.ref_type);
                try w.print(", \"{f}\")", .{std.zig.fmtString(field.name)});
            },
            .type_of => |expression| {
                try w.writeAll("@TypeOf(");
                try self.emitExpr(w, expression);
                try w.writeByte(')');
            },
            .type_value => |ty| try self.emitType(w, ty),
            .builtin => |name| try w.writeAll(name),
            .error_value => |name| try w.print("error.{f}", .{std.zig.fmtId(name)}),
            .bound_method => |method| {
                try self.emitForeignRef(w, .{ .module = method.module, .name = "makeView" });
                try w.writeByte('(');
                try self.emitExpr(w, method.owner);
                try w.writeAll(", (struct { fn bind(receiver: *anyopaque) ");
                try self.emitForeignRef(w, .{ .module = method.module, .name = "BoundMethod" });
                try w.writeAll("(@TypeOf(&invoke)) { return .{ .invoke = &invoke, .receiver = receiver }; } fn invoke(receiver: *anyopaque, __saphine_owner: ");
                try self.emitForeignRef(w, .{ .module = method.module, .name = "ViewOwner" });
                for (method.params) |param| {
                    try w.print(", {f}: ", .{std.zig.fmtId(param.name)});
                    try self.emitType(w, param.ty);
                }
                try w.writeAll(") ");
                try self.emitType(w, method.result);
                try w.writeAll(" { const __saphine_receiver: ");
                try self.emitType(w, method.receiver_type);
                try w.writeAll(" = @ptrCast(@alignCast(receiver)); return ");
                try self.emitExpr(w, method.call);
                try w.writeAll("; } }).bind(@ptrCast(");
                try self.emitExpr(w, method.receiver);
                try w.writeAll(")))");
            },
            .preserve_result => |save| {
                try w.print("(preserve{d}: {{ {f} = ", .{ save.id, std.zig.fmtId(save.slot) });
                try self.emitExpr(w, save.value);
                try w.print("; break :preserve{d} {f}.?; }})", .{ save.id, std.zig.fmtId(save.slot) });
            },
            .managed_get => |receiver| {
                try self.emitPostfixBase(w, receiver);
                try w.writeAll(".get()");
            },
            .managed_method => |method| {
                try self.emitPostfixBase(w, method.receiver);
                try w.print(".{f}()", .{std.zig.fmtId(method.name)});
            },
            .managed_scope => |scope| {
                try w.print("(managed{d}: {{\n", .{scope.id});
                try self.emitBlock(w, scope.body, 1);
                try w.print("break :managed{d} ", .{scope.id});
                try self.emitExpr(w, scope.result);
                try w.writeAll("; })");
            },
            .unwrap_allocation => |value| {
                try w.writeByte('(');
                try self.emitExpr(w, value);
                try w.writeAll(" catch @panic(\"saphine: out of memory\"))");
            },
            .optional_none => |ty| {
                try w.writeAll("@as(");
                try self.emitType(w, ty);
                try w.writeAll(", null)");
            },
            .foreign_call => |call| {
                if (call.site) |site| try w.print("(zig_call_{d}: {{ break :zig_call_{d} ", .{ site, site });
                try self.emitForeignRef(w, call.target);
                try w.writeByte('(');
                for (call.args, 0..) |arg, index| {
                    if (index != 0) try w.writeAll(", ");
                    try self.emitExpr(w, arg);
                }
                try w.writeByte(')');
                if (call.site != null) try w.writeAll("; })");
            },
            .range => |r| try w.print("makeRange({d}, {d})", .{ r.start, r.length }),
            .conditional => |cond| {
                try w.writeByte('(');
                try self.emitConditional(w, cond, 0);
                try w.writeByte(')');
            },
            .matching => |matching| {
                try w.writeByte('(');
                try self.emitMatch(w, matching, 0);
                try w.writeByte(')');
            },
            .enum_init => |init| {
                try w.print("{f}{{ .{f} = ", .{ std.zig.fmtId(self.names.get(init.id)), std.zig.fmtId(init.name) });
                if (init.payload) |payload| try self.emitExpr(w, payload) else try w.writeAll("{}");
                try w.writeAll(" }");
            },
            .logical_not => |child| {
                try w.writeAll("!(");
                try self.emitExpr(w, child);
                try w.writeByte(')');
            },
            .predicate => |p| {
                const op = switch (p.op) {
                    .eq => "==",
                    .ne => "!=",
                    .lt => "<",
                    .le => "<=",
                    .gt => ">",
                    .ge => ">=",
                    .logical_and => "and",
                    .logical_or => "or",
                };
                try w.writeByte('(');
                try self.emitExpr(w, p.left);
                try w.print(" {s} ", .{op});
                try self.emitExpr(w, p.right);
                try w.writeByte(')');
            },
            .module_object => |id| switch (self.current_environment) {
                .typed => try w.writeAll("__saphine_context.*"),
                else => try w.print("(@as(*{f}, @ptrCast(@alignCast(__saphine_context.?)))).*", .{std.zig.fmtId(self.names.get(id))}),
            },
            .module_cast => |cast| {
                try w.print("(@as(*{f}, @ptrCast(@alignCast(@as(?*anyopaque, ", .{std.zig.fmtId(self.names.get(cast.shape))});
                try self.emitExpr(w, cast.context);
                try w.writeAll(").?)))).*");
            },

            .null_context => try w.writeAll("@as(?*anyopaque, null)"),
            .forward_context => try w.writeAll("__saphine_context"),
            .object_context => |object| {
                try w.writeByte('(');
                try self.emitExpr(w, object);
                try w.writeAll(").__saphine_module_context");
            },

            .variable => |name| try w.print("{f}", .{std.zig.fmtId(name)}),

            .bound => |binding| {
                try w.print("(call{d}: {{ const {s} = ", .{ binding.serial, binding.name });
                try self.emitExpr(w, binding.value);
                try w.print("; keep({s}); break :call{d} ", .{ binding.name, binding.serial });
                try self.emitExpr(w, binding.result);
                try w.writeAll("; })");
            },

            .boolean => |value| try w.writeAll(if (value) "true" else "false"),
            .number => |n| try w.print("@as({s}, {s})", .{ @tagName(n.ty), n.canonical }),
            .bytes => |bytes| {
                try w.writeByte('"');
                for (bytes) |byte| switch (byte) {
                    '"', '\\' => try w.print("\\{c}", .{byte}),
                    32...33, 35...91, 93...126 => try w.writeByte(byte),
                    else => try w.print("\\x{x:0>2}", .{byte}),
                };
                try w.writeByte('"');
            },
            .array_init => |array| {
                try self.emitType(w, array.ty);
                try w.writeAll("{ ");
                for (array.elements) |element| {
                    try self.emitExpr(w, element);
                    try w.writeAll(", ");
                }
                try w.writeByte('}');
            },
            .index => |idx| {
                try w.writeByte('(');
                try self.emitExpr(w, idx.base);
                try w.writeAll(")[");
                try self.emitExpr(w, idx.index);
                try w.writeByte(']');
            },
            .subslice => |slice| {
                try w.writeByte('(');
                try self.emitExpr(w, slice.base);
                try w.writeAll(")[");
                try self.emitExpr(w, slice.start);
                try w.writeAll("..");
                if (slice.end) |end| try self.emitExpr(w, end);
                try w.writeByte(']');
            },
            .length => |base| {
                try w.writeByte('(');
                try self.emitExpr(w, base);
                try w.writeAll(").len");
            },
            .field => |field| {
                try self.emitPostfixBase(w, field.base);
                try w.print(".{f}", .{nativeFieldName(field.name)});
            },
            .address, .dereference, .negate, .bit_not => |child| {
                if (expr.* == .address) try w.writeByte('&');
                if (expr.* == .negate) try w.writeByte('-');
                if (expr.* == .bit_not) try w.writeByte('~');
                try w.writeByte('(');
                try self.emitExpr(w, child);
                try w.writeAll(if (expr.* == .dereference) ").*" else ")");
            },
            .object => |obj| {
                var buffer: [64]u8 = undefined;
                const name = std.fmt.bufPrint(&buffer, "__object{d}", .{obj.temporary}) catch unreachable;
                try w.print("(object{d}: {{ var {s}: {f} = undefined; ", .{ obj.temporary, name, std.zig.fmtId(self.names.get(obj.shape)) });
                var pointer_buffer: [80]u8 = undefined;
                const pointer = std.fmt.bufPrint(&pointer_buffer, "(&{s})", .{name}) catch unreachable;
                try self.emitInitPointer(w, pointer, expr);
                try w.print(" break :object{d} {s}; }})", .{ obj.temporary, name });
            },
            .arithmetic => |op| {
                try w.print("arithmetic(.{s}, ", .{@tagName(op.op)});
                try self.emitExpr(w, op.left);
                try w.writeAll(", ");
                try self.emitExpr(w, op.right);
                try w.writeByte(')');
            },
            .function_address => |function| {
                const erased = (self.environments.get(function.id) orelse .erased) == .erased;
                const name = if (erased) std.zig.fmtId(self.names.get(function.id)) else null;
                if (name) |spelling| {
                    try w.print("Closure(@TypeOf(&{f})){{ .function = &{f}, .context = ", .{ spelling, spelling });
                } else {
                    const spelling = self.names.get(adapterSymbol(function.id));
                    try w.print("Closure(@TypeOf(&{f})){{ .function = &{f}, .context = ", .{ std.zig.fmtId(spelling), std.zig.fmtId(spelling) });
                }
                const context = if ((self.environments.get(function.id) orelse .erased) == .none) null else function.context;
                if (context) |expr_context| try self.emitExpr(w, expr_context) else try w.writeAll("null");
                try w.writeAll(" }");
            },
            .call => |call| {
                switch (call.target) {
                    .direct => |id| {
                        try w.print("{f}(", .{std.zig.fmtId(self.names.get(id))});
                        try self.emitContext(w, id, call.context);
                    },
                    .indirect => |target| {
                        try w.writeByte('(');
                        try self.emitExpr(w, target);
                        try w.writeAll(").call(.{");
                    },
                }
                for (call.args) |arg| {
                    try self.emitExpr(w, arg);
                    try w.writeAll(", ");
                }
                try w.writeAll(if (call.target == .indirect) "})" else ")");
            },
        }
    }

    /// 将值写入目标地址；结构体先设置上下文并递归初始化显式字段，再调用默认初始化器。
    fn emitInitPointer(self: Emitter, w: *Writer, destination: Text, value: *const Expr) Writer.Error!void {
        if (value.* != .object) {
            try w.print("{s}.* = ", .{destination});
            try self.emitExpr(w, value);
            try w.writeByte(';');
            return;
        }
        const object = value.object;
        if (object.initializer == null) try w.print("{s}.* = undefined; ", .{destination});
        try w.print("{s}.__saphine_module_context = ", .{destination});
        if (object.context) |context| try self.emitExpr(w, context) else try w.writeAll("null");
        try w.writeAll("; ");
        for (object.fields, 0..) |field, index| {
            var buffer: [80]u8 = undefined;
            const name = std.fmt.bufPrint(&buffer, "__field{d}_{d}", .{ object.temporary, index }) catch unreachable;
            try w.print("{{ const {s} = &({s}.{f}); ", .{ name, destination, nativeFieldName(field.name) });
            try self.emitInitPointer(w, name, field.value);
            try w.writeAll(" } ");
        }
        if (object.initializer) |initializer| try w.print("{f}({s}); ", .{ std.zig.fmtId(self.names.get(initializer)), destination });
    }

    /// 输出不额外绑定载荷的分支，复用带绑定分支的块与结果生成逻辑。
    fn emitBranch(self: Emitter, w: *Writer, branch: Branch, depth: usize) Writer.Error!void {
        return self.emitBoundBranch(w, branch, depth, null);
    }

    /// 输出缩进块和可选结果标签，同时消费载荷绑定以避免 Zig 的未使用变量错误。
    fn emitBoundBranch(self: Emitter, w: *Writer, branch: Branch, depth: usize, binding: ?Text) Writer.Error!void {
        if (branch.value != null) try w.print("branch{d}: ", .{branch.label});
        try w.writeAll("{\n");
        if (binding) |name| {
            for (0..depth + 1) |_| try w.writeAll("    ");
            try w.print("keep({f});\n", .{std.zig.fmtId(name)});
        }
        try self.emitBlock(w, branch.body, depth + 1);
        if (branch.value) |value| {
            for (0..depth + 1) |_| try w.writeAll("    ");
            try w.print("break :branch{d} ", .{branch.label});
            try self.emitExpr(w, value);
            try w.writeAll(";\n");
        }
        for (0..depth) |_| try w.writeAll("    ");
        try w.writeByte('}');
    }

    /// 输出 if 条件及可选 else，统一复用分支体和尾值的生成方式。
    fn emitConditional(self: Emitter, w: *Writer, cond: Conditional, depth: usize) Writer.Error!void {
        try w.writeAll("if (");
        try self.emitExpr(w, cond.test_expr);
        try w.writeAll(") ");
        try self.emitBranch(w, cond.yes, depth);
        if (cond.no) |no| {
            try w.writeAll(" else ");
            try self.emitBranch(w, no, depth);
        }
    }

    /// 将枚举匹配输出为 switch，将 optional 和错误联合匹配输出为带载荷捕获的 if。
    fn emitMatch(self: Emitter, w: *Writer, matching: Match, depth: usize) Writer.Error!void {
        if (matching.kind == .optional or matching.kind == .error_union) {
            const first = if (matching.kind == .optional) "Some" else "Ok";
            let: {
                try w.writeAll("if (");
                try self.emitExpr(w, matching.subject);
                try w.writeAll(") ");
                for (matching.arms) |arm| {
                    if (arm.name != null and !std.mem.eql(u8, arm.name.?, first)) continue;
                    if (arm.binding) |binding| try w.print("|{f}| ", .{std.zig.fmtId(binding)});
                    if (arm.binding == null) {
                        try w.writeAll("|__saphine_payload| ");
                        try self.emitBoundBranch(w, arm.branch, depth, "__saphine_payload");
                    } else try self.emitBoundBranch(w, arm.branch, depth, arm.binding);
                    break :let;
                }
                unreachable;
            }
            try w.writeAll(" else ");
            for (matching.arms) |arm| {
                if (arm.name != null and std.mem.eql(u8, arm.name.?, first)) continue;
                if (arm.binding) |binding| {
                    try w.print("|{f}| ", .{std.zig.fmtId(binding)});
                } else if (matching.kind == .error_union) {
                    try w.writeAll("|__saphine_error| ");
                    try self.emitBoundBranch(w, arm.branch, depth, "__saphine_error");
                    return;
                }
                try self.emitBoundBranch(w, arm.branch, depth, arm.binding);
                return;
            }
            unreachable;
        }
        try w.writeAll("switch (");
        try self.emitExpr(w, matching.subject);
        try w.writeAll(") {\n");
        for (matching.arms) |arm| {
            for (0..depth + 1) |_| try w.writeAll("    ");
            if (arm.name) |name| {
                try w.print(".{f} => ", .{std.zig.fmtId(name)});
                if (arm.binding) |binding| try w.print("|{f}| ", .{std.zig.fmtId(binding)});
            } else {
                try w.writeAll("else => ");
            }
            try self.emitBoundBranch(w, arm.branch, depth + 1, if (arm.name != null) arm.binding else null);
            try w.writeAll(",\n");
        }
        for (0..depth) |_| try w.writeAll("    ");
        try w.writeByte('}');
    }

    /// 逐条输出语句及缩进，为托管局部和赋值插入根帧、defer 清理及所有权操作。
    fn emitBlock(self: Emitter, w: *Writer, body: []const Stmt, depth: usize) Writer.Error!void {
        for (body) |stmt| {
            for (0..depth) |_| try w.writeAll("    ");
            switch (stmt) {
                .local => |local| {
                    if (local.value.* == .object) {
                        try w.print("var {f}: ", .{std.zig.fmtId(local.slot.name)});
                        try self.emitType(w, local.slot.ty);
                        try w.writeAll(" = undefined; ");
                        var buffer: [160]u8 = undefined;
                        const pointer = std.fmt.bufPrint(&buffer, "(&{f})", .{std.zig.fmtId(local.slot.name)}) catch unreachable;
                        try self.emitInitPointer(w, pointer, local.value);
                        try w.print(" _ = &{f};\n", .{std.zig.fmtId(local.slot.name)});
                        continue;
                    }
                    try w.print("{s} {f}: ", .{ if (local.mutable) "var" else "const", std.zig.fmtId(local.slot.name) });
                    try self.emitType(w, local.slot.ty);
                    try w.writeAll(" = ");
                    try self.emitExpr(w, local.value);
                    try w.writeAll(";\n");
                    for (0..depth) |_| try w.writeAll("    ");
                    if (local.mutable) try w.print("_ = &{f};\n", .{std.zig.fmtId(local.slot.name)}) else try w.print("keep({f});\n", .{std.zig.fmtId(local.slot.name)});
                    continue;
                },
                .managed_local => |local| {
                    const name = std.zig.fmtId(local.slot.name);
                    try w.print("var {f}: ", .{name});
                    try self.emitType(w, local.slot.ty);
                    try w.writeAll(" = ");
                    try self.emitExpr(w, local.value);
                    try w.print("; _ = &{f};\n", .{name});
                    if (local.trace) {
                        try w.print("var __saphine_root_{d} = ", .{local.id});
                        try self.emitForeignRef(w, .{ .module = local.module, .name = "rootFrame" });
                        try w.print("(&{f});\n", .{name});
                        try self.emitForeignRef(w, .{ .module = local.module, .name = "pushFrame" });
                        try w.print("(&__saphine_root_{d});\n", .{local.id});
                        try w.writeAll("defer ");
                        try self.emitForeignRef(w, .{ .module = local.module, .name = "popFrame" });
                        try w.print("(&__saphine_root_{d});\n", .{local.id});
                    }
                    if (local.drop) {
                        try w.writeAll("defer ");
                        try self.emitForeignRef(w, .{ .module = local.module, .name = "dropValue" });
                        try w.print("(&{f});\n", .{name});
                    }
                    continue;
                },
                .managed_guard => |guard| {
                    if (guard.trace) {
                        try w.print("var __saphine_global_root_{d} = ", .{guard.id});
                        try self.emitForeignRef(w, .{ .module = guard.module, .name = "rootFrame" });
                        try w.writeAll("(&(");
                        try self.emitExpr(w, guard.target);
                        try w.writeAll("));\n");
                        try self.emitForeignRef(w, .{ .module = guard.module, .name = "pushFrame" });
                        try w.print("(&__saphine_global_root_{d});\ndefer ", .{guard.id});
                        try self.emitForeignRef(w, .{ .module = guard.module, .name = "popFrame" });
                        try w.print("(&__saphine_global_root_{d});\n", .{guard.id});
                    }
                    if (guard.drop) {
                        try w.writeAll("defer ");
                        try self.emitForeignRef(w, .{ .module = guard.module, .name = "dropValue" });
                        try w.writeAll("(&(");
                        try self.emitExpr(w, guard.target);
                        try w.writeAll("));\n");
                    }
                    continue;
                },
                .managed_assign => |assign| {
                    try self.emitForeignRef(w, .{ .module = assign.module, .name = "replaceValue" });
                    try w.writeAll("(&(");
                    try self.emitExpr(w, assign.target);
                    try w.writeAll("), ");
                    try self.emitExpr(w, assign.value);
                    try w.writeByte(')');
                },
                .assign => |assign| {
                    if (assign.initialize and assign.value.* == .object) {
                        var buffer: [64]u8 = undefined;
                        const name = std.fmt.bufPrint(&buffer, "__destination{d}", .{assign.value.object.temporary}) catch unreachable;
                        try w.print("{{ const {s} = &(", .{name});
                        try self.emitExpr(w, assign.target);
                        try w.writeAll("); ");
                        try self.emitInitPointer(w, name, assign.value);
                        try w.writeAll(" }\n");
                        continue;
                    }
                    try self.emitExpr(w, assign.target);
                    try w.writeAll(" = ");
                    try self.emitExpr(w, assign.value);
                },
                .ret => |value| {
                    try w.writeAll("return");
                    if (value) |expr| {
                        try w.writeByte(' ');
                        try self.emitExpr(w, expr);
                    }
                },
                .expr => |expr| try self.emitExpr(w, expr),
                .defer_expr => |expr| {
                    try w.writeAll("defer ");
                    try self.emitExpr(w, expr);
                },
                .loop => |loop| {
                    if (loop.first) |id| {
                        try w.print("{{\n", .{});
                        for (0..depth + 1) |_| try w.writeAll("    ");
                        try w.print("var first{d} = true;\n", .{id});
                        for (0..depth + 1) |_| try w.writeAll("    ");
                        try w.print("while (first{d} or ", .{id});
                        try self.emitExpr(w, loop.condition);
                        try w.print(") : (first{d} = false) ", .{id});
                    } else {
                        try w.writeAll("while (");
                        try self.emitExpr(w, loop.condition);
                        try w.writeAll(") ");
                    }
                    try self.emitBranch(w, .{ .body = loop.body }, depth + @intFromBool(loop.first != null));
                    if (loop.first != null) {
                        try w.writeByte('\n');
                        for (0..depth) |_| try w.writeAll("    ");
                        try w.writeByte('}');
                    }
                    try w.writeByte('\n');
                    continue;
                },
                .for_each => |loop| {
                    if (loop.items.* == .range) {
                        const r = loop.items.range;
                        try w.print("{{\n", .{});
                        for (0..depth + 1) |_| try w.writeAll("    ");
                        try w.print("var {f}: i32 = {d};\n", .{ std.zig.fmtId(loop.index_name), r.start });
                        for (0..depth + 1) |_| try w.writeAll("    ");
                        try w.print("while ({f} < {d}) : ({f} += 1) {{\n", .{ std.zig.fmtId(loop.index_name), r.end, std.zig.fmtId(loop.index_name) });
                        for (0..depth + 2) |_| try w.writeAll("    ");
                        try w.print("const {f} = {f};\n", .{ std.zig.fmtId(loop.name), std.zig.fmtId(loop.index_name) });
                    } else {
                        try w.writeAll("for (");
                        try self.emitExpr(w, loop.items);
                        try w.print(") |{f}| {{\n", .{std.zig.fmtId(loop.name)});
                    }
                    const indent = depth + @as(usize, @intFromBool(loop.items.* == .range));

                    for (0..indent + 1) |_| try w.writeAll("    ");
                    try w.print("keep({f});\n", .{std.zig.fmtId(loop.name)});
                    try self.emitBlock(w, loop.body, indent + 1);
                    for (0..indent) |_| try w.writeAll("    ");
                    try w.writeByte('}');
                    if (loop.items.* == .range) {
                        try w.writeByte('\n');
                        for (0..depth) |_| try w.writeAll("    ");
                        try w.writeByte('}');
                    }
                    try w.writeByte('\n');
                    continue;
                },
                .loop_exit => |exit| try w.writeAll(if (exit == .stop) "break" else "continue"),
                .matching => |matching| {
                    try self.emitMatch(w, matching, depth);
                    try w.writeByte('\n');
                    continue;
                },
                .conditional => |cond| {
                    try self.emitConditional(w, cond, depth);
                    try w.writeByte('\n');
                    continue;
                },
                .block => |inner| {
                    try w.writeAll("{\n");
                    try self.emitBlock(w, inner, depth + 1);
                    for (0..depth) |_| try w.writeAll("    ");
                    try w.writeAll("}\n");
                    continue;
                },
            }
            try w.writeAll(";\n");
        }
    }

    /// 递归输出外部声明路径，内嵌标准库和独立模块分别使用对应命名空间。
    fn emitForeignRef(self: Emitter, w: *Writer, reference: ForeignRef) Writer.Error!void {
        if (reference.parent) |parent| {
            try self.emitForeignRef(w, parent.*);
            try w.print(".{f}", .{std.zig.fmtId(reference.name)});
        } else if (reference.module == stdlib_module) {
            try w.print("__saphine_runtime.stdlib.{f}", .{std.zig.fmtId(reference.name)});
        } else {
            try w.print("{f}.{f}", .{ std.zig.fmtId(self.importName(reference.module)), std.zig.fmtId(reference.name) });
        }
    }
};

/// 按符号编号查找源码信息，输出便于阅读生成代码的原文件行列注释。
fn emitSource(w: *Writer, symbols: []const naming.Symbol, id: naming.SymbolId) Writer.Error!void {
    for (symbols) |symbol| {
        if (symbol.id != id) continue;
        if (symbol.source) |source|
            try w.print("// source: {f}:{d}:{d}\n", .{ std.zig.fmtString(std.fs.path.basename(source.path)), source.line, source.column });
        return;
    }
}

/// 将函数编号映射到专用高位区间，为闭包适配器分配可独立命名的符号编号。
fn adapterSymbol(id: usize) usize {
    return (std.math.maxInt(usize) / 2) + id;
}

/// 格式化 Zig 字段名，并转义可能与内部模块上下文字段冲突的用户字段。
fn nativeFieldName(name: Text) std.zig.FormatId {
    // The leading dot in the escaped spelling cannot be authored in a saphine identifier.
    return std.zig.fmtId(if (std.mem.eql(u8, name, "__saphine_module_context")) ".saphine_module_context" else name);
}

/// 根据外部导入表输出正确转义的 Zig @import 声明，供程序和类型查询复用。
pub fn emitImportDeclarations(a: std.mem.Allocator, imports: []const ForeignImport) Writer.Error!Text {
    var output: Writer.Allocating = .init(a);
    for (imports) |import| {
        try output.writer.print("\nconst {f} = @import(\"{f}\");\n", .{ std.zig.fmtId(import.name), std.zig.fmtString(import.path) });
    }
    return output.toOwnedSlice() catch error.WriteFailed;
}

/// 在给定导入映射下单独输出一个表达式，主要用于生成外部类型查询源码。
pub fn emitExpression(a: std.mem.Allocator, imports: []const ForeignImport, expression: *const Expr) Writer.Error!Text {
    var output: Writer.Allocating = .init(a);
    const emitter: Emitter = .{ .names = .{}, .imports = imports };
    try emitter.emitExpr(&output.writer, expression);
    return output.toOwnedSlice() catch error.WriteFailed;
}

/// 返回生成源码及最终名称表，名称表供格式化后的源码映射收集使用。
pub const Generated = struct { code: Text, names: naming.NameTable };

/// 分析函数环境并分配名称，输出辅助代码、标准库、类型布局、函数及原生程序入口。
pub fn emitZig(a: std.mem.Allocator, module: Module, imports: []const ForeignImport) Writer.Error!Generated {
    var symbols: std.ArrayList(naming.Symbol) = .empty;
    symbols.appendSlice(a, module.symbols) catch return error.WriteFailed;
    for (imports) |import| symbols.append(a, .{ .id = std.math.maxInt(usize) - 1 - import.id, .name = import.name, .owner = "zig" }) catch return error.WriteFailed;
    const context_table = environments.analyze(a, module.functions) catch return error.WriteFailed;
    const closure_adapters = environments.collectAddresses(a, module) catch return error.WriteFailed;
    for (module.symbols) |symbol| {
        if (!closure_adapters.contains(symbol.id) or context_table.get(symbol.id).? == .erased) continue;
        const adapter = std.fmt.allocPrint(a, "{s}__closure_adapter", .{symbol.name}) catch return error.WriteFailed;
        symbols.append(a, .{ .id = adapterSymbol(symbol.id), .name = adapter, .owner = symbol.owner }) catch return error.WriteFailed;
    }
    const names = naming.NameTable.init(a, symbols.items, module.local_spellings) catch return error.WriteFailed;
    const final_imports = a.dupe(ForeignImport, imports) catch return error.WriteFailed;
    for (final_imports) |*import| import.name = names.get(std.math.maxInt(usize) - 1 - import.id);
    var emitter: Emitter = .{
        .names = names,
        .imports = final_imports,
        .environments = context_table,
        .closure_adapters = closure_adapters,
    };
    var output: Writer.Allocating = .init(a);
    errdefer output.deinit();
    const w = &output.writer;
    try w.writeAll(
        \\const std = @import("std");
        \\var __saphine_io: std.Io = undefined;
        \\
        \\fn keep(_: anytype) void {}
        \\
        \\fn Closure(comptime F: type) type {
        \\    return struct {
        \\        function: F,
        \\        context: ?*anyopaque,
        \\        fn call(self: @This(), args: anytype) @typeInfo(@typeInfo(F).pointer.child).@"fn".return_type.? {
        \\            return @call(.auto, self.function, .{self.context} ++ args);
        \\        }
        \\    };
        \\}
        \\
        \\fn makeRange(start: i32, comptime length: usize) [length]i32 {
        \\    var items: [length]i32 = undefined;
        \\    for (&items, 0..) |*item, index| {
        \\        item.* = @intCast(@as(i64, start) + @as(i64, @intCast(index)));
        \\    }
        \\    return items;
        \\}
        \\
        \\fn arithmetic(comptime op: enum { add, sub, mul, div, rem, bit_and, bit_or, bit_xor, shl, shr }, a: anytype, b: anytype) @TypeOf(a) {
        \\    return switch (op) {
        \\        .add => a + b,
        \\        .sub => a - b,
        \\        .mul => a * b,
        \\        .div => if (@typeInfo(@TypeOf(a)) == .int) @divTrunc(a, b) else a / b,
        \\        .rem => if (@typeInfo(@TypeOf(a)) == .int and @typeInfo(@TypeOf(a)).int.signedness == .signed and b == -1) 0 else @rem(a, b),
        \\        .bit_and => a & b,
        \\        .bit_or => a | b,
        \\        .bit_xor => a ^ b,
        \\        .shl => a << @as(std.math.Log2Int(@TypeOf(a)), @intCast(b)),
        \\        .shr => a >> @as(std.math.Log2Int(@TypeOf(a)), @intCast(b)),
        \\    };
        \\}
        \\
    );
    try w.writeAll(try emitImportDeclarations(a, final_imports));
    try w.writeAll("\nconst __saphine_runtime = struct { const stdlib = struct {\n");
    try w.writeAll(@embedFile("stdlib/root.zig"));
    try w.writeAll("}; };\n\n");
    for (module.layouts) |layout| {
        try emitSource(w, module.symbols, layout.id);
        try w.print("const {f} = struct {{\n    __saphine_module_context: ?*anyopaque = null,\n", .{std.zig.fmtId(emitter.names.get(layout.id))});
        for (layout.fields) |field| {
            try w.print("    {f}: ", .{nativeFieldName(field.name)});
            try emitter.emitType(w, field.ty);
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }
    for (module.enums) |layout| {
        try emitSource(w, module.symbols, layout.id);
        try w.print("const {f} = union(enum) {{\n", .{std.zig.fmtId(emitter.names.get(layout.id))});
        for (layout.variants) |variant| {
            try w.print("    {f}: ", .{std.zig.fmtId(variant.name)});
            if (variant.ty) |ty| try emitter.emitType(w, ty) else try w.writeAll("void");
            try w.writeAll(",\n");
        }
        try w.writeAll("};\n\n");
    }
    for (module.globals) |global| {
        try w.print("var {f}: ", .{std.zig.fmtId(global.name)});
        try emitter.emitType(w, global.ty);
        try w.writeAll(" = undefined;\n");
    }
    for (module.functions) |fun| {
        const name = std.zig.fmtId(emitter.names.get(fun.id));
        emitter.current_environment = emitter.environments.get(fun.id).?;
        try w.writeByte('\n');
        try emitSource(w, module.symbols, fun.id);
        try w.print("fn {f}(", .{name});
        switch (emitter.current_environment) {
            .none => {},
            .erased => try w.writeAll("__saphine_context: ?*anyopaque"),
            .typed => |shape| try w.print("__saphine_context: *{f}", .{std.zig.fmtId(emitter.names.get(shape))}),
        }
        for (fun.params, 0..) |p, index| {
            if (index != 0 or emitter.current_environment != .none) try w.writeAll(", ");
            try w.print("{f}: ", .{std.zig.fmtId(p.name)});
            try emitter.emitType(w, p.ty);
        }
        try w.writeAll(if (fun.c_abi) ") callconv(.c) " else ") ");
        try emitter.emitType(w, fun.result);
        try w.writeAll(" {\n");
        if (emitter.current_environment != .none) try w.writeAll("    keep(__saphine_context);\n");
        for (fun.params) |param| {
            if (param.ty == .erased_context or !environments.usesVariable(fun.body, param.name))
                try w.print("    _ = {f};\n", .{std.zig.fmtId(param.name)});
        }
        try emitter.emitBlock(w, fun.body, 1);
        try w.writeAll("}\n");
        if (emitter.current_environment != .erased and emitter.closure_adapters.contains(fun.id)) {
            try w.print("\nfn {f}(__saphine_context: ?*anyopaque", .{std.zig.fmtId(names.get(adapterSymbol(fun.id)))});
            for (fun.params) |p| {
                try w.print(", {f}: ", .{std.zig.fmtId(p.name)});
                try emitter.emitType(w, p.ty);
            }
            try w.writeAll(") ");
            try emitter.emitType(w, fun.result);
            try w.print(" {{\n    keep(__saphine_context);\n    return {f}(", .{name});
            try emitter.emitContext(w, fun.id, &.{ .builtin = "__saphine_context" });
            for (fun.params) |p| try w.print("{f}, ", .{std.zig.fmtId(p.name)});
            try w.writeAll(");\n}\n");
        }
    }
    emitter.current_environment = .erased;
    try w.writeAll("\npub fn main(init: std.process.Init) void {\n    __saphine_io = init.io;\n    __saphine_runtime.stdlib.initProcess(init);\n");
    try emitter.emitBlock(w, module.startup, 1);
    try w.print("    {f}(", .{std.zig.fmtId(emitter.names.get(module.entry))});
    try emitter.emitContext(w, module.entry, module.entry_context);
    try w.writeAll(");\n}\n");
    return .{ .code = output.toOwnedSlice() catch return error.WriteFailed, .names = names };
}
