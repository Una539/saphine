//! 语义分析的数据模型，保存类型、编译期值、作用域和容器初始化信息。
//! 模型之间通过引用保留类型身份与词法关系，供 semantic.zig 构造类型化 IR。

const std = @import("std");
const syn = @import("parser.zig");
const Text = syn.Text;
const Expr = syn.Expr;
const Stmt = syn.Stmt;
const naming = @import("names.zig");
const ir = @import("ir.zig");
const FileModule = @import("module_loader.zig").Module;
const Primitive = ir.Primitive;
const foreign = @import("zig_interop/store.zig");
const ZigAst = std.zig.Ast;

/// 定位外部 Zig 声明，结合文件、AST 节点和容器记录可生成的引用路径。
pub const ForeignDeclaration = struct { file: *foreign.File, name: Text, node: ZigAst.Node.Index, container: ?*ForeignType = null, reference: ?ir.ForeignRef = null };
/// 保存 Zig 类型的身份和访问方式；动态查询得到的类型另外携带反射元数据。
pub const ForeignType = struct {
    decl: ForeignDeclaration,
    node: ZigAst.Node.Index,
    reference: ir.ForeignRef,
    kind: enum { structure, enumeration, union_type, opaque_type, error_set },
    is_factory: bool = false,
    queried: ?struct { expression: *const ir.Expr, type_name: Text, key: Text, metadata: Text } = null,
};
/// 保存尚需按实参解析的 Zig 函数，通过参数 AST 和返回类型节点支持泛型调用。
pub const ZigFunction = struct {
    declaration: ForeignDeclaration,
    reference: ir.ForeignRef,
    parameters: []const Parameter,
    result_node: ZigAst.Node.Index,
    /// 保存 Zig 参数的名称、类型节点与 comptime 标记，供实参替换时使用。
    pub const Parameter = struct { name: ?Text, node: ?ZigAst.Node.Index, comptime_param: bool };
};
/// 关联外部函数和生成的适配函数符号，使 Zig 函数可作为语言函数值使用。
pub const ForeignAdapter = struct { target: ir.ForeignRef, symbol: usize };
/// 保留 Zig 数值常量的文本及整数／浮点类别，待期望类型确定后检查范围。
pub const ZigConstant = struct { source: Text, is_float: bool };
/// 将 Zig 泛型参数名关联到实际语义值，用于解析依赖参数的类型表达式。
pub const ZigSubstitution = struct { name: Text, value: Value };
/// 表示分析阶段的类型；容器用对象身份区分，复合类型递归保存子类型。
pub const Type = union(enum) {
    managed: struct { kind: ir.ManagedKind, child: *const Type, module: usize },
    primitive: Primitive,
    structure: *Shape,
    foreign: *ForeignType,
    foreign_pointer: struct { child: *const Type, is_const: bool, size: std.lang.Type.Pointer.Size = .one, sentinel: ?i128 = null },
    optional: *const Type,
    error_union: struct { errors: *const Type, payload: *const Type },
    enumeration: *EnumShape,
    array: struct { length: usize, element: *const Type, sentinel: ?i128 = null },
    slice: struct { element: *const Type, is_const: bool, sentinel: ?i128 = null },
    pointer: *Shape,
    function: *Signature,
    zig_callback: struct { signature: *Signature, c_abi: bool },

    /// 判断是否为指定基础类型，同时检查联合标签和基础类型枚举值。
    pub fn is(self: Type, p: Primitive) bool {
        return self == .primitive and self.primitive == p;
    }

    /// 比较语义类型；容器比较身份，指针、数组和函数等递归比较组成部分。
    pub fn equal(a: Type, b: Type) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .managed => |m| m.kind == b.managed.kind and m.child.equal(b.managed.child.*),
            .primitive => |p| p == b.primitive,
            .structure => |s| s == b.structure,
            .foreign => |ty| ty == b.foreign,
            .foreign_pointer => |ptr| ptr.size == b.foreign_pointer.size and ptr.sentinel == b.foreign_pointer.sentinel and ptr.is_const == b.foreign_pointer.is_const and ptr.child.equal(b.foreign_pointer.child.*),
            .optional => |child| child.equal(b.optional.*),
            .error_union => |result| result.errors.equal(b.error_union.errors.*) and result.payload.equal(b.error_union.payload.*),
            .enumeration => |e| e == b.enumeration,
            .array => |a_array| a_array.length == b.array.length and a_array.sentinel == b.array.sentinel and a_array.element.equal(b.array.element.*),
            .slice => |s| s.is_const == b.slice.is_const and s.sentinel == b.slice.sentinel and s.element.equal(b.slice.element.*),
            .pointer => |s| s == b.pointer,
            .function => |s| s.equal(b.function),
            .zig_callback => |cb| cb.c_abi == b.zig_callback.c_abi and cb.signature.equal(b.zig_callback.signature),
        };
    }

    /// 利用基础类型枚举的排列范围，判断类型是否为整数或浮点数。
    pub fn numeric(self: Type) bool {
        return self == .primitive and @backingInt(self.primitive) <= @backingInt(Primitive.f128);
    }

    /// 在数值类型范围内进一步判断是否属于浮点类型。
    pub fn float(self: Type) bool {
        return self.numeric() and @backingInt(self.primitive) >= @backingInt(Primitive.f16);
    }
};
pub const i32_type: Type = .{ .primitive = .i32 };
pub const bool_type: Type = .{ .primitive = .bool };
pub const void_type: Type = .{ .primitive = .void };
pub const meta_type: Type = .{ .primitive = .type };

/// 描述函数参数和结果类型，并记录隐式上下文及与 manager 关联的返回类型。
pub const Signature = struct {
    params: []Type,
    result: Type,
    context_parameter: ?usize = null,
    result_manager: ?usize = null,

    /// 比较参数、结果及上下文约定，只有各项一致时签名才相同。
    pub fn equal(a: *Signature, b: *Signature) bool {
        if (a.params.len != b.params.len or a.context_parameter != b.context_parameter or a.result_manager != b.result_manager or !a.result.equal(b.result)) return false;
        for (a.params, b.params) |x, y| if (!x.equal(y)) return false;
        return true;
    }
};

/// 保存一个枚举类型的唯一身份、变体列表及源码位置，供匹配和 IR 布局使用。
pub const EnumShape = struct { id: usize, variants: []EnumVariant, name: Text = "Enumeration", source: ?naming.SourceSpan = null };
/// 描述枚举变体；可选类型表示该变体是否携带载荷。
pub const EnumVariant = struct { name: Text, ty: ?Type };
/// 表示一个具体版本的结构体，组合顺序成员表、持久化名称索引和原始声明。
/// 声明另存词法父作用域，使类型扩展时仍按声明处环境解析保留的成员。
pub const Shape = struct {
    id: usize,
    name: Text = "Structure",
    version: usize = 0,
    source: ?naming.SourceSpan = null,
    members: []Member = &.{},
    member_index: @import("hamt.zig").Hamt(*const Member) = .{},
    declarations: []syn.Field = &.{},
    declaration_parents: []const ?*Scope = &.{},
    redeclarations: []Redeclaration = &.{},
    file: ?*ContainerState = null,
    zig_file: ?*foreign.File = null,
    foreign_instance: ?*ForeignType = null,
    method_contexts: []MethodContext = &.{},
};
/// 为方法名称保存声明环境表达式，供方法绑定和类型演化后恢复上下文。
pub const MethodContext = struct { name: Text, context: ?*const ir.Expr };
/// 记录提升成员的可见性重声明，以嵌入路径定位原成员。
pub const Redeclaration = struct { name: Text, path: []const Text, visibility: syn.Visibility };
/// 统一表示字段、编译期值、方法和运算符，并保存组合与访问控制信息。
pub const Member = struct {
    name: Text,
    embedded_namespace: bool = false,
    visibility: syn.Visibility = .public,
    data: union(enum) {
        field: struct { ty: Type, embedded: bool = false, file_mutable: bool = true, has_default: bool = false },
        value: Value,
        method: *Function,
        operator: *Function,
    },
};
/// 保存函数定义、签名和声明环境；不同实际参数对应的特化缓存在 instances 中。
pub const Function = struct {
    name: Text = "lambda",
    ast: syn.Function,
    sig: *Signature,
    at: usize,
    owner: ?*Shape,
    declaration_scope: ?*Scope = null,
    file: ?*ContainerState = null,
    instances: std.ArrayList(*Instance) = .empty,
};
/// 保存一次函数特化的实参、结果和分析状态，支持复用及编译期类型结果计算。
pub const Instance = struct {
    id: usize,
    function: *Function,
    args: []Value,
    specialization_site: ?naming.SourceSpan = null,
    type_result: ?Type = null,
    type_context: ?*const ir.Expr = null,
    evaluating: bool = false,
    result_root: ?Text = null,
    result: Type,
};
/// 记录静态多态视图的原始结构和嵌入路径，不等同于内存运行库的托管 View。
pub const View = struct { shape: *Shape, path: []const Text };
/// 表达式分析结果，将语义类型、可选运行时 IR 与编译期信息组合保存。
/// 可写性、来源和内存所有者用于后续借用、成员访问及参数转换检查。
pub const Value = struct {
    ty: Type,
    expr: ?*const ir.Expr = null,
    constant_int: ?i128 = null,
    zig_constant: ?ZigConstant = null,
    type_value: ?Type = null,
    function: ?*Function = null,
    foreign_function: ?ir.ForeignRef = null,
    zig_generic: ?*const ZigFunction = null,
    foreign_c_abi: bool = false,
    stdlib_print: ?ir.ForeignRef = null,
    foreign_declaration: ?ForeignDeclaration = null,
    context: ?*const ir.Expr = null,
    memory_owner: ?*const ir.Expr = null,
    pointer_readonly: bool = false,
    static_callback: ?*Signature = null,

    writable: bool = false,
    view: ?View = null,
    origin: ?Origin = null,

    /// 保留成员访问的原始结构及路径，避免通过中间视图绕过访问控制。
    pub const Origin = struct { shape: *Shape, path: []const Text };
};
/// 将名称绑定到语义值，并记录可重新赋值性和初始化期间的不可用状态。
pub const Binding = struct { value: Value, mutable: bool, unavailable: bool = false };
/// 通过父作用域和绑定表组织名称查找，同时记录函数实例、容器及控制流状态。
pub const Scope = struct {
    parent: ?*Scope = null,
    instance: ?*Instance = null,
    runtime_branch: bool = false,
    in_loop: bool = false,
    bindings: std.StringHashMapUnmanaged(*Binding) = .empty,
    container: ?*ContainerState = null,
    member_scope: ?*Scope = null,
    default_manager: ?Value = null,

    /// 向父作用域查找默认 manager，但不跨越函数实例，以免隐式捕获调用者状态。
    pub fn defaultManager(self: *Scope) ?Value {
        if (self.default_manager) |manager| return manager;
        const parent = self.parent orelse return null;
        if (parent.instance != self.instance) return null;
        return parent.defaultManager();
    }

    /// 先查当前绑定，再查关联成员作用域；不继续搜索词法父作用域。
    pub fn local(self: *Scope, name: Text) ?*Binding {
        return self.bindings.get(name) orelse if (self.member_scope) |members| members.bindings.get(name) else null;
    }

    /// 从当前作用域开始递归搜索父作用域，返回首个同名绑定。
    pub fn get(self: *Scope, name: Text) ?*Binding {
        return self.local(name) orelse if (self.parent) |p| p.get(name) else null;
    }
};
/// 保存成员查找结果，包括嵌入路径、实际声明者及 Zig 字段或接收者信息。
pub const Found = struct { member: *const Member, path: []const Text, visibility: syn.Visibility, declaring: *Shape, foreign_field: bool = false, foreign_receiver: ?*ForeignType = null };
pub const Body = std.ArrayList(ir.Stmt);
/// 按源码顺序保留默认初始化步骤，供排除显式初始化字段后重新生成函数。
pub const Initialization = union(enum) {
    field: struct { name: Text, value: *Expr, lexical_parent: ?*Scope = null },
    embedded: struct { name: Text, context: ?*const ir.Expr },
    statement: Stmt,
};
/// 缓存跳过指定默认字段的初始化函数，以显式字段集合区分不同变体。
pub const InitializerVariant = struct { excluded: []const Text, id: usize };
/// 文件与显式结构体共用的定义、作用域和初始化状态。
/// 此记录只保存分析信息；每次嵌入使用调用方提供的子对象地址，不拥有运行时存储。
pub const ContainerState = struct {
    module: *const FileModule,
    scope: *Scope,
    shape: *Shape,
    object: *const ir.Expr,
    initializer: usize,
    ready: bool = false,
    parent: ?*ContainerState = null,
    static_fields: std.ArrayList(Member) = .empty,
    initialization: std.ArrayList(Initialization) = .empty,
    variants: std.ArrayList(InitializerVariant) = .empty,
};
