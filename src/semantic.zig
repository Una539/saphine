//! 执行 Saphine 语义分析，将文件结构体 AST 转换为类型化 IR。
//! 结合词法作用域、结构体组合和函数特化检查程序，并生成初始化、托管值及 Zig 调用操作。

const std = @import("std");
const syn = @import("parser.zig");
const Text = syn.Text;
const Error = syn.Error;
const Expr = syn.Expr;
const Stmt = syn.Stmt;
const Allocator = std.mem.Allocator;

const naming = @import("names.zig");
const ir = @import("ir.zig");
const FileModule = @import("module_loader.zig").Module;
const Primitive = ir.Primitive;
const foreign = @import("zig_interop/store.zig");
const model = @import("semantic_model.zig");
const ForeignDeclaration = model.ForeignDeclaration;
const ForeignType = model.ForeignType;
const ZigAst = std.zig.Ast;
const Artifact = @import("zig_interop/artifact.zig").Artifact;
const compiler_query = @import("zig_interop/compiler_query.zig");
const ZigFunction = model.ZigFunction;
const ForeignAdapter = model.ForeignAdapter;
const ZigConstant = model.ZigConstant;
const ZigSubstitution = model.ZigSubstitution;
const Type = model.Type;
const i32_type = model.i32_type;
const bool_type = model.bool_type;
const void_type = model.void_type;
const meta_type = model.meta_type;
const Signature = model.Signature;

const EnumShape = model.EnumShape;
const EnumVariant = model.EnumVariant;
const Shape = model.Shape;
const MethodContext = model.MethodContext;
const Redeclaration = model.Redeclaration;
const Member = model.Member;
const Function = model.Function;
const Instance = model.Instance;
const View = model.View;
const Value = model.Value;
const Binding = model.Binding;
const Scope = model.Scope;
const Found = model.Found;
const Body = model.Body;
const Initialization = model.Initialization;
const InitializerVariant = model.InitializerVariant;
const ContainerState = model.ContainerState;

/// 保存单次编译的分析状态，通过递归检查 AST 和处理待分析特化构建完整 IR 模块。
pub const Analyzer = struct {
    /// 保存非致命诊断的文件、源码和位置，供命令行入口统一输出。
    pub const Warning = struct { path: Text, source: Text, at: usize, message: Text };
    warnings: std.ArrayList(Warning) = .empty,

    zig_backend: []const u8 = "zig",
    zig_target: []const u8 = "native",
    zig_optimize: []const u8 = "Debug",
    zig_entry: ?[]const u8 = null,
    zig_substitutions: []const ZigSubstitution = &.{},
    declaration_hint: ?syn.Token = null,
    all_local_names: std.StringHashMapUnmanaged(void) = .empty,
    local_names: std.StringHashMapUnmanaged(void) = .empty,
    symbols: std.ArrayList(naming.Symbol) = .empty,
    zig_store: ?*foreign.Store = null,
    prelude_store: ?*foreign.Store = null,
    zig_shapes: std.AutoHashMapUnmanaged(*foreign.File, *Shape) = .empty,
    foreign_storage_shapes: std.AutoHashMapUnmanaged(*ForeignType, *Shape) = .empty,
    foreign_adapters: std.ArrayList(ForeignAdapter) = .empty,
    requested_callbacks: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    foreign_types: std.ArrayList(*ForeignType) = .empty,
    resolving_zig: std.ArrayList(ForeignDeclaration) = .empty,
    call_sites: std.ArrayList(naming.SourceSpan) = .empty,

    a: Allocator,
    diag: *syn.Diagnostic,
    globals: Scope = .{},
    shapes: std.ArrayList(*Shape) = .empty,
    enums: std.ArrayList(*EnumShape) = .empty,
    functions: std.ArrayList(*Function) = .empty,
    pending: std.ArrayList(*Instance) = .empty,
    globals_ir: std.ArrayList(ir.Slot) = .empty,
    startup: Body = .empty,
    bodies: std.ArrayList(ir.Function) = .empty,
    serial: usize = 0,
    files: std.AutoHashMapUnmanaged(*const FileModule, *ContainerState) = .empty,
    current_file: ?*ContainerState = null,
    entry_context: ?*const ir.Expr = null,
    expected_context: ?*const ir.Expr = null,

    pub_failure: ?*const FileModule = null,

    /// 记录当前出错文件并格式化诊断，返回统一的语义分析错误。
    fn fail(self: *Analyzer, at: usize, comptime pattern: Text, args: anytype) Error {
        if (self.current_file) |file| self.pub_failure = file.module;
        return self.diag.fail(self.a, at, pattern, args);
    }

    /// 使用分析器分配器保存一个值，返回在本次编译期间有效的指针。
    fn make(self: *Analyzer, value: anytype) *@TypeOf(value) {
        const item = self.a.create(@TypeOf(value)) catch @panic("out of memory");
        item.* = value;
        return item;
    }

    /// 向分析结果列表追加元素，使用统一分配器并在内存不足时终止。
    fn append(self: *Analyzer, list: anytype, value: anytype) void {
        list.append(self.a, value) catch @panic("out of memory");
    }

    /// 分配格式化文本，用于生成名称及诊断中的类型描述。
    fn fmt(self: *Analyzer, comptime pattern: Text, args: anytype) Text {
        return std.fmt.allocPrint(self.a, pattern, args) catch @panic("out of memory");
    }

    /// 保存 IR 表达式并返回只读引用，供表达式树共享使用。
    fn irExpr(self: *Analyzer, expr: ir.Expr) *const ir.Expr {
        return self.make(expr);
    }

    /// 递增本次编译的序号，为类型、函数和生成代码标签分配唯一编号。
    fn id(self: *Analyzer) usize {
        self.serial += 1;
        return self.serial;
    }

    /// 递归将语义类型转换为 IR 类型，以编号表示语言容器并保留外部类型引用。
    fn lowerType(self: *Analyzer, ty: Type) ir.Type {
        return switch (ty) {
            .managed => |m| .{ .managed = .{ .kind = m.kind, .child = self.make(self.lowerType(m.child.*)), .module = m.module } },
            .primitive => |p| .{ .primitive = p },
            .structure => |shape| .{ .structure = shape.id },
            .foreign => |ty_ref| if (ty_ref.queried) |query| .{ .queried = query.expression } else .{ .foreign = ty_ref.reference },
            .foreign_pointer => |ptr| .{ .foreign_pointer = .{ .child = self.make(self.lowerType(ptr.child.*)), .is_const = ptr.is_const, .size = ptr.size, .sentinel = ptr.sentinel } },
            .optional => |child| .{ .optional = self.make(self.lowerType(child.*)) },
            .error_union => |result| .{ .error_union = .{ .errors = self.make(self.lowerType(result.errors.*)), .payload = self.make(self.lowerType(result.payload.*)) } },
            .enumeration => |shape| .{ .enumeration = shape.id },
            .array => |a| .{ .array = .{ .length = a.length, .sentinel = a.sentinel, .element = self.make(self.lowerType(a.element.*)) } },
            .slice => |s| .{ .slice = .{ .element = self.make(self.lowerType(s.element.*)), .is_const = s.is_const, .sentinel = s.sentinel } },
            .pointer => |shape| .{ .pointer = shape.id },
            .zig_callback => |callback| blk: {
                const sig = callback.signature;
                const params = self.a.alloc(ir.Type, sig.params.len) catch @panic("out of memory");
                for (params, sig.params) |*out, param| out.* = self.lowerType(param);
                break :blk .{ .zig_callback = .{ .params = params, .result = self.make(self.lowerType(sig.result)), .c_abi = callback.c_abi } };
            },
            .function => |sig| blk: {
                const params = self.a.alloc(ir.Type, sig.params.len) catch @panic("out of memory");
                for (params, sig.params) |*out, param| out.* = self.lowerType(param);
                break :blk .{ .function = .{ .params = params, .result = self.make(self.lowerType(sig.result)) } };
            },
        };
    }

    /// 按类型组成格式化可读名称，用于诊断并区分指针、切片和托管类型。
    fn typeName(self: *Analyzer, ty: Type) Text {
        return switch (ty) {
            .primitive => |p| if (p == .bytes) "[]const u8" else @tagName(p),
            .array => |a| self.fmt("[{d}]{s}", .{ a.length, self.typeName(a.element.*) }),
            .slice => |s| self.fmt("[]{s}{s}", .{ if (s.is_const) "const " else "", self.typeName(s.element.*) }),
            .structure => |shape| self.stableTypeName(.{ .structure = shape }),
            .foreign => |ty_ref| ty_ref.reference.name,
            .foreign_pointer => |ptr| self.fmt("{s}{s}{s}", .{
                switch (ptr.size) {
                    .one => "*",
                    .c => "[*c]",
                    .many => if (ptr.sentinel) |sentinel| self.fmt("[*:{d}]", .{sentinel}) else "[*]",
                    .slice => unreachable,
                },
                if (ptr.is_const) "const " else "",
                self.typeName(ptr.child.*),
            }),
            .managed => |m| self.fmt("{s}({s})", .{ @tagName(m.kind), self.typeName(m.child.*) }),
            .optional => |child| self.fmt("?{s}", .{self.typeName(child.*)}),
            .error_union => |result| self.fmt("{s}!{s}", .{ self.typeName(result.errors.*), self.typeName(result.payload.*) }),
            .enumeration => |shape| self.fmt("E{d}", .{shape.id}),
            .pointer => |shape| self.fmt("*S{d}", .{shape.id}),
            .function => "function",
            .zig_callback => "Zig function pointer",
        };
    }

    /// 将名称匹配到基础类型枚举，未识别的名称返回空值。
    fn primitive(name: Text) ?Primitive {
        return std.meta.stringToEnum(Primitive, name);
    }

    /// 解析类型位置的 AST，递归构造复合类型，其余表达式必须产生编译期类型值。
    fn typeExpr(self: *Analyzer, scope: *Scope, node: *Expr, owner: ?*Shape) Error!Type {
        switch (node.data) {
            .slice => |s| {
                const element = try self.typeExpr(scope, s.element, owner);

                if (element.is(.void) or element.is(.type)) return self.fail(node.at, "invalid slice element type", .{});
                if (s.is_const and element.is(.u8)) return .{ .primitive = .bytes };
                return .{ .slice = .{ .element = self.make(element), .is_const = s.is_const } };
            },
            .array_type => |a| {
                const length_value = try self.eval(scope, a.length, .{ .primitive = .usize }, owner);
                const length = if (length_value.constant_int) |n| std.math.cast(usize, n) else null;
                const element = try self.typeExpr(scope, a.element, owner);

                if (element.is(.void) or element.is(.type))
                    return self.fail(a.element.at, "invalid array element type", .{});
                return .{ .array = .{
                    .length = length orelse return self.fail(a.length.at, "array length must be a compile-time nonnegative integer", .{}),
                    .element = self.make(element),
                } };
            },
            .name => |name| {
                if (same(name, "Self")) return .{ .structure = owner orelse return self.fail(node.at, "Self requires a structure member", .{}) };
            },
            .unary => |u| if (u.op == .question) {
                const child = try self.typeExpr(scope, u.operand, owner);
                if (child.is(.type) or child.is(.void)) return self.fail(node.at, "invalid optional payload", .{});
                return .{ .optional = self.make(child) };
            } else if (u.op == .star) {
                const ty = try self.typeExpr(scope, u.operand, owner);
                if (ty == .foreign or (ty == .primitive and !ty.is(.type) and !ty.is(.void)))
                    return .{ .foreign_pointer = .{ .child = self.make(ty), .is_const = false } };
                if (ty == .managed and ty.managed.kind == .Ptr) return ty;
                if (ty != .structure) return self.fail(node.at, "pointer target must be a structure", .{});
                return .{ .pointer = ty.structure };
            },
            .function => |f| return .{ .function = try self.signature(scope, f, owner) },
            else => {},
        }
        const value = try self.eval(scope, node, meta_type, owner);

        return value.type_value orelse self.fail(node.at, "expected a compile-time type value", .{});
    }

    /// 根据托管类型标签识别只读 Ptr 参数约束。
    fn pointerConstraint(ty: Type) bool {
        return ty == .managed and ty.managed.kind == .Ptr;
    }

    /// 扫描函数参数，判断该回调是否因包含 Ptr 约束而需要静态特化。
    fn staticPointerCallback(ty: Type) bool {
        if (ty != .function) return false;
        for (ty.function.params) |param| if (pointerConstraint(param)) return true;
        return false;
    }

    /// 检查单个外部指针的目标是否为内存运行库中的 Manager 接口。
    fn managerConstraint(self: *Analyzer, ty: Type) bool {
        const candidate = if (ty == .foreign_pointer) ty.foreign_pointer.child.* else return false;
        return candidate == .foreign and self.isRuntimeType(candidate.foreign, "Manager");
    }

    /// 同时比较声明所属文件和名称，避免把用户同名类型识别为运行库类型。
    fn isRuntimeType(self: *Analyzer, ty: *ForeignType, name: Text) bool {
        const store = self.zig_store orelse return false;
        return store.runtime == ty.decl.file and same(ty.decl.name, name);
    }

    /// 分析参数和结果类型，检查上下文参数，并识别依赖 manager 的关联返回指针。
    fn signature(self: *Analyzer, scope: *Scope, ast: syn.Function, owner: ?*Shape) Error!*Signature {
        const params = self.a.alloc(Type, ast.params.len) catch @panic("out of memory");
        var context_parameter: ?usize = null;

        for (ast.params, 0..) |p, i| {
            for (ast.params[0..i]) |prior| if (same(prior.name.text, p.name.text))
                return self.fail(p.name.at, "duplicate parameter '{s}'", .{p.name.text});
            const value = try self.eval(scope, p.ty, meta_type, owner);
            params[i] = value.type_value orelse return self.fail(p.ty.at, "expected a compile-time type value", .{});

            if (params[i].is(.void)) return self.fail(p.name.at, "parameter cannot have type void", .{});
            if (p.context) {
                if (context_parameter != null) return self.fail(p.name.at, "only one context parameter is supported", .{});
                if (params[i] != .pointer and !(params[i] == .foreign_pointer and params[i].foreign_pointer.size == .one))
                    return self.fail(p.name.at, "context parameter requires a structure pointer", .{});
                context_parameter = i;
            }
        }
        if (ast.result.data == .call) {
            const assoc = ast.result.data.call;
            if (assoc.callee.data == .member and assoc.args.len == 1) {
                const member = assoc.callee.data.member;
                if (same(member.name, "Ptr") and member.base.data == .name) {
                    for (ast.params, params, 0..) |param, ty, index| {
                        if (same(param.name.text, member.base.data.name) and self.managerConstraint(ty)) {
                            const child = try self.typeExpr(scope, assoc.args[0], owner);
                            if (child.is(.void) or child.is(.type)) return self.fail(ast.result.at, "invalid pointer target", .{});
                            return self.make(Signature{ .params = params, .result = child, .context_parameter = context_parameter, .result_manager = index });
                        }
                    }
                }
            }
        }
        const result = try self.eval(scope, ast.result, meta_type, owner);
        return self.make(Signature{ .params = params, .result = result.type_value orelse return self.fail(ast.result.at, "expected a compile-time type value", .{}), .context_parameter = context_parameter });
    }

    /// 建立函数定义与签名，保存声明环境和所属容器，有函数体时登记待用定义。
    fn function(self: *Analyzer, scope: *Scope, ast: syn.Function, at: usize, owner: ?*Shape) Error!*Function {
        const effective_owner = owner orelse if (self.current_file) |file| file.shape else null;
        const method_owner = if (self.current_file) |file| if (owner == file.shape) null else owner else owner;
        const f = self.make(Function{ .name = if (self.declaration_hint) |hint| hint.text else "lambda", .ast = ast, .sig = try self.signature(scope, ast, effective_owner), .at = at, .owner = if (ast.body == null) owner else method_owner, .declaration_scope = if (self.current_file) |file| self.memberScope(file, file.scope.parent) else null, .file = self.current_file });
        if (owner) |shape| if (f.sig.params.len != 0 and f.sig.params[0] == .pointer and f.sig.params[0].pointer == shape) {
            f.owner = shape;
        };
        if (ast.body != null) self.append(&self.functions, f);
        return f;
    }

    /// 按字节比较名称文本，避免将切片地址当作名称身份。
    fn same(a: Text, b: Text) bool {
        return std.mem.eql(u8, a, b);
    }

    /// 替换顺序成员表并重建 HAMT 名称索引，使查找指向当前成员存储。
    fn setMembers(self: *Analyzer, shape: *Shape, members: []Member) void {
        shape.members = members;
        shape.member_index = .{};
        for (members) |*member| shape.member_index = shape.member_index.put(self.a, member.name, member);
    }

    /// 通过 HAMT 查询结构体的直接成员，不搜索嵌入对象。
    fn direct(shape: *Shape, name: Text) ?*const Member {
        return shape.member_index.get(name);
    }

    /// 复制成员路径并在开头插入一段名称，构造从外层对象出发的访问路径。
    fn prepend(self: *Analyzer, name: Text, path: []const Text) []const Text {
        const result = self.a.alloc(Text, path.len + 1) catch @panic("out of memory");
        result[0] = name;
        @memcpy(result[1..], path);
        return result;
    }

    /// 按重声明、直接成员及嵌入成员的顺序查找，计算有效可见性并拒绝提升歧义。
    fn lookup(self: *Analyzer, shape: *Shape, name: Text, at: usize) Error!?Found {
        for (shape.redeclarations) |r| if (same(r.name, name)) {
            var target = shape;
            for (r.path) |part| {
                const field = direct(target, part) orelse return self.fail(at, "invalid redeclaration path '{s}'", .{part});
                const child = self.embeddedShape(field) orelse return self.fail(at, "invalid redeclaration path '{s}'", .{part});
                if (field.visibility == .private and r.visibility != .private)
                    return self.fail(at, "cannot expose private use path '{s}'", .{part});
                target = child;
            }
            var found = (try self.lookup(target, name, at)) orelse return self.fail(at, "invalid redeclaration target '{s}'", .{name});
            found.path = r.path;
            found.visibility = r.visibility;
            found.declaring = shape;
            return found;
        };
        if (direct(shape, name)) |member| return .{ .member = member, .path = &.{}, .visibility = member.visibility, .declaring = shape };
        if (shape.foreign_instance) |ty| {
            if (self.foreignField(ty, name)) |field| {
                const node = field.ast.type_expr.unwrap() orelse return null;
                const field_ty = try self.zigTypeIn(ty.decl.file, ty, node, at);
                return .{ .member = self.make(Member{ .name = name, .data = .{ .field = .{ .ty = field_ty } } }), .path = &.{}, .visibility = .public, .declaring = shape, .foreign_field = true };
            }
            if (self.foreignMemberDecl(ty, name)) |entry| {
                return .{
                    .member = self.make(Member{ .name = name, .data = .{ .value = .{ .ty = meta_type, .foreign_declaration = entry.decl } } }),
                    .path = &.{},
                    .visibility = if (entry.public) .public else .private,
                    .declaring = shape,
                    .foreign_receiver = ty,
                };
            }
        }
        var result: ?Found = null;
        for (shape.members) |member| {
            const child = self.embeddedShape(&member) orelse continue;
            if (try self.lookup(child, name, at)) |found| {
                if (found.visibility == .private) continue;
                if (result != null) return self.fail(at, "ambiguous promoted member '{s}'", .{name});
                result = found;
                if (child.zig_file == null) result.?.path = self.prepend(member.name, found.path);
                if (member.visibility == .private) {
                    result.?.visibility = .private;
                    result.?.declaring = shape;
                } else if (member.visibility == .internal) {
                    result.?.visibility = .internal;
                    result.?.declaring = shape;
                }
            }
        }
        return result;
    }

    /// 提取可参与成员提升的结构，必要时为嵌入的 Zig 类型建立代理 Shape。
    fn embeddedShape(self: *Analyzer, member: *const Member) ?*Shape {
        if (member.data == .field and member.data.field.embedded) return switch (member.data.field.ty) {
            .structure => |shape| shape,
            .foreign => |ty| self.foreignStorageShape(ty),
            else => null,
        };
        if (member.embedded_namespace and member.data == .value) {
            if (member.data.value.type_value) |ty| {
                if (ty == .structure and ty.structure.zig_file != null) return ty.structure;
            }
        }
        return null;
    }

    /// 递归检查结构嵌入关系，离开起点后不穿过私有嵌入，用于 internal 访问判断。
    fn containsInternal(shape: *Shape, target: *Shape, first: bool) bool {
        if (shape == target) return true;
        for (shape.members) |member| {
            if (member.data != .field or !member.data.field.embedded or member.data.field.ty != .structure) continue;
            if (!first and member.visibility == .private) continue;
            if (containsInternal(member.data.field.ty.structure, target, false)) return true;
        }
        return false;
    }

    /// 根据实际声明者和调用方所属结构，判定 public、private 与 internal 访问权限。
    fn allowed(found: Found, owner: ?*Shape, root: *Shape) bool {
        return switch (found.visibility) {
            .public => true,
            .private => owner != null and owner.? == found.declaring,
            .internal => owner != null and containsInternal(owner.?, root, true),
        };
    }

    /// 将名称或连续成员访问 AST 展开为路径段，拒绝其他表达式形式。
    fn pathParts(self: *Analyzer, node: *Expr, parts: *std.ArrayList(Text)) Error!void {
        switch (node.data) {
            .name => |name| self.append(parts, name),
            .member => |m| {
                try self.pathParts(m.base, parts);
                self.append(parts, m.name);
            },
            else => return self.fail(node.at, "invalid member path", .{}),
        }
    }

    /// 沿可访问的结构体嵌入查找目标类型，返回唯一路径，存在多条时报告歧义。
    fn importPath(self: *Analyzer, shape: *Shape, target: *Shape, owner: ?*Shape, at: usize) Error!?[]const Text {
        if (shape == target) return &.{};
        var result: ?[]const Text = null;
        for (shape.members) |member| {
            if (member.data != .field or !member.data.field.embedded or member.data.field.ty != .structure) continue;
            const found = (try self.lookup(shape, member.name, at)) orelse continue;
            if (found.path.len != 0 or !allowed(found, owner, shape)) continue;
            if (try self.importPath(member.data.field.ty.structure, target, owner, at)) |path| {
                if (result != null) return self.fail(at, "ambiguous use path to S{d}", .{target.id});
                result = self.prepend(member.name, path);
            }
        }
        return result;
    }

    /// 按路径段连续构造字段 IR，得到从指定基对象出发的子对象表达式。
    fn access(self: *Analyzer, base: *const ir.Expr, path: []const Text) *const ir.Expr {
        var result = base;
        for (path) |name| result = self.irExpr(.{ .field = .{ .base = result, .name = name } });
        return result;
    }

    /// 分配带唯一编号的结构体模型，并登记到最终需要生成布局的集合。
    fn newShape(self: *Analyzer) *Shape {
        const s = self.make(Shape{ .id = self.id() });
        self.append(&self.shapes, s);
        return s;
    }

    /// 展开结构体声明并建立新版本，分别保存各声明的词法父环境后执行成员分析。
    fn structure(self: *Analyzer, scope: *Scope, fields: []syn.Field, target: ?*Shape) Error!Value {
        var expanded: std.ArrayList(syn.Field) = .empty;
        var parents: std.ArrayList(?*Scope) = .empty;
        const lexical_parent = self.lexicalScope(scope);
        var spread_seen = false;
        for (fields) |field| {
            if (field.spread) {
                if (spread_seen) return self.fail(field.ty.at, "duplicate structure spread", .{});
                spread_seen = true;
                const original = target orelse return self.fail(field.ty.at, "structure spread requires a structure assignment target", .{});
                for (original.declarations, original.declaration_parents) |declaration, parent| {
                    self.append(&expanded, declaration);
                    self.append(&parents, parent);
                }
            } else {
                self.append(&expanded, field);
                self.append(&parents, lexical_parent);
            }
        }
        const source = self.current_file orelse return self.fail(0, "structure requires a source container", .{});
        const s = self.newShape();
        if (target) |previous| {
            s.name = previous.name;
            s.version = previous.version + 1;
            s.source = previous.source;
        } else if (self.declaration_hint) |hint| {
            s.name = hint.text;
            s.source = self.span(hint.at, hint.text.len);
        }
        const state = self.make(ContainerState{ .module = source.module, .scope = self.make(Scope{ .parent = self.lexicalScope(scope) }), .shape = s, .object = self.irExpr(.{ .module_object = s.id }), .initializer = self.id(), .parent = source });
        s.file = state;
        s.declarations = expanded.items;
        s.declaration_parents = parents.items;
        try self.defineStructure(state, expanded.items);
        var value = typeValue(.{ .structure = s });
        value.context = self.irExpr(.{ .address = source.object });
        return value;
    }

    /// 按声明顺序建立字段、静态值和方法，处理成员可见性重声明并生成默认初始化函数。
    fn defineStructure(self: *Analyzer, state: *ContainerState, fields: []syn.Field) Error!void {
        const previous = self.current_file;
        self.current_file = state;
        defer self.current_file = previous;
        const s = state.shape;
        s.declarations = fields;
        const scope = state.scope;
        scope.container = state;
        if (s.declaration_parents.len == 0) {
            const parents = self.a.alloc(?*Scope, fields.len) catch @panic("out of memory");
            for (parents) |*parent| parent.* = scope.parent;
            s.declaration_parents = parents;
        }
        const original_parent = scope.parent;
        defer scope.parent = original_parent;
        var initialization: Body = .empty;
        var members: std.ArrayList(Member) = .empty;
        for (fields, s.declaration_parents) |field, parent| {
            scope.parent = parent;
            if (field.redeclaration) continue;
            if (field.declaration) |declaration| {
                var copy = declaration.*;
                if (copy.data == .binding) copy.data.binding.visibility = .public;
                _ = try self.block(scope, @as(*[1]Stmt, &copy), &initialization, null, 1);
                if (declaration.data == .binding) {
                    const binding = scope.bindings.get(declaration.data.binding.name.text).?;
                    const runtime = !binding.value.ty.is(.type) and binding.value.function == null and binding.value.foreign_function == null;
                    if (runtime) self.append(&state.initialization, Initialization{ .field = .{ .name = declaration.data.binding.name.text, .value = declaration.data.binding.value, .lexical_parent = parent } });
                    const data: @FieldType(Member, "data") = if (binding.value.function) |function_value| if (isMethod(function_value)) .{ .method = function_value } else .{ .value = binding.value } else if (runtime) .{ .field = .{ .ty = binding.value.ty, .file_mutable = binding.mutable, .has_default = true } } else .{ .value = binding.value };
                    self.append(&members, Member{ .name = declaration.data.binding.name.text, .visibility = declaration.data.binding.visibility, .data = data });
                }
                if (declaration.data != .binding) {
                    const type_assignment = if (declaration.data == .assign) blk: {
                        var base = declaration.data.assign.left;
                        if (base.data == .member) base = base.data.member.base;
                        break :blk base.data == .name and scope.get(base.data.name) != null and scope.get(base.data.name).?.value.ty.is(.type);
                    } else false;
                    if (!type_assignment) self.append(&state.initialization, Initialization{ .statement = declaration.* });
                }
                for (members.items) |*member| if (member.data == .value) {
                    if (scope.bindings.get(member.name)) |binding| member.data.value = binding.value;
                };
                self.setMembers(s, members.items);
                continue;
            }
            for (members.items) |m| if (same(m.name, field.name.text))
                return self.fail(field.name.at, "duplicate member '{s}'", .{m.name});
            var type_context: ?*const ir.Expr = null;
            const data: @FieldType(Member, "data") = if (field.ty.data == .function and !field.embedded) blk: {
                const f = try self.function(scope, field.ty.data.function, field.ty.at, s);
                f.name = field.name.text;
                if (std.meta.stringToEnum(Operator, field.name.text)) |op| {
                    try self.checkOperator(op, f, s, field.ty.at);
                    break :blk .{ .operator = f };
                }
                if (!isMethod(f)) return self.fail(field.ty.at, "abstract method requires a *Self receiver", .{});
                break :blk .{ .method = f };
            } else blk: {
                const ty: Type = if (field.embedded and field.ty.data == .string) blk2: {
                    const file = self.current_file orelse return self.fail(field.ty.at, "embedded file requires a module", .{});
                    for (file.module.embedded_imports) |import| {
                        if (import.expression == field.ty) {
                            switch (import.module) {
                                .lang => |module| {
                                    const child = try self.fileStructure(module, false);
                                    break :blk2 .{ .structure = child.shape };
                                },
                                .zig => |module| break :blk .{ .value = typeValue(.{ .structure = self.zigShape(module) }) },
                            }
                        }
                    }
                    return self.fail(field.ty.at, "embedded file was not loaded", .{});
                } else blk2: {
                    const value = try self.eval(scope, field.ty, meta_type, s);
                    type_context = value.context;
                    break :blk2 value.type_value orelse return self.fail(field.ty.at, "expected a compile-time type value", .{});
                };
                if (field.embedded and ty != .structure and !(ty == .foreign and ty.foreign.kind == .structure)) return self.fail(field.ty.at, "use requires a structure type", .{});
                if (ty.is(.void) or ty.is(.type) or (ty == .structure and (ty.structure == s or ty.structure.zig_file != null)))
                    return self.fail(field.ty.at, "invalid instance field type", .{});
                break :blk .{ .field = .{ .ty = ty, .embedded = field.embedded } };
            };
            var member = Member{ .name = field.name.text, .embedded_namespace = field.embedded and data == .value, .visibility = field.visibility, .data = data };
            if (member.data == .field and member.data.field.embedded and member.data.field.ty == .foreign) {
                const ty = member.data.field.ty.foreign;
                if (self.foreignHasDefaults(ty)) {
                    member.data.field.has_default = true;
                    self.append(&state.initialization, Initialization{ .embedded = .{ .name = member.name, .context = null } });
                    self.initializeForeignDefault(state.object, member.name, ty, &initialization);
                }
            }
            if (member.data == .field and member.data.field.embedded and member.data.field.ty == .structure) {
                const child = member.data.field.ty.structure;
                const has_default = defaultConstructible(child);
                member.data.field.has_default = has_default;
                if (has_default) if (child.file) |container| {
                    self.append(&state.initialization, Initialization{ .embedded = .{ .name = member.name, .context = type_context } });
                    const target = self.access(state.object, &.{member.name});
                    try self.initializeContainer(container, target, type_context, &initialization);
                    self.guardMemory(&initialization, target, member.data.field.ty, false);
                };
            }
            self.append(&members, member);
            self.setMembers(s, members.items);
            if (scope.bindings.contains(member.name)) return self.fail(field.name.at, "duplicate member '{s}'", .{member.name});
            const found: Found = .{ .member = &members.items[members.items.len - 1], .path = &.{}, .visibility = member.visibility, .declaring = s };
            const value: Value = switch (member.data) {
                .method, .operator => |function_value| .{ .ty = .{ .function = function_value.sig }, .function = function_value, .context = self.irExpr(.{ .address = state.object }) },
                else => try self.memberValue(.{ .ty = .{ .structure = s }, .expr = state.object, .writable = true }, found, member.name, field.name.at),
            };
            scope.bindings.put(self.a, member.name, self.make(Binding{ .value = value, .mutable = value.writable })) catch @panic("out of memory");
        }
        for (state.static_fields.items) |member| self.append(&members, member);
        self.setMembers(s, members.items);
        var redeclarations: std.ArrayList(Redeclaration) = .empty;
        for (fields) |field| {
            if (!field.redeclaration) continue;
            var parts: std.ArrayList(Text) = .empty;
            try self.pathParts(field.ty, &parts);
            const name = parts.items[parts.items.len - 1];
            for (redeclarations.items) |r| if (same(r.name, name)) return self.fail(field.name.at, "duplicate visibility redeclaration '{s}'", .{name});
            var current = s;
            var path: std.ArrayList(Text) = .empty;
            for (parts.items[0 .. parts.items.len - 1]) |part| {
                const found = (try self.lookup(current, part, field.name.at)) orelse return self.fail(field.name.at, "unknown member '{s}'", .{part});
                if (!allowed(found, s, current)) return self.fail(field.name.at, "inaccessible use path '{s}'", .{part});
                const child = self.embeddedShape(found.member) orelse return self.fail(field.name.at, "inaccessible use path '{s}'", .{part});
                for (found.path) |p| self.append(&path, p);
                self.append(&path, part);
                current = child;
            }
            const found = (try self.lookup(current, name, field.name.at)) orelse return self.fail(field.name.at, "unknown member '{s}'", .{name});
            if (current == s and found.path.len == 0) return self.fail(field.name.at, "duplicate member '{s}'", .{name});
            if (!allowed(found, s, current))
                return self.fail(field.name.at, "cannot redeclare inaccessible member '{s}'", .{name});
            for (found.path) |p| self.append(&path, p);
            var target = s;
            for (path.items) |part| {
                const member = direct(target, part) orelse return self.fail(field.name.at, "invalid use path '{s}'", .{part});
                const child = self.embeddedShape(member) orelse return self.fail(field.name.at, "invalid use path '{s}'", .{part});
                if (member.visibility == .private and field.visibility != .private)
                    return self.fail(field.name.at, "cannot expose private use path '{s}'", .{part});
                target = child;
            }
            self.append(&redeclarations, Redeclaration{ .name = name, .path = path.items, .visibility = field.visibility });
            s.redeclarations = redeclarations.items;
        }
        s.redeclarations = redeclarations.items;
        self.append(&self.bodies, ir.Function{ .id = state.initializer, .params = &.{}, .result = self.lowerType(void_type), .body = initialization.items, .initializes = s.id });
        state.ready = true;
    }

    /// 顺序比较名称集合，用于判断默认字段是否被显式初始化排除。
    fn containsName(names: []const Text, name: Text) bool {
        for (names) |candidate| if (same(candidate, name)) return true;
        return false;
    }

    /// 按排除字段集合复用或生成初始化变体，跳过显式字段的默认副作用并保留其余顺序。
    fn initializerFor(self: *Analyzer, state: *ContainerState, excluded: []const Text) Error!usize {
        if (excluded.len == 0 and state.ready) return state.initializer;
        for (state.variants.items) |variant| {
            if (variant.excluded.len != excluded.len) continue;
            var equal = true;
            for (excluded) |name| if (!containsName(variant.excluded, name)) {
                equal = false;
                break;
            };
            if (equal) return variant.id;
        }
        const previous = self.current_file;
        const previous_context = self.expected_context;
        self.current_file = state;
        self.expected_context = null;
        defer {
            self.current_file = previous;
            self.expected_context = previous_context;
        }
        var body: Body = .empty;
        for (state.initialization.items) |step| switch (step) {
            .field => |field| {
                if (containsName(excluded, field.name)) continue;
                const member = direct(state.shape, field.name) orelse continue;
                if (member.data != .field or !member.data.field.has_default) continue;
                var lexical = state.scope.*;
                lexical.parent = field.lexical_parent orelse state.scope.parent;
                const value = try self.expect(try self.eval(&lexical, field.value, member.data.field.ty, state.shape), member.data.field.ty, field.value.at);
                const target = self.access(state.object, &.{field.name});
                self.append(&body, ir.Stmt{ .assign = .{ .target = target, .value = try self.ownedExpr(value, field.value.at), .initialize = true } });
                self.guardMemory(&body, target, member.data.field.ty, false);
            },
            .embedded => |field| {
                if (containsName(excluded, field.name)) continue;
                const member = direct(state.shape, field.name) orelse continue;
                if (member.data != .field or !member.data.field.has_default) continue;
                if (member.data.field.ty == .foreign) {
                    self.initializeForeignDefault(state.object, field.name, member.data.field.ty.foreign, &body);
                    continue;
                }
                const child = member.data.field.ty.structure.file orelse continue;
                const target = self.access(state.object, &.{field.name});
                try self.initializeContainer(child, target, field.context, &body);
                self.guardMemory(&body, target, member.data.field.ty, false);
            },
            .statement => |statement| {
                var copy = statement;
                _ = try self.block(state.scope, @as(*[1]Stmt, &copy), &body, null, 1);
            },
        };
        const initializer_id = if (excluded.len == 0) state.initializer else self.id();
        self.append(&self.bodies, ir.Function{ .id = initializer_id, .params = &.{}, .result = self.lowerType(void_type), .body = body.items, .initializes = state.shape.id });
        if (excluded.len == 0) state.ready = true else self.append(&state.variants, InitializerVariant{ .excluded = self.a.dupe(Text, excluded) catch @panic("out of memory"), .id = initializer_id });
        return initializer_id;
    }

    /// 检查所有实例字段是否具有默认值，以判断是否允许省略字段构造对象。
    fn defaultConstructible(shape: *Shape) bool {
        for (shape.members) |member| if (member.data == .field and !member.data.field.has_default) return false;
        return true;
    }

    /// 检查枚举变体的重名与载荷类型，分配枚举身份并返回编译期类型值。
    fn enumeration(self: *Analyzer, scope: *Scope, variants: []syn.EnumVariant, owner: ?*Shape, at: usize) Error!Value {
        if (variants.len == 0) return self.fail(at, "enum requires at least one member", .{});
        var members: std.ArrayList(EnumVariant) = .empty;
        for (variants) |variant| {
            for (members.items) |member| if (same(member.name, variant.name.text)) return self.fail(variant.name.at, "duplicate enum member '{s}'", .{variant.name.text});
            const ty = if (variant.ty) |node| try self.typeExpr(scope, node, owner) else null;
            if (ty != null and (ty.?.is(.void) or ty.?.is(.type))) return self.fail(variant.name.at, "invalid enum payload type", .{});
            self.append(&members, EnumVariant{ .name = variant.name.text, .ty = ty });
        }
        const shape = self.make(EnumShape{
            .id = self.id(),
            .variants = members.items,
            .name = if (self.declaration_hint) |hint| hint.text else "Enumeration",
            .source = if (self.declaration_hint) |hint| self.span(hint.at, hint.text.len) else self.span(at, 1),
        });
        self.append(&self.enums, shape);
        return typeValue(.{ .enumeration = shape });
    }

    /// 按名称查找枚举变体，缺失时在使用位置报告错误。
    fn enumVariant(self: *Analyzer, shape: *EnumShape, name: Text, at: usize) Error!EnumVariant {
        for (shape.variants) |variant| if (same(variant.name, name)) return variant;
        return self.fail(at, "unknown enum member '{s}'", .{name});
    }

    /// 将语义类型包装为 type 类型的编译期值，不生成运行时表达式。
    fn typeValue(ty: Type) Value {
        return .{ .ty = meta_type, .type_value = ty };
    }

    /// 检查首参数是否为所属结构的指针，以区分实例方法和普通函数。
    fn isMethod(f: *Function) bool {
        return f.owner != null and f.sig.params.len != 0 and f.sig.params[0] == .pointer and
            f.sig.params[0].pointer == f.owner.?;
    }

    /// 比较方法的非接收者参数、返回值及上下文参数约定，允许接收者所属结构不同。
    fn compatibleMethod(a: *Function, b: *Function) bool {
        if (a.sig.params.len != b.sig.params.len or a.sig.context_parameter != b.sig.context_parameter or !a.sig.result.equal(b.sig.result)) return false;
        for (a.sig.params[1..], b.sig.params[1..]) |x, y| if (!x.equal(y)) return false;
        return true;
    }

    /// 保存静态分发选中的方法及其接收者路径，供调用时投影实际对象。
    const Dispatch = struct { function: *Function, receiver_path: []const Text };

    /// 沿嵌入路径由外向内选择首个兼容实现，并按私有声明限制可覆盖的层级。
    fn dispatch(self: *Analyzer, outer: *Shape, path: []const Text, name: Text, required: *Function, at: usize) Error!Dispatch {
        var current = outer;
        var declaring = outer;
        var first_override: usize = 0;
        for (path, 0..) |part, depth| {
            for (declaring.redeclarations) |r| {
                if (r.visibility != .private or !same(r.name, name) or r.path.len != path.len - depth) continue;
                var matches = true;
                for (r.path, path[depth..]) |a, b| {
                    if (!same(a, b)) {
                        matches = false;
                        break;
                    }
                }
                if (matches) first_override = depth;
            }
            const field = direct(declaring, part) orelse return self.fail(at, "invalid dispatch path '{s}'", .{part});
            if (field.data != .field or field.data.field.ty != .structure)
                return self.fail(at, "invalid dispatch path '{s}'", .{part});
            const visible = (try self.lookup(declaring, part, at)) orelse return self.fail(at, "invalid dispatch path '{s}'", .{part});
            if (visible.visibility == .private) first_override = depth + 1;
            declaring = field.data.field.ty.structure;
        }
        const declaration = (try self.lookup(declaring, name, at)) orelse return self.fail(at, "unknown method '{s}'", .{name});
        if (declaration.visibility == .private) first_override = path.len;
        var chosen: ?Dispatch = null;
        for (0..path.len + 1) |depth| {
            if (depth >= first_override and direct(current, name) != null) {
                const member = direct(current, name).?;
                const visible = (try self.lookup(current, name, at)).?;
                if (depth < path.len and visible.visibility == .private) {
                    current = direct(current, path[depth]).?.data.field.ty.structure;
                    continue;
                }
                if (member.data != .method or !compatibleMethod(member.data.method, required))
                    return self.fail(at, "incompatible override of '{s}'", .{name});
                if (chosen == null and member.data.method.ast.body != null)
                    chosen = .{ .function = member.data.method, .receiver_path = path[0..depth] };
            }
            if (depth < path.len) current = direct(current, path[depth]).?.data.field.ty.structure;
        }
        return chosen orelse self.fail(at, "missing implementation of abstract method '{s}'", .{name});
    }

    /// 递归检查嵌入结构中的方法要求，通过静态分发确认存在兼容实现。
    fn validate(self: *Analyzer, outer: *Shape, sub: *Shape, path: []const Text, at: usize) Error!void {
        for (sub.members) |m| {
            switch (m.data) {
                .field => |f| if (f.embedded and f.ty == .structure) {
                    const child_path = std.mem.concat(self.a, Text, &.{ path, &.{m.name} }) catch @panic("out of memory");
                    try self.validate(outer, f.ty.structure, child_path, at);
                },
                .method => |required| {
                    _ = try self.dispatch(outer, path, m.name, required, at);
                },
                else => {},
            }
        }
    }

    /// 按期望数值类型解析字面量，检查范围并生成规范文本及可用的整数常量信息。
    fn literal(self: *Analyzer, node: *Expr, raw: Text, expected: ?Type) Error!Value {
        const signed_text = if (std.mem.startsWith(u8, raw, "-")) raw[1..] else raw;
        const hex = std.mem.startsWith(u8, signed_text, "0x");
        const decimal = !(hex or std.mem.startsWith(u8, signed_text, "0b") or std.mem.startsWith(u8, signed_text, "0o"));
        const floating = if (hex) std.mem.indexOfAny(u8, raw, ".pP") != null else decimal and std.mem.indexOfAny(u8, raw, ".eE") != null;
        const ty = if (expected != null and expected.?.numeric()) expected.? else Type{ .primitive = if (floating) .f64 else .i32 };
        const canonical = if (ty.float()) blk: {
            const value = std.fmt.parseFloat(f128, raw) catch return self.fail(node.at, "invalid floating-point literal", .{});
            const fits = switch (ty.primitive) {
                .f16 => std.math.isFinite(@as(f16, @floatCast(value))),
                .f32 => std.math.isFinite(@as(f32, @floatCast(value))),
                .f64 => std.math.isFinite(@as(f64, @floatCast(value))),
                .f128 => std.math.isFinite(value),
                else => unreachable,
            };
            if (!fits) return self.fail(node.at, "literal out of range for {s}", .{self.typeName(ty)});
            break :blk self.fmt("{e}", .{value});
        } else blk: {
            if (floating) return self.fail(node.at, "expected an integer literal", .{});
            break :blk switch (ty.primitive) {
                inline .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .usize => |p| val: {
                    const Native = @Int(if (@tagName(p)[0] == 'i') .signed else .unsigned, if (p == .usize) @bitSizeOf(usize) else std.fmt.parseInt(u16, @tagName(p)[1..], 10) catch unreachable);
                    const value = std.fmt.parseInt(Native, raw, 0) catch return self.fail(node.at, "invalid or out-of-range literal for {s}", .{@tagName(p)});
                    break :val self.fmt("{d}", .{value});
                },
                else => unreachable,
            };
        };
        return .{ .ty = ty, .constant_int = if (ty.float()) null else std.fmt.parseInt(i128, canonical, 10) catch null, .expr = self.irExpr(.{ .number = .{ .ty = ty.primitive, .canonical = canonical } }) };
    }

    /// 检查字符串 UTF-8 并解码支持的转义，生成只读字节串 IR。
    fn string(self: *Analyzer, node: *Expr, raw: Text) Error!Value {
        if (!std.unicode.utf8ValidateSlice(raw)) return self.fail(node.at, "string literal must be UTF-8", .{});
        var out: std.ArrayList(u8) = .empty;
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
                    else => return self.fail(node.at + i, "unsupported string escape", .{}),
                };
            }
            self.append(&out, byte);
        }
        return .{ .ty = .{ .primitive = .bytes }, .expr = self.irExpr(.{ .bytes = out.items }) };
    }

    /// 检查值是否符合目标类型，处理受限的只读转换、Zig 常量定型和托管地址保活。
    fn expect(self: *Analyzer, value: Value, ty: Type, at: usize) Error!Value {
        if (value.pointer_readonly and (ty == .pointer or ty == .foreign_pointer or ty == .managed or ty == .slice or ty == .structure or ty == .array))
            return self.fail(at, "read-only Ptr cannot escape as a writable value", .{});
        if (value.memory_owner != null and (value.ty == .pointer or value.ty == .foreign_pointer)) {
            if (ty == .managed and ty.managed.kind == .View and ty.managed.child.equal(value.ty))
                return self.packMemoryView(value, at);
            return self.fail(at, "managed address requires a view that preserves its owner", .{});
        }
        if (value.zig_constant) |constant| {
            if (ty.numeric() and (!constant.is_float or ty.float())) {
                var converted = try self.literal(self.make(Expr{ .at = at, .data = .{ .number = constant.source } }), constant.source, ty);
                if (value.expr) |expression| if (expression.* == .foreign_ref) {
                    converted.expr = self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(ty), .value = expression } });
                };
                return converted;
            }
        }
        const compatible = value.ty.equal(ty) or
            (value.ty == .foreign_pointer and ty == .foreign_pointer and value.ty.foreign_pointer.size == ty.foreign_pointer.size and value.ty.foreign_pointer.sentinel == ty.foreign_pointer.sentinel and !value.ty.foreign_pointer.is_const and ty.foreign_pointer.is_const and value.ty.foreign_pointer.child.equal(ty.foreign_pointer.child.*)) or (value.ty == .slice and ty == .slice and (ty.slice.sentinel == null or value.ty.slice.sentinel == ty.slice.sentinel) and (!value.ty.slice.is_const or ty.slice.is_const) and value.ty.slice.element.equal(ty.slice.element.*)) or (value.ty == .slice and value.ty.slice.element.is(.u8) and ty.is(.bytes));
        if (!compatible or value.view != null)
            return self.fail(at, "expected {s}, got {s}", .{ self.typeName(ty), self.typeName(value.ty) });
        var converted = value;
        converted.ty = ty;
        return converted;
    }

    /// 检查数组长度并逐项分析元素，暂存托管值后构造带正确所有权的数组 IR。
    fn initArray(self: *Analyzer, scope: *Scope, at: usize, ty: Type, elements: []*Expr, owner: ?*Shape) Error!Value {
        if (ty != .array) return self.fail(at, "array initializer requires an array type", .{});
        if (elements.len != ty.array.length) return self.fail(at, "expected {d} array elements, got {d}", .{ ty.array.length, elements.len });
        var values: std.ArrayList(*const ir.Expr) = .empty;
        var setup: Body = .empty;
        for (elements) |element| {
            var value = try self.expect(try self.eval(scope, element, ty.array.element.*, owner), ty.array.element.*, element.at);
            if (memoryTraits(value.ty).active()) value = try self.stageManaged(&setup, value, element.at);
            self.append(&values, try self.ownedExpr(value, element.at));
        }
        return self.wrapManagedScope(setup, .{ .ty = ty, .expr = self.irExpr(.{ .array_init = .{ .ty = self.lowerType(ty), .elements = values.items } }) });
    }

    /// 分析数组或切片下标，检查已知越界并传播元素可写性和托管所有者信息。
    fn indexValue(self: *Analyzer, scope: *Scope, base_node: *Expr, index_node: *Expr, owner: ?*Shape, at: usize) Error!Value {
        var base = try self.eval(scope, base_node, null, owner);
        var setup: Body = .empty;
        if (memoryTraits(base.ty).active() and !isLvalueExpression(base.expr.?))
            base = try self.stageManaged(&setup, base, base_node.at);
        base = self.unpackMemoryView(base);
        const element: Type = if (base.ty == .array) base.ty.array.element.* else if (base.ty == .slice) base.ty.slice.element.* else if (base.ty.is(.bytes)) .{ .primitive = .u8 } else return self.fail(at, "index requires an array or slice", .{});
        const index = try self.expect(try self.eval(scope, index_node, .{ .primitive = .usize }, owner), .{ .primitive = .usize }, index_node.at);
        if (base.ty == .array and index.constant_int != null and index.constant_int.? >= base.ty.array.length) return self.fail(index_node.at, "array index out of bounds", .{});
        const result: Value = .{ .ty = element, .memory_owner = if (setup.items.len == 0) base.memory_owner else null, .writable = !base.pointer_readonly and (if (base.ty == .array) base.writable else if (base.ty == .slice) !base.ty.slice.is_const else false), .pointer_readonly = base.pointer_readonly, .expr = self.irExpr(.{ .index = .{ .base = try self.runtimeExpr(base, at), .index = try self.runtimeExpr(index, index_node.at) } }) };
        return if (setup.items.len == 0) result else try self.finishManagedScope(setup, result, at);
    }

    /// 分析切片起止位置与可写性，检查已知范围并为托管对象派生的切片保留所有者。
    fn sliceValue(self: *Analyzer, scope: *Scope, base_node: *Expr, start_node: *Expr, end_node: ?*Expr, owner: ?*Shape, at: usize) Error!Value {
        var base = try self.eval(scope, base_node, null, owner);
        var setup: Body = .empty;
        if (memoryTraits(base.ty).active() and !isLvalueExpression(base.expr.?))
            base = try self.stageManaged(&setup, base, base_node.at);
        base = self.unpackMemoryView(base);
        const element: Type = if (base.ty == .array) base.ty.array.element.* else if (base.ty == .slice) base.ty.slice.element.* else if (base.ty.is(.bytes)) .{ .primitive = .u8 } else return self.fail(at, "slice requires an array or slice", .{});
        const is_const = base.pointer_readonly or (if (base.ty == .array) !base.writable else if (base.ty == .slice) base.ty.slice.is_const else true);
        const usize_ty: Type = .{ .primitive = .usize };
        const start = try self.expect(try self.eval(scope, start_node, usize_ty, owner), usize_ty, start_node.at);
        const end = if (end_node) |n| try self.expect(try self.eval(scope, n, usize_ty, owner), usize_ty, n.at) else null;
        if (start.constant_int != null and end != null and end.?.constant_int != null and start.constant_int.? > end.?.constant_int.?) return self.fail(at, "invalid slice bounds", .{});
        if (base.ty == .array) {
            if (start.constant_int != null and start.constant_int.? > base.ty.array.length) return self.fail(at, "slice bounds out of range", .{});
            if (end != null and end.?.constant_int != null and end.?.constant_int.? > base.ty.array.length) return self.fail(at, "slice bounds out of range", .{});
        }
        const ty: Type = if (is_const and element.is(.u8)) .{ .primitive = .bytes } else .{ .slice = .{ .element = self.make(element), .is_const = is_const } };
        const result: Value = .{ .ty = ty, .memory_owner = base.memory_owner, .pointer_readonly = base.pointer_readonly, .expr = self.irExpr(.{ .subslice = .{ .base = try self.runtimeExpr(base, at), .start = try self.runtimeExpr(start, start_node.at), .end = if (end) |v| try self.runtimeExpr(v, end_node.?.at) else null } }) };
        return self.wrapManagedScope(setup, try self.packMemoryView(result, at));
    }

    /// 检查对象的显式字段、访问权限及必需字段，选择跳过显式字段默认值的初始化函数。
    fn initObject(self: *Analyzer, scope: *Scope, node: *Expr, expected: ?Type, owner: ?*Shape, embedded: bool) Error!Value {
        const obj = node.data.object;
        const type_value = if (obj.ty) |t| try self.eval(scope, t, meta_type, owner) else null;
        const ty = if (type_value) |value| value.type_value orelse return self.fail(node.at, "expected a structure type for initializer", .{}) else expected orelse
            return self.fail(node.at, "object initializer requires a structure type", .{});
        if (ty == .foreign) return self.initForeignObject(scope, node, ty.foreign, owner);
        if (ty != .structure or ty.structure.zig_file != null) return self.fail(node.at, "expected a structure type for initializer", .{});
        const context = if (type_value) |value| value.context else self.expected_context orelse if (self.current_file) |file| self.irExpr(.{ .address = file.object }) else null;
        const previous_context = self.expected_context;
        self.expected_context = context;
        defer self.expected_context = previous_context;
        if (!embedded) try self.validate(ty.structure, ty.structure, &.{}, node.at);
        var fields: std.ArrayList(ir.Initializer) = .empty;
        var setup: Body = .empty;
        const managed = memoryTraits(ty).active();
        for (obj.fields, 0..) |field, i| {
            for (obj.fields[0..i]) |prior| if (same(prior.name.text, field.name.text))
                return self.fail(field.name.at, "duplicate initializer for '{s}'", .{field.name.text});
            const m = direct(ty.structure, field.name.text) orelse return self.fail(field.name.at, "unknown instance field '{s}'", .{field.name.text});
            const found = (try self.lookup(ty.structure, field.name.text, field.name.at)).?;
            if (!allowed(found, owner, ty.structure))
                return self.fail(field.name.at, "inaccessible member '{s}'", .{field.name.text});
            if (m.data != .field) return self.fail(field.name.at, "'{s}' is not an instance field", .{field.name.text});
            const ft = m.data.field;
            if (ty.structure.file != null and !ft.file_mutable) return self.fail(field.name.at, "file constant '{s}' is initialized by its declaration", .{m.name});
            self.expected_context = context;
            var value = if (ft.embedded and field.value.data == .object)
                try self.initObject(scope, field.value, ft.ty, owner, true)
            else
                try self.eval(scope, field.value, ft.ty, owner);
            _ = try self.expect(value, ft.ty, field.value.at);
            if (managed) value = try self.stageManaged(&setup, value, field.value.at);
            self.append(&fields, ir.Initializer{ .name = m.name, .value = try self.ownedExpr(value, field.value.at) });
        }
        for (ty.structure.members) |m| {
            if (m.data != .field) continue;
            for (obj.fields) |field| {
                if (same(field.name.text, m.name)) break;
            } else {
                if (m.data.field.has_default) continue;

                return self.fail(node.at, "missing initializer for '{s}'", .{m.name});
            }
        }

        const initializer = if (ty.structure.file) |state| blk: {
            if (!state.ready) return self.fail(node.at, "cyclic structure initialization", .{});
            var excluded: std.ArrayList(Text) = .empty;
            for (fields.items) |field| {
                const member = direct(ty.structure, field.name).?;
                if (member.data.field.has_default) self.append(&excluded, field.name);
            }
            break :blk try self.initializerFor(state, excluded.items);
        } else null;
        return self.wrapManagedScope(setup, .{ .ty = ty, .expr = self.irExpr(.{ .object = .{ .shape = ty.structure.id, .fields = fields.items, .context = context, .initializer = initializer, .temporary = self.id() } }) });
    }

    /// 按 AST 种类分析表达式，结合期望类型返回编译期信息或运行时 IR，不执行运行时程序。
    fn eval(self: *Analyzer, scope: *Scope, node: *Expr, expected: ?Type, owner: ?*Shape) Error!Value {
        return switch (node.data) {
            .name => |name| blk: {
                if (try self.lexicalValue(scope, name, owner, node.at)) |value| break :blk value;
                if (self.current_file) |file| {
                    if (try self.promotedMember(file, name, owner, node.at)) |value| break :blk try self.contextualZigConstant(value, expected, node.at);
                }
                if (primitive(name)) |p| break :blk typeValue(.{ .primitive = p });
                if (same(name, "Self") and owner != null) {
                    var value = typeValue(.{ .structure = owner.? });
                    if (self.current_file) |file| value.context = self.irExpr(.{ .address = file.object });
                    if (self.selfReceiver(scope, owner.?)) |receiver| {
                        value.context = self.memberContext(receiver, &.{});
                    }
                    break :blk value;
                }
                if (try self.preludeMember(name, node.at)) |value| break :blk value;
                if (same(name, "true") or same(name, "false")) break :blk .{ .ty = .{ .primitive = .bool }, .expr = self.irExpr(.{ .boolean = same(name, "true") }) };
                return self.fail(node.at, "unknown name '{s}'", .{name});
            },
            .array_type, .slice => typeValue(try self.typeExpr(scope, node, owner)),
            .number => |raw| self.literal(node, raw, expected),
            .string => |raw| self.string(node, raw),
            .structure => |fields| self.structure(scope, fields, null),
            .enumeration => |variants| self.enumeration(scope, variants, owner, node.at),
            .matching => |match| blk: {
                const result = try self.matching(scope, match, expected, owner, node.at, 1);
                break :blk self.wrapManagedScope(result.setup, .{ .ty = result.ty orelse void_type, .expr = self.irExpr(.{ .matching = result.lowered }) });
            },
            .function => |ast| blk: {
                if (ast.body == null) break :blk typeValue(.{ .function = try self.signature(scope, ast, owner) });
                const f = try self.function(scope, ast, node.at, owner);
                break :blk .{ .ty = .{ .function = f.sig }, .function = f };
            },
            .object => |obj| blk: {
                if (obj.fields.len == 0) {
                    const ty = if (obj.ty) |t| try self.typeExpr(scope, t, owner) else expected;
                    if (ty != null and ty.? == .array) break :blk try self.initArray(scope, node.at, ty.?, &.{}, owner);
                }
                break :blk try self.initObject(scope, node, expected, owner, false);
            },
            .array_init => |init| blk: {
                const ty = if (init.ty) |t| try self.typeExpr(scope, t, owner) else expected orelse return self.fail(node.at, "array initializer requires an array type", .{});
                break :blk try self.initArray(scope, node.at, ty, init.elements, owner);
            },
            .index => |idx| try self.indexValue(scope, idx.base, idx.index, owner, node.at),
            .subslice => |slice| try self.sliceValue(scope, slice.base, slice.start, slice.end, owner, node.at),
            .conditional => |cond| self.conditionalValue(scope, cond, expected, owner, node.at),
            .unary => |u| blk: {
                if (u.op == .star or u.op == .question) break :blk typeValue(try self.typeExpr(scope, node, owner));
                if (u.op == .minus and u.operand.data == .number)
                    break :blk try self.literal(node, self.fmt("-{s}", .{u.operand.data.number}), expected);
                if (u.op == .amp and u.operand.data == .member) {
                    const member = u.operand.data.member;
                    var receiver = try self.eval(scope, member.base, null, owner);
                    if (receiver.ty == .managed) {
                        var setup: Body = .empty;
                        if (!isLvalueExpression(receiver.expr.?))
                            receiver = try self.stageManaged(&setup, receiver, member.base.at);
                        receiver = if (receiver.ty.managed.kind == .View) self.unpackMemoryView(receiver) else try self.managedPointee(receiver, node.at);
                        const found = try self.resolveMember(receiver, member.name, owner, node.at);
                        var field = try self.memberValue(receiver, found, member.name, node.at);
                        field.memory_owner = receiver.memory_owner;
                        break :blk self.wrapManagedScope(setup, try self.addressOfValue(field, node.at));
                    }
                }
                const hint = if (u.op == .kw_not) bool_type else if (u.op != .amp) expected else null;
                const value = try self.eval(scope, u.operand, hint, owner);
                if (u.op == .amp) break :blk try self.addressOfValue(value, node.at);
                break :blk try self.unaryOperator(value, u.op, owner, node.at);
            },
            .binary => |b| blk: {
                if (b.op == .kw_and or b.op == .kw_or) {
                    const left = try self.condition(scope, b.left, owner);
                    const right = try self.condition(scope, b.right, owner);
                    break :blk self.predicate(if (b.op == .kw_and) .logical_and else .logical_or, left, right);
                }
                const operand_hint = if (comparison(b.op) != null) null else expected;
                if (isNumericLiteral(b.left) and !isNumericLiteral(b.right)) {
                    const right = try self.eval(scope, b.right, operand_hint, owner);
                    const left = try self.eval(scope, b.left, right.ty, owner);
                    break :blk try self.binary(left, right, b.op, owner, node.at);
                }
                const left = try self.eval(scope, b.left, operand_hint, owner);
                const right = try self.eval(scope, b.right, left.ty, owner);
                break :blk try self.binary(left, right, b.op, owner, node.at);
            },
            .member => |m| blk: {
                var base = try self.eval(scope, m.base, null, owner);
                var staged: Body = .empty;
                if (memoryTraits(base.ty).active() and !isLvalueExpression(base.expr.?))
                    base = try self.stageManaged(&staged, base, m.base.at);
                if (base.ty == .managed) {
                    base = if (base.ty.managed.kind == .View) self.unpackMemoryView(base) else try self.managedPointee(base, node.at);
                }
                if (base.type_value) |ty| if (ty == .optional and same(m.name, "None")) {
                    break :blk .{ .ty = ty, .expr = self.irExpr(.{ .optional_none = self.lowerType(ty) }) };
                };
                if (try self.getForeignMember(base, m.name, node.at)) |value| break :blk try self.contextualZigConstant(value, expected, node.at);
                if (base.type_value) |ty| if (ty == .enumeration) {
                    const variant = try self.enumVariant(ty.enumeration, m.name, node.at);
                    if (variant.ty != null) return self.fail(node.at, "enum member '{s}' requires a payload", .{m.name});
                    break :blk .{ .ty = ty, .expr = self.irExpr(.{ .enum_init = .{ .id = ty.enumeration.id, .name = m.name, .payload = null } }) };
                };
                if (same(m.name, "len") and (base.ty == .array or base.ty == .slice or base.ty.is(.bytes))) {
                    const length: Value = .{ .ty = .{ .primitive = .usize }, .constant_int = if (base.ty == .array) @intCast(base.ty.array.length) else null, .expr = self.irExpr(.{ .length = try self.runtimeExpr(base, node.at) }) };
                    break :blk self.wrapManagedScope(staged, length);
                }
                const found = try self.resolveMember(base, m.name, owner, node.at);
                if (!base.ty.is(.type) and found.foreign_receiver != null and found.member.data.value.foreign_declaration != null) {
                    const value = try self.memberValue(base, found, m.name, node.at);
                    if (value.foreign_function != null) return self.fail(node.at, "Zig instance method must be called with a receiver", .{});
                    break :blk value;
                }
                if (found.member.data == .method and base.memory_owner != null) {
                    if (base.pointer_readonly) return self.fail(node.at, "method requires a mutable receiver", .{});
                    break :blk self.wrapManagedScope(staged, try self.bindManagedMethod(base, found, m.name, node.at));
                }
                var field = try self.contextualZigConstant(try self.memberValue(base, found, m.name, node.at), expected, node.at);
                field.memory_owner = base.memory_owner;
                if (field.ty == .slice or field.ty.is(.bytes) or field.ty == .pointer or field.ty == .foreign_pointer)
                    field = try self.packMemoryView(field, node.at);
                if (staged.items.len != 0 and field.memory_owner != null) {
                    if (field.ty == .array or field.ty == .structure)
                        return self.fail(node.at, "bind the managed object before deriving an address from this field", .{});
                    field.memory_owner = null;
                }
                break :blk if (staged.items.len != 0) try self.finishManagedScope(staged, field, node.at) else field;
            },
            .call => self.call(scope, node, owner),
        };
    }

    /// 检查值是否可取址及是否只读，生成指针，并用 View 保活托管对象的派生地址。
    fn addressOfValue(self: *Analyzer, value: Value, at: usize) Error!Value {
        if (value.ty.is(.type)) return self.fail(at, "type and module namespaces are compile-time only", .{});
        if (value.pointer_readonly and value.ty == .managed)
            return self.fail(at, "cannot take the address of a read-only smart pointer", .{});
        if (value.ty == .foreign or value.ty == .managed or (value.ty == .primitive and !value.ty.is(.void))) {
            if (!try self.isForeignLvalue(value, at)) return self.fail(at, "& requires an addressable value", .{});
            return self.packMemoryView(.{
                .ty = .{ .foreign_pointer = .{ .child = self.make(value.ty), .is_const = !value.writable } },
                .expr = self.irExpr(.{ .address = try self.runtimeExpr(value, at) }),
                .memory_owner = value.memory_owner,
            }, at);
        }
        if (value.ty != .structure or !value.writable) return self.fail(at, "& requires a mutable structure lvalue", .{});
        var result = value;
        result.ty = .{ .pointer = value.ty.structure };
        result.expr = self.irExpr(.{ .address = value.expr.? });
        result.writable = false;
        return self.packMemoryView(result, at);
    }

    /// 合并原始对象与静态多态视图路径，恢复成员访问的真实来源以检查可见性。
    fn memberOrigin(self: *Analyzer, base: Value, at: usize) Error!Value.Origin {
        const visible = try self.baseShape(base, at);
        var origin = base.origin orelse if (base.view) |view|
            Value.Origin{ .shape = view.shape, .path = view.path }
        else
            Value.Origin{ .shape = visible, .path = &.{} };
        if (base.origin != null) if (base.view) |view| {
            var shape = origin.shape;
            for (origin.path) |part| {
                const member = direct(shape, part) orelse return self.fail(at, "invalid member origin '{s}'", .{part});
                if (member.data != .field) return self.fail(at, "invalid member origin '{s}'", .{part});
                const ty = member.data.field.ty;
                shape = switch (ty) {
                    .pointer => ty.pointer,
                    .structure => ty.structure,
                    else => return self.fail(at, "invalid member origin '{s}'", .{part}),
                };
            }
            if (shape != visible and shape == view.shape)
                origin.path = std.mem.concat(self.a, Text, &.{ origin.path, view.path }) catch @panic("out of memory")
            else if (shape != visible)
                origin = .{ .shape = view.shape, .path = view.path };
        };
        return origin;
    }

    /// 将 Zig 文件声明映射为命名空间 Shape，并按文件缓存以复用成员索引。
    fn zigShape(self: *Analyzer, file: *foreign.File) *Shape {
        if (self.zig_shapes.get(file)) |shape| return shape;
        const shape = self.newShape();
        shape.zig_file = file;
        self.zig_shapes.put(self.a, file, shape) catch @panic("out of memory");
        var members: std.ArrayList(Member) = .empty;
        var declarations = file.declarations.iterator();
        while (declarations.next()) |entry| {
            self.append(&members, Member{
                .name = entry.key_ptr.*,
                .visibility = if (entry.value_ptr.public) .public else .private,
                .data = .{ .value = .{
                    .ty = meta_type,
                    .foreign_declaration = .{ .file = file, .name = entry.key_ptr.*, .node = entry.value_ptr.node },
                } },
            });
        }
        self.setMembers(shape, members.items);
        return shape;
    }

    /// 按需从标准库解析隐式 print，其他名称不参与隐式导入。
    fn preludeMember(self: *Analyzer, name: Text, at: usize) Error!?Value {
        // Only the compatibility exports are implicitly imported.
        if (!same(name, "print")) return null;
        const store = self.zig_store orelse self.prelude_store orelse blk: {
            const store = self.make(foreign.Store{ .a = self.a, .io = std.Io.failing });
            self.prelude_store = store;
            break :blk store;
        };
        const file = store.loadStdlib() catch |err|
            return self.fail(at, "cannot load the saphine standard library: {s}", .{@errorName(err)});
        const namespace = self.zigShape(file);
        const found = (try self.lookup(namespace, name, at)) orelse
            return self.fail(at, "standard library is missing '{s}'", .{name});
        if (found.visibility != .public)
            return self.fail(at, "standard library member '{s}' must be public", .{name});
        return try self.memberValue(typeValue(.{ .structure = namespace }), found, name, at);
    }

    /// 将 Zig 声明解析为函数、类型或值，保留类型身份与可访问引用，并检测递归解析。
    fn resolveZig(self: *Analyzer, declaration: ForeignDeclaration, at: usize) Error!Value {
        const file = declaration.file;
        const reference = declaration.reference orelse ir.ForeignRef{ .module = if (file.embedded) ir.stdlib_module else file.id, .name = declaration.name };
        const tree = file.tree;
        const node = declaration.node;
        for (self.resolving_zig.items) |pending| {
            if (pending.file == file and pending.node == node)
                return self.fail(at, "recursive Zig declaration '{s}'", .{declaration.name});
        }
        self.append(&self.resolving_zig, declaration);
        defer _ = self.resolving_zig.pop();

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullFnProto(&buffer, node)) |proto| {
            if (file.embedded and declaration.container == null and same(declaration.name, "print"))
                return .{ .ty = meta_type, .stdlib_print = reference };
            var zig_parameters: std.ArrayList(ZigFunction.Parameter) = .empty;
            var is_generic = false;
            var signature_iterator = proto.iterate(&tree);
            while (signature_iterator.next()) |param| {
                if (param.anytype_ellipsis3 != null and tree.tokenTag(param.anytype_ellipsis3.?) == .ellipsis3)
                    return self.fail(at, "unsupported variadic Zig function '{s}'", .{declaration.name});
                const comptime_param = param.comptime_noalias != null and tree.tokenTag(param.comptime_noalias.?) == .keyword_comptime;
                is_generic = is_generic or comptime_param or param.type_expr == null;
                self.append(&zig_parameters, ZigFunction.Parameter{
                    .name = if (param.name_token) |token| tree.tokenSlice(token) else null,
                    .node = param.type_expr,
                    .comptime_param = comptime_param,
                });
            }
            if (is_generic) return .{ .ty = meta_type, .zig_generic = self.make(ZigFunction{
                .declaration = declaration,
                .reference = reference,
                .parameters = zig_parameters.items,
                .result_node = proto.ast.return_type.unwrap() orelse return self.fail(at, "missing Zig return type", .{}),
            }) };
            var params: std.ArrayList(Type) = .empty;
            for (zig_parameters.items) |param| {
                const ty = try self.zigTypeIn(file, declaration.container, param.node.?, at);
                if (ty.is(.type) or ty.is(.void)) return self.fail(at, "unsupported Zig parameter type in '{s}'", .{declaration.name});
                self.append(&params, ty);
            }
            const result_node = proto.ast.return_type.unwrap() orelse return self.fail(at, "missing Zig return type", .{});
            const result = try self.zigTypeIn(file, declaration.container, result_node, at);
            if (result.is(.type)) return .{ .ty = meta_type, .zig_generic = self.make(ZigFunction{
                .declaration = declaration,
                .reference = reference,
                .parameters = zig_parameters.items,
                .result_node = result_node,
            }) };
            const c_abi = if (proto.ast.callconv_expr.unwrap()) |expr|
                tree.nodeTag(expr) == .enum_literal and same(tree.tokenSlice(tree.nodeMainToken(expr)), "c")
            else
                tree.tokenTag(proto.ast.fn_token -| 1) == .keyword_extern;
            return .{ .ty = .{ .function = self.make(Signature{ .params = params.items, .result = result }) }, .foreign_function = reference, .foreign_c_abi = c_abi };
        }
        const variable = tree.fullVarDecl(node) orelse unreachable;
        const mutable = tree.tokenTag(variable.ast.mut_token) == .keyword_var;
        if (variable.ast.type_node.unwrap()) |annotation| {
            const ty = try self.zigTypeIn(file, declaration.container, annotation, at);
            if (!ty.is(.type)) {
                var constant_int: ?i128 = null;
                if (!mutable and ty.numeric() and !ty.float()) if (variable.ast.init_node.unwrap()) |init| {
                    if (tree.nodeTag(init) == .number_literal) {
                        constant_int = std.fmt.parseInt(i128, tree.tokenSlice(tree.nodeMainToken(init)), 0) catch null;
                    }
                };
                return .{ .ty = ty, .expr = self.irExpr(.{ .foreign_ref = reference }), .writable = mutable, .constant_int = constant_int };
            }
        }
        const initializer = variable.ast.init_node.unwrap() orelse return self.fail(at, "unsupported Zig declaration '{s}'", .{declaration.name});
        if (try self.foreignTypeDecl(declaration, initializer, reference, at)) |resolved| return typeValue(.{ .foreign = resolved });
        if (tree.fullCall(&buffer, initializer) != null)
            return typeValue(try self.queryZigType(declaration, reference, at));
        var value = try self.zigValueIn(file, declaration.container, initializer, at);
        if (value.type_value) |ty| if (ty == .foreign) {
            // Keep the canonical identity while using an accessible spelling.
            if (!isZigAllocator(ty) and ty.foreign.queried == null and (!self.isPublicZigType(ty.foreign) or !self.isZigRoot(ty.foreign.decl.file)))
                ty.foreign.reference = reference;
        };
        if (value.expr != null) {
            if (mutable and value.zig_constant != null)
                return self.fail(at, "Zig numeric var requires an explicit runtime type", .{});
            const declaration_expr = self.irExpr(.{ .foreign_ref = reference });
            value.expr = if (mutable or value.zig_constant != null) declaration_expr else self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(value.ty), .value = declaration_expr } });
            value.writable = mutable;
            if (mutable) value.constant_int = null;
        }
        if (value.foreign_function != null) value.foreign_function = reference;
        if (value.zig_generic) |generic| {
            var alias = generic.*;
            alias.reference = reference;
            value.zig_generic = self.make(alias);
        }
        return value;
    }

    /// 求出 Zig 哨兵表达式的整数常量，缺失哨兵时返回空值。
    fn zigSentinel(self: *Analyzer, file: *foreign.File, container: ?*ForeignType, node: ?ZigAst.Node.Index, at: usize) Error!?i128 {
        const sentinel = node orelse return null;
        const value = try self.zigValueIn(file, container, sentinel, at);
        return value.constant_int orelse return self.fail(at, "unsupported Zig sentinel expression", .{});
    }

    /// 在 Zig 文件及容器环境中解析类型 AST，递归处理复合类型并按需查询类型工厂。
    fn zigTypeIn(self: *Analyzer, file: *foreign.File, container: ?*ForeignType, node: ZigAst.Node.Index, at: usize) Error!Type {
        const tree = file.tree;
        if (tree.fullArrayType(node)) |array| {
            const length = try self.zigValueIn(file, container, array.ast.elem_count, at);
            const count = std.math.cast(usize, length.constant_int orelse return self.fail(at, "unsupported Zig array length", .{})) orelse
                return self.fail(at, "invalid Zig array length", .{});
            return .{ .array = .{ .length = count, .sentinel = try self.zigSentinel(file, container, array.ast.sentinel.unwrap(), at), .element = self.make(try self.zigTypeIn(file, container, array.ast.elem_type, at)) } };
        }
        if (tree.fullPtrType(node)) |pointer| {
            if (pointer.ast.align_node.unwrap() != null or pointer.ast.bit_range_start.unwrap() != null or
                pointer.ast.addrspace_node.unwrap() != null or pointer.allowzero_token != null or pointer.volatile_token != null)
                return self.fail(at, "unsupported Zig pointer or slice qualifier", .{});
            var fn_buffer: [1]ZigAst.Node.Index = undefined;
            if (tree.fullFnProto(&fn_buffer, pointer.ast.child_type)) |proto| {
                if (pointer.size != .one or pointer.const_token == null)
                    return self.fail(at, "Zig callbacks require a *const fn pointer", .{});
                var params: std.ArrayList(Type) = .empty;
                var iterator = proto.iterate(&tree);
                while (iterator.next()) |param| {
                    const parameter_node = param.type_expr orelse return self.fail(at, "unsupported Zig callback parameter", .{});
                    self.append(&params, try self.zigTypeIn(file, container, parameter_node, at));
                }
                const result = try self.zigTypeIn(file, container, proto.ast.return_type.unwrap() orelse return self.fail(at, "missing callback return type", .{}), at);
                var c_abi = false;
                if (proto.ast.callconv_expr.unwrap()) |expr| {
                    if (tree.nodeTag(expr) != .enum_literal or !same(tree.tokenSlice(tree.nodeMainToken(expr)), "c"))
                        return self.fail(at, "unsupported Zig callback calling convention", .{});
                    c_abi = true;
                }
                return .{ .zig_callback = .{ .signature = self.make(Signature{ .params = params.items, .result = result }), .c_abi = c_abi } };
            }
            const child = try self.zigTypeIn(file, container, pointer.ast.child_type, at);
            const sentinel = try self.zigSentinel(file, container, pointer.ast.sentinel.unwrap(), at);
            if (pointer.size != .slice) return .{ .foreign_pointer = .{ .child = self.make(child), .is_const = pointer.const_token != null, .size = pointer.size, .sentinel = sentinel } };
            if (child.is(.u8) and pointer.const_token != null and sentinel == null) return .{ .primitive = .bytes };
            return .{ .slice = .{ .element = self.make(child), .is_const = pointer.const_token != null, .sentinel = sentinel } };
        }
        if (tree.nodeTag(node) == .optional_type)
            return .{ .optional = self.make(try self.zigTypeIn(file, container, tree.nodeData(node).node, at)) };
        if (tree.nodeTag(node) == .error_union) {
            const errors, const payload = tree.nodeData(node).node_and_node;
            return .{ .error_union = .{
                .errors = self.make(try self.zigTypeIn(file, container, errors, at)),
                .payload = self.make(try self.zigTypeIn(file, container, payload, at)),
            } };
        }
        var call_buffer: [1]ZigAst.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, node)) |call_expr| {
            const factory = try self.zigValueIn(file, container, call_expr.ast.fn_expr, at);
            const generic = factory.zig_generic orelse return self.fail(at, "unsupported Zig type factory expression", .{});
            const args = self.a.alloc(Value, call_expr.ast.params.len) catch @panic("out of memory");
            const operands = self.a.alloc(*const ir.Expr, args.len) catch @panic("out of memory");
            for (call_expr.ast.params, args, operands) |arg, *value, *operand| {
                value.* = try self.zigValueIn(file, container, arg, at);
                if (value.type_value) |argument_ty| {
                    if (argument_ty == .structure or argument_ty == .enumeration or argument_ty == .pointer or argument_ty == .function)
                        return self.fail(at, "unsupported type factory argument", .{});
                    operand.* = self.irExpr(.{ .type_value = self.lowerType(argument_ty) });
                } else if (value.constant_int) |integer| {
                    operand.* = self.irExpr(.{ .number = .{ .ty = value.ty.primitive, .canonical = self.fmt("{d}", .{integer}) } });
                } else return self.fail(at, "Zig factory type expression requires compile-time arguments", .{});
            }
            if (args.len != generic.parameters.len) return self.fail(at, "wrong Zig type factory argument count", .{});
            const expression = self.irExpr(.{ .foreign_call = .{ .target = generic.reference, .args = operands } });
            if (!self.isAccessibleZigDeclaration(generic.declaration))
                return self.fail(at, "Zig type factory is private", .{});
            return self.performQuery(generic.declaration, expression, at);
        }
        const value = try self.zigValueIn(file, container, node, at);
        const ty = value.type_value orelse return self.fail(at, "Zig expression does not denote a supported type", .{});
        if (ty == .structure and ty.structure.zig_file != null) return self.fail(at, "Zig module namespace cannot be used as a runtime type", .{});
        return ty;
    }

    /// 在使用处按期望类型确定 Zig 数值常量的类型，普通值保持不变。
    fn contextualZigConstant(self: *Analyzer, value: Value, expected: ?Type, at: usize) Error!Value {
        if (value.zig_constant == null) return value;
        return self.expect(value, expected orelse value.ty, at);
    }

    /// 识别 Zig 数值文本的类别，选择初始数值类型并保留文本供后续定型。
    fn zigNumber(self: *Analyzer, source: Text) Value {
        const unsigned = if (std.mem.startsWith(u8, source, "-")) source[1..] else source;
        const hex = std.mem.startsWith(u8, unsigned, "0x");
        const floating = if (hex) std.mem.indexOfAny(u8, source, ".pP") != null else std.mem.indexOfAny(u8, source, ".eE") != null;
        const int = if (floating) null else std.fmt.parseInt(i128, source, 0) catch null;
        const ty: Primitive = if (floating) .f64 else if (int != null and std.math.cast(i32, int.?) != null) .i32 else if (int != null) .i128 else .u128;
        return .{
            .ty = .{ .primitive = ty },
            .zig_constant = .{ .source = source, .is_float = floating },
            .constant_int = int,
            .expr = self.irExpr(.{ .number = .{ .ty = ty, .canonical = source } }),
        };
    }

    /// 解析支持的 Zig 值表达式，结合泛型替换、容器声明和导入处理常量及类型引用。
    fn zigValueIn(self: *Analyzer, file: *foreign.File, container: ?*ForeignType, node: ZigAst.Node.Index, at: usize) Error!Value {
        const tree = file.tree;
        const token = tree.nodeMainToken(node);
        const raw = tree.tokenSlice(token);
        switch (tree.nodeTag(node)) {
            .identifier => {
                for (self.zig_substitutions) |substitution| {
                    if (same(substitution.name, raw)) return substitution.value;
                }
                if (primitive(raw)) |p| if (p != .bytes) return typeValue(.{ .primitive = p });
                if (same(raw, "true") or same(raw, "false")) return .{ .ty = bool_type, .expr = self.irExpr(.{ .boolean = same(raw, "true") }) };
                const name = if (std.mem.startsWith(u8, raw, "@\""))
                    std.zig.string_literal.parseAlloc(self.a, raw[1..]) catch return self.fail(at, "invalid Zig identifier", .{})
                else
                    raw;
                if (container) |ty| if (self.foreignMemberDecl(ty, name)) |member| return self.resolveZig(member.decl, at);
                const decl = file.declarations.get(name) orelse return self.fail(at, "unsupported Zig identifier '{s}'", .{name});
                return self.resolveZig(.{ .file = file, .name = name, .node = decl.node }, at);
            },
            .number_literal => return self.zigNumber(raw),
            .char_literal => switch (std.zig.string_literal.parseCharLiteral(raw)) {
                .success => |codepoint| return self.zigNumber(self.fmt("{d}", .{codepoint})),
                .failure => return self.fail(at, "invalid Zig character literal", .{}),
            },
            .negation => {
                const child = tree.nodeData(node).node;
                if (tree.nodeTag(child) == .number_literal) {
                    const number = self.fmt("-{s}", .{tree.tokenSlice(tree.nodeMainToken(child))});
                    return self.zigNumber(number);
                }
            },
            .string_literal => {
                const bytes = std.zig.string_literal.parseAlloc(self.a, raw) catch return self.fail(at, "invalid Zig string", .{});
                return .{ .ty = .{ .primitive = .bytes }, .expr = self.irExpr(.{ .bytes = bytes }) };
            },
            .grouped_expression => return self.zigValueIn(file, container, tree.nodeData(node).node_and_token[0], at),
            .add, .sub, .mul => {
                const left_node, const right_node = tree.nodeData(node).node_and_node;
                const left = (try self.zigValueIn(file, container, left_node, at)).constant_int orelse
                    return self.fail(at, "unsupported Zig compile-time arithmetic", .{});
                const right = (try self.zigValueIn(file, container, right_node, at)).constant_int orelse
                    return self.fail(at, "unsupported Zig compile-time arithmetic", .{});
                const result = switch (tree.nodeTag(node)) {
                    .add => std.math.add(i128, left, right),
                    .sub => std.math.sub(i128, left, right),
                    .mul => std.math.mul(i128, left, right),
                    else => unreachable,
                } catch return self.fail(at, "Zig compile-time integer is outside the supported range", .{});
                return self.zigNumber(self.fmt("{d}", .{result}));
            },
            .field_access => {
                const base_node, const name_token = tree.nodeData(node).node_and_token;
                const base = try self.zigValueIn(file, container, base_node, at);
                if (base.type_value) |ty| if (ty == .foreign) {
                    return (try self.getForeignMember(base, self.zigIdentifier(tree.tokenSlice(name_token)), at)) orelse
                        return self.fail(at, "unsupported Zig container member", .{});
                };
                if (base.type_value) |ty| if (ty == .structure) {
                    const target = ty.structure.zig_file orelse return self.fail(at, "unsupported Zig field access", .{});
                    const raw_name = tree.tokenSlice(name_token);
                    const name = if (std.mem.startsWith(u8, raw_name, "@\""))
                        std.zig.string_literal.parseAlloc(self.a, raw_name[1..]) catch return self.fail(at, "invalid Zig identifier", .{})
                    else
                        raw_name;
                    const decl = target.declarations.get(name) orelse return self.fail(at, "unknown Zig member '{s}'", .{name});
                    if (target.system and same(name, "Allocator") and same(std.fs.path.basename(target.path), "mem.zig")) {
                        for (self.foreign_types.items) |known| {
                            if (known.decl.file == target and known.node == decl.node) return typeValue(.{ .foreign = known });
                        }
                        const store = self.zig_store.?;
                        const root = store.resolveImport(file.path, "zig:std") catch return self.fail(at, "failed to load Zig standard library", .{});
                        const reference: ir.ForeignRef = .{
                            .module = root.id,
                            .name = "Allocator",
                            .parent = self.make(ir.ForeignRef{ .module = root.id, .name = "mem" }),
                        };
                        const allocator = self.make(ForeignType{
                            .decl = .{ .file = target, .name = name, .node = decl.node },
                            .node = decl.node,
                            .reference = reference,
                            .kind = .structure,
                        });
                        self.append(&self.foreign_types, allocator);
                        return typeValue(.{ .foreign = allocator });
                    }
                    if (target != file and !decl.public) return self.fail(at, "inaccessible Zig member '{s}'", .{name});
                    return self.resolveZig(.{ .file = target, .name = name, .node = decl.node }, at);
                };
            },
            .array_type, .array_type_sentinel, .ptr_type_aligned, .ptr_type_sentinel, .ptr_type, .ptr_type_bit_range, .optional_type, .error_union => return typeValue(try self.zigTypeIn(file, container, node, at)),
            else => {
                if (same(raw, "@TypeOf")) {
                    var buffer: [2]ZigAst.Node.Index = undefined;
                    const args = tree.builtinCallParams(&buffer, node) orelse unreachable;
                    if (args.len == 1) {
                        const subject = try self.zigValueIn(file, container, args[0], at);
                        return typeValue(subject.ty);
                    }
                }
                if (same(raw, "@This") and container != null) return typeValue(.{ .foreign = container.? });
                if (same(raw, "@import")) {
                    var buffer: [2]std.zig.Ast.Node.Index = undefined;
                    const args = tree.builtinCallParams(&buffer, node) orelse unreachable;
                    if (args.len == 1 and tree.nodeTag(args[0]) == .string_literal) {
                        const path = std.zig.string_literal.parseAlloc(self.a, tree.tokenSlice(tree.nodeMainToken(args[0]))) catch
                            return self.fail(at, "invalid Zig import path", .{});
                        const imported = self.zig_store.?.importedFile(file, path) catch |err|
                            return self.fail(at, "cannot resolve Zig import '{s}': {s}", .{ path, @errorName(err) });
                        return typeValue(.{ .structure = self.zigShape(imported) });
                    }
                }
            },
        }
        return self.fail(at, "unsupported Zig expression '{s}' in {s}", .{ raw, std.fs.path.basename(file.path) });
    }

    /// 为外部实例类型缓存代理 Shape，使嵌入的 Zig 字段和方法进入统一成员查找。
    fn foreignStorageShape(self: *Analyzer, ty: *ForeignType) *Shape {
        if (self.foreign_storage_shapes.get(ty)) |shape| return shape;
        const shape = self.make(Shape{ .id = self.id(), .foreign_instance = ty });
        self.foreign_storage_shapes.put(self.a, ty, shape) catch @panic("out of memory");
        return shape;
    }

    /// 遍历 Zig 容器字段，只有非元组字段全部带默认值时才允许默认构造。
    fn foreignHasDefaults(_: *Analyzer, ty: *ForeignType) bool {
        const tree = ty.decl.file.tree;
        var buffer: [2]ZigAst.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, ty.node) orelse return false;
        for (container.ast.members) |node| {
            const field = tree.fullContainerField(node) orelse continue;
            if (field.ast.tuple_like or field.ast.value_expr.unwrap() == null) return false;
        }
        return true;
    }

    /// 为目标字段生成空字段初始化，由 Zig 使用该外部类型的默认字段值。
    fn initializeForeignDefault(self: *Analyzer, target: *const ir.Expr, name: Text, ty: *ForeignType, body: *Body) void {
        self.append(body, ir.Stmt{ .assign = .{
            .target = self.access(target, &.{name}),
            .value = self.irExpr(.{ .foreign_object = .{ .ty = self.lowerType(.{ .foreign = ty }), .fields = &.{} } }),
            .initialize = true,
        } });
    }

    /// 识别 Zig 容器和错误集合声明，按文件与 AST 节点复用外部类型身份。
    fn foreignTypeDecl(self: *Analyzer, declaration: ForeignDeclaration, node: ZigAst.Node.Index, reference: ir.ForeignRef, at: usize) Error!?*ForeignType {
        const tree = declaration.file.tree;
        const kind: @FieldType(ForeignType, "kind") = if (tree.nodeTag(node) == .error_set_decl) .error_set else blk: {
            var buffer: [2]ZigAst.Node.Index = undefined;
            const container = tree.fullContainerDecl(&buffer, node) orelse return null;
            break :blk switch (tree.tokenTag(container.ast.main_token)) {
                .keyword_struct => .structure,
                .keyword_enum => .enumeration,
                .keyword_union => .union_type,
                .keyword_opaque => .opaque_type,
                else => return self.fail(at, "unsupported Zig container type", .{}),
            };
        };
        for (self.foreign_types.items) |ty| {
            if (ty.decl.file == declaration.file and ty.node == node) return ty;
        }
        const ty = self.make(ForeignType{ .decl = declaration, .node = node, .reference = reference, .kind = kind });
        self.append(&self.foreign_types, ty);
        return ty;
    }

    /// 判断 Zig 文件是否可作为导入根引用，对配置模块和系统模块核对规范路径。
    fn isZigRoot(self: *Analyzer, file: *foreign.File) bool {
        if (file.embedded or file.config.len == 0) return true;
        const store = self.zig_store orelse return false;
        const path = if (file.system)
            std.fs.path.join(self.a, &.{ store.std_root orelse return false, "std.zig" }) catch @panic("out of memory")
        else
            (store.named.get(file.config) orelse return false).root;
        const root = std.Io.Dir.cwd().realPathFileAlloc(store.io, path, self.a) catch return false;
        return same(root, file.path);
    }

    /// 检查声明是否能从模块根公开访问，同时核对其外层容器的公开性。
    fn isAccessibleZigDeclaration(self: *Analyzer, declaration: ForeignDeclaration) bool {
        if (!self.isZigRoot(declaration.file)) return false;
        if (declaration.container) |owner| {
            if (!self.isPublicZigType(owner)) return false;
            return if (self.foreignMemberDecl(owner, declaration.name)) |member| member.public else false;
        }
        return if (declaration.file.declarations.get(declaration.name)) |decl| decl.public else false;
    }

    /// 沿外层容器递归检查 Zig 类型声明的公开性，防止生成不可访问的类型名称。
    fn isPublicZigType(self: *Analyzer, ty: *ForeignType) bool {
        if (ty.decl.container) |owner| {
            if (self.foreignMemberDecl(owner, ty.decl.name)) |member| return member.public and self.isPublicZigType(owner);
            return false;
        }
        return if (ty.decl.file.declarations.get(ty.decl.name)) |decl| decl.public else false;
    }

    /// 扫描 Zig 容器的函数和变量声明，返回成员公开性及带父路径的外部引用。
    fn foreignMemberDecl(self: *Analyzer, ty: *ForeignType, name: Text) ?struct { decl: ForeignDeclaration, public: bool } {
        const tree = ty.decl.file.tree;
        var nodes: [2]ZigAst.Node.Index = undefined;
        const container = tree.fullContainerDecl(&nodes, ty.node) orelse return null;
        for (container.ast.members) |node| {
            var proto_buffer: [1]ZigAst.Node.Index = undefined;
            const token, const public = if (tree.fullFnProto(&proto_buffer, node)) |proto|
                .{ proto.name_token orelse continue, proto.visib_token != null }
            else if (tree.fullVarDecl(node)) |variable|
                .{ variable.ast.mut_token + 1, variable.visib_token != null }
            else
                continue;
            if (!same(self.zigIdentifier(tree.tokenSlice(token)), name)) continue;
            return .{
                .decl = .{
                    .file = ty.decl.file,
                    .name = name,
                    .node = node,
                    .container = ty,
                    .reference = .{ .module = ty.reference.module, .name = name, .parent = self.make(ty.reference) },
                },
                .public = public,
            };
        }
        return null;
    }

    /// 解码 Zig 的带引号标识符，普通名称直接返回原文本。
    fn zigIdentifier(self: *Analyzer, raw: Text) Text {
        if (!std.mem.startsWith(u8, raw, "@\"")) return raw;
        return std.zig.string_literal.parseAlloc(self.a, raw[1..]) catch raw;
    }

    /// 遍历 Zig 容器字段并匹配名称，对枚举和联合字段统一为具名字段形式。
    fn foreignField(self: *Analyzer, ty: *ForeignType, name: Text) ?ZigAst.full.ContainerField {
        const tree = ty.decl.file.tree;
        var nodes: [2]ZigAst.Node.Index = undefined;
        const container = tree.fullContainerDecl(&nodes, ty.node) orelse return null;
        for (container.ast.members) |node| {
            var field = tree.fullContainerField(node) orelse continue;
            if (ty.kind == .enumeration or ty.kind == .union_type) field.convertToNonTupleLike(&tree);
            if (!field.ast.tuple_like and same(self.zigIdentifier(tree.tokenSlice(field.ast.main_token)), name)) return field;
        }
        return null;
    }

    /// 检查 Zig 结构体或联合的字段初始化，按声明类型分析实参并验证必填字段。
    fn initForeignObject(self: *Analyzer, scope: *Scope, node: *Expr, ty: *ForeignType, owner: ?*Shape) Error!Value {
        if (ty.queried != null) return self.initQueriedObject(scope, node, ty, owner);
        if (ty.kind != .structure and ty.kind != .union_type) return self.fail(node.at, "Zig type '{s}' cannot be constructed with fields", .{ty.reference.name});
        const obj = node.data.object;
        if (ty.kind == .union_type and obj.fields.len != 1) return self.fail(node.at, "Zig union initialization requires one field", .{});
        const tree = ty.decl.file.tree;
        var nodes: [2]ZigAst.Node.Index = undefined;
        const container = tree.fullContainerDecl(&nodes, ty.node).?;
        var fields: std.ArrayList(ir.Initializer) = .empty;
        for (obj.fields, 0..) |field, index| {
            const name = field.name.text;
            for (obj.fields[0..index]) |prior| if (same(prior.name.text, name))
                return self.fail(field.name.at, "duplicate initializer for '{s}'", .{name});
            const ast = self.foreignField(ty, name) orelse return self.fail(field.name.at, "unknown Zig field '{s}'", .{name});
            if (ast.comptime_token != null) return self.fail(field.name.at, "unsupported comptime Zig field initializer", .{});
            const type_node = ast.ast.type_expr.unwrap() orelse return self.fail(field.name.at, "missing Zig field type", .{});
            const field_ty = try self.zigTypeIn(ty.decl.file, ty, type_node, field.name.at);
            const value = try self.expect(try self.eval(scope, field.value, field_ty, owner), field_ty, field.value.at);
            self.append(&fields, ir.Initializer{ .name = name, .value = try self.runtimeExpr(value, field.value.at) });
        }
        if (ty.kind == .structure) for (container.ast.members) |member| {
            const field = tree.fullContainerField(member) orelse continue;
            if (field.ast.tuple_like) return self.fail(node.at, "unsupported Zig tuple initializer", .{});
            const name = self.zigIdentifier(tree.tokenSlice(field.ast.main_token));
            if (field.ast.value_expr.unwrap() == null) {
                for (fields.items) |written| {
                    if (same(written.name, name)) break;
                } else return self.fail(node.at, "missing initializer for Zig field '{s}'", .{name});
            }
        };
        const value_ty: Type = .{ .foreign = ty };
        return .{ .ty = value_ty, .expr = self.irExpr(.{ .foreign_object = .{ .ty = self.lowerType(value_ty), .fields = fields.items } }) };
    }

    /// 保存反射查询得到的字段名称、类型索引及初始化属性，替代直接 AST 字段信息。
    const QueriedField = struct { name: Text, index: usize, has_default: bool, comptime_field: bool };

    /// 从类型查询元数据的结构体记录中解码字段列表和默认值、comptime 属性。
    fn queriedFields(self: *Analyzer, ty: *ForeignType, at: usize) Error![]const QueriedField {
        var records = std.mem.splitScalar(u8, ty.queried.?.metadata, '\n');
        var fields = std.mem.tokenizeScalar(u8, records.next() orelse "", ' ');
        if (!same(fields.next() orelse "", "struct")) return self.fail(at, "queried type is not a Zig structure", .{});
        _ = fields.next();
        var result: std.ArrayList(QueriedField) = .empty;
        while (fields.next()) |name| {
            const index = std.fmt.parseInt(usize, fields.next() orelse "", 10) catch return self.fail(at, "invalid queried Zig field index", .{});
            const attrs = fields.next() orelse return self.fail(at, "missing queried Zig field attributes", .{});
            self.append(&result, QueriedField{
                .name = name,
                .index = index,
                .has_default = same(attrs, "default") or same(attrs, "comptime"),
                .comptime_field = same(attrs, "comptime"),
            });
        }
        return result.items;
    }

    /// 按查询字段索引恢复语义类型，并构造字段类型表达式以便生成 Zig 引用。
    fn queriedFieldType(self: *Analyzer, ty: *ForeignType, field: QueriedField, at: usize) Error!Type {
        if (field.index == 0) return .{ .foreign = ty };
        const query = ty.queried.?;
        const expression = self.irExpr(.{ .field_type = .{ .ref_type = query.expression, .name = field.name } });
        return self.queriedType(query.metadata, field.index, 0, ty.decl, expression, query.key, at);
    }

    /// 依据反射元数据检查查询类型的对象初始化，拒绝写入 comptime 字段并检查缺项。
    fn initQueriedObject(self: *Analyzer, scope: *Scope, node: *Expr, ty: *ForeignType, owner: ?*Shape) Error!Value {
        const obj = node.data.object;
        const known = try self.queriedFields(ty, node.at);
        var fields: std.ArrayList(ir.Initializer) = .empty;
        for (obj.fields, 0..) |field, index| {
            for (obj.fields[0..index]) |previous| if (same(previous.name.text, field.name.text))
                return self.fail(field.name.at, "duplicate initializer for '{s}'", .{field.name.text});
            const found = for (known) |candidate| {
                if (same(candidate.name, field.name.text)) break candidate;
            } else return self.fail(field.name.at, "unknown queried Zig field '{s}'", .{field.name.text});
            if (found.comptime_field) return self.fail(field.name.at, "cannot assign queried Zig comptime field", .{});
            const field_ty = try self.queriedFieldType(ty, found, field.name.at);
            const value = try self.expect(try self.eval(scope, field.value, field_ty, owner), field_ty, field.value.at);
            self.append(&fields, ir.Initializer{ .name = found.name, .value = try self.runtimeExpr(value, field.value.at) });
        }
        for (known) |required| {
            if (required.has_default) continue;
            for (fields.items) |written| {
                if (same(required.name, written.name)) break;
            } else return self.fail(node.at, "missing initializer for Zig field '{s}'", .{required.name});
        }
        const ty_value: Type = .{ .foreign = ty };
        return .{ .ty = ty_value, .expr = self.irExpr(.{ .foreign_object = .{ .fields = fields.items, .ty = self.lowerType(ty_value) } }) };
    }

    /// 解析外部类型或实例的字段、变体和公开声明，不属于外部对象时返回空值。
    fn getForeignMember(self: *Analyzer, base: Value, name: Text, at: usize) Error!?Value {
        const candidate = base.type_value orelse if (base.ty == .foreign_pointer) base.ty.foreign_pointer.child.* else base.ty;
        if (candidate != .foreign or (base.ty == .foreign_pointer and base.ty.foreign_pointer.size != .one)) return null;
        const ty = candidate.foreign;
        if (ty.queried != null) {
            if (base.type_value == null and ty.kind == .structure) {
                const fields = try self.queriedFields(ty, at);
                for (fields) |field| {
                    if (!same(field.name, name)) continue;
                    const field_ty = try self.queriedFieldType(ty, field, at);
                    return .{
                        .ty = field_ty,
                        .expr = self.irExpr(.{ .foreign_field = .{ .base = try self.runtimeExpr(base, at), .name = name } }),
                        .writable = !field.comptime_field and (if (base.ty == .foreign_pointer) !base.ty.foreign_pointer.is_const else base.writable),
                    };
                }
            }
            return self.fail(at, "unsupported queried Zig member '{s}'; use an explicit Zig facade", .{name});
        }
        const tree = ty.decl.file.tree;
        if (base.type_value != null and ty.kind == .enumeration and self.foreignField(ty, name) != null)
            return .{ .ty = candidate, .expr = self.irExpr(.{ .foreign_variant = .{ .ty = self.lowerType(candidate), .name = name, .payload = null } }) };
        if (base.type_value != null and ty.kind == .error_set and ty.queried == null) {
            const end = tree.nodeData(ty.node).token_and_token[1];
            var token = tree.nodeMainToken(ty.node) + 1;
            while (token < end) : (token += 1) {
                if (tree.tokenTag(token) == .identifier and same(self.zigIdentifier(tree.tokenSlice(token)), name))
                    return .{ .ty = candidate, .expr = self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(candidate), .value = self.irExpr(.{ .error_value = name }) } }) };
            }
        }
        if (base.type_value == null and (ty.kind == .structure or ty.kind == .union_type)) {
            if (self.foreignField(ty, name)) |field| {
                const field_ty = if (field.ast.type_expr.unwrap()) |type_node| try self.zigTypeIn(ty.decl.file, ty, type_node, at) else void_type;
                return .{
                    .ty = field_ty,
                    .expr = self.irExpr(.{ .foreign_field = .{ .base = try self.runtimeExpr(base, at), .name = name } }),
                    .writable = !base.pointer_readonly and (if (base.ty == .foreign_pointer) !base.ty.foreign_pointer.is_const else base.writable),
                    .pointer_readonly = base.pointer_readonly,
                };
            }
        }
        if (self.foreignMemberDecl(ty, name)) |member| {
            if (!member.public) return self.fail(at, "inaccessible Zig member '{s}'", .{name});
            return try self.resolveZig(member.decl, at);
        }
        return self.fail(at, "unknown Zig member '{s}' on {s}", .{ name, ty.reference.name });
    }

    /// 取得值的运行时表达式，再按 IR 形式判断是否可寻址。
    fn isForeignLvalue(self: *Analyzer, value: Value, at: usize) Error!bool {
        const expression = try self.runtimeExpr(value, at);
        return isLvalueExpression(expression);
    }

    /// 识别变量、解引用及由可寻址基对象派生的字段和下标表达式。
    fn isLvalueExpression(expression: *const ir.Expr) bool {
        return switch (expression.*) {
            .variable, .module_object, .module_cast, .foreign_ref, .dereference => true,
            .field => |field| isLvalueExpression(field.base),
            .foreign_field => |field| isLvalueExpression(field.base),
            .index => |index| isLvalueExpression(index.base),
            else => false,
        };
    }

    /// 按 Zig 接收者类型自动取址或解引用，同时检查可寻址性与可写权限。
    fn foreignReceiver(self: *Analyzer, value: Value, ty: Type, at: usize) Error!Value {
        if (value.pointer_readonly and ty == .foreign_pointer and !ty.foreign_pointer.is_const)
            return self.fail(at, "read-only Ptr cannot be converted to a mutable pointer", .{});
        if (ty == .foreign_pointer and ty.foreign_pointer.size == .one and value.ty.equal(ty.foreign_pointer.child.*)) {
            if ((!value.writable and !ty.foreign_pointer.is_const) or !try self.isForeignLvalue(value, at))
                return self.fail(at, "Zig pointer receiver requires a compatible lvalue", .{});
            return .{ .ty = ty, .expr = self.irExpr(.{ .address = try self.runtimeExpr(value, at) }) };
        }
        if (value.ty == .foreign_pointer and value.ty.foreign_pointer.size == .one and value.ty.foreign_pointer.child.equal(ty))
            return .{ .ty = ty, .expr = self.irExpr(.{ .dereference = try self.runtimeExpr(value, at) }) };
        return self.expect(value, ty, at);
    }

    /// 将成员查找结果转换为值，构造字段访问或重绑静态值的声明上下文。
    fn memberValue(self: *Analyzer, base: Value, found: Found, name: Text, at: usize) Error!Value {
        return switch (found.member.data) {
            .field => |field| blk: {
                var value: Value = if (base.ty.is(.type))
                    typeValue(field.ty)
                else
                    .{
                        .ty = field.ty,
                        .expr = if (found.foreign_field)
                            self.irExpr(.{ .foreign_field = .{ .base = self.access(self.objectExpr(base), found.path), .name = name } })
                        else
                            self.access(self.access(self.objectExpr(base), found.path), &.{name}),
                        .writable = !base.pointer_readonly and field.file_mutable and (base.writable or base.ty == .pointer),
                        .pointer_readonly = base.pointer_readonly,
                    };
                if (field.ty == .structure or field.ty == .pointer) {
                    const origin = try self.memberOrigin(base, at);
                    const path = std.mem.concat(self.a, Text, &.{ origin.path, found.path, &.{name} }) catch @panic("out of memory");
                    value.origin = .{ .shape = origin.shape, .path = path };
                }
                break :blk value;
            },
            .value => |v| blk: {
                if (v.foreign_declaration) |declaration| break :blk try self.resolveZig(declaration, at);
                if (v.type_value) |ty| if (ty == .structure and ty.structure.zig_file != null) break :blk v;
                var value = v;
                const context = self.memberContext(base, found.path);
                if (value.expr) |expression| value.expr = self.rebindContext(expression, context, null);
                if (value.function != null or value.type_value != null) value.context = if (v.context) |stored| self.rebindContext(stored, context, null) else context;
                break :blk value;
            },
            .method, .operator => |f| if (base.ty.is(.type))
                .{ .ty = .{ .function = f.sig }, .function = f, .context = self.methodContext(f.owner orelse found.declaring, name, base.context) }
            else
                return self.fail(at, "instance method must be called with a receiver", .{}),
        };
    }

    /// 从结构体值、结构体指针或结构体类型值提取 Shape，其他类型报告错误。
    fn baseShape(self: *Analyzer, base: Value, at: usize) Error!*Shape {
        if (base.ty == .structure) return base.ty.structure;
        if (base.ty == .pointer) return base.ty.pointer;
        if (base.type_value) |t| if (t == .structure) return t.structure;
        return self.fail(at, "member access requires a structure", .{});
    }

    /// 查找成员并沿原始对象路径复核可见性，防止通过视图绕过重声明限制。
    fn resolveMember(self: *Analyzer, base: Value, name: Text, owner: ?*Shape, at: usize) Error!Found {
        const s = try self.baseShape(base, at);
        const found = (try self.lookup(s, name, at)) orelse return self.fail(at, "unknown member '{s}' in S{d}", .{ name, s.id });
        if (!allowed(found, owner, s)) return self.fail(at, "inaccessible member '{s}'", .{name});
        if (found.member.data == .value and found.member.data.value.foreign_declaration != null) return found;
        const origin = try self.memberOrigin(base, at);
        const path = std.mem.concat(self.a, Text, &.{ origin.path, found.path, &.{name} }) catch @panic("out of memory");
        var shape = origin.shape;
        for (0..path.len) |depth| {
            for (shape.redeclarations) |r| {
                if (!same(r.name, name) or r.path.len != path.len - depth - 1) continue;
                var matches = true;
                for (r.path, path[depth .. path.len - 1]) |a, b| {
                    if (!same(a, b)) {
                        matches = false;
                        break;
                    }
                }
                if (matches and !allowed(.{ .member = found.member, .path = r.path, .visibility = r.visibility, .declaring = shape }, owner, shape))
                    return self.fail(at, "inaccessible member '{s}'", .{name});
            }
            if (depth + 1 < path.len) {
                const member = direct(shape, path[depth]) orelse return self.fail(at, "invalid member path '{s}'", .{path[depth]});
                if (member.data != .field) return self.fail(at, "invalid member path '{s}'", .{path[depth]});
                const ty = member.data.field.ty;
                shape = switch (ty) {
                    .pointer => ty.pointer,
                    .structure => ty.structure,
                    .foreign => self.foreignStorageShape(ty.foreign),
                    else => return self.fail(at, "invalid member path '{s}'", .{path[depth]}),
                };
            }
        }
        return found;
    }

    /// 返回结构体实际存储表达式，结构体指针先解引用。
    fn storageExpr(self: *Analyzer, base: Value) *const ir.Expr {
        return if (base.ty == .pointer) self.irExpr(.{ .dereference = base.expr.? }) else base.expr.?;
    }

    /// 在原始存储上应用静态多态视图路径，取得当前可见的子对象表达式。
    fn objectExpr(self: *Analyzer, base: Value) *const ir.Expr {
        const storage = self.storageExpr(base);
        return if (base.view) |view| self.access(storage, view.path) else storage;
    }

    /// 识别数字字面量及其负号形式，用于优先从另一操作数推导数值类型。
    fn isNumericLiteral(node: *Expr) bool {
        return node.data == .number or (node.data == .unary and
            node.data.unary.op == .minus and node.data.unary.operand.data == .number);
    }

    /// 将重载成员名称映射为运算符类别，统一检查元数、返回类型及词法运算符。
    const Operator = enum {
        OperatorAdd,
        OperatorSub,
        OperatorMul,
        OperatorDiv,
        OperatorRem,
        OperatorBitAnd,
        OperatorBitOr,
        OperatorBitXor,
        OperatorShl,
        OperatorShr,
        OperatorEq,
        OperatorNe,
        OperatorLt,
        OperatorLe,
        OperatorGt,
        OperatorGe,
        OperatorPos,
        OperatorNeg,
        OperatorBitNot,
        OperatorNot,

        /// 按运算符枚举判断是否只接受一个操作数。
        fn unary(op: Operator) bool {
            return switch (op) {
                .OperatorPos, .OperatorNeg, .OperatorBitNot, .OperatorNot => true,
                else => false,
            };
        }

        /// 区分比较和逻辑非等布尔结果运算符，以确定重载返回类型。
        fn returnsBool(op: Operator) bool {
            return switch (op) {
                .OperatorEq, .OperatorNe, .OperatorLt, .OperatorLe, .OperatorGt, .OperatorGe, .OperatorNot => true,
                else => false,
            };
        }

        /// 将解析器的二元运算符标签映射到对应的重载成员名称。
        fn binaryTag(tag: syn.Tag) Operator {
            return switch (tag) {
                .plus => .OperatorAdd,
                .minus => .OperatorSub,
                .star => .OperatorMul,
                .slash => .OperatorDiv,
                .percent => .OperatorRem,
                .amp => .OperatorBitAnd,
                .pipe => .OperatorBitOr,
                .caret => .OperatorBitXor,
                .shift_left => .OperatorShl,
                .shift_right => .OperatorShr,
                .equal_equal => .OperatorEq,
                .not_equal => .OperatorNe,
                .less => .OperatorLt,
                .less_equal => .OperatorLe,
                .greater => .OperatorGt,
                .greater_equal => .OperatorGe,
                else => unreachable,
            };
        }
    };

    /// 检查运算符函数的参数个数、Self 参数和结果类型，并登记所属结构体。
    fn checkOperator(self: *Analyzer, operator: Operator, function_value: *Function, shape: *Shape, at: usize) Error!void {
        const signature_type = function_value.sig;
        const operand: Type = .{ .structure = shape };
        const result = if (operator.returnsBool()) bool_type else operand;
        const arity: usize = if (operator.unary()) 1 else 2;
        if (signature_type.params.len == arity and signature_type.context_parameter == null and
            signature_type.result_manager == null and signature_type.result.equal(result))
        {
            for (signature_type.params) |parameter| {
                if (!parameter.equal(operand)) break;
            } else {
                function_value.owner = shape;
                return;
            }
        }
        return self.fail(at, "{s} must have signature fn({s}) -> {s}", .{
            @tagName(operator),                             if (operator.unary()) "Self" else "Self, Self",
            if (operator.returnsBool()) "bool" else "Self",
        });
    }

    /// 查找可访问的运算符实现，暂存左操作数以避免重复求值，再生成托管安全的调用。
    fn callOperator(self: *Analyzer, operator: Operator, left: Value, right: ?Value, owner: ?*Shape, at: usize) Error!Value {
        const name = @tagName(operator);
        const shape = left.ty.structure;
        const member = direct(shape, name) orelse return self.fail(at, "structure has no {s}", .{name});
        const found = (try self.lookup(shape, name, at)).?;
        if (!allowed(found, owner, shape)) return self.fail(at, "inaccessible member '{s}'", .{name});
        if (member.data != .operator) return self.fail(at, "{s} must be a function assigned to the type", .{name});
        const implementation = member.data.operator;
        var setup: Body = .empty;
        const name_temp = self.localName("__saphine_operator_operand");
        self.append(&setup, self.localValue(
            .{ .name = name_temp, .ty = self.lowerType(left.ty) },
            try self.ownedExpr(left, at),
            true,
            left.ty,
        ));
        var staged = left;
        staged.expr = self.irExpr(.{ .variable = name_temp });
        const arguments = [2]Value{ staged, right orelse staged };
        const result = try self.invokeManaged(.{
            .ty = .{ .function = implementation.sig },
            .function = implementation,
            .context = self.methodContext(shape, name, self.memberContext(staged, &.{})),
        }, arguments[0..if (right != null) 2 else 1], at);
        return self.wrapManagedScope(setup, result);
    }

    /// 对结构体调用重载，对基础类型检查一元运算规则并保留可计算的整数结果。
    fn unaryOperator(self: *Analyzer, value: Value, tag: syn.Tag, owner: ?*Shape, at: usize) Error!Value {
        const operator: Operator = switch (tag) {
            .plus => .OperatorPos,
            .minus => .OperatorNeg,
            .tilde => .OperatorBitNot,
            .kw_not => .OperatorNot,
            else => unreachable,
        };
        if (value.ty == .structure) return self.callOperator(operator, value, null, owner, at);
        switch (operator) {
            .OperatorPos => {
                if (!value.ty.numeric()) return self.fail(at, "unary plus requires a number", .{});
                return value;
            },
            .OperatorNeg => {
                if (!value.ty.numeric() or @tagName(value.ty.primitive)[0] == 'u')
                    return self.fail(at, "negation requires a signed number", .{});
                return .{ .ty = value.ty, .constant_int = if (value.constant_int) |n| checkedInt(value.ty, std.math.negate(n) catch null) else null, .expr = self.irExpr(.{ .negate = value.expr.? }) };
            },
            .OperatorNot => {
                const operand = try self.expect(value, bool_type, at);
                return .{ .ty = bool_type, .expr = self.irExpr(.{ .logical_not = operand.expr.? }) };
            },
            .OperatorBitNot => {
                if (!value.ty.numeric() or value.ty.float()) return self.fail(at, "bitwise complement requires an integer", .{});
                return .{
                    .ty = value.ty,
                    .constant_int = if (value.constant_int) |n| foldIntegerBits(value.ty, n, 0, .complement) else null,
                    .expr = self.irExpr(.{ .bit_not = value.expr.? }),
                };
            },
            else => unreachable,
        }
    }

    /// 将比较 Token 映射为 IR 谓词，非比较运算符返回空值。
    fn comparison(op: syn.Tag) ?ir.Predicate {
        return switch (op) {
            .equal_equal => .eq,
            .not_equal => .ne,
            .less => .lt,
            .less_equal => .le,
            .greater => .gt,
            .greater_equal => .ge,
            else => null,
        };
    }

    /// 将两个 IR 操作数组合为布尔类型的谓词表达式。
    fn predicate(self: *Analyzer, op: ir.Predicate, left: *const ir.Expr, right: *const ir.Expr) Value {
        return .{ .ty = bool_type, .expr = self.irExpr(.{ .predicate = .{ .op = op, .left = left, .right = right } }) };
    }

    /// 以 bool 为期望类型分析条件并再次核对类型，返回条件 IR。
    fn condition(self: *Analyzer, scope: *Scope, node: *Expr, owner: ?*Shape) Error!*const ir.Expr {
        const value = try self.expect(try self.eval(scope, node, bool_type, owner), bool_type, node.at);
        return value.expr.?;
    }

    /// 汇总分支 IR、结果类型和是否返回，供 if 与 match 合并控制流结果。
    const CheckedBranch = struct { lowered: ir.Branch, ty: ?Type, returns: bool };

    /// 在子作用域中分析分支语句和尾值，检查不可达结果及不可逃逸的视图。
    fn checkBranch(self: *Analyzer, scope: *Scope, branch: syn.Branch, expected: ?Type, owner: ?*Shape, depth: usize) Error!CheckedBranch {
        var child: Scope = .{ .parent = scope, .instance = scope.instance, .runtime_branch = true, .in_loop = scope.in_loop };
        var body: Body = .empty;
        const returns = try self.block(&child, branch.body, &body, scope.instance, depth + 1);
        if (branch.tail) |tail| {
            if (returns) return self.fail(tail.at, "unreachable branch value after return", .{});
            const value = try self.eval(&child, tail, expected, owner);
            if (value.view != null) return self.fail(tail.at, "branch cannot yield a polymorphic view", .{});
            if (value.pointer_readonly and (value.ty == .pointer or value.ty == .foreign_pointer or value.ty == .managed or value.ty == .slice or value.ty == .structure or value.ty == .array))
                return self.fail(tail.at, "read-only Ptr cannot escape as a writable value", .{});
            return .{
                .lowered = .{ .body = body.items, .value = try self.ownedExpr(value, tail.at), .label = self.id() },
                .ty = value.ty,
                .returns = false,
            };
        }
        return .{ .lowered = .{ .body = body.items }, .ty = if (returns) null else void_type, .returns = returns };
    }

    /// 检查 if 两分支结果类型一致，为需要 GC 跟踪的结果生成跨分支保活操作。
    fn conditionalValue(self: *Analyzer, scope: *Scope, cond: syn.If, expected: ?Type, owner: ?*Shape, at: usize) Error!Value {
        if (scope.instance) |item| {
            if (item.function.sig.result.is(.type)) return self.fail(at, "runtime if is unavailable in a type-returning function", .{});
        }
        const test_expr = try self.condition(scope, cond.condition, owner);
        const yes = try self.checkBranch(scope, cond.yes, expected, owner, 1);
        const no = if (cond.no) |branch| try self.checkBranch(scope, branch, expected orelse yes.ty, owner, 1) else CheckedBranch{ .lowered = .{ .body = &.{} }, .ty = void_type, .returns = false };
        if (yes.ty != null and no.ty != null and !yes.ty.?.equal(no.ty.?))
            return self.fail(at, "if branches must produce the same type and a value requires else", .{});
        const ty = yes.ty orelse no.ty orelse void_type;
        var lowered: ir.Conditional = .{ .test_expr = test_expr, .yes = yes.lowered, .no = if (cond.no != null) no.lowered else null };
        var setup: Body = .empty;
        if (memoryTraits(ty).trace) {
            const root = self.resultRoot(&setup, ty);
            if (lowered.yes.value) |value| lowered.yes.value = self.preserveResult(root, value);
            if (lowered.no) |*other| if (other.value) |value| {
                other.value = self.preserveResult(root, value);
            };
        }
        return self.wrapManagedScope(setup, .{ .ty = ty, .expr = self.irExpr(.{ .conditional = lowered }) });
    }

    /// 保存匹配 IR、结果及返回状态，并携带主体暂存和结果保活所需的前置语句。
    const CheckedMatch = struct { lowered: ir.Match, ty: ?Type, returns: bool, setup: Body };

    /// 检查枚举、optional 或错误联合匹配的覆盖与载荷，合并分支类型并生成匹配 IR。
    fn matching(self: *Analyzer, scope: *Scope, match: syn.Match, expected: ?Type, owner: ?*Shape, at: usize, depth: usize) Error!CheckedMatch {
        if (scope.instance) |item| if (item.function.sig.result.is(.type)) return self.fail(at, "runtime match is unavailable in a type-returning function", .{});
        var subject = try self.eval(scope, match.subject, null, owner);
        var setup: Body = .empty;
        if (memoryTraits(subject.ty).active()) subject = try self.stageManaged(&setup, subject, match.subject.at);
        const kind: @FieldType(ir.Match, "kind") = switch (subject.ty) {
            .enumeration => .native,
            .optional => .optional,
            .error_union => .error_union,
            .foreign => |ty| if (ty.kind == .enumeration) .foreign_enum else return self.fail(match.subject.at, "match requires an enum value, optional or error union", .{}),
            else => return self.fail(match.subject.at, "match requires an enum value, optional or error union", .{}),
        };
        const variants: []EnumVariant = switch (subject.ty) {
            .enumeration => |shape| shape.variants,
            .optional => |child| self.make([2]EnumVariant{ .{ .name = "Some", .ty = child.* }, .{ .name = "None", .ty = null } }),
            .error_union => |result| self.make([2]EnumVariant{ .{ .name = "Ok", .ty = if (result.payload.is(.void)) null else result.payload.* }, .{ .name = "Err", .ty = result.errors.* } }),
            .foreign => |ty| blk: {
                if (ty.kind != .enumeration) unreachable;
                if (ty.queried != null) return self.fail(at, "match on a queried Zig enum requires an explicit Zig facade", .{});
                const tree = ty.decl.file.tree;
                var buffer: [2]ZigAst.Node.Index = undefined;
                const container = tree.fullContainerDecl(&buffer, ty.node).?;
                var members: std.ArrayList(EnumVariant) = .empty;
                for (container.ast.members) |node| {
                    var field = tree.fullContainerField(node) orelse continue;
                    field.convertToNonTupleLike(&tree);
                    const name = self.zigIdentifier(tree.tokenSlice(field.ast.main_token));
                    self.append(&members, EnumVariant{ .name = name, .ty = null });
                }
                break :blk members.items;
            },
            else => unreachable,
        };
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        var arms: std.ArrayList(ir.MatchArm) = .empty;
        var result_ty: ?Type = null;
        var all_return = true;
        var has_default = false;
        for (match.arms, 0..) |arm, index| {
            var name: ?Text = null;
            var binding: ?Text = null;

            var arm_scope: Scope = .{ .parent = scope, .instance = scope.instance, .runtime_branch = true, .in_loop = scope.in_loop };
            switch (arm.pattern) {
                .default => |token| {
                    if (has_default) return self.fail(token.at, "duplicate default branch", .{});
                    if (index + 1 != match.arms.len) return self.fail(token.at, "default must be the last branch", .{});
                    has_default = true;
                },
                .variant => |pattern| {
                    const variant = for (variants) |variant| {
                        if (same(variant.name, pattern.name.text)) break variant;
                    } else return self.fail(pattern.name.at, "unknown match member '{s}'", .{pattern.name.text});
                    if (seen.contains(variant.name)) return self.fail(pattern.name.at, "duplicate match member '{s}'", .{variant.name});
                    seen.put(self.a, variant.name, {}) catch @panic("out of memory");
                    name = variant.name;
                    if (variant.ty != null and pattern.payload == null) return self.fail(pattern.name.at, "enum member '{s}' requires a payload pattern", .{variant.name});
                    if (variant.ty == null and pattern.payload != null) return self.fail(pattern.name.at, "enum member '{s}' has no payload", .{variant.name});
                    if (pattern.payload) |payload| switch (payload) {
                        .discard => {},
                        .binding => |token| {
                            binding = self.localName(token.text);
                            const value: Value = .{ .ty = variant.ty.?, .expr = self.irExpr(.{ .variable = binding.? }) };
                            arm_scope.bindings.put(self.a, token.text, self.make(Binding{ .value = value, .mutable = false })) catch @panic("out of memory");
                        },
                    };
                },
            }
            const checked = try self.checkBranch(&arm_scope, arm.branch, expected orelse result_ty, owner, depth);
            if (checked.ty) |ty| {
                if (result_ty) |previous| {
                    if (!ty.equal(previous)) return self.fail(at, "match branches must produce the same type", .{});
                } else result_ty = ty;
            }
            all_return = all_return and checked.returns;
            // Zig rejects a redundant else when all variants were named.
            if (kind == .optional or kind == .error_union) {
                if (name != null) {
                    self.append(&arms, ir.MatchArm{ .name = name, .binding = binding, .branch = checked.lowered });
                } else for (variants) |variant| {
                    if (!seen.contains(variant.name)) self.append(&arms, ir.MatchArm{ .name = variant.name, .binding = null, .branch = checked.lowered });
                }
            } else if (name != null or seen.count() != variants.len) self.append(&arms, ir.MatchArm{ .name = name, .binding = binding, .branch = checked.lowered });
        }
        if (!has_default) for (variants) |variant| {
            if (!seen.contains(variant.name)) return self.fail(at, "match is missing enum member '{s}'", .{variant.name});
        };
        if (result_ty) |ty| {
            if (memoryTraits(ty).trace) {
                // This frame precedes the subject's frame and lives across branch cleanup.
                var outer: Body = .empty;
                const root = self.resultRoot(&outer, ty);
                for (arms.items) |*arm| {
                    if (arm.branch.value) |value| arm.branch.value = self.preserveResult(root, value);
                }
                outer.appendSlice(self.a, setup.items) catch @panic("out of memory");
                setup = outer;
            }
        }
        return .{ .lowered = .{ .subject = try self.runtimeExpr(subject, match.subject.at), .arms = arms.items, .kind = kind }, .ty = result_ty, .returns = all_return, .setup = setup };
    }

    /// 将整数常量试转换到目标整数位宽，超出范围或不可计算时返回空值。
    fn checkedInt(ty: Type, result: ?i128) ?i128 {
        const n = result orelse return null;
        return switch (ty.primitive) {
            inline .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .usize => |p| blk: {
                const Native = @Int(if (@tagName(p)[0] == 'i') .signed else .unsigned, if (p == .usize) @bitSizeOf(usize) else std.fmt.parseInt(u16, @tagName(p)[1..], 10) catch unreachable);
                _ = std.math.cast(Native, n) orelse break :blk null;
                break :blk n;
            },
            else => null,
        };
    }

    /// 对已知整数操作数执行安全常量折叠，溢出或无效运算时放弃编译期结果。
    fn foldInteger(left: Value, right: Value, op: ir.Operation) ?i128 {
        const a = left.constant_int orelse return null;
        const b = right.constant_int orelse return null;
        return checkedInt(left.ty, switch (op) {
            .add => std.math.add(i128, a, b) catch null,
            .sub => std.math.sub(i128, a, b) catch null,
            .mul => std.math.mul(i128, a, b) catch null,
            .div => std.math.divTrunc(i128, a, b) catch null,
            .rem => if (b == 0) null else if (b == -1) 0 else @rem(a, b),
            .bit_and => a & b,
            .bit_or => a | b,
            .bit_xor => a ^ b,
            .shl, .shr => foldIntegerBits(left.ty, a, b, if (op == .shl) .left else .right),
        });
    }

    /// 按目标整数位宽执行取反或移位，检查移位量并限制可表示的结果。
    fn foldIntegerBits(ty: Type, a: i128, b: i128, transform: enum { complement, left, right }) ?i128 {
        return switch (ty.primitive) {
            inline .i8, .i16, .i32, .i64, .i128, .u8, .u16, .u32, .u64, .u128, .usize => |p| blk: {
                const Native = @Int(if (@tagName(p)[0] == 'i') .signed else .unsigned, if (p == .usize) @bitSizeOf(usize) else std.fmt.parseInt(u16, @tagName(p)[1..], 10) catch unreachable);
                const operand = std.math.cast(Native, a) orelse break :blk null;
                if (transform == .complement) break :blk std.math.cast(i128, ~operand);
                if (b < 0 or b >= @bitSizeOf(Native)) break :blk null;
                const shift: std.math.Log2Int(Native) = @intCast(b);
                break :blk std.math.cast(i128, if (transform == .left) operand << shift else operand >> shift);
            },
            else => null,
        };
    }

    /// 检查二元操作数兼容性，选择结构体重载或基础类型运算并尝试整数常量折叠。
    fn binary(self: *Analyzer, left: Value, right_value: Value, op: syn.Tag, owner: ?*Shape, at: usize) Error!Value {
        const shift = op == .shift_left or op == .shift_right;
        const right = if (shift and left.ty != .structure) right_value else try self.expect(right_value, left.ty, at);
        if (left.ty == .structure) return self.callOperator(Operator.binaryTag(op), left, right, owner, at);
        if (comparison(op)) |cmp| {
            if (!left.ty.numeric() and !(left.ty.is(.bool) and (cmp == .eq or cmp == .ne)))
                return self.fail(at, "comparison requires numbers or boolean equality", .{});
            return self.predicate(cmp, left.expr.?, right.expr.?);
        }
        if (!left.ty.numeric()) return self.fail(at, "arithmetic requires numbers", .{});
        const operation: ir.Operation = switch (op) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .rem,
            .amp => .bit_and,
            .pipe => .bit_or,
            .caret => .bit_xor,
            .shift_left => .shl,
            .shift_right => .shr,
            else => unreachable,
        };
        switch (operation) {
            .bit_and, .bit_or, .bit_xor, .shl, .shr => {
                if (left.ty.float() or !right.ty.numeric() or right.ty.float())
                    return self.fail(at, "bitwise operators require integers", .{});
            },
            else => {},
        }
        return .{ .ty = left.ty, .constant_int = foldInteger(left, right, operation), .expr = self.irExpr(.{ .arithmetic = .{
            .op = operation,
            .left = left.expr.?,
            .right = right.expr.?,
        } }) };
    }

    /// 分析调用目标、接收者和实参，处理内建构造、隐式上下文及静态分发后生成调用。
    fn call(self: *Analyzer, scope: *Scope, node: *Expr, owner: ?*Shape) Error!Value {
        const c = node.data.call;
        const callee = c.callee;
        if (callee.data == .name and same(callee.data.name, "range") and scope.get("range") == null) {
            if (c.args.len != 2) return self.fail(node.at, "range expects start and end", .{});
            var endpoints: [2]i32 = undefined;
            for (c.args, &endpoints) |arg, *endpoint| {
                const value = try self.eval(scope, arg, i32_type, owner);
                endpoint.* = if (value.ty.numeric() and !value.ty.float() and value.constant_int != null)
                    std.math.cast(i32, value.constant_int.?) orelse return self.fail(arg.at, "range endpoint is outside i32", .{})
                else
                    return self.fail(arg.at, "range endpoints must be compile-time integers", .{});
            }
            const start, const end = endpoints;
            const length: usize = @intCast(@max(0, @as(i64, end) - start));
            return .{
                .ty = .{ .array = .{ .length = length, .element = self.make(i32_type) } },
                .expr = self.irExpr(.{ .range = .{ .start = start, .end = end, .length = length } }),
            };
        }
        // 保存调用目标或接收者的临时绑定，使复杂表达式在一次调用中只求值一次。
        const CallBinding = struct { name: Text, value: *const ir.Expr, serial: usize };
        var base_binding: ?CallBinding = null;
        var callee_binding: ?CallBinding = null;
        var receiver: ?Value = null;
        var managed_receiver: Body = .empty;
        var callable = if (callee.data == .member) blk: {
            const m = callee.data.member;
            var base = try self.eval(scope, m.base, null, owner);
            if (base.type_value == null and same(m.name, "Ptr")) {
                if (self.managerPolicy(base.ty)) |policy| {
                    if (c.args.len != 1) return self.fail(node.at, "Ptr requires one target type", .{});
                    const pointee = try self.typeExpr(scope, c.args[0], owner);
                    if (pointee.is(.void) or pointee.is(.type)) return self.fail(node.at, "invalid pointer target", .{});
                    return typeValue(self.allocationPointer(policy, pointee));
                }
            }
            if (base.type_value) |ty| {
                const runtime = if (self.zig_store) |store| store.runtime else null;
                if (ty == .foreign and ty.foreign.decl.file == runtime and same(ty.foreign.decl.name, "Heap") and
                    same(m.name, "new") and c.args.len == 1)
                {
                    const constructor = self.foreignMemberDecl(ty.foreign, "newWith").?;
                    const function_value = try self.resolveZig(constructor.decl, node.at);
                    const allocator = function_value.ty.function.params[0];
                    const operand = try self.expect(try self.eval(scope, c.args[0], allocator, owner), allocator, c.args[0].at);
                    return self.invoke(function_value, &.{operand}, node.at);
                }
            }
            if (base.type_value) |ty| if (ty == .enumeration) {
                const variant = try self.enumVariant(ty.enumeration, m.name, node.at);
                const payload_ty = variant.ty orelse return self.fail(node.at, "enum member '{s}' has no payload", .{m.name});
                if (c.args.len != 1) return self.fail(node.at, "enum member '{s}' expects one payload", .{m.name});
                const value = try self.expect(try self.eval(scope, c.args[0], payload_ty, owner), payload_ty, c.args[0].at);
                return .{ .ty = ty, .expr = self.irExpr(.{ .enum_init = .{ .id = ty.enumeration.id, .name = m.name, .payload = try self.ownedExpr(value, c.args[0].at) } }) };
            };
            if (base.type_value) |ty| {
                const payload_ty: ?Type = switch (ty) {
                    .optional => |child| if (same(m.name, "Some")) child.* else null,
                    .error_union => |result| if (same(m.name, "Ok")) result.payload.* else if (same(m.name, "Err")) result.errors.* else null,
                    else => null,
                };
                if (payload_ty) |payload| {
                    const count: usize = if (payload.is(.void)) 0 else 1;
                    if (c.args.len != count) return self.fail(node.at, "'{s}' expects {d} arguments", .{ m.name, count });
                    const expression = if (count == 0)
                        self.irExpr(.{ .foreign_object = .{ .ty = self.lowerType(void_type), .fields = &.{} } })
                    else blk2: {
                        const value = try self.expect(try self.eval(scope, c.args[0], payload, owner), payload, c.args[0].at);
                        break :blk2 try self.ownedExpr(value, c.args[0].at);
                    };
                    return .{ .ty = ty, .expr = self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(ty), .value = expression } }) };
                }
            }
            if (base.ty == .managed) {
                base = try self.stageManaged(&managed_receiver, base, m.base.at);
                if (try self.callManagedPointer(base, m.name, c.args.len, node.at)) |value| {
                    const result = value;
                    return self.wrapManagedScope(managed_receiver, result);
                }
                base = if (base.ty.managed.kind == .View) self.unpackMemoryView(base) else try self.managedPointee(base, node.at);
            }
            if (try self.callMemoryManager(scope, base, m.name, c.args, owner, node.at)) |value| return value;
            if (try self.getForeignMember(base, m.name, node.at)) |value| {
                if (base.type_value == null and value.foreign_function != null) {
                    const params = value.ty.function.params;
                    if (params.len == 0) return self.fail(node.at, "Zig function '{s}' has no receiver", .{m.name});
                    receiver = try self.foreignReceiver(base, params[0], node.at);
                }
                break :blk value;
            }
            const found = try self.resolveMember(base, m.name, owner, node.at);
            if (found.member.data == .value and found.member.data.value.foreign_declaration != null) {
                const value = try self.memberValue(base, found, m.name, node.at);
                if (found.foreign_receiver) |ty| {
                    if (!base.ty.is(.type) and value.foreign_function != null) {
                        const params = value.ty.function.params;
                        if (params.len == 0) return self.fail(node.at, "Zig function '{s}' has no receiver", .{m.name});
                        const foreign_self: Value = .{
                            .ty = .{ .foreign = ty },
                            .expr = self.access(self.objectExpr(base), found.path),
                            .writable = base.writable or base.ty == .pointer,
                        };
                        receiver = try self.foreignReceiver(foreign_self, params[0], node.at);
                    }
                }
                break :blk value;
            }
            const compile_time = switch (found.member.data) {
                .value => |value| if (value.function) |f| f.sig.result.is(.type) else false,
                .method, .operator => |f| f.sig.result.is(.type),
                else => false,
            };
            if (!compile_time and !base.ty.is(.type) and base.expr != null) {
                const serial = self.id();
                const name = self.fmt("__saphine_receiver_{d}", .{serial});
                base_binding = .{ .name = name, .value = if (base.ty == .pointer) base.expr.? else self.irExpr(.{ .address = base.expr.? }), .serial = serial };
                const pointer = self.irExpr(.{ .variable = name });
                base.expr = if (base.ty == .pointer) pointer else self.irExpr(.{ .dereference = pointer });
            }
            if (found.member.data != .method or base.ty.is(.type)) break :blk try self.memberValue(base, found, m.name, node.at);
            const visible = try self.baseShape(base, node.at);
            const outer = if (base.view) |view| view.shape else visible;
            const path = if (base.view) |view|
                std.mem.concat(self.a, Text, &.{ view.path, found.path }) catch @panic("out of memory")
            else
                found.path;
            const implementation = try self.dispatch(outer, path, m.name, found.member.data.method, node.at);
            const f = implementation.function;
            const code = self.access(self.storageExpr(base), implementation.receiver_path);
            if (base.pointer_readonly or (!base.writable and base.ty != .pointer))
                return self.fail(node.at, "method requires a mutable receiver", .{});
            receiver = .{ .ty = f.sig.params[0], .expr = self.irExpr(.{ .address = code }), .memory_owner = base.memory_owner };
            break :blk Value{ .ty = .{ .function = f.sig }, .function = f, .context = self.receiverContext(base, implementation.receiver_path, m.name) };
        } else try self.eval(scope, callee, null, owner);
        if (callable.stdlib_print) |target| return self.callStdlibPrint(scope, node, owner, target);
        if (callable.ty == .zig_callback) {
            const callback = callable.ty.zig_callback.signature;
            if (c.args.len != callback.params.len)
                return self.fail(node.at, "expected {d} arguments, got {d}", .{ callback.params.len, c.args.len });
            var args: std.ArrayList(*const ir.Expr) = .empty;
            for (c.args, callback.params) |arg, ty| {
                const value = try self.expect(try self.eval(scope, arg, ty, owner), ty, arg.at);
                self.append(&args, try self.runtimeExpr(value, arg.at));
            }
            return .{ .ty = callback.result, .expr = self.irExpr(.{ .zig_indirect = .{ .function = try self.runtimeExpr(callable, node.at), .args = args.items } }) };
        }
        if (callable.zig_generic) |generic| {
            if (self.zig_store.?.runtime == generic.declaration.file) {
                if (std.meta.stringToEnum(ir.ManagedKind, generic.declaration.name)) |kind| {
                    if (c.args.len != 1) return self.fail(node.at, "managed pointer type requires one argument", .{});
                    const child = try self.typeExpr(scope, c.args[0], owner);
                    if (child.is(.type) or child.is(.void)) return self.fail(node.at, "invalid managed pointer target", .{});
                    if (kind == .View and child != .slice and !child.is(.bytes) and child != .function and child != .pointer and child != .foreign_pointer)
                        return self.fail(node.at, "View requires a slice, pointer or function type", .{});
                    return typeValue(self.managedType(kind, child));
                }
            }
            return self.callZigGeneric(scope, node, owner, generic);
        }
        if (callable.ty == .managed and callable.ty.managed.kind == .View) {
            callable = try self.stageManaged(&managed_receiver, callable, node.at);
            const handle = callable;
            callable = self.unpackMemoryView(callable);
            if (callable.ty == .function) callable.expr = handle.expr;
        }
        if (callable.ty != .function) return self.fail(node.at, "value is not callable", .{});
        if (callable.function == null and callable.foreign_function == null and callable.expr != null) {
            const serial = self.id();
            const name = self.fmt("__saphine_callee_{d}", .{serial});
            callee_binding = .{ .name = name, .value = callable.expr.?, .serial = serial };
            callable.expr = self.irExpr(.{ .variable = name });
        }
        const sig = callable.ty.function;
        const offset: usize = if (receiver != null) 1 else 0;
        const implicit_context = if (sig.context_parameter) |index|
            if (index >= offset and c.args.len + offset + 1 == sig.params.len) index else null
        else
            null;
        if (implicit_context == null and c.args.len + offset != sig.params.len)
            return self.fail(node.at, "expected {d} arguments, got {d}", .{ sig.params.len - offset, c.args.len });
        var args: std.ArrayList(Value) = .empty;
        if (receiver) |r| self.append(&args, r);
        const previous_context = self.expected_context;
        defer self.expected_context = previous_context;
        self.expected_context = self.callableContext(callable);
        var next_arg: usize = 0;
        for (sig.params[offset..], offset..) |ty, index| {
            if (implicit_context == index) {
                const manager = scope.defaultManager() orelse return self.fail(node.at, "missing default manager for context parameter", .{});
                self.append(&args, try self.convertArgument(manager, ty, owner, node.at));
                continue;
            }
            const arg = c.args[next_arg];
            next_arg += 1;
            var value = try self.eval(scope, arg, ty, owner);
            if (callable.static_callback) |declared| {
                const required = declared.params[index];
                if (pointerConstraint(required))
                    value = try self.abstractPointer(value, required.managed.child.*, owner, arg.at);
            }
            const converted = if (callable.foreign_function != null and isZigAllocator(ty))
                (try self.managerAllocator(value, owner, arg.at)) orelse value
            else
                value;
            self.append(&args, if (sig.context_parameter == index and ty == .foreign_pointer and !self.managerConstraint(ty))
                try self.foreignReceiver(converted, ty, arg.at)
            else
                try self.convertArgument(converted, ty, owner, arg.at));
        }
        var result = try self.invokeManaged(callable, args.items, node.at);
        if (result.expr) |expression| {
            var wrapped = expression;
            if (callee_binding) |binding| wrapped = self.irExpr(.{ .bound = .{ .name = binding.name, .value = binding.value, .result = wrapped, .serial = binding.serial } });
            if (base_binding) |binding| wrapped = self.irExpr(.{ .bound = .{ .name = binding.name, .value = binding.value, .result = wrapped, .serial = binding.serial } });
            result.expr = wrapped;
        }
        return self.wrapManagedScope(managed_receiver, result);
    }

    /// 检查 print 的单个实参，按类型选择格式并显式传入程序 IO 上下文。
    fn callStdlibPrint(self: *Analyzer, scope: *Scope, node: *Expr, owner: ?*Shape, target: ir.ForeignRef) Error!Value {
        const args = node.data.call.args;
        if (args.len != 1) return self.fail(node.at, "print expects one argument", .{});
        var arg = try self.eval(scope, args[0], null, owner);
        if (arg.ty == .slice and arg.ty.slice.element.is(.u8)) arg = try self.expect(arg, .{ .primitive = .bytes }, args[0].at);
        if (!arg.ty.numeric() and !arg.ty.is(.bytes) and !arg.ty.is(.bool))
            return self.fail(node.at, "print expects bytes, a number or bool", .{});
        const format = if (arg.ty.is(.bytes)) "{s}\n" else if (arg.ty.is(.bool)) "{any}\n" else if (arg.ty.float()) "{e}\n" else "{d}\n";
        return .{ .ty = void_type, .expr = self.irExpr(.{ .foreign_call = .{
            .target = target,
            .args = self.make([3]*const ir.Expr{
                self.irExpr(.{ .builtin = "__saphine_io" }),
                self.irExpr(.{ .bytes = format }),
                try self.runtimeExpr(arg, args[0].at),
            }),
        } }) };
    }

    /// 按文件和偏移复用外部调用位置编号，用于将 Zig 诊断映射回源调用。
    fn foreignCallSite(self: *Analyzer, at: usize) ?usize {
        const source_span = self.span(at, 1) orelse return null;
        for (self.call_sites.items, 0..) |site, index| {
            if (site.start == at and same(site.path, source_span.path)) return index;
        }
        self.append(&self.call_sites, source_span);
        return self.call_sites.items.len - 1;
    }

    /// 逐项分析 Zig 泛型实参并替换参数名，直接解析或查询返回类型后生成调用。
    fn callZigGeneric(self: *Analyzer, scope: *Scope, node: *Expr, owner: ?*Shape, generic: *const ZigFunction) Error!Value {
        const args = node.data.call.args;
        if (args.len != generic.parameters.len)
            return self.fail(node.at, "expected {d} arguments, got {d}", .{ generic.parameters.len, args.len });
        const previous = self.zig_substitutions;
        defer self.zig_substitutions = previous;
        const declaration = generic.declaration;
        const substitutions = self.a.alloc(ZigSubstitution, args.len) catch @panic("out of memory");
        var substitution_count: usize = 0;
        var operands: std.ArrayList(*const ir.Expr) = .empty;
        var values: std.ArrayList(Value) = .empty;
        for (args, generic.parameters) |arg, param| {
            const expected = if (param.node) |type_node| try self.zigTypeIn(declaration.file, declaration.container, type_node, arg.at) else null;
            self.zig_substitutions = previous;
            var value = try self.eval(scope, arg, expected, owner);
            self.zig_substitutions = substitutions[0..substitution_count];
            if (expected) |ty| {
                if (isZigAllocator(ty)) value = (try self.managerAllocator(value, owner, arg.at)) orelse value;
                value = try self.expect(value, ty, arg.at);
            }
            if (value.type_value) |ty| {
                if (!param.comptime_param and expected != null) return self.fail(arg.at, "Zig argument must be a runtime value", .{});
                if (ty == .structure or ty == .enumeration or ty == .pointer or ty == .function)
                    return self.fail(arg.at, "unsupported saphine type in Zig comptime argument", .{});
                self.append(&operands, self.irExpr(.{ .type_value = self.lowerType(ty) }));
            } else {
                if (memoryTraits(value.ty).active())
                    return self.fail(arg.at, "managed values cannot cross an untyped Zig argument boundary", .{});
                if (param.comptime_param and value.constant_int == null and (value.expr == null or (value.expr.?.* != .bytes and value.expr.?.* != .boolean and value.expr.?.* != .number)))
                    return self.fail(arg.at, "Zig argument must be a supported compile-time value", .{});
                const expression = if (param.comptime_param and value.constant_int != null)
                    self.irExpr(.{ .number = .{ .ty = value.ty.primitive, .canonical = self.fmt("{d}", .{value.constant_int.?}) } })
                else
                    try self.runtimeExpr(value, arg.at);
                self.append(&operands, expression);
            }
            self.append(&values, value);
            if (param.name) |name| {
                substitutions[substitution_count] = .{ .name = name, .value = value };
                substitution_count += 1;
                self.zig_substitutions = substitutions[0..substitution_count];
            }
        }
        const saved_diagnostic = self.diag.*;
        const result = self.zigTypeIn(declaration.file, declaration.container, generic.result_node, node.at) catch blk: {
            self.diag.* = saved_diagnostic;
            break :blk try self.queryZigResult(generic, values.items, operands.items, false, node.at);
        };
        if (result.is(.type)) return typeValue(try self.queryZigResult(generic, values.items, operands.items, true, node.at));
        return .{ .ty = result, .expr = self.irExpr(.{ .foreign_call = .{ .target = generic.reference, .args = operands.items, .site = self.foreignCallSite(node.at) } }) };
    }

    /// 查询外部声明表示的类型，并在适用时保留声明本身的可访问引用名称。
    fn queryZigType(self: *Analyzer, declaration: ForeignDeclaration, reference: ir.ForeignRef, at: usize) Error!Type {
        const operand = self.irExpr(.{ .foreign_ref = reference });
        const result = try self.performQuery(declaration, operand, at);
        if (result == .foreign and result.foreign.queried != null and !result.foreign.is_factory)
            result.foreign.reference = reference;
        return result;
    }

    /// 为 Zig 调用构造类型查询表达式，运行时参数用同类型 undefined 代替而不执行调用。
    fn queryZigResult(self: *Analyzer, function_value: *const ZigFunction, values: []const Value, operands: []const *const ir.Expr, type_factory: bool, at: usize) Error!Type {
        var call_args: std.ArrayList(*const ir.Expr) = .empty;
        for (values, operands, function_value.parameters) |value, operand, parameter| {
            if (parameter.comptime_param or value.type_value != null) {
                self.append(&call_args, operand);
            } else {
                if (type_factory) return self.fail(at, "Zig type factories require compile-time arguments", .{});
                if (value.ty == .structure or value.ty == .enumeration or value.ty == .pointer or value.ty == .function)
                    return self.fail(at, "query requires an explicit facade for saphine nominal or function arguments", .{});
                const undefined_value = self.irExpr(.{ .builtin = "undefined" });
                self.append(&call_args, self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(value.ty), .value = undefined_value } }));
            }
        }
        const expression = self.irExpr(.{ .foreign_call = .{ .target = function_value.reference, .args = call_args.items } });
        return self.performQuery(function_value.declaration, if (type_factory) expression else self.irExpr(.{ .type_of = expression }), at);
    }

    /// 准备同一模块图和编译选项，调用 Zig 查询类型元数据，再解码为语义类型。
    fn performQuery(self: *Analyzer, declaration: ForeignDeclaration, expression: *const ir.Expr, at: usize) Error!Type {
        const store = self.zig_store orelse return self.fail(at, "Zig query requires the compiler driver", .{});
        store.discover() catch |err| return self.fail(at, "cannot resolve Zig query dependencies: {s}", .{@errorName(err)});
        const artifact = Artifact.init(store, self.zig_entry orelse return self.fail(at, "Zig query requires an entry module", .{}), "query.zig", self.zig_target, self.zig_optimize, self.zig_backend) catch |err| return self.fail(at, "cannot stage Zig query: {s}", .{@errorName(err)});
        const imports = artifact.imports() catch |err| return self.fail(at, "cannot resolve Zig query imports: {s}", .{@errorName(err)});
        const declarations = ir.emitImportDeclarations(self.a, imports) catch @panic("out of memory");
        const type_expression = ir.emitExpression(self.a, imports, expression) catch @panic("out of memory");
        const data = compiler_query.describeType(artifact, declarations, type_expression) catch |err|
            return self.fail(at, "Zig compiler query failed: {s}; use an explicit Zig facade", .{@errorName(err)});
        return self.queriedType(data, 0, 0, declaration, expression, type_expression, at);
    }

    /// 按记录索引递归解码查询类型，复用具名类型身份并拒绝暂不支持的限定或嵌套类型。
    fn queriedType(self: *Analyzer, metadata: Text, index: usize, depth: usize, declaration: ForeignDeclaration, expression: *const ir.Expr, key: Text, at: usize) Error!Type {
        if (depth > 32) return self.fail(at, "Zig compiler query type is too deeply nested", .{});
        var records = std.mem.splitScalar(u8, metadata, '\n');
        for (0..index) |_| _ = records.next() orelse return self.fail(at, "invalid Zig compiler query reference", .{});
        const record = records.next() orelse return self.fail(at, "invalid Zig compiler query record", .{});
        var fields = std.mem.tokenizeScalar(u8, record, ' ');
        const kind = fields.next() orelse return self.fail(at, "empty Zig compiler query record", .{});
        if (same(kind, "int") or same(kind, "float")) {
            if (primitive(fields.next() orelse "")) |p| return .{ .primitive = p };
        } else if (same(kind, "bool")) {
            return bool_type;
        } else if (same(kind, "void")) {
            return void_type;
        } else if (same(kind, "optional") or same(kind, "pointer") or same(kind, "array") or same(kind, "error_union")) {
            const child_id = std.fmt.parseInt(usize, fields.next() orelse "", 10) catch return self.fail(at, "invalid Zig compiler query edge", .{});
            const child = try self.queriedType(metadata, child_id, depth + 1, declaration, expression, key, at);
            if (same(kind, "optional")) return .{ .optional = self.make(child) };
            if (same(kind, "error_union")) {
                const payload = std.fmt.parseInt(usize, fields.next() orelse "", 10) catch return self.fail(at, "invalid Zig compiler query payload", .{});
                return .{ .error_union = .{ .errors = self.make(child), .payload = self.make(try self.queriedType(metadata, payload, depth + 1, declaration, expression, key, at)) } };
            }
            if (same(kind, "array")) {
                const length = std.fmt.parseInt(usize, fields.next() orelse "", 10) catch return self.fail(at, "invalid Zig compiler query array length", .{});
                if (fields.next() != null) return self.fail(at, "unsupported sentinel in queried Zig array", .{});
                return .{ .array = .{ .length = length, .element = self.make(child) } };
            }
            const size = std.meta.stringToEnum(std.lang.Type.Pointer.Size, fields.next() orelse "") orelse return self.fail(at, "invalid Zig compiler query pointer size", .{});
            const is_const = same(fields.next() orelse "", "const");
            if (fields.next() != null) return self.fail(at, "unsupported qualifiers in queried Zig pointer", .{});
            if (size != .slice) return .{ .foreign_pointer = .{ .child = self.make(child), .is_const = is_const, .size = size } };
            if (is_const and child.is(.u8)) return .{ .primitive = .bytes };
            return .{ .slice = .{ .element = self.make(child), .is_const = is_const } };
        }
        if ((same(kind, "struct") or same(kind, "enum") or same(kind, "union") or same(kind, "opaque") or same(kind, "error_set"))) {
            const type_name = fields.next() orelse return self.fail(at, "missing nominal Zig query name", .{});
            for (self.foreign_types.items) |known| {
                if (known.queried) |query| {
                    if (known.decl.file == declaration.file and same(query.type_name, type_name) and same(query.metadata, metadata))
                        return .{ .foreign = known };
                }
            }
            if (depth != 0) return self.fail(at, "query cannot name the nested Zig type '{s}'", .{type_name});
            if (index != 0) return self.fail(at, "nested queried Zig nominal types require an explicit facade", .{});
            const ty = self.make(ForeignType{
                .decl = declaration,
                .node = declaration.node,
                .reference = .{ .module = declaration.file.id, .name = declaration.name },
                .kind = if (same(kind, "struct")) .structure else if (same(kind, "enum")) .enumeration else if (same(kind, "union")) .union_type else if (same(kind, "opaque")) .opaque_type else .error_set,
                .is_factory = true,
                .queried = .{ .expression = expression, .type_name = type_name, .key = key, .metadata = metadata },
            });
            self.append(&self.foreign_types, ty);
            return .{ .foreign = ty };
        }
        return self.fail(at, "unsupported result from Zig compiler query: {s}; use an explicit Zig facade", .{record});
    }

    /// 汇总值是否需要自动清理及 GC 跟踪，通过合并子类型特征传播到复合类型。
    const MemoryTraits = struct {
        drop: bool = false,
        trace: bool = false,

        /// 对清理和跟踪标记分别取并集，合并不同字段的内存管理需求。
        fn merge(a: MemoryTraits, b: MemoryTraits) MemoryTraits {
            return .{ .drop = a.drop or b.drop, .trace = a.trace or b.trace };
        }

        /// 判断是否需要清理或跟踪，以选择普通 IR 或托管值 IR。
        fn active(traits: MemoryTraits) bool {
            return traits.drop or traits.trace;
        }
    };

    /// 按托管指针类别确定内存特征，并递归汇总数组、结构体和枚举载荷的需求。
    fn memoryTraits(ty: Type) MemoryTraits {
        return switch (ty) {
            .managed => |ptr| switch (ptr.kind) {
                .GcPtr => .{ .trace = true },
                .View => .{ .drop = true, .trace = true },
                .ArcPtr, .WeakPtr => .{ .drop = true },
                .Ptr => .{},
            },
            .optional => |child| memoryTraits(child.*),
            .array => |array| memoryTraits(array.element.*),
            .structure => |shape| blk: {
                var traits: MemoryTraits = .{};
                for (shape.members) |member| {
                    if (member.data == .field) traits = traits.merge(memoryTraits(member.data.field.ty));
                }
                break :blk traits;
            },
            .enumeration => |shape| blk: {
                var traits: MemoryTraits = .{};
                for (shape.variants) |variant| {
                    if (variant.ty) |child| traits = traits.merge(memoryTraits(child));
                }
                break :blk traits;
            },
            else => .{},
        };
    }

    /// 取得已加载内存运行库的模块编号，供生成托管类型及运行库调用引用。
    fn memoryModule(self: *Analyzer) usize {
        return self.zig_store.?.runtime.?.id;
    }

    /// 将目标类型与托管指针类别组合，并关联到当前内存运行库模块。
    fn managedType(self: *Analyzer, kind: ir.ManagedKind, child: Type) Type {
        return .{ .managed = .{ .kind = kind, .child = self.make(child), .module = self.memoryModule() } };
    }

    /// 复制实参列表并构造指向内存运行库具名函数的外部调用 IR。
    fn memoryCall(self: *Analyzer, name: Text, args: []const *const ir.Expr) *const ir.Expr {
        return self.irExpr(.{ .foreign_call = .{
            .target = .{ .module = self.memoryModule(), .name = name },
            .args = self.a.dupe(*const ir.Expr, args) catch @panic("out of memory"),
        } });
    }

    /// 取得可转移的值表达式；需要清理的左值通过 copyValue 复制所有权，临时值直接使用。
    fn ownedExpr(self: *Analyzer, value: Value, at: usize) Error!*const ir.Expr {
        const expression = try self.runtimeExpr(value, at);
        if (!memoryTraits(value.ty).drop) return expression;
        return switch (expression.*) {
            .variable, .module_object, .module_cast, .foreign_ref, .field, .foreign_field, .index, .dereference => self.memoryCall("copyValue", &.{expression}),
            else => expression,
        };
    }

    /// 根据类型特征追加作用域保护 IR，为目标登记 GC 跟踪和可选的退出清理。
    fn guardMemory(self: *Analyzer, body: *Body, target: *const ir.Expr, ty: Type, drop: bool) void {
        const traits = memoryTraits(ty);
        if (traits.trace or (drop and traits.drop)) {
            self.append(body, ir.Stmt{ .managed_guard = .{
                .target = target,
                .module = self.memoryModule(),
                .id = self.id(),
                .trace = traits.trace,
                .drop = drop and traits.drop,
            } });
        }
    }

    /// 根据类型是否需要清理或跟踪，选择普通局部声明或托管局部声明 IR。
    fn localValue(self: *Analyzer, slot: ir.Slot, value: *const ir.Expr, mutable: bool, ty: Type) ir.Stmt {
        const traits = memoryTraits(ty);
        if (!traits.active()) return .{ .local = .{ .slot = slot, .mutable = mutable, .value = value } };
        return .{ .managed_local = .{
            .slot = slot,
            .value = value,
            .module = self.memoryModule(),
            .id = self.id(),
            .drop = traits.drop,
            .trace = traits.trace,
        } };
    }

    /// 将值保存到受保护的临时局部变量，返回该变量引用以稳定求值和清理顺序。
    fn stageManaged(self: *Analyzer, body: *Body, value: Value, at: usize) Error!Value {
        const name = self.localName("__saphine_temp");
        self.append(body, self.localValue(.{ .name = name, .ty = self.lowerType(actualType(value)) }, try self.ownedExpr(value, at), false, value.ty));
        var staged = value;
        staged.expr = self.irExpr(.{ .variable = name });
        staged.writable = false;
        return staged;
    }

    /// 创建初始为空的结果槽并登记 GC 根，跨越内部清理保活即将返回的值而不释放它。
    fn resultRoot(self: *Analyzer, body: *Body, ty: Type) Text {
        const name = self.localName("__saphine_result");
        const optional: Type = .{ .optional = self.make(ty) };
        const slot: ir.Slot = .{ .name = name, .ty = self.lowerType(optional) };
        // The result is transferred to the caller. Only register its GC root here.
        self.append(body, ir.Stmt{ .managed_local = .{
            .slot = slot,
            .module = self.memoryModule(),
            .id = self.id(),
            .value = self.irExpr(.{ .optional_none = slot.ty }),
            .drop = false,
            .trace = true,
        } });
        return name;
    }

    /// 生成将结果保存到保活槽的 IR，避免其在离开内部作用域时失去 GC 根。
    fn preserveResult(self: *Analyzer, slot: Text, value: *const ir.Expr) *const ir.Expr {
        return self.irExpr(.{ .preserve_result = .{ .slot = slot, .value = value, .id = self.id() } });
    }

    /// 将前置语句和结果包装为表达式作用域，需要跟踪的结果另外放入外层保活槽。
    fn wrapManagedScope(self: *Analyzer, body: Body, value: Value) Value {
        if (body.items.len == 0) return value;
        var result = value;
        result.writable = false;
        if (memoryTraits(value.ty).trace) {
            var outer: Body = .empty;
            const root = self.resultRoot(&outer, value.ty);
            const inner = self.irExpr(.{ .managed_scope = .{
                .body = body.items,
                .result = self.preserveResult(root, value.expr.?),
                .id = self.id(),
            } });
            result.expr = self.irExpr(.{ .managed_scope = .{ .body = outer.items, .result = inner, .id = self.id() } });
        } else {
            result.expr = self.irExpr(.{ .managed_scope = .{ .body = body.items, .result = value.expr.?, .id = self.id() } });
        }
        return result;
    }

    /// 先取得结果所有权，再包装临时作用域，使内部清理不会破坏输出值。
    fn finishManagedScope(self: *Analyzer, body: Body, value: Value, at: usize) Error!Value {
        var result = value;
        result.expr = try self.ownedExpr(value, at);
        return self.wrapManagedScope(body, result);
    }

    /// 实参含托管值时先暂存运行时参数，调用后统一清理，并保活返回结果。
    fn invokeManaged(self: *Analyzer, callable: Value, args: []const Value, at: usize) Error!Value {
        for (args) |arg| {
            if (memoryTraits(arg.ty).active()) break;
        } else return self.invoke(callable, args, at);
        var body: Body = .empty;
        const operands = self.a.alloc(Value, args.len) catch @panic("out of memory");
        for (args, operands) |arg, *operand| {
            operand.* = if (arg.ty.is(.type) or arg.static_callback != null) arg else try self.stageManaged(&body, arg, at);
        }
        return self.wrapManagedScope(body, try self.invoke(callable, operands, at));
    }

    /// 为托管对象的方法生成接收者适配调用，以函数 View 同时保留方法和对象所有者。
    fn bindManagedMethod(self: *Analyzer, base: Value, found: Found, name: Text, at: usize) Error!Value {
        const visible = try self.baseShape(base, at);
        const implementation = try self.dispatch(visible, found.path, name, found.member.data.method, at);
        const method = implementation.function;
        if (method.sig.context_parameter != null or method.sig.result.is(.type))
            return self.fail(at, "bound managed methods require a runtime signature", .{});
        const receiver_node = self.irExpr(.{ .variable = "__saphine_receiver" });
        const receiver: Value = .{
            .ty = method.sig.params[0],
            .expr = receiver_node,
            .memory_owner = self.irExpr(.{ .variable = "__saphine_owner" }),
        };
        const actual_receiver = self.irExpr(.{ .address = self.access(self.storageExpr(base), implementation.receiver_path) });
        const params = self.a.alloc(ir.Slot, method.sig.params.len - 1) catch @panic("out of memory");
        const args = self.a.alloc(Value, method.sig.params.len) catch @panic("out of memory");
        args[0] = receiver;
        for (method.sig.params[1..], params, args[1..], 0..) |ty, *slot, *arg, index| {
            if (ty.is(.type)) return self.fail(at, "bound managed methods require runtime parameters", .{});
            const param = self.fmt("__saphine_arg_{d}", .{index});
            slot.* = .{ .name = param, .ty = self.lowerType(ty) };
            arg.* = .{ .ty = ty, .expr = self.irExpr(.{ .variable = param }) };
        }
        const invocation = try self.invoke(.{
            .ty = .{ .function = method.sig },
            .function = method,
            .context = self.receiverContext(receiver, &.{}, name),
        }, args, at);
        const bound_signature = self.make(Signature{ .params = method.sig.params[1..], .result = method.sig.result });
        return .{
            .ty = self.managedType(.View, .{ .function = bound_signature }),
            .expr = self.irExpr(.{ .bound_method = .{
                .module = self.memoryModule(),
                .receiver = actual_receiver,
                .receiver_type = self.lowerType(receiver.ty),
                .owner = base.memory_owner.?,
                .params = params,
                .result = self.lowerType(method.sig.result),
                .call = invocation.expr.?,
            } }),
        };
    }

    /// 从托管 View 取出值并保留所有者表达式，让后续成员访问仍能追溯保活对象。
    fn unpackMemoryView(self: *Analyzer, value: Value) Value {
        if (value.ty != .managed or value.ty.managed.kind != .View) return value;
        return .{
            .ty = value.ty.managed.child.*,
            .expr = self.irExpr(.{ .foreign_field = .{ .base = value.expr.?, .name = "value" } }),
            .memory_owner = self.memoryCall("ownerOf", &.{value.expr.?}),
            .writable = value.writable and !value.pointer_readonly,
            .pointer_readonly = value.pointer_readonly,
        };
    }

    /// 值带内存所有者时生成 makeView 调用，把派生地址或切片与所有者一起保存。
    fn packMemoryView(self: *Analyzer, value: Value, at: usize) Error!Value {
        const owner = value.memory_owner orelse return value;
        const payload = self.irExpr(.{ .typed_value = .{ .ty = self.lowerType(value.ty), .value = try self.runtimeExpr(value, at) } });
        return .{ .ty = self.managedType(.View, value.ty), .expr = self.memoryCall("makeView", &.{ owner, payload }), .pointer_readonly = value.pointer_readonly };
    }

    /// 从强托管指针取得结构体地址和所有者，拒绝未升级的弱指针及非结构体目标。
    fn managedPointee(self: *Analyzer, value: Value, at: usize) Error!Value {
        const pointer = value.ty.managed;
        if (pointer.kind == .WeakPtr) return self.fail(at, "upgrade the weak pointer before accessing the object", .{});
        if (pointer.child.* != .structure) return self.fail(at, "managed member access requires a structure", .{});
        return .{
            .ty = .{ .pointer = pointer.child.structure },
            .expr = self.irExpr(.{ .managed_get = try self.runtimeExpr(value, at) }),
            .memory_owner = self.memoryCall("ownerOf", &.{value.expr.?}),
            .writable = !value.pointer_readonly,
            .pointer_readonly = value.pointer_readonly,
        };
    }

    /// 识别 ArcPtr.weak 与 WeakPtr.upgrade，检查参数和只读限制后生成托管方法 IR。
    fn callManagedPointer(self: *Analyzer, value: Value, name: Text, argc: usize, at: usize) Error!?Value {
        const pointer = value.ty.managed;
        if (value.pointer_readonly and (same(name, "weak") or same(name, "upgrade")))
            return self.fail(at, "read-only Ptr cannot produce a mutable smart pointer", .{});
        const result = if (pointer.kind == .ArcPtr and same(name, "weak"))
            self.managedType(.WeakPtr, pointer.child.*)
        else if (pointer.kind == .WeakPtr and same(name, "upgrade"))
            Type{ .optional = self.make(self.managedType(.ArcPtr, pointer.child.*)) }
        else
            return null;
        if (argc != 0) return self.fail(at, "{s} expects no arguments", .{name});
        return .{ .ty = result, .expr = self.irExpr(.{ .managed_method = .{ .receiver = try self.runtimeExpr(value, at), .name = name } }) };
    }

    /// 处理具体 manager 的 create、destroy 和 root，检查对象内存特征并选择运行库操作。
    fn callMemoryManager(self: *Analyzer, scope: *Scope, base: Value, name: Text, args: []*Expr, owner: ?*Shape, at: usize) Error!?Value {
        if (base.type_value != null or (!same(name, "create") and !same(name, "destroy") and !same(name, "root"))) return null;
        const runtime = (self.zig_store orelse return null).runtime orelse return null;
        const candidate = if (base.ty == .foreign_pointer) base.ty.foreign_pointer.child.* else base.ty;
        if (candidate != .foreign or candidate.foreign.decl.file != runtime) return null;
        const manager = candidate.foreign;
        const heap = same(manager.decl.name, "Heap");
        const arena = same(manager.decl.name, "Arena");
        const destroy = same(name, "destroy");
        const arc = same(manager.decl.name, "Arc");
        const gc = same(manager.decl.name, "GC");
        const root = same(name, "root");
        if ((!heap and !arena and !arc and !gc) or (destroy and !heap) or (root and !gc)) return null;
        if (args.len != 1) return self.fail(at, "{s} expects one argument", .{name});
        const receiver_ty = if (arena)
            Type{ .foreign_pointer = .{ .child = self.make(candidate), .is_const = false } }
        else
            candidate;
        const receiver = try self.foreignReceiver(base, receiver_ty, at);
        const operand = try self.eval(scope, args[0], null, owner);
        if (root) {
            if (operand.ty != .managed or operand.ty.managed.kind != .GcPtr)
                return self.fail(args[0].at, "GC.root requires a GC pointer", .{});
            const declaration = runtime.declarations.get("GcRoot").?;
            const root_type = (try self.resolveZig(.{ .file = runtime, .name = "GcRoot", .node = declaration.node }, at)).type_value.?;
            return .{ .ty = root_type, .expr = self.memoryCall("rootGc", &.{ try self.runtimeExpr(receiver, at), try self.runtimeExpr(operand, at) }) };
        }
        if (!destroy) {
            const traits = memoryTraits(operand.ty);
            if (gc and traits.drop) return self.fail(args[0].at, "GC objects cannot contain ARC values", .{});
            if ((heap or arena) and traits.drop) return self.fail(args[0].at, "manual allocations cannot contain automatically released ARC values", .{});
            if (!gc and traits.trace) return self.fail(args[0].at, "this allocation cannot contain GC values", .{});
            if (arc or gc) {
                const allocation_type = self.managedType(if (arc) .ArcPtr else .GcPtr, operand.ty);
                const manager_expr = try self.runtimeExpr(receiver, at);
                const payload = try self.ownedExpr(operand, args[0].at);
                if (arc and operand.ty == .structure) {
                    if (direct(operand.ty.structure, "arc_deinit")) |member| {
                        if (member.data != .method) return self.fail(at, "arc_deinit must be a method", .{});
                        const method = member.data.method;
                        if (!isMethod(method) or method.sig.params.len != 1 or !method.sig.result.is(.void))
                            return self.fail(at, "arc_deinit requires only self: *Self and a void result", .{});
                        const closure = try self.runtimeExpr(.{ .ty = .{ .function = method.sig }, .function = method, .context = operand.context }, at);
                        return .{ .ty = allocation_type, .expr = self.memoryCall("createArcWithHook", &.{ manager_expr, payload, closure }) };
                    }
                }
                return .{ .ty = allocation_type, .expr = self.memoryCall(if (arc) "createArc" else "createGc", &.{ manager_expr, payload }) };
            }
        }
        const method = self.foreignMemberDecl(manager, name).?.decl.reference.?;
        var operands: std.ArrayList(*const ir.Expr) = .empty;
        self.append(&operands, try self.runtimeExpr(receiver, at));
        if (!destroy) self.append(&operands, self.irExpr(.{ .type_value = self.lowerType(operand.ty) }));
        self.append(&operands, try self.runtimeExpr(operand, args[0].at));
        const expression = self.irExpr(.{ .foreign_call = .{ .target = method, .args = operands.items, .site = self.foreignCallSite(at) } });
        if (destroy) {
            if (operand.ty != .pointer and !(operand.ty == .foreign_pointer and operand.ty.foreign_pointer.size == .one and !operand.ty.foreign_pointer.is_const))
                return self.fail(args[0].at, "destroy requires a mutable object pointer", .{});
            return .{ .ty = void_type, .expr = expression };
        }
        const pointer: Type = if (operand.ty == .structure)
            .{ .pointer = operand.ty.structure }
        else
            .{ .foreign_pointer = .{ .child = self.make(operand.ty), .is_const = false } };
        return .{ .ty = pointer, .expr = self.irExpr(.{ .unwrap_allocation = expression }) };
    }

    /// 通过 Zig 系统文件和声明名称识别 std.mem.Allocator，避免接受用户同名类型。
    fn isZigAllocator(ty: Type) bool {
        return ty == .foreign and ty.foreign.decl.file.system and
            same(ty.foreign.decl.name, "Allocator") and same(std.fs.path.basename(ty.foreign.decl.file.path), "mem.zig");
    }

    /// 从具体或嵌入的 manager 查找 allocator 方法，仅对可寻址实例生成隐式转换调用。
    fn managerAllocator(self: *Analyzer, value: Value, owner: ?*Shape, at: usize) Error!?Value {
        const store = self.zig_store orelse return null;
        const runtime = store.runtime orelse return null;
        var base = value;
        if (value.ty == .structure or value.ty == .pointer) {
            const shape = try self.baseShape(value, at);
            const found = (try self.lookup(shape, "allocator", at)) orelse return null;
            const manager = found.foreign_receiver orelse return null;
            if (manager.decl.file != runtime or !allowed(found, owner, shape)) return null;
            base = .{
                .ty = .{ .foreign = manager },
                .expr = self.access(self.objectExpr(value), found.path),
                .writable = value.writable or value.ty == .pointer,
            };
        }
        const manager = switch (base.ty) {
            .foreign => |ty| ty,
            .foreign_pointer => |ptr| if (ptr.size == .one and ptr.child.* == .foreign) ptr.child.foreign else return null,
            else => return null,
        };
        if (manager.decl.file != runtime) return null;
        const method = self.foreignMemberDecl(manager, "allocator") orelse return null;
        if (!try self.isForeignLvalue(base, at)) return self.fail(at, "implicit Zig allocator conversion requires a manager lvalue", .{});
        const callable = try self.resolveZig(method.decl, at);
        const receiver = try self.foreignReceiver(base, callable.ty.function.params[0], at);
        return try self.invoke(callable, &.{receiver}, at);
    }

    /// 区分四种具体内存策略，用于按 manager 确定分配结果的指针表示。
    const ManagerPolicy = enum { heap, arena, arc, gc };

    /// 核对运行库来源和类型名称，将 manager 值或指针映射到具体内存策略。
    fn managerPolicy(self: *Analyzer, ty: Type) ?ManagerPolicy {
        const candidate = if (ty == .foreign_pointer) ty.foreign_pointer.child.* else ty;
        if (candidate != .foreign) return null;
        const runtime = (self.zig_store orelse return null).runtime orelse return null;
        if (candidate.foreign.decl.file != runtime) return null;
        const name = candidate.foreign.decl.name;
        if (same(name, "Heap")) return .heap;
        if (same(name, "Arena")) return .arena;
        if (same(name, "Arc")) return .arc;
        if (same(name, "GC")) return .gc;
        return null;
    }

    /// 保存嵌入 manager 的具体类型及子对象路径，供抽象接口实参转换使用。
    const ManagerPath = struct { ty: *ForeignType, path: []const Text };

    /// 递归搜索可访问的嵌入 manager，只有唯一匹配路径时才返回结果。
    fn embeddedManager(self: *Analyzer, shape: *Shape, owner: ?*Shape, at: usize) Error!?ManagerPath {
        var result: ?ManagerPath = null;
        for (shape.members) |*member| {
            if (member.data != .field or !member.data.field.embedded) continue;
            const found: Found = .{ .member = member, .path = &.{}, .visibility = member.visibility, .declaring = shape };
            if (!allowed(found, owner, shape)) continue;
            const member_type = member.data.field.ty;
            const candidate: ManagerPath = switch (member_type) {
                .foreign => if (self.managerPolicy(member_type) != null)
                    .{ .ty = member_type.foreign, .path = &.{} }
                else
                    continue,
                .structure => (try self.embeddedManager(member_type.structure, owner, at)) orelse continue,
                else => continue,
            };
            if (result != null) return self.fail(at, "ambiguous use path to memory Manager", .{});
            result = .{ .ty = candidate.ty, .path = self.prepend(member.name, candidate.path) };
        }
        return result;
    }

    /// 将具体 manager 或包含它的结构投影为可写实例指针，用于 Manager 参数的静态特化。
    fn abstractManager(self: *Analyzer, value: Value, owner: ?*Shape, at: usize) Error!Value {
        var base = value;
        if (value.ty == .structure or value.ty == .pointer) {
            const shape = try self.baseShape(value, at);
            const candidate = (try self.embeddedManager(shape, owner, at)) orelse
                return self.fail(at, "expected a structure containing a memory Manager", .{});
            base = .{
                .ty = .{ .foreign = candidate.ty },
                .expr = self.access(self.objectExpr(value), candidate.path),
                .writable = value.writable or value.ty == .pointer,
            };
        }
        if (self.managerPolicy(base.ty) == null) return self.fail(at, "expected a memory Manager implementation", .{});
        if (base.ty == .foreign_pointer) {
            if (base.ty.foreign_pointer.size != .one or base.ty.foreign_pointer.is_const)
                return self.fail(at, "Manager requires a mutable instance pointer", .{});
            return base;
        }
        if (!base.writable or !isLvalueExpression(base.expr.?)) return self.fail(at, "Manager requires a mutable instance", .{});
        const candidate = base.ty;
        base.ty = .{ .foreign_pointer = .{ .child = self.make(candidate), .is_const = false } };
        base.expr = self.irExpr(.{ .address = base.expr.? });
        return base;
    }

    /// 按分配策略选择 ArcPtr、GcPtr 或普通对象指针，解析关联返回类型。
    fn allocationPointer(self: *Analyzer, policy: ManagerPolicy, child: Type) Type {
        return switch (policy) {
            .arc => self.managedType(.ArcPtr, child),
            .gc => self.managedType(.GcPtr, child),
            .heap, .arena => if (child == .structure)
                .{ .pointer = child.structure }
            else
                .{ .foreign_pointer = .{ .child = self.make(child), .is_const = false } },
        };
    }

    /// 检查具体对象指针能否满足只读 Ptr 约束，沿嵌入路径协变投影并保持托管所有者。
    fn abstractPointer(self: *Analyzer, original: Value, child: Type, owner: ?*Shape, at: usize) Error!Value {
        var value = original;
        if (value.ty == .foreign_pointer and value.ty.foreign_pointer.size == .one and value.ty.foreign_pointer.child.* == .managed) {
            value.ty = value.ty.foreign_pointer.child.*;
            value.expr = self.irExpr(.{ .dereference = value.expr.? });
        }
        const target: Type = switch (value.ty) {
            .pointer => |shape| .{ .structure = shape },
            .foreign_pointer => |ptr| if (ptr.size == .one) ptr.child.* else return self.fail(at, "expected a single-object pointer", .{}),
            .managed => |ptr| switch (ptr.kind) {
                .ArcPtr, .GcPtr => ptr.child.*,
                .View => if (ptr.child.* == .pointer) .{ .structure = ptr.child.pointer } else return self.fail(at, "expected an object address view", .{}),
                else => return self.fail(at, "expected a strong object pointer", .{}),
            },
            else => return self.fail(at, "expected a concrete object pointer", .{}),
        };
        value.pointer_readonly = true;
        if (target.equal(child)) return value;
        if (target != .structure or child != .structure)
            return self.fail(at, "pointer target {s} cannot be viewed as {s}", .{ self.typeName(target), self.typeName(child) });
        const path = (try self.importPath(target.structure, child.structure, owner, at)) orelse
            return self.fail(at, "no use path for pointer covariance from {s} to {s}", .{ self.typeName(target), self.typeName(child) });
        var setup: Body = .empty;
        if (value.ty == .managed) {
            value = try self.stageManaged(&setup, value, at);
            value = if (value.ty.managed.kind == .View) self.unpackMemoryView(value) else try self.managedPointee(value, at);
        }
        const storage = if (value.ty == .pointer) self.storageExpr(value) else self.irExpr(.{ .dereference = value.expr.? });
        const addr = self.irExpr(.{ .address = self.access(storage, path) });
        var projected = try self.packMemoryView(.{ .ty = .{ .pointer = child.structure }, .expr = addr, .memory_owner = value.memory_owner }, at);
        projected.pointer_readonly = true;
        return self.wrapManagedScope(setup, projected);
    }

    /// 检查静态 Ptr 回调的输入逆变兼容性，记录目标签名供调用时再次转换参数。
    fn convertStaticPointerCallback(self: *Analyzer, value: Value, target: *Signature, owner: ?*Shape, at: usize) Error!Value {
        if (value.ty != .function or value.function == null)
            return self.fail(at, "Ptr callback requires a statically known function", .{});
        const source = value.static_callback orelse value.ty.function;
        if (source.params.len != target.params.len or source.context_parameter != target.context_parameter or
            source.result_manager != null or target.result_manager != null or !source.result.equal(target.result))
            return self.fail(at, "incompatible Ptr callback signature", .{});
        for (source.params, target.params) |input, required| {
            if (input.equal(required)) continue;
            if (pointerConstraint(input) and pointerConstraint(required)) {
                const accepted = input.managed.child.*;
                const supplied = required.managed.child.*;
                if (accepted == .structure and supplied == .structure and
                    (try self.importPath(supplied.structure, accepted.structure, owner, at)) != null) continue;
            }
            return self.fail(at, "Ptr callback input is not contravariantly compatible", .{});
        }
        var result = value;
        result.static_callback = target;
        return result;
    }

    /// 对普通结构指针回调生成逆变适配函数，在参数进入原函数前投影嵌入子对象。
    fn adaptPointerCallback(self: *Analyzer, value: Value, target: *Signature, owner: ?*Shape, at: usize) Error!?Value {
        if (value.ty != .function or value.ty.function.equal(target)) return null;
        const source = value.ty.function;
        const callback = value.function orelse return null;
        if (source.params.len != target.params.len or source.context_parameter != target.context_parameter or
            source.result_manager != null or target.result_manager != null or !source.result.equal(target.result)) return null;
        const params = self.a.alloc(ir.Slot, target.params.len) catch @panic("out of memory");
        const operands = self.a.alloc(*const ir.Expr, target.params.len) catch @panic("out of memory");
        var changed = false;
        for (source.params, target.params, params, operands, 0..) |input, required, *slot, *operand, index| {
            const name = self.fmt("__saphine_variant_arg_{d}", .{index});
            slot.* = .{ .name = name, .ty = self.lowerType(required) };
            operand.* = self.irExpr(.{ .variable = name });
            if (input.equal(required)) continue;
            if (input != .pointer or required != .pointer) return null;
            const path = (try self.importPath(required.pointer, input.pointer, owner, at)) orelse return null;
            operand.* = self.irExpr(.{ .address = self.access(self.irExpr(.{ .dereference = operand.* }), path) });
            changed = true;
        }
        if (!changed) return null;
        const original = try self.exactInstance(callback, at);
        const adapter = self.id();
        const invocation = self.irExpr(.{ .call = .{
            .target = .{ .direct = original.id },
            .args = operands,
            .context = self.irExpr(.forward_context),
        } });
        const statement: ir.Stmt = if (target.result.is(.void)) .{ .expr = invocation } else .{ .ret = invocation };
        self.append(&self.bodies, ir.Function{
            .id = adapter,
            .params = params,
            .result = self.lowerType(target.result),
            .body = self.make([1]ir.Stmt{statement}),
        });
        self.append(&self.symbols, naming.Symbol{ .id = adapter, .name = self.fmt("{s}__ptr_variance", .{callback.name}), .source = self.span(at, 1) });
        return .{ .ty = .{ .function = target }, .expr = self.irExpr(.{ .function_address = .{ .id = adapter, .context = self.callableContext(value) } }) };
    }

    /// 按形参规则转换实参，处理 manager、只读指针、回调及 use 投影，保留特化所需信息。
    fn convertArgument(self: *Analyzer, value: Value, ty: Type, owner: ?*Shape, at: usize) Error!Value {
        if (self.managerConstraint(ty)) return self.abstractManager(value, owner, at);
        if (staticPointerCallback(ty)) return self.convertStaticPointerCallback(value, ty.function, owner, at);
        if (ty == .function) {
            if (try self.adaptPointerCallback(value, ty.function, owner, at)) |adapted| return adapted;
        }
        if (ty == .managed and ty.managed.kind == .Ptr) return self.abstractPointer(value, ty.managed.child.*, owner, at);
        if (value.pointer_readonly and (value.ty == .pointer or value.ty == .foreign_pointer or value.ty == .managed))
            return self.fail(at, "read-only Ptr cannot be converted to a mutable pointer", .{});
        if (value.memory_owner != null and (value.ty == .pointer or value.ty == .foreign_pointer))
            return self.expect(value, ty, at);
        if (ty == .zig_callback and value.ty == .function) {
            const callback = ty.zig_callback;
            if (!callback.signature.equal(value.ty.function)) return self.fail(at, "Zig callback signature mismatch", .{});
            if (value.foreign_function) |reference| {
                if (value.foreign_c_abi != callback.c_abi) return self.fail(at, "Zig callback calling convention mismatch", .{});
                return .{ .ty = ty, .expr = self.irExpr(.{ .address = self.irExpr(.{ .foreign_ref = reference }) }) };
            }
            const function_value = value.function orelse return self.fail(at, "Zig callback requires a statically known, non-capturing function", .{});
            const instance_value = try self.exactInstance(function_value, at);
            const symbol = self.id();
            const params = self.a.alloc(ir.Slot, callback.signature.params.len) catch @panic("out of memory");
            const args = self.a.alloc(*const ir.Expr, params.len) catch @panic("out of memory");
            for (params, args, callback.signature.params, 0..) |*param, *arg, parameter_ty, index| {
                param.* = .{ .name = self.fmt("arg_{d}", .{index}), .ty = self.lowerType(parameter_ty) };
                arg.* = self.irExpr(.{ .variable = param.name });
            }
            const expression = self.irExpr(.{ .call = .{ .target = .{ .direct = instance_value.id }, .args = args } });
            self.append(&self.bodies, ir.Function{
                .id = symbol,
                .params = params,
                .result = self.lowerType(callback.signature.result),
                .c_abi = callback.c_abi,
                .body = self.make([1]ir.Stmt{.{ .ret = expression }}),
            });
            self.append(&self.symbols, naming.Symbol{ .id = symbol, .name = self.fmt("{s}__zig_callback", .{function_value.name}), .source = self.span(at, 1) });
            self.requested_callbacks.put(self.a, instance_value.id, at) catch @panic("out of memory");
            return .{ .ty = ty, .expr = self.irExpr(.{ .callback_address = symbol }) };
        }
        if (ty != .structure and ty != .pointer) return self.expect(value, ty, at);
        if (value.ty != .structure and value.ty != .pointer) return self.expect(value, ty, at);
        if (ty == .structure and value.ty != .structure) return self.expect(value, ty, at);
        const visible = try self.baseShape(value, at);
        const target = if (ty == .structure) ty.structure else ty.pointer;
        const path = (try self.importPath(visible, target, owner, at)) orelse
            return self.fail(at, "no use path from S{d} to S{d}", .{ visible.id, target.id });
        const actual = if (value.view) |v| v.shape else visible;
        var full = path;
        if (value.view) |v| {
            full = std.mem.concat(self.a, Text, &.{ v.path, path }) catch @panic("out of memory");
        }
        var converted = value;
        converted.ty = ty;
        converted.view = if (actual == target) null else .{ .shape = actual, .path = full };
        if (ty == .pointer and value.ty == .structure) {
            if (!value.writable) return self.fail(at, "pointer argument requires a mutable lvalue", .{});
            converted.expr = self.irExpr(.{ .address = value.expr.? });
        }
        return converted;
    }

    /// 对静态多态视图恢复底层实际结构类型，供存储布局和函数特化区分使用。
    fn actualType(value: Value) Type {
        if (value.view) |v| {
            return if (value.ty == .pointer) .{ .pointer = v.shape } else .{ .structure = v.shape };
        }
        return value.ty;
    }

    /// 比较影响特化的类型、视图、来源和约束信息，而不按普通运行时数值区分实例。
    fn sameInstance(a: Value, b: Value) bool {
        if (!actualType(a).equal(actualType(b)) or a.pointer_readonly != b.pointer_readonly) return false;
        if ((a.static_callback == null) != (b.static_callback == null)) return false;
        if (a.static_callback) |signature_type| {
            if (a.function != b.function or !signature_type.equal(b.static_callback.?)) return false;
        }
        if ((a.memory_owner != null) != (b.memory_owner != null)) return false;
        if (a.view) |av| {
            const bv = b.view orelse return false;
            if (av.path.len != bv.path.len) return false;
            for (av.path, bv.path) |x, y| if (!same(x, y)) return false;
        } else if (b.view != null) return false;
        if (a.origin) |origin| {
            const other = b.origin orelse return false;
            if (origin.shape != other.shape or origin.path.len != other.path.len) return false;
            for (origin.path, other.path) |x, y| if (!same(x, y)) return false;
        } else if (b.origin != null) return false;

        if (a.type_value) |ty| return b.type_value != null and ty.equal(b.type_value.?);
        return b.type_value == null;
    }

    /// 复用参数特征相同的函数特化，否则分配新实例并将运行时函数加入待分析队列。
    fn instance(self: *Analyzer, f: *Function, args: []const Value, at: usize) Error!*Instance {
        if (f.ast.body == null) return self.fail(at, "abstract function cannot be called directly", .{});
        for (f.instances.items) |existing| {
            for (existing.args, args) |a, b| {
                if (!sameInstance(a, b)) break;
            } else return existing;
        }
        if (self.serial >= 10000)
            return self.fail(at, "prototype specialization limit exceeded", .{});
        const item = self.make(Instance{
            .id = self.id(),
            .specialization_site = self.span(at, 1),
            .function = f,
            .args = self.a.dupe(Value, args) catch @panic("out of memory"),
            .result = if (f.sig.result_manager) |index|
                self.allocationPointer(self.managerPolicy(args[index].ty) orelse return self.fail(at, "unresolved return Manager", .{}), f.sig.result)
            else
                f.sig.result,
        });
        self.append(&f.instances, item);
        if (!f.sig.result.is(.type)) self.append(&self.pending, item);
        return item;
    }

    /// 按声明签名取得不需调用处信息的特化，拒绝含类型参数或抽象内存约束的函数。
    fn exactInstance(self: *Analyzer, f: *Function, at: usize) Error!*Instance {
        for (f.sig.params) |param| {
            if (self.managerConstraint(param) or pointerConstraint(param) or staticPointerCallback(param))
                return self.fail(at, "memory interface requires a statically specialized call", .{});
        }
        const args = self.a.alloc(Value, f.sig.params.len) catch @panic("out of memory");
        for (args, f.sig.params) |*a, p| {
            if (p.is(.type) or f.sig.result.is(.type)) return self.fail(at, "compile-time function requires a statically known callee", .{});
            a.* = .{ .ty = p };
        }
        return self.instance(f, args, at);
    }

    /// 递归比较外部引用的模块、名称和父路径，用于复用同一外部函数的适配器。
    fn sameForeignRef(a: ir.ForeignRef, b: ir.ForeignRef) bool {
        if (a.module != b.module or !same(a.name, b.name)) return false;
        if (a.parent) |parent| return b.parent != null and sameForeignRef(parent.*, b.parent.?.*);
        return b.parent == null;
    }

    /// 将语义值转换为可生成的运行时表达式，为函数值建立适配器并拒绝运行时类型值。
    fn runtimeExpr(self: *Analyzer, value: Value, at: usize) Error!*const ir.Expr {
        if (value.foreign_function) |reference| {
            for (self.foreign_adapters.items) |adapter| {
                if (sameForeignRef(adapter.target, reference))
                    return self.irExpr(.{ .function_address = .{ .id = adapter.symbol } });
            }
            const symbol = self.id();
            self.append(&self.foreign_adapters, ForeignAdapter{ .target = reference, .symbol = symbol });
            const sig = value.ty.function;
            const parameters = self.a.alloc(ir.Slot, sig.params.len) catch @panic("out of memory");
            const operands = self.a.alloc(*const ir.Expr, sig.params.len) catch @panic("out of memory");
            for (sig.params, parameters, operands, 0..) |ty, *parameter, *operand, index| {
                parameter.* = .{ .name = self.fmt("arg_{d}", .{index}), .ty = self.lowerType(ty) };
                operand.* = self.irExpr(.{ .variable = parameter.name });
            }
            const call_expr = self.irExpr(.{ .foreign_call = .{ .target = reference, .args = operands, .site = self.foreignCallSite(at) } });
            self.append(&self.bodies, ir.Function{ .id = symbol, .params = parameters, .result = self.lowerType(sig.result), .body = self.make([1]ir.Stmt{.{ .ret = call_expr }}) });
            self.append(&self.symbols, naming.Symbol{ .id = symbol, .name = self.fmt("{s}__closure_adapter", .{reference.name}), .source = self.span(at, 1) });
            return self.irExpr(.{ .function_address = .{ .id = symbol } });
        }
        if (value.type_value) |ty| if (ty == .structure and ty.structure.zig_file != null)
            return self.fail(at, "Zig module namespaces are compile-time only", .{});
        if (value.function) |f| return self.irExpr(.{ .function_address = .{
            .id = (try self.exactInstance(f, at)).id,
            .context = self.callableContext(value),
        } });
        if (value.ty.is(.type)) return self.fail(at, "type values are compile-time only", .{});
        return value.expr.?;
    }

    /// 生成外部、直接或间接调用；返回 type 的函数立即分析并返回编译期类型结果。
    fn invoke(self: *Analyzer, callable: Value, args: []const Value, at: usize) Error!Value {
        const sig = callable.ty.function;
        if (callable.foreign_function) |target| {
            var operands: std.ArrayList(*const ir.Expr) = .empty;
            for (args) |arg| self.append(&operands, try self.runtimeExpr(arg, at));
            return .{ .ty = sig.result, .expr = self.irExpr(.{ .foreign_call = .{ .target = target, .args = operands.items, .site = self.foreignCallSite(at) } }) };
        }
        var result_type = sig.result;
        const target: @FieldType(@FieldType(ir.Expr, "call"), "target") = if (callable.function) |f| blk: {
            const item = try self.instance(f, args, at);
            result_type = item.result;
            if (sig.result.is(.type)) {
                for (args) |arg| if (!arg.ty.is(.type)) return self.fail(at, "type-returning functions accept only type arguments", .{});
                if (item.evaluating) return self.fail(at, "recursive compile-time type evaluation", .{});
                if (item.type_result == null) try self.analyzeFunction(item);
                var result = typeValue(item.type_result.?);
                result.context = if (item.type_context) |context| self.rebindContext(context, self.callableContext(callable), args) else self.callableContext(callable);

                return result;
            }
            break :blk .{ .direct = item.id };
        } else blk: {
            for (sig.params) |param| {
                if (self.managerConstraint(param) or pointerConstraint(param) or staticPointerCallback(param))
                    return self.fail(at, "memory interface requires a statically specialized call", .{});
            }
            for (args) |arg| if (arg.view != null or arg.ty.is(.type))
                return self.fail(at, "polymorphic call requires a statically known function", .{});
            break :blk .{ .indirect = callable.expr.? };
        };
        var operands: std.ArrayList(*const ir.Expr) = .empty;
        for (args) |arg| {
            if (arg.static_callback != null) {
                self.append(&operands, self.callableContext(arg) orelse self.irExpr(.null_context));
                continue;
            }
            if (!arg.ty.is(.type)) self.append(&operands, try self.runtimeExpr(arg, at));
            if (arg.memory_owner) |memory_owner| {
                if (arg.ty == .pointer and callable.function != null) self.append(&operands, memory_owner);
            }
        }
        const expression = self.irExpr(.{ .call = .{ .target = target, .args = operands.items, .context = if (callable.function != null) self.callableContext(callable) else null } });
        return .{ .ty = result_type, .expr = expression };
    }

    /// 创建关联容器成员表的作用域包装，并指定独立的词法父作用域。
    fn memberScope(self: *Analyzer, state: *ContainerState, parent: ?*Scope) *Scope {
        return self.make(Scope{ .parent = parent, .container = state, .member_scope = state.scope });
    }

    /// 为新结构版本复制函数定义，更新 Self 签名和本地容器，保留原声明的词法环境。
    fn rebase(self: *Analyzer, f: *Function, old: *Shape, new: *Shape) Error!*Function {
        // Only source-level Self changes version. Resolved explicit aliases and
        // array lengths must not be re-evaluated in a later lexical environment.
        const sig = if (f.owner == old) self.rebaseSignature(f.sig, f.ast, old, new) else f.sig;
        const local = old.file != null and f.file == old.file;
        const updated = self.make(Function{ .name = f.name, .ast = f.ast, .sig = sig, .at = f.at, .owner = if (f.owner == old) new else f.owner, .declaration_scope = if (local and new.file != null) self.memberScope(new.file.?, if (f.declaration_scope) |lexical| lexical.parent else null) else f.declaration_scope, .file = if (local) new.file else f.file });
        if (f.ast.body != null) self.append(&self.functions, updated);
        return updated;
    }

    /// 递归替换上下文表达式中旧结构的对象编号，使新版本使用自己的接收者存储。
    fn versionReceiver(self: *Analyzer, expression: *const ir.Expr, old: *Shape, new: *Shape) *const ir.Expr {
        return switch (expression.*) {
            .module_object => |shape_id| if (shape_id == old.id) self.irExpr(.{ .module_object = new.id }) else expression,
            .module_cast => |cast| self.irExpr(.{ .module_cast = .{ .shape = if (cast.shape == old.id) new.id else cast.shape, .context = self.versionReceiver(cast.context, old, new) } }),
            .field => |field| self.irExpr(.{ .field = .{ .base = self.versionReceiver(field.base, old, new), .name = field.name } }),
            .address => |child| self.irExpr(.{ .address = self.versionReceiver(child, old, new) }),
            .dereference => |child| self.irExpr(.{ .dereference = self.versionReceiver(child, old, new) }),
            .object_context => |child| self.irExpr(.{ .object_context = self.versionReceiver(child, old, new) }),
            else => expression,
        };
    }

    /// 结合原签名语法更新参数和结果中的 Self，保留上下文与关联 manager 约定。
    fn rebaseSignature(self: *Analyzer, sig: *Signature, ast: syn.Function, old: *Shape, new: *Shape) *Signature {
        const params = self.a.dupe(Type, sig.params) catch @panic("out of memory");
        for (params, ast.params) |*param, syntax| param.* = self.rebaseType(param.*, syntax.ty, old, new);
        const result_syntax = if (sig.result_manager != null) ast.result.data.call.args[0] else ast.result;
        return self.make(Signature{ .params = params, .result = self.rebaseType(sig.result, result_syntax, old, new), .context_parameter = sig.context_parameter, .result_manager = sig.result_manager });
    }

    /// 仅按源码中的 Self 递归替换类型版本，不重新求值显式别名及数组长度。
    fn rebaseType(self: *Analyzer, ty: Type, syntax: *Expr, old: *Shape, new: *Shape) Type {
        return switch (syntax.data) {
            .name => |name| if (same(name, "Self") and ty == .structure and ty.structure == old) .{ .structure = new } else ty,
            .unary => |u| if (u.op == .star and ty == .pointer and u.operand.data == .name and same(u.operand.data.name, "Self") and ty.pointer == old)
                .{ .pointer = new }
            else if (u.op == .question and ty == .optional)
                .{ .optional = self.make(self.rebaseType(ty.optional.*, u.operand, old, new)) }
            else
                ty,
            .call => |type_call| if (ty == .managed and type_call.args.len == 1)
                self.managedType(ty.managed.kind, self.rebaseType(ty.managed.child.*, type_call.args[0], old, new))
            else
                ty,
            .array_type => |array| if (ty == .array) .{ .array = .{ .length = ty.array.length, .element = self.make(self.rebaseType(ty.array.element.*, array.element, old, new)) } } else ty,
            .slice => |slice| if (ty == .slice) .{ .slice = .{ .is_const = ty.slice.is_const, .element = self.make(self.rebaseType(ty.slice.element.*, slice.element, old, new)) } } else ty,
            .function => |function_ast| if (ty == .function) .{ .function = self.rebaseSignature(ty.function, function_ast, old, new) } else ty,
            else => ty,
        };
    }

    /// 添加结构成员时创建新版本，复制旧成员及初始化信息并调整方法上下文，最后重绑类型。
    fn evolve(self: *Analyzer, scope: *Scope, binding: *Binding, name: Text, rhs: *Expr, out: *Body, owner: ?*Shape, in_function: bool, at: usize) Error!void {
        const old = binding.value.type_value orelse return self.fail(at, "expected type value", .{});
        if (old == .foreign or (old == .structure and old.structure.zig_file != null))
            return self.fail(at, "cannot extend a Zig type or module namespace", .{});
        if (old != .structure) return self.fail(at, "only structure types have editable members", .{});
        if (direct(old.structure, name) != null) return self.fail(at, "duplicate member '{s}'", .{name});
        const inherited = try self.lookup(old.structure, name, at);
        if (inherited) |found| {
            if (!allowed(found, owner, old.structure)) return self.fail(at, "inaccessible member '{s}'", .{name});
        }
        const s = self.newShape();
        s.name = old.structure.name;
        s.version = old.structure.version + 1;
        s.source = old.structure.source;
        if (old.structure.file) |original| {
            const state = self.make(ContainerState{ .module = original.module, .scope = self.make(Scope{ .parent = original.scope.parent }), .shape = s, .object = self.irExpr(.{ .module_object = s.id }), .initializer = self.id(), .parent = original.parent });
            state.scope.container = state;
            for (original.initialization.items) |step| {
                const keep = switch (step) {
                    .field => |field| !same(field.name, name),
                    .embedded => |field| !same(field.name, name),
                    .statement => true,
                };
                if (!keep) continue;
                var copy = step;
                if (copy == .embedded) if (copy.embedded.context) |context| {
                    copy.embedded.context = self.versionReceiver(context, old.structure, s);
                };
                self.append(&state.initialization, copy);
            }
            s.file = state;
        }
        // A version can combine inherited methods and new overrides declared in
        // different modules. Preserve each method's lexical instance separately.
        const old_context = binding.value.context;
        const new_context = if (self.current_file) |file| self.irExpr(.{ .address = file.object }) else old_context;

        var method_contexts: std.ArrayList(MethodContext) = .empty;
        var redeclarations: std.ArrayList(Redeclaration) = .empty;
        for (old.structure.redeclarations) |r| {
            if (!same(r.name, name)) self.append(&redeclarations, r);
        }
        s.redeclarations = redeclarations.items;
        var members: std.ArrayList(Member) = .empty;
        for (old.structure.members) |m| {
            if (same(m.name, name)) continue;
            var copy = m;
            switch (m.data) {
                .method => |f| {
                    copy.data.method = try self.rebase(f, old.structure, s);
                    self.append(&method_contexts, MethodContext{ .name = m.name, .context = if (f.file == old.structure.file) null else self.methodContext(old.structure, m.name, old_context) });
                },
                .operator => |f| {
                    copy.data.operator = try self.rebase(f, old.structure, s);
                    self.append(&method_contexts, MethodContext{ .name = m.name, .context = if (f.file == old.structure.file) null else self.methodContext(old.structure, m.name, old_context) });
                },
                .value => |stored| {
                    if (stored.function) |function_value| if (function_value.file == old.structure.file) {
                        copy.data.value.function = try self.rebase(function_value, old.structure, s);
                        copy.data.value.ty = .{ .function = copy.data.value.function.?.sig };
                    };
                    if (stored.context) |context| copy.data.value.context = self.versionReceiver(context, old.structure, s);
                    if (stored.expr) |expression| copy.data.value.expr = self.versionReceiver(expression, old.structure, s);
                },
                else => {},
            }
            self.append(&members, copy);
        }
        self.setMembers(s, members.items);
        var value = try self.eval(scope, rhs, null, s);
        if (value.function) |f| {
            if (f.sig.params.len != 0 and f.sig.params[0] == .pointer and f.sig.params[0].pointer == old.structure) {
                const method = try self.rebase(f, old.structure, s);
                value = .{ .ty = .{ .function = method.sig }, .function = method, .context = value.context };
            }
        }
        const data: @FieldType(Member, "data") = blk: {
            if (std.meta.stringToEnum(Operator, name)) |op| {
                const f = value.function orelse return self.fail(at, "{s} requires a function", .{name});
                try self.checkOperator(op, f, s, at);
                break :blk .{ .operator = f };
            }
            if (value.type_value) |ty| {
                if (ty.is(.void) or ty.is(.type) or (ty == .structure and (ty.structure == s or ty.structure.zig_file != null)))
                    return self.fail(at, "invalid instance field type", .{});
                break :blk .{ .field = .{ .ty = ty } };
            }
            if (value.function) |f| if (isMethod(f)) break :blk .{ .method = f };
            if (value.ty.is(.void)) return self.fail(at, "static member cannot have type void", .{});
            var stored = value;
            if (value.function == null) {
                if (in_function) return self.fail(at, "runtime static members must be assigned at top level", .{});
                const container = self.current_file orelse return self.fail(at, "static member requires a declaration container", .{});
                const storage_name = self.fmt("__static{d}", .{self.id()});
                stored.expr = self.access(container.object, &.{storage_name});
                self.append(&container.static_fields, Member{ .name = storage_name, .visibility = .private, .data = .{ .field = .{ .ty = value.ty, .file_mutable = false, .has_default = true } } });
                self.append(&container.initialization, Initialization{ .field = .{ .name = storage_name, .value = rhs } });
                self.append(out, ir.Stmt{ .assign = .{ .target = stored.expr.?, .value = value.expr.?, .initialize = true } });
                stored.writable = false;
            }
            break :blk .{ .value = stored };
        };
        if (data == .method or data == .operator) {
            self.append(&method_contexts, MethodContext{ .name = name, .context = value.context orelse new_context });
        }
        s.method_contexts = method_contexts.items;
        self.append(&members, Member{ .name = name, .visibility = if (inherited) |found| found.visibility else .public, .data = data });
        self.setMembers(s, members.items);
        if (s.file) |state| {
            var bindings = old.structure.file.?.scope.bindings.iterator();
            while (bindings.next()) |entry| {
                var copy = entry.value_ptr.*.*;
                if (direct(s, entry.key_ptr.*)) |member| switch (member.data) {
                    .field => |field| {
                        copy.value.ty = field.ty;
                        copy.value.expr = self.access(state.object, &.{member.name});
                        copy.value.function = null;
                        copy.value.type_value = null;
                        if (same(member.name, name)) copy.value.constant_int = null;
                    },
                    .method, .operator => |function_value| copy.value = .{ .ty = .{ .function = function_value.sig }, .function = function_value },
                    .value => |stored| copy.value = stored,
                };
                if (copy.value.context) |context| copy.value.context = self.versionReceiver(context, old.structure, s);
                state.scope.bindings.put(self.a, entry.key_ptr.*, self.make(copy)) catch @panic("out of memory");
            }
            if (!state.scope.bindings.contains(name)) {
                const stored: Value = switch (data) {
                    .field => |field| .{ .ty = field.ty, .expr = self.access(state.object, &.{name}), .writable = field.file_mutable },
                    .method, .operator => |function_value| .{ .ty = .{ .function = function_value.sig }, .function = function_value },
                    .value => |member_value| member_value,
                };
                state.scope.bindings.put(self.a, name, self.make(Binding{ .value = stored, .mutable = stored.writable })) catch @panic("out of memory");
            }
            _ = try self.initializerFor(state, &.{});
        }
        var declarations: std.ArrayList(syn.Field) = .empty;
        var parents: std.ArrayList(?*Scope) = .empty;
        for (old.structure.declarations, old.structure.declaration_parents) |field, parent| {
            self.append(&declarations, field);
            self.append(&parents, parent);
        }
        self.append(&parents, self.lexicalScope(scope));
        if (data == .field or data == .method or data == .operator) {
            self.append(&declarations, syn.Field{ .name = .{ .tag = .name, .text = name, .at = at }, .ty = rhs, .embedded = false });
        } else {
            const token: syn.Token = .{ .tag = .name, .text = name, .at = at };
            const declaration = self.make(Stmt{ .at = at, .data = .{ .binding = .{ .name = token, .mutable = false, .ty = null, .value = rhs, .visibility = .public } } });
            self.append(&declarations, syn.Field{ .name = token, .ty = rhs, .embedded = false, .declaration = declaration });
        }
        s.declarations = declarations.items;
        s.declaration_parents = parents.items;
        binding.value.type_value = .{ .structure = s };
        binding.value.context = new_context;
    }

    /// 记录局部指针直接或通过 defer 释放的情况，用于提示明显的重复 Heap.destroy。
    const DestroyState = struct { deferred: bool = false, destroyed: bool = false };

    /// 识别针对局部变量的 Heap.destroy，累计直接／延迟释放标记并去重输出警告。
    fn noteDestroy(self: *Analyzer, states: *std.StringHashMapUnmanaged(DestroyState), expression: *const ir.Expr, deferred: bool, at: usize) void {
        const runtime = (self.zig_store orelse return).runtime orelse return;
        const file = self.current_file orelse return;
        if (expression.* != .foreign_call) return;
        const target = expression.foreign_call.target;
        if (target.module != runtime.id or !same(target.name, "destroy")) return;
        const parent = target.parent orelse return;
        if (!same(parent.name, "Heap")) return;
        const arg = expression.foreign_call.args[1];
        if (arg.* != .variable) return;
        const result = states.getOrPut(self.a, arg.variable) catch @panic("out of memory");
        if (!result.found_existing) result.value_ptr.* = .{};
        const state = result.value_ptr;
        const message: ?Text = if ((deferred and state.destroyed) or (!deferred and state.deferred))
            "Heap.destroy can release the same pointer both directly and through defer"
        else if ((deferred and state.deferred) or (!deferred and state.destroyed))
            "repeated Heap.destroy on the same pointer"
        else
            null;
        if (deferred) state.deferred = true else state.destroyed = true;
        if (message) |warning| {
            for (self.warnings.items) |existing| if (existing.at == at and same(existing.path, file.module.path)) return;
            self.append(&self.warnings, Warning{ .path = file.module.path, .source = file.module.source, .at = at, .message = warning });
        }
    }

    /// 按顺序检查语句并追加 IR，维护绑定、类型演化和控制流状态，返回是否已终止返回。
    fn block(self: *Analyzer, scope: *Scope, stmts: []Stmt, out: *Body, item: ?*Instance, depth: usize) Error!bool {
        const owner = if (item) |i| i.function.owner orelse if (i.function.file) |file| file.shape else null else if (self.current_file) |file| file.shape else null;
        const top = item == null and depth == 1;
        var returned = false;
        var destroys: std.StringHashMapUnmanaged(DestroyState) = .empty;
        for (stmts) |stmt| {
            switch (stmt.data) {
                .block, .conditional, .matching, .loop, .for_each => destroys.clearRetainingCapacity(),
                else => {},
            }
            if (returned) return self.fail(stmt.at, "unreachable statement after return", .{});
            const type_only = if (item) |i| i.function.sig.result.is(.type) else false;
            if (type_only and stmt.data == .expr)
                return self.fail(stmt.at, "compile-time type function cannot execute a runtime expression", .{});
            switch (stmt.data) {
                .use => return self.fail(stmt.at, "use is a structure member declaration", .{}),
                .visibility_redeclaration => return self.fail(stmt.at, "visibility redeclarations require a structure scope", .{}),
                .binding => |b| {
                    if (b.visibility != .public) return self.fail(stmt.at, "visibility modifiers require a structure member declaration", .{});
                    if (scope.bindings.contains(b.name.text)) return self.fail(b.name.at, "duplicate binding '{s}'", .{b.name.text});
                    const annotation = if (b.ty) |t| try self.eval(scope, t, meta_type, owner) else null;
                    const ty = if (annotation) |value| value.type_value orelse return self.fail(b.name.at, "expected a compile-time type value", .{}) else null;
                    const previous_context = self.expected_context;
                    self.expected_context = if (annotation) |value| value.context else null;
                    defer self.expected_context = previous_context;
                    const previous_hint = self.declaration_hint;
                    self.declaration_hint = b.name;
                    defer self.declaration_hint = previous_hint;
                    var value = try self.eval(scope, b.value, ty, owner);
                    if (ty) |t| value = try self.expect(value, t, b.value.at) else if (value.memory_owner != null and (value.ty == .pointer or value.ty == .foreign_pointer))
                        value = try self.packMemoryView(value, b.value.at);
                    if (value.ty.is(.void)) return self.fail(stmt.at, "cannot bind a void value", .{});
                    if (type_only and !value.ty.is(.type))
                        return self.fail(stmt.at, "compile-time type function requires type bindings", .{});
                    if (!value.ty.is(.type) and ((value.function == null and value.foreign_function == null) or b.mutable)) {
                        const code = try self.ownedExpr(value, b.value.at);
                        const name = if (top) self.fmt("__saphine_global_{d}", .{self.id()}) else self.localName(b.name.text);
                        const slot: ir.Slot = .{ .name = name, .ty = self.lowerType(actualType(value)) };
                        value.expr = self.irExpr(.{ .variable = name });
                        if (top and self.current_file != null and scope == self.current_file.?.scope) {
                            value.expr = self.access(self.current_file.?.object, &.{b.name.text});
                            self.append(out, ir.Stmt{ .assign = .{ .target = value.expr.?, .value = code, .initialize = true } });
                            self.guardMemory(out, value.expr.?, value.ty, false);
                        } else if (top) {
                            self.append(&self.globals_ir, slot);
                            self.append(out, ir.Stmt{ .assign = .{ .target = value.expr.?, .value = code, .initialize = true } });
                            self.guardMemory(out, value.expr.?, value.ty, false);
                        } else {
                            self.append(out, self.localValue(slot, code, b.mutable, actualType(value)));
                        }
                        value.function = null;
                        value.foreign_function = null;
                    }
                    if (b.mutable) value.constant_int = null;
                    value.writable = b.mutable;
                    scope.bindings.put(self.a, b.name.text, self.make(Binding{ .value = value, .mutable = b.mutable })) catch @panic("out of memory");
                },
                .assign => |a| {
                    const base = if (a.left.data == .member) a.left.data.member.base else a.left;
                    if (base.data == .name) {
                        if (scope.get(base.data.name)) |b| {
                            if (b.value.type_value != null and !(b.value.type_value.? == .structure and b.value.type_value.?.structure.zig_file != null and a.left.data == .member and a.right.data != .structure)) {
                                if (scope.runtime_branch) return self.fail(stmt.at, "cannot modify a type binding in a runtime branch", .{});
                                if (!b.mutable) return self.fail(stmt.at, "cannot modify const binding '{s}'", .{base.data.name});
                                if (a.op != .equal and !(a.op == .plus_equal and a.right.data == .structure)) return self.fail(stmt.at, "type extension requires a member declaration", .{});
                                if (item != null and self.globals.get(base.data.name) == b)
                                    return self.fail(stmt.at, "cannot modify a top-level type binding inside a function", .{});
                                if (a.left.data == .member) {
                                    try self.evolve(scope, b, a.left.data.member.name, a.right, out, owner, item != null, stmt.at);
                                } else {
                                    if (a.op == .plus_equal and (b.value.type_value.? == .foreign or
                                        (b.value.type_value.? == .structure and b.value.type_value.?.structure.zig_file != null)))
                                        return self.fail(stmt.at, "cannot extend a Zig type or module namespace", .{});
                                    const target = if (b.value.type_value.? == .structure) b.value.type_value.?.structure else null;
                                    const value = if (a.right.data == .structure)
                                        try self.structure(scope, a.right.data.structure, target)
                                    else
                                        try self.eval(scope, a.right, meta_type, owner);
                                    b.value = try self.expect(value, meta_type, a.right.at);
                                }
                                continue;
                            }
                        }
                    }
                    if (a.op == .plus_equal and a.right.data == .structure)
                        return self.fail(stmt.at, "only structure type bindings can be extended", .{});
                    if (type_only) return self.fail(stmt.at, "compile-time type function requires type assignment", .{});
                    if (a.left.data == .name) {
                        if (scope.get(a.left.data.name)) |binding| if (!binding.mutable) return self.fail(stmt.at, "cannot modify const binding '{s}'", .{a.left.data.name});
                    }
                    var left = try self.eval(scope, a.left, null, owner);
                    if (left.view != null or !left.writable or left.expr == null or (a.left.data != .name and a.left.data != .member and a.left.data != .index))
                        return self.fail(stmt.at, "assignment requires a mutable lvalue", .{});
                    const previous_context = self.expected_context;
                    if (left.ty == .structure) self.expected_context = self.memberContext(left, &.{});
                    defer self.expected_context = previous_context;
                    const compound = a.op.compoundOperator();
                    if (left.expr.?.* == .variable) _ = destroys.remove(left.expr.?.variable);
                    var target = left.expr.?;
                    var setup: Body = .empty;
                    if (left.memory_owner) |memory_owner| {
                        const pin: Value = .{
                            .ty = self.managedType(.View, .{ .primitive = .u8 }),
                            .expr = self.memoryCall("pinOwner", &.{memory_owner}),
                        };
                        _ = try self.stageManaged(&setup, pin, a.left.at);
                    }
                    if (left.memory_owner != null or (compound != null and target.* != .variable)) {
                        const name = self.localName("__saphine_destination");
                        const destination: Type = .{ .foreign_pointer = .{ .child = self.make(left.ty), .is_const = false } };
                        self.append(&setup, self.localValue(.{ .name = name, .ty = self.lowerType(destination) }, self.irExpr(.{ .address = target }), false, destination));
                        target = self.irExpr(.{ .dereference = self.irExpr(.{ .variable = name }) });
                    }
                    left.expr = target;
                    const operand = try self.eval(scope, a.right, left.ty, owner);
                    const next = if (compound) |operator|
                        try self.binary(left, operand, operator, owner, stmt.at)
                    else
                        try self.expect(operand, left.ty, a.right.at);
                    const replacement = try self.ownedExpr(next, a.right.at);
                    const assignment = if (memoryTraits(left.ty).drop)
                        ir.Stmt{ .managed_assign = .{ .target = target, .value = replacement, .module = self.memoryModule() } }
                    else
                        ir.Stmt{ .assign = .{ .target = target, .value = replacement } };
                    if (setup.items.len == 0) {
                        self.append(out, assignment);
                    } else {
                        self.append(&setup, assignment);
                        self.append(out, ir.Stmt{ .block = setup.items });
                    }
                },
                .ret => |r| {
                    const inst = item orelse return self.fail(stmt.at, "return outside a function", .{});
                    const ty = inst.result;
                    const previous_context = self.expected_context;
                    if (ty == .structure) if (self.selfReceiver(scope, ty.structure)) |receiver| {
                        self.expected_context = self.memberContext(receiver, &.{});
                    };
                    defer self.expected_context = previous_context;
                    if (r) |expr| {
                        const value = try self.expect(try self.eval(scope, expr, ty, owner), ty, expr.at);
                        if (ty.is(.type)) {
                            inst.type_result = value.type_value orelse return self.fail(stmt.at, "expected compile-time type result", .{});
                            inst.type_context = value.context;
                        } else {
                            const result = try self.ownedExpr(value, expr.at);
                            self.append(out, ir.Stmt{ .ret = if (inst.result_root) |root| self.preserveResult(root, result) else result });
                        }
                    } else {
                        if (!ty.is(.void)) return self.fail(stmt.at, "return value required", .{});
                        self.append(out, ir.Stmt{ .ret = null });
                    }
                    returned = true;
                },
                .using => |e| {
                    if (item == null or type_only) return self.fail(stmt.at, "using requires a runtime function", .{});
                    var manager = try self.eval(scope, e, null, owner);
                    const operand = try self.runtimeExpr(manager, e.at);
                    switch (manager.ty) {
                        .structure, .foreign => {
                            if (!manager.writable or !isLvalueExpression(operand))
                                return self.fail(e.at, "using requires an addressable manager", .{});
                            const pointee = manager.ty;
                            manager.ty = if (pointee == .structure)
                                .{ .pointer = pointee.structure }
                            else
                                .{ .foreign_pointer = .{ .child = self.make(pointee), .is_const = false } };
                            manager.expr = self.irExpr(.{ .address = operand });
                        },
                        .pointer, .foreign_pointer => {},
                        else => return self.fail(e.at, "using requires a manager structure", .{}),
                    }
                    const name = self.localName("__saphine_manager");
                    self.append(out, ir.Stmt{ .local = .{
                        .slot = .{ .name = name, .ty = self.lowerType(actualType(manager)) },
                        .mutable = false,
                        .value = manager.expr.?,
                    } });
                    manager.expr = self.irExpr(.{ .variable = name });
                    scope.default_manager = manager;
                },
                .defer_expr => |e| {
                    if (item == null or type_only) return self.fail(stmt.at, "defer requires a runtime function", .{});
                    const value = try self.eval(scope, e, void_type, owner);
                    if (!value.ty.is(.void)) return self.fail(e.at, "deferred expression must return void", .{});
                    const expression = try self.runtimeExpr(value, e.at);
                    self.noteDestroy(&destroys, expression, true, stmt.at);
                    self.append(out, ir.Stmt{ .defer_expr = expression });
                },
                .expr => |e| {
                    const value = try self.eval(scope, e, null, owner);
                    if (!value.ty.is(.void)) return self.fail(e.at, "expression statement must return void", .{});
                    self.noteDestroy(&destroys, value.expr.?, false, stmt.at);
                    self.append(out, ir.Stmt{ .expr = value.expr.? });
                },
                .loop, .for_each => {
                    if (type_only) return self.fail(stmt.at, "runtime loop is unavailable in a type-returning function", .{});
                    var child: Scope = .{ .parent = scope, .instance = item, .runtime_branch = true, .in_loop = true };
                    var body: Body = .empty;
                    if (stmt.data == .loop) {
                        const loop = stmt.data.loop;
                        const cond = try self.condition(scope, loop.condition, owner);
                        _ = try self.block(&child, loop.body, &body, item, depth + 1);
                        self.append(out, ir.Stmt{ .loop = .{ .condition = cond, .body = body.items, .first = if (loop.post_test) self.id() else null } });
                    } else {
                        const loop = stmt.data.for_each;
                        var items = try self.eval(scope, loop.items, null, owner);
                        var setup: Body = .empty;
                        if (memoryTraits(items.ty).active()) items = try self.stageManaged(&setup, items, loop.items.at);
                        items = self.unpackMemoryView(items);
                        if (items.ty != .array and items.ty != .slice and !items.ty.is(.bytes)) return self.fail(loop.items.at, "for expects an array or slice", .{});
                        const name = self.localName(loop.name.text);
                        const element: Type = if (items.ty == .array) items.ty.array.element.* else if (items.ty == .slice) items.ty.slice.element.* else .{ .primitive = .u8 };
                        const value: Value = .{ .ty = element, .expr = self.irExpr(.{ .variable = name }) };
                        child.bindings.put(self.a, loop.name.text, self.make(Binding{ .value = value, .mutable = false })) catch @panic("out of memory");
                        _ = try self.block(&child, loop.body, &body, item, depth + 1);
                        const statement: ir.Stmt = .{ .for_each = .{ .name = name, .index_name = self.fmt("__saphine_index_{d}", .{self.id()}), .items = try self.runtimeExpr(items, loop.items.at), .body = body.items } };
                        if (setup.items.len != 0) {
                            self.append(&setup, statement);
                            self.append(out, ir.Stmt{ .block = setup.items });
                        } else self.append(out, statement);
                    }
                },
                .loop_exit => |exit| {
                    if (!scope.in_loop) return self.fail(stmt.at, "break and continue require an enclosing loop", .{});
                    self.append(out, ir.Stmt{ .loop_exit = if (exit == .stop) .stop else .next });
                    returned = true;
                },
                .matching => |match| {
                    const checked = try self.matching(scope, match, null, owner, stmt.at, depth);
                    returned = checked.returns;
                    if (checked.setup.items.len == 0) {
                        self.append(out, ir.Stmt{ .matching = checked.lowered });
                    } else {
                        var setup = checked.setup;
                        self.append(&setup, ir.Stmt{ .matching = checked.lowered });
                        self.append(out, ir.Stmt{ .block = setup.items });
                    }
                },
                .conditional => |cond| {
                    if (type_only) return self.fail(stmt.at, "runtime if is unavailable in a type-returning function", .{});
                    const test_expr = try self.condition(scope, cond.condition, owner);
                    const yes = try self.checkBranch(scope, cond.yes, null, owner, depth);
                    const no = if (cond.no) |branch| try self.checkBranch(scope, branch, null, owner, depth) else null;
                    returned = yes.returns and no != null and no.?.returns;
                    self.append(out, ir.Stmt{ .conditional = .{
                        .test_expr = test_expr,
                        .yes = yes.lowered,
                        .no = if (no) |n| n.lowered else null,
                    } });
                },
                .block => |stmts_inner| {
                    var child: Scope = .{ .parent = scope, .instance = item, .runtime_branch = scope.runtime_branch, .in_loop = scope.in_loop };
                    var body: Body = .empty;
                    returned = try self.block(&child, stmts_inner, &body, item, depth + 1);
                    self.append(out, ir.Stmt{ .block = body.items });
                },
            }
        }
        return returned;
    }

    /// 按具体实参建立函数作用域，分析函数体并检查返回值，输出特化函数或编译期类型结果。
    fn analyzeFunction(self: *Analyzer, item: *Instance) Error!void {
        item.evaluating = true;
        defer item.evaluating = false;
        const f = item.function;
        const previous_file = self.current_file;
        const previous_context = self.expected_context;
        self.current_file = f.file;
        self.expected_context = null;
        defer {
            self.current_file = previous_file;
            self.expected_context = previous_context;
        }
        const saved_local_names = self.local_names;
        self.local_names = .empty;
        defer self.local_names = saved_local_names;
        var scope: Scope = .{ .parent = f.declaration_scope orelse &self.globals, .instance = item };
        var body: Body = .empty;
        if (memoryTraits(item.result).trace) item.result_root = self.resultRoot(&body, item.result);
        var params: std.ArrayList(ir.Slot) = .empty;
        for (item.args, f.ast.params, 0..) |a, p, index| {
            var value = a;
            if (a.static_callback != null) {
                const context_name = self.localName(p.name.text);
                self.append(&params, ir.Slot{ .name = context_name, .ty = .erased_context });
                value.context = self.irExpr(.{ .variable = context_name });
                scope.bindings.put(self.a, p.name.text, self.make(Binding{ .value = value, .mutable = false })) catch @panic("out of memory");
                continue;
            }
            value.function = null;
            value.constant_int = null;
            value.writable = a.ty == .structure or (a.ty == .foreign and a.ty.foreign.kind == .structure);
            if (!a.ty.is(.type)) {
                const name = self.localName(p.name.text);
                const input = if (value.writable) self.localName(self.fmt("{s}_arg", .{name})) else name;
                const ty = self.lowerType(actualType(a));
                value.expr = self.irExpr(.{ .variable = name });
                self.append(&params, ir.Slot{ .name = input, .ty = ty });
                if (value.writable) {
                    var argument = value;
                    argument.expr = self.irExpr(.{ .variable = input });
                    self.append(&body, self.localValue(.{ .name = name, .ty = ty }, try self.ownedExpr(argument, f.at), true, actualType(value)));
                }
            }
            scope.bindings.put(self.a, p.name.text, self.make(Binding{ .value = value, .mutable = false })) catch @panic("out of memory");
            if (f.sig.context_parameter == index) scope.default_manager = value;
            if (a.memory_owner != null and a.ty == .pointer) {
                const owner_name = self.localName("__saphine_owner");
                self.append(&params, ir.Slot{ .name = owner_name, .ty = .{ .foreign = .{ .module = self.memoryModule(), .name = "ViewOwner" } } });
                scope.bindings.get(p.name.text).?.value.memory_owner = self.irExpr(.{ .variable = owner_name });
            }
        }
        const returned = try self.block(&scope, f.ast.body.?, &body, item, 1);
        if (!returned and !item.result.is(.void)) return self.fail(f.at, "missing return value", .{});
        if (!item.result.is(.type)) {
            var key: std.ArrayList(u8) = .empty;
            for (item.args, f.sig.params) |arg, param| {
                const ty = arg.type_value orelse actualType(arg);
                if (arg.type_value == null and ty.equal(param)) continue;
                key.appendSlice(self.a, "__") catch @panic("out of memory");
                key.appendSlice(self.a, self.stableTypeName(ty)) catch @panic("out of memory");
            }
            const name = if (f.owner) |shape| self.fmt("{s}__{s}{s}", .{ shape.name, f.name, key.items }) else self.fmt("{s}{s}", .{ f.name, key.items });
            self.append(&self.symbols, naming.Symbol{
                .id = item.id,
                .name = name,
                .owner = if (f.file) |file| file.shape.name else "",
                .source = self.span(f.at, 1),
                .specialization = if (key.items.len != 0) item.specialization_site else null,
            });
            self.append(&self.bodies, ir.Function{
                .id = item.id,
                .params = params.items,
                .result = self.lowerType(item.result),
                .body = body.items,
            });
        }
    }

    /// 根据当前文件的字节偏移计算源码范围和行列，单字符范围按 UTF-8 字符长度扩展。
    fn span(self: *Analyzer, start: usize, len: usize) ?naming.SourceSpan {
        const file = self.current_file orelse return null;
        const offset = @min(start, file.module.source.len);
        const before = file.module.source[0..offset];
        const token_length = if (len == 1 and offset < file.module.source.len)
            std.unicode.utf8ByteSequenceLength(file.module.source[offset]) catch 1
        else
            len;
        const line = std.mem.count(u8, before, "\n") + 1;
        const column = if (std.mem.lastIndexOfScalar(u8, before, '\n')) |newline| before.len - newline else before.len + 1;
        return .{ .path = file.module.path, .start = offset, .end = @min(offset + token_length, file.module.source.len), .line = line, .column = column };
    }

    /// 避开保留名称并用后缀消除局部重名，同时登记所有生成名称供后端分配全局名称。
    fn localName(self: *Analyzer, declared: Text) Text {
        var name = if (std.mem.startsWith(u8, declared, "__saphine_") or same(declared, "_") or same(declared, "keep") or
            same(declared, "std") or same(declared, "arithmetic") or same(declared, "makeRange") or same(declared, "Closure"))
            self.fmt("local_{s}", .{declared})
        else
            declared;
        const base = name;
        var variant: usize = 1;
        while (self.local_names.contains(name)) : (variant += 1)
            name = self.fmt("{s}__{d}", .{ base, variant });
        self.local_names.put(self.a, name, {}) catch @panic("out of memory");
        self.all_local_names.put(self.a, name, {}) catch @panic("out of memory");
        return name;
    }

    /// 以声明名称、版本及复合类型组成生成稳定类型名，避免依赖临时编号命名特化。
    fn stableTypeName(self: *Analyzer, ty: Type) Text {
        return switch (ty) {
            .structure => |shape| if (shape.version == 0) shape.name else self.fmt("{s}__v{d}", .{ shape.name, shape.version + 1 }),
            .enumeration => |shape| shape.name,
            .pointer => |shape| self.fmt("ptr_{s}", .{self.stableTypeName(.{ .structure = shape })}),
            .array => |array| self.fmt("array{d}_{s}", .{ array.length, self.stableTypeName(array.element.*) }),
            .slice => |slice| self.fmt("{s}slice_{s}", .{ if (slice.is_const) "const_" else "", self.stableTypeName(slice.element.*) }),
            else => self.typeName(ty),
        };
    }

    /// 判断函数能否仅凭声明签名检查，排除类型工厂、方法和需要具体实参的约束。
    fn canCheckWithoutCall(self: *Analyzer, f: *Function) bool {
        // Type factories and staged structure members are checked when used.
        if (f.owner != null or f.sig.result.is(.type)) return false;
        for (f.sig.params) |param| {
            if (param.is(.type) or self.managerConstraint(param) or pointerConstraint(param) or staticPointerCallback(param)) return false;
            const shape = switch (param) {
                .structure => |shape| shape,
                .pointer => |shape| shape,
                else => continue,
            };
            const saved = self.diag.*;
            self.validate(shape, shape, &.{}, f.at) catch {
                self.diag.* = saved;
                return false;
            };
        }
        return true;
    }

    /// 将相对声明模块的上下文表达式重绑到使用处实例，避免静态成员别名固定到某次嵌入。
    fn rebindContext(self: *Analyzer, expression: *const ir.Expr, context: ?*const ir.Expr, _: ?[]const Value) *const ir.Expr {
        return switch (expression.*) {
            .module_object => |shape| if (context) |bound| self.irExpr(.{ .module_cast = .{ .shape = shape, .context = bound } }) else expression,

            .address => |child| self.irExpr(.{ .address = self.rebindContext(child, context, null) }),
            .dereference => |child| self.irExpr(.{ .dereference = self.rebindContext(child, context, null) }),
            .object_context => |child| self.irExpr(.{ .object_context = self.rebindContext(child, context, null) }),
            .field => |field| self.irExpr(.{ .field = .{ .base = self.rebindContext(field.base, context, null), .name = field.name } }),
            .module_cast => |cast| self.irExpr(.{ .module_cast = .{ .shape = cast.shape, .context = self.rebindContext(cast.context, context, null) } }),
            else => expression,
        };
    }

    /// 核对当前方法所属结构和首参数类型，返回作用域中对应的 Self 接收者。
    fn selfReceiver(self: *Analyzer, scope: *Scope, shape: *Shape) ?Value {
        _ = self;
        const item = scope.instance orelse return null;
        const f = item.function;
        if (f.owner != shape or f.sig.params.len == 0) return null;
        const first = f.sig.params[0];
        if ((first == .pointer and first.pointer == shape) or (first == .structure and first.structure == shape)) {
            return scope.get(f.ast.params[0].name.text).?.value;
        }
        return null;
    }

    /// 查找方法单独保留的声明环境，并相对当前对象重绑；没有记录时沿用给定上下文。
    fn methodContext(self: *Analyzer, shape: *Shape, name: Text, context: ?*const ir.Expr) ?*const ir.Expr {
        for (shape.method_contexts) |method| if (same(method.name, name)) {
            return if (method.context) |stored| self.rebindContext(stored, context, null) else context;
        };
        return context;
    }

    /// 沿分发路径确定方法所属子对象，区分本地声明与捕获环境后恢复调用上下文。
    fn receiverContext(self: *Analyzer, base: Value, path: []const Text, name: Text) ?*const ir.Expr {
        var shape = if (base.view) |view| view.shape else if (base.ty == .pointer) base.ty.pointer else base.ty.structure;
        for (path) |part| shape = direct(shape, part).?.data.field.ty.structure;
        const object = self.access(self.storageExpr(base), path);
        const member = direct(shape, name);
        const declaration = if (member) |m| switch (m.data) {
            .method, .operator => |function_value| function_value.file,
            else => null,
        } else null;
        const context = if (shape.file != null and declaration == shape.file) self.irExpr(.{ .address = object }) else self.irExpr(.{ .object_context = object });
        return self.methodContext(shape, name, context);
    }

    /// 根据成员路径取得子对象的声明上下文，类型值沿用已有环境，实例使用对象地址或环境字段。
    fn memberContext(self: *Analyzer, base: Value, path: []const Text) ?*const ir.Expr {
        if (base.ty.is(.type)) return base.context;
        const object = self.access(self.objectExpr(base), path);
        var shape = switch (base.ty) {
            .structure => |s| s,
            .pointer => |s| s,
            else => return base.context,
        };
        if (base.view) |view| shape = view.shape;
        if (base.view) |view| for (view.path) |part| {
            shape = direct(shape, part).?.data.field.ty.structure;
        };
        for (path) |part| shape = direct(shape, part).?.data.field.ty.structure;
        return if (shape.file != null) self.irExpr(.{ .address = object }) else self.irExpr(.{ .object_context = object });
    }

    /// 优先使用函数值绑定的上下文，否则从函数声明容器取得默认对象地址。
    fn callableContext(self: *Analyzer, value: Value) ?*const ir.Expr {
        if (value.context) |context| return context;
        if (value.function) |f| if (f.file) |file| return self.irExpr(.{ .address = file.object });
        return null;
    }

    /// 递归保存词法作用域快照，保留类型和可捕获常量，将不可捕获运行时局部标记为不可用。
    fn lexicalScope(self: *Analyzer, scope: *Scope) *Scope {
        const snapshot = self.make(Scope{ .parent = if (scope.parent) |parent| self.lexicalScope(parent) else null, .container = scope.container });
        var bindings = (scope.member_scope orelse scope).bindings.iterator();
        while (bindings.next()) |entry| {
            const binding = entry.value_ptr.*;
            if (binding.value.ty.is(.type)) {
                snapshot.bindings.put(self.a, entry.key_ptr.*, self.make(binding.*)) catch @panic("out of memory");
            } else if (scope.container != null) {
                snapshot.bindings.put(self.a, entry.key_ptr.*, self.make(binding.*)) catch @panic("out of memory");
            } else if (!binding.mutable and binding.value.constant_int != null) {
                var value = binding.value;
                value.expr = self.irExpr(.{ .number = .{ .ty = value.ty.primitive, .canonical = self.fmt("{d}", .{value.constant_int.?}) } });
                value.writable = false;
                snapshot.bindings.put(self.a, entry.key_ptr.*, self.make(Binding{ .value = value, .mutable = false })) catch @panic("out of memory");
            } else {
                snapshot.bindings.put(self.a, entry.key_ptr.*, self.make(Binding{ .value = binding.value, .mutable = binding.mutable, .unavailable = true })) catch @panic("out of memory");
            }
        }
        return snapshot;
    }

    /// 沿词法作用域解析名称，检查捕获及访问权限，并把外层容器引用重绑到可到达的环境。
    fn lexicalValue(self: *Analyzer, scope: *Scope, name: Text, owner: ?*Shape, at: usize) Error!?Value {
        var cursor: ?*Scope = scope;
        while (cursor) |current| : (cursor = current.parent) {
            const binding = current.local(name) orelse continue;
            if (binding.unavailable) return self.fail(at, "structure cannot capture runtime local '{s}'", .{name});
            var value = binding.value;
            if (value.foreign_function != null or value.zig_generic != null or value.stdlib_print != null) return value;
            if (current.container) |declaring| if (self.current_file) |active| {
                if (declaring != active) {
                    if (try self.lookup(declaring.shape, name, at)) |found| if (!allowed(found, owner, declaring.shape)) return self.fail(at, "inaccessible member '{s}'", .{name});
                    var source: ?*ContainerState = active;
                    var context: *const ir.Expr = self.irExpr(.{ .address = active.object });
                    while (source) |container| {
                        if (container == declaring) break;
                        context = self.irExpr(.{ .object_context = self.irExpr(.{ .module_cast = .{ .shape = container.shape.id, .context = context } }) });
                        source = container.parent;
                    }
                    if (source != null) {
                        if (value.expr) |expression| value.expr = self.rebindContext(expression, context, null);
                        value.context = if (value.context) |stored| self.rebindContext(stored, context, null) else context;
                    } else if (value.constant_int) |integer| {
                        value.expr = self.irExpr(.{ .number = .{ .ty = value.ty.primitive, .canonical = self.fmt("{d}", .{integer}) } });
                    } else if (!value.ty.is(.type)) {
                        // No runtime environment for this unrelated instance is
                        // carried by the current fixed-layout object ABI.
                        return self.fail(at, "structure cannot capture runtime member '{s}' from an unrelated container", .{name});
                    }
                }
            };
            if (value.ty == .structure and value.view == null) value.origin = null;
            return value;
        }
        return null;
    }

    /// 从当前容器查找提升成员，核对可见性后以该容器对象构造成员值。
    fn promotedMember(self: *Analyzer, container: *ContainerState, name: Text, owner: ?*Shape, at: usize) Error!?Value {
        const found = (try self.lookup(container.shape, name, at)) orelse return null;
        if (!allowed(found, owner, container.shape)) return self.fail(at, "inaccessible member '{s}'", .{name});
        return try self.memberValue(.{ .ty = .{ .structure = container.shape }, .expr = container.object, .writable = true }, found, name, at);
    }

    /// 分析入口文件结构体，分配模块根存储及初始化调用，再完成函数特化和 IR 汇总。
    pub fn analyzeModule(self: *Analyzer, entry: *const FileModule) Error!ir.Module {
        self.zig_entry = entry.path;
        const file = try self.fileStructure(entry, true);
        const root = self.irExpr(.{ .variable = self.fmt("module{d}", .{self.id()}) });
        self.append(&self.globals_ir, ir.Slot{ .name = root.variable, .ty = self.lowerType(.{ .structure = file.shape }) });
        self.entry_context = self.irExpr(.{ .address = root });
        try self.initializeContainer(file, root, null, &self.startup);
        self.guardMemory(&self.startup, root, .{ .structure = file.shape }, true);
        self.current_file = file;
        return self.finish();
    }

    /// 给目标对象写入词法上下文并调用已生成的初始化函数，拒绝尚未就绪的循环初始化。
    fn initializeContainer(self: *Analyzer, file: *ContainerState, target: *const ir.Expr, lexical_context: ?*const ir.Expr, out: *Body) Error!void {
        if (!file.ready) return self.fail(0, "cyclic module initialization", .{});
        self.append(out, ir.Stmt{ .assign = .{ .target = self.irExpr(.{ .object_context = target }), .value = lexical_context orelse self.irExpr(.null_context) } });
        self.append(out, ir.Stmt{ .expr = self.irExpr(.{ .call = .{
            .target = .{ .direct = file.initializer },
            .context = self.irExpr(.{ .address = target }),
            .args = &.{},
        } }) });
    }

    /// 将已加载文件缓存为结构体分析状态，按普通成员规则定义并检查其可默认初始化。
    fn fileStructure(self: *Analyzer, module: *const FileModule, entry: bool) Error!*ContainerState {
        if (self.files.get(module)) |cached| return cached;
        const shape = self.newShape();
        shape.name = std.fs.path.stem(module.path);
        shape.source = .{ .path = module.path, .start = 0, .end = module.source.len };
        const state = self.make(ContainerState{ .module = module, .scope = if (entry) &self.globals else self.make(Scope{}), .shape = shape, .object = self.irExpr(.{ .module_object = shape.id }), .initializer = self.id() });
        shape.file = state;
        self.files.put(self.a, module, state) catch @panic("out of memory");
        try self.defineStructure(state, module.container.data.structure);
        if (!defaultConstructible(shape)) return self.fail(0, "file contains an embedded structure without default initialization", .{});
        return state;
    }

    /// 将内存中的语句包装为匿名文件结构体，复用文件模块分析入口。
    pub fn analyze(self: *Analyzer, stmts: []Stmt) Error!ir.Module {
        const module = self.make(FileModule{ .path = "<source>", .source = "", .statements = stmts, .container = @import("module_loader.zig").normalizeFile(self.a, stmts) catch @panic("out of memory") });
        return self.analyzeModule(module);
    }

    /// 校验 main 并处理待分析特化，检查 Zig 回调捕获，汇总布局、符号及函数为最终 IR 模块。
    fn finish(self: *Analyzer) Error!ir.Module {
        const binding = self.globals.get("main") orelse return self.fail(0, "missing const main = fn() -> void", .{});
        const f = binding.value.function orelse return self.fail(0, "main must be a constant function", .{});
        if (binding.mutable or f.sig.params.len != 0 or !f.sig.result.is(.void))
            return self.fail(f.at, "main must be a constant fn() -> void", .{});
        const entry = try self.instance(f, &.{}, f.at);
        const entry_context = if (binding.value.context) |context| self.rebindContext(context, self.entry_context, null) else self.entry_context;
        var fi: usize = 0;
        var pi: usize = 0;
        while (fi < self.functions.items.len or pi < self.pending.items.len) {
            while (pi < self.pending.items.len) : (pi += 1) try self.analyzeFunction(self.pending.items[pi]);
            if (fi < self.functions.items.len) {
                const fun = self.functions.items[fi];
                fi += 1;
                if (fun.instances.items.len == 0 and self.canCheckWithoutCall(fun)) _ = try self.exactInstance(fun, fun.at);
            }
        }
        if (self.requested_callbacks.count() != 0) {
            const contexts = @import("environments.zig").analyze(self.a, self.bodies.items) catch @panic("out of memory");
            var callbacks = self.requested_callbacks.iterator();
            while (callbacks.next()) |callback| {
                if (contexts.get(callback.key_ptr.*).? != .none)
                    return self.fail(callback.value_ptr.*, "Zig callback cannot capture a saphine environment", .{});
            }
        }
        var layouts: std.ArrayList(ir.Layout) = .empty;
        for (self.shapes.items) |shape| {
            if (shape.zig_file != null) continue;
            var fields: std.ArrayList(ir.Slot) = .empty;
            for (shape.members) |m| if (m.data == .field) {
                self.append(&fields, ir.Slot{ .name = m.name, .ty = self.lowerType(m.data.field.ty) });
            };
            self.append(&self.symbols, naming.Symbol{
                .id = shape.id,
                .name = self.stableTypeName(.{ .structure = shape }),
                .owner = if (shape.source) |source| std.fs.path.stem(source.path) else "",
                .source = shape.source,
                .version = shape.version,
            });
            self.append(&layouts, ir.Layout{ .id = shape.id, .fields = fields.items });
        }
        var enum_layouts: std.ArrayList(ir.EnumLayout) = .empty;
        for (self.enums.items) |shape| {
            var variants: std.ArrayList(ir.EnumVariant) = .empty;
            for (shape.variants) |variant| self.append(&variants, ir.EnumVariant{ .name = variant.name, .ty = if (variant.ty) |ty| self.lowerType(ty) else null });
            self.append(&self.symbols, naming.Symbol{
                .id = shape.id,
                .name = shape.name,
                .source = shape.source,
                .owner = if (shape.source) |source| std.fs.path.stem(source.path) else "",
            });
            self.append(&enum_layouts, ir.EnumLayout{ .id = shape.id, .variants = variants.items });
        }
        for (self.bodies.items) |body| if (body.initializes) |shape_id| {
            for (self.shapes.items) |shape| {
                if (shape.id != shape_id) continue;
                self.append(&self.symbols, naming.Symbol{
                    .id = body.id,
                    .name = self.fmt("{s}__init", .{self.stableTypeName(.{ .structure = shape })}),
                    .owner = shape.name,
                    .source = shape.source,
                });
                break;
            }
        };
        const local_spellings = self.a.alloc(Text, self.all_local_names.count()) catch @panic("out of memory");
        var locals = self.all_local_names.keyIterator();
        for (local_spellings) |*name| name.* = locals.next().?.*;
        return .{
            .symbols = self.symbols.items,
            .local_spellings = local_spellings,
            .call_sites = self.call_sites.items,
            .layouts = layouts.items,
            .enums = enum_layouts.items,
            .globals = self.globals_ir.items,
            .startup = self.startup.items,
            .functions = self.bodies.items,
            .entry = entry.id,
            .entry_context = entry_context,
        };
    }
};
