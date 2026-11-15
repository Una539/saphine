//! 定义 Saphine AST 并通过递归下降和优先级爬升解析 Token，保留声明顺序与源码位置。
const std = @import("std");
const lex = @import("lexer.zig");
pub const Text = lex.Text;
pub const Error = lex.Error;
pub const Tag = lex.Tag;
pub const Token = lex.Token;
pub const Diagnostic = lex.Diagnostic;

/// 表示尚未类型检查的表达式，以联合区分语法形式并引用子表达式。
pub const Expr = struct {
    at: usize,
    data: union(enum) {
        name: Text,
        number: Text,
        string: Text,
        unary: struct { op: Tag, operand: *Expr },
        binary: struct { op: Tag, left: *Expr, right: *Expr },
        member: struct { base: *Expr, name: Text },
        call: struct { callee: *Expr, args: []*Expr },
        object: struct { ty: ?*Expr, fields: []Init },
        structure: []Field,
        enumeration: []EnumVariant,
        matching: Match,
        function: Function,
        slice: struct { element: *Expr, is_const: bool },
        array_type: struct { length: *Expr, element: *Expr },
        array_init: struct { ty: ?*Expr, elements: []*Expr },
        index: struct { base: *Expr, index: *Expr },
        subslice: struct { base: *Expr, start: *Expr, end: ?*Expr },
        conditional: If,
    },
};
/// 保存分支语句和可选尾值，以统一表示语句分支与表达式分支。
pub const Branch = struct { body: []Stmt, tail: ?*Expr = null };
/// 保存条件及两个分支，else 缺失时保留空值供语义分析检查。
pub const If = struct { condition: *Expr, yes: Branch, no: ?Branch };
/// 保存枚举变体名称和可选载荷类型表达式，稍后由语义分析确定类型。
pub const EnumVariant = struct { name: Token, ty: ?*Expr };
/// 区分匹配载荷的名称绑定和下划线丢弃，保留 Token 供定位错误。
pub const MatchPayload = union(enum) { binding: Token, discard: Token };
/// 表示具名变体模式或默认模式，并保存可选的载荷接收方式。
pub const MatchPattern = union(enum) {
    variant: struct { name: Token, payload: ?MatchPayload },
    default: Token,
};
/// 将匹配模式关联到分支体，不在解析阶段检查覆盖性。
pub const MatchArm = struct { pattern: MatchPattern, branch: Branch };
/// 保存匹配主体和有序分支，供后续检查变体及结果类型。
pub const Match = struct { subject: *Expr, arms: []MatchArm };
/// 保存一个具名字段初始化项，延后处理重名及字段类型检查。
pub const Init = struct { name: Token, value: *Expr };
/// 表示声明的三种可见性，语义分析结合嵌入路径决定实际访问权限。
pub const Visibility = enum { public, private, internal };
/// 统一保存字段、嵌入、展开及成员声明，必要时携带原始语句供顺序初始化。
pub const Field = struct {
    name: Token,
    ty: *Expr,
    spread: bool = false,
    embedded: bool,
    visibility: Visibility = .public,
    // For a redeclaration, ty is the name/member path rather than a type.
    redeclaration: bool = false,
    declaration: ?*Stmt = null,
};
/// 保存参数名、类型表达式和上下文标记，类型解析在语义阶段完成。
pub const Param = struct { name: Token, ty: *Expr, context: bool = false };
/// 保存参数、结果类型和可选函数体，以同一结构表示函数类型与函数定义。
pub const Function = struct { params: []Param, result: *Expr, body: ?[]Stmt };
/// 以带位置的联合保存声明、赋值和控制流，不混入类型化 IR 信息。
pub const Stmt = struct {
    at: usize,
    data: union(enum) {
        binding: struct { name: Token, mutable: bool, ty: ?*Expr, value: *Expr, visibility: Visibility = .public },
        visibility_redeclaration: struct { visibility: Visibility, path: *Expr },
        use: struct { name: Token, ty: *Expr, visibility: Visibility = .public },
        assign: struct { left: *Expr, right: *Expr, op: Tag },
        ret: ?*Expr,
        expr: *Expr,
        defer_expr: *Expr,
        using: *Expr,
        block: []Stmt,
        conditional: If,
        matching: Match,
        loop: struct { condition: *Expr, body: []Stmt, post_test: bool },
        for_each: struct { name: Token, items: *Expr, body: []Stmt },
        loop_exit: enum { stop, next },
    },
};

/// 保存单 Token 前瞻及词法器，通过递归解析分配 AST 节点并记录语法错误。
pub const Parser = struct {
    a: std.mem.Allocator,
    diag: *Diagnostic,
    lexer: lex.Lexer,
    token: Token = undefined,

    /// 使用共享诊断对象记录当前位置的语法错误并返回统一源码错误。
    fn fail(self: *Parser, at: usize, comptime fmt: Text, args: anytype) Error {
        return self.diag.fail(self.a, at, fmt, args);
    }

    /// 从词法器读取下一个 Token，推进当前前瞻状态。
    fn next(self: *Parser) Error!void {
        self.token = try self.lexer.next();
    }

    /// 要求当前 Token 为指定类别，匹配后消费，否则在该位置报告错误。
    fn take(self: *Parser, tag: Tag) Error!Token {
        const token = self.token;
        if (token.tag != tag) return self.fail(token.at, "expected {s}, found '{s}'", .{ @tagName(tag), token.text });
        try self.next();
        return token;
    }

    /// 当前 Token 匹配时才消费，供可选语法分支探测使用。
    fn eat(self: *Parser, tag: Tag) Error!bool {
        if (self.token.tag != tag) return false;
        try self.next();
        return true;
    }

    /// 按名称文本识别并消费上下文关键字，避免将其全部固定为独立 Token。
    fn word(self: *Parser, name: Text) Error!bool {
        if (self.token.tag != .name or !std.mem.eql(u8, name, self.token.text)) return false;
        try self.next();
        return true;
    }

    /// 结合后续名称探测可见性修饰符，只在声明形式中消费 public、private 或 internal。
    fn visibility(self: *Parser) Error!?Visibility {
        if (self.token.tag != .name) return null;
        const value: Visibility = if (std.mem.eql(u8, self.token.text, "public")) .public else if (std.mem.eql(u8, self.token.text, "private")) .private else if (std.mem.eql(u8, self.token.text, "internal")) .internal else return null;
        var lookahead = self.lexer;
        if ((try lookahead.next()).tag != .name) return null;
        try self.next();
        return value;
    }

    /// 解析连续名称与点号组成的成员路径，用于可见性重声明。
    fn visibilityPath(self: *Parser) Error!*Expr {
        const name = try self.take(.name);
        var path = self.make(name.at, .{ .name = name.text });
        while (try self.eat(.dot)) {
            const member = try self.take(.name);
            path = self.make(path.at, .{ .member = .{ .base = path, .name = member.text } });
        }
        return path;
    }

    /// 分配带源码位置的表达式节点，将其生命周期交给解析器分配器。
    fn make(self: *Parser, at: usize, data: @FieldType(Expr, "data")) *Expr {
        const node = self.a.create(Expr) catch @panic("out of memory");
        node.* = .{ .at = at, .data = data };
        return node;
    }

    /// 初始化前瞻并解析到文件末尾，返回按源码顺序排列的语句。
    pub fn parse(self: *Parser) Error![]Stmt {
        try self.next();
        return self.statements(.eof);
    }

    /// 持续解析语句直到指定结束 Token，块结束时消费右括号并检查意外 EOF。
    fn statements(self: *Parser, end: Tag) Error![]Stmt {
        var items: std.ArrayList(Stmt) = .empty;
        while (self.token.tag != end) {
            if (self.token.tag == .eof) return self.fail(self.token.at, "expected closing brace", .{});
            items.append(self.a, try self.statement(null, end == .eof)) catch @panic("out of memory");
        }
        if (end != .eof) try self.next();
        return items.items;
    }

    /// 解析声明、赋值和控制流，按上下文识别分支尾值并将字段扩展写法转为结构展开。
    fn statement(self: *Parser, tail: ?*?*Expr, top_level: bool) Error!Stmt {
        const at = self.token.at;
        const access = try self.visibility();
        if (top_level and try self.word("use")) {
            const name = try self.take(.name);
            _ = try self.take(.colon);
            const ty = try self.typeExpr();
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .use = .{ .name = name, .ty = ty, .visibility = access orelse .public } } };
        }
        if (access != null and self.token.tag == .name and
            !std.mem.eql(u8, self.token.text, "var") and !std.mem.eql(u8, self.token.text, "const"))
        {
            if (!top_level) return self.fail(at, "visibility redeclarations are only allowed at top level or in structures", .{});
            const path = try self.visibilityPath();
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .visibility_redeclaration = .{ .visibility = access.?, .path = path } } };
        }
        if (access != null and !(self.token.tag == .name and
            (std.mem.eql(u8, self.token.text, "var") or std.mem.eql(u8, self.token.text, "const"))))
            return self.fail(at, "expected const or var after visibility modifier", .{});
        if (try self.word("using")) {
            const manager = try self.expr(0);
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .using = manager } };
        }
        if (try self.word("defer")) {
            const expression = try self.expr(0);
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .defer_expr = expression } };
        }
        if (tail == null and try self.word("if"))
            return .{ .at = at, .data = .{ .conditional = try self.conditional(false) } };
        if (tail == null and try self.word("match"))
            return .{ .at = at, .data = .{ .matching = try self.matching(false) } };
        if (try self.word("while")) {
            const condition = try self.parenthesized();
            _ = try self.take(.lbrace);
            return .{ .at = at, .data = .{ .loop = .{ .condition = condition, .body = try self.statements(.rbrace), .post_test = false } } };
        }
        if (try self.word("do")) {
            _ = try self.take(.lbrace);
            const body = try self.statements(.rbrace);
            if (!try self.word("while")) return self.fail(self.token.at, "expected while after do block", .{});
            const condition = try self.parenthesized();
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .loop = .{ .condition = condition, .body = body, .post_test = true } } };
        }
        if (try self.word("for")) {
            _ = try self.take(.lparen);
            const name = try self.take(.name);
            if (!try self.word("in")) return self.fail(self.token.at, "expected in after iteration binding", .{});
            const items = try self.expr(0);
            _ = try self.take(.rparen);
            _ = try self.take(.lbrace);
            return .{ .at = at, .data = .{ .for_each = .{ .name = name, .items = items, .body = try self.statements(.rbrace) } } };
        }
        const stop = try self.word("break");
        if (stop or try self.word("continue")) {
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .loop_exit = if (stop) .stop else .next } };
        }
        const mutable = try self.word("var");
        if (mutable or try self.word("const")) {
            const name = try self.take(.name);
            const ty = if (try self.eat(.colon)) try self.typeExpr() else null;
            _ = try self.take(.equal);
            const value = try self.expr(0);
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .binding = .{ .name = name, .mutable = mutable, .ty = ty, .value = value, .visibility = access orelse .public } } };
        }
        if (try self.word("return")) {
            const value = if (self.token.tag == .semicolon) null else try self.expr(0);
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .ret = value } };
        }
        if (try self.eat(.lbrace)) return .{ .at = at, .data = .{ .block = try self.statements(.rbrace) } };
        const left = try self.expr(0);
        const op = self.token.tag;
        if (op == .equal or op.compoundOperator() != null) {
            try self.next();
            var right = try self.expr(0);
            if (op == .plus_equal and right.data == .name and try self.eat(.colon)) {
                const name: Token = .{ .tag = .name, .text = right.data.name, .at = right.at };
                const ty = try self.memberType();
                const fields = self.a.alloc(Field, 2) catch @panic("out of memory");
                fields[0] = .{ .name = name, .ty = right, .embedded = false, .spread = true };
                fields[1] = .{ .name = name, .ty = ty, .embedded = false };
                right = self.make(right.at, .{ .structure = fields });
            }
            _ = try self.take(.semicolon);
            return .{ .at = at, .data = .{ .assign = .{ .left = left, .right = right, .op = op } } };
        }
        if (tail) |slot| {
            if (self.token.tag == .rbrace) {
                slot.* = left;
                return .{ .at = at, .data = .{ .expr = left } };
            }
            if (self.token.tag != .semicolon) {
                if (left.data == .conditional) return .{ .at = at, .data = .{ .conditional = left.data.conditional } };
                if (left.data == .matching) return .{ .at = at, .data = .{ .matching = left.data.matching } };
            }
        }
        _ = try self.take(.semicolon);
        return .{ .at = at, .data = .{ .expr = left } };
    }

    /// 解析花括号分支，表达式上下文中单独保存无分号的末尾表达式。
    fn branch(self: *Parser, value_context: bool) Error!Branch {
        _ = try self.take(.lbrace);
        if (!value_context) return .{ .body = try self.statements(.rbrace) };
        var body: std.ArrayList(Stmt) = .empty;
        var tail: ?*Expr = null;
        while (!try self.eat(.rbrace)) {
            const stmt = try self.statement(&tail, false);
            if (tail == null) body.append(self.a, stmt) catch @panic("out of memory");
        }
        return .{ .body = body.items, .tail = tail };
    }

    /// 消费一对圆括号并解析其中的完整表达式。
    fn parenthesized(self: *Parser) Error!*Expr {
        _ = try self.take(.lparen);
        const value = try self.expr(0);
        _ = try self.take(.rparen);
        return value;
    }

    /// 解析 if 条件及分支，将 else if 递归表示为嵌套条件分支。
    fn conditional(self: *Parser, value_context: bool) Error!If {
        const condition = try self.parenthesized();
        const yes = try self.branch(value_context);
        const no: ?Branch = if (try self.word("else")) blk: {
            const at = self.token.at;
            if (!try self.word("if")) break :blk try self.branch(value_context);
            const nested = try self.conditional(value_context);
            if (value_context) break :blk .{ .body = &.{}, .tail = self.make(at, .{ .conditional = nested }) };
            const stmt = self.a.alloc(Stmt, 1) catch @panic("out of memory");
            stmt[0] = .{ .at = at, .data = .{ .conditional = nested } };
            break :blk .{ .body = stmt };
        } else null;
        return .{ .condition = condition, .yes = yes, .no = no };
    }

    /// 解析 match 的变体、载荷绑定和默认分支，保留原顺序供语义检查。
    fn matching(self: *Parser, value_context: bool) Error!Match {
        const subject = try self.parenthesized();
        _ = try self.take(.lbrace);
        var arms: std.ArrayList(MatchArm) = .empty;
        while (!try self.eat(.rbrace)) {
            const pattern: MatchPattern = if (self.token.tag == .name and std.mem.eql(u8, self.token.text, "default")) blk: {
                break :blk .{ .default = try self.take(.name) };
            } else blk: {
                _ = try self.take(.dot);
                const name = try self.take(.name);
                const payload: ?MatchPayload = if (try self.eat(.lparen)) payload_blk: {
                    const binding = try self.take(.name);
                    _ = try self.take(.rparen);
                    break :payload_blk if (std.mem.eql(u8, binding.text, "_")) .{ .discard = binding } else .{ .binding = binding };
                } else null;
                break :blk .{ .variant = .{ .name = name, .payload = payload } };
            };
            _ = try self.take(.fat_arrow);
            arms.append(self.a, .{ .pattern = pattern, .branch = try self.branch(value_context) }) catch @panic("out of memory");
            if (try self.eat(.rbrace)) break;
            _ = try self.take(.comma);
        }
        return .{ .subject = subject, .arms = arms.items };
    }

    /// 解析指针、optional、数组、切片和函数类型，避免把后续块误读为对象初始化。
    fn typeExpr(self: *Parser) Error!*Expr {
        const start = self.token;
        if (try self.eat(.question)) return self.make(start.at, .{ .unary = .{ .op = .question, .operand = try self.typeExpr() } });
        if (try self.eat(.star)) return self.make(start.at, .{ .unary = .{ .op = .star, .operand = try self.typeExpr() } });
        if (try self.eat(.lbracket)) {
            if (!try self.eat(.rbracket)) {
                const length = try self.expr(0);
                _ = try self.take(.rbracket);
                return self.make(start.at, .{ .array_type = .{ .length = length, .element = try self.typeExpr() } });
            }
            const is_const = try self.word("const");
            return self.make(start.at, .{ .slice = .{ .element = try self.typeExpr(), .is_const = is_const } });
        }
        if (try self.word("fn")) return self.function(start.at, false);
        return self.postfix(try self.primary(), false);
    }

    /// 解析成员类型，并允许函数签名后接函数体以表示结构体方法。
    fn memberType(self: *Parser) Error!*Expr {
        const value = try self.typeExpr();
        if (value.data == .function and try self.eat(.lbrace)) value.data.function.body = try self.statements(.rbrace);
        return value;
    }

    /// 解析参数、context 标记和返回类型，按调用位置决定是否接收函数体。
    fn function(self: *Parser, at: usize, with_body: bool) Error!*Expr {
        _ = try self.take(.lparen);
        var params: std.ArrayList(Param) = .empty;
        while (!try self.eat(.rparen)) {
            var name = try self.take(.name);
            const context = std.mem.eql(u8, name.text, "context") and self.token.tag == .name;
            if (context) name = try self.take(.name);
            _ = try self.take(.colon);
            params.append(self.a, .{ .name = name, .ty = try self.typeExpr(), .context = context }) catch @panic("out of memory");
            if (try self.eat(.rparen)) break;
            _ = try self.take(.comma);
        }
        _ = try self.take(.arrow);
        const result = try self.typeExpr();
        const body = if (with_body and try self.eat(.lbrace)) try self.statements(.rbrace) else null;
        return self.make(at, .{ .function = .{ .params = params.items, .result = result, .body = body } });
    }

    /// 解析字面量、名称、类型声明及条件等基本表达式，递归保存结构体内部声明。
    fn primary(self: *Parser) Error!*Expr {
        const t = self.token;
        if (try self.word("if")) return self.make(t.at, .{ .conditional = try self.conditional(true) });
        if (try self.word("match")) return self.make(t.at, .{ .matching = try self.matching(true) });
        if (try self.word("enum")) {
            _ = try self.take(.lbrace);
            var variants: std.ArrayList(EnumVariant) = .empty;
            while (!try self.eat(.rbrace)) {
                const name = try self.take(.name);
                const ty = if (try self.eat(.colon)) try self.typeExpr() else null;
                variants.append(self.a, .{ .name = name, .ty = ty }) catch @panic("out of memory");
                if (try self.eat(.rbrace)) break;
                _ = try self.take(.comma);
            }
            return self.make(t.at, .{ .enumeration = variants.items });
        }
        if (try self.word("struct")) {
            _ = try self.take(.lbrace);
            var fields: std.ArrayList(Field) = .empty;
            while (!try self.eat(.rbrace)) {
                const member_at = self.token.at;
                if (try self.eat(.dot_dot)) {
                    fields.append(self.a, .{ .name = t, .ty = self.make(member_at, .{ .name = ".." }), .embedded = false, .spread = true }) catch @panic("out of memory");
                    if (self.token.tag != .rbrace) _ = try self.take(.comma);
                    continue;
                }
                const access = try self.visibility();
                if (self.token.tag == .name and (std.mem.eql(u8, self.token.text, "const") or std.mem.eql(u8, self.token.text, "var"))) {
                    var declaration = try self.statement(null, true);
                    declaration.data.binding.visibility = access orelse .public;
                    const stored = self.a.create(Stmt) catch @panic("out of memory");
                    stored.* = declaration;
                    fields.append(self.a, .{ .name = declaration.data.binding.name, .ty = declaration.data.binding.value, .embedded = false, .declaration = stored }) catch @panic("out of memory");
                    continue;
                }
                if (access == null and self.token.tag == .name and !std.mem.eql(u8, self.token.text, "use")) {
                    var lookahead = self.lexer;
                    if ((try lookahead.next()).tag != .colon) {
                        const stored = self.a.create(Stmt) catch @panic("out of memory");
                        stored.* = try self.statement(null, true);
                        fields.append(self.a, .{ .name = .{ .tag = .name, .text = "", .at = member_at }, .ty = self.make(member_at, .{ .name = "" }), .embedded = false, .declaration = stored }) catch @panic("out of memory");
                        continue;
                    }
                }
                const embedded = try self.word("use");
                const name = try self.take(.name);
                if (!embedded and access != null and self.token.tag != .colon) {
                    var path = self.make(name.at, .{ .name = name.text });
                    while (try self.eat(.dot)) {
                        const member = try self.take(.name);
                        path = self.make(path.at, .{ .member = .{ .base = path, .name = member.text } });
                    }
                    _ = try self.take(.semicolon);
                    fields.append(self.a, .{ .name = name, .ty = path, .embedded = false, .visibility = access.?, .redeclaration = true }) catch @panic("out of memory");
                    continue;
                }
                _ = try self.take(.colon);
                fields.append(self.a, .{ .name = name, .ty = try self.memberType(), .embedded = embedded, .visibility = access orelse .public }) catch @panic("out of memory");
                if (embedded) {
                    _ = try self.take(.semicolon);
                } else if (self.token.tag != .rbrace) {
                    _ = try self.take(.comma);
                }
            }
            return self.make(t.at, .{ .structure = fields.items });
        }
        if (try self.word("fn")) return self.function(t.at, true);
        if (try self.eat(.lparen)) {
            const value = try self.expr(0);
            _ = try self.take(.rparen);
            return value;
        }
        if (try self.eat(.dot)) return self.initializer(t.at, null);
        if (t.tag == .name or t.tag == .number or t.tag == .string) {
            try self.next();
            return self.make(t.at, switch (t.tag) {
                .name => .{ .name = t.text },
                .number => .{ .number = t.text },
                .string => .{ .string = t.text },
                else => unreachable,
            });
        }
        return self.fail(t.at, "expected expression, found '{s}'", .{t.text});
    }

    /// 根据类型和字段起始形式区分数组初始化与对象初始化，再收集元素或具名字段。
    fn initializer(self: *Parser, at: usize, ty: ?*Expr) Error!*Expr {
        _ = try self.take(.lbrace);
        const is_array = blk: {
            if (ty) |t| if (t.data == .array_type) break :blk true;
            if (self.token.tag == .rbrace) break :blk false;
            if (self.token.tag != .dot) break :blk true;
            var lookahead = self.lexer;
            break :blk (try lookahead.next()).tag != .name;
        };
        if (is_array) {
            var elements: std.ArrayList(*Expr) = .empty;
            while (!try self.eat(.rbrace)) {
                elements.append(self.a, try self.expr(0)) catch @panic("out of memory");
                if (try self.eat(.rbrace)) break;
                _ = try self.take(.comma);
            }
            return self.make(at, .{ .array_init = .{ .ty = ty, .elements = elements.items } });
        }
        var fields: std.ArrayList(Init) = .empty;
        while (!try self.eat(.rbrace)) {
            _ = try self.take(.dot);
            const name = try self.take(.name);
            _ = try self.take(.equal);
            fields.append(self.a, .{ .name = name, .value = try self.expr(0) }) catch @panic("out of memory");
            if (try self.eat(.rbrace)) break;
            _ = try self.take(.comma);
        }
        return self.make(at, .{ .object = .{ .ty = ty, .fields = fields.items } });
    }

    /// 连续解析成员、调用、下标和切片等后缀，并按上下文允许对象初始化。
    fn postfix(self: *Parser, base: *Expr, objects: bool) Error!*Expr {
        var current = base;
        while (true) {
            if (try self.eat(.dot)) {
                const member = (try self.take(.name)).text;
                current = self.make(current.at, .{ .member = .{ .base = current, .name = member } });
            } else if (try self.eat(.lparen)) {
                var args: std.ArrayList(*Expr) = .empty;
                while (!try self.eat(.rparen)) {
                    args.append(self.a, try self.expr(0)) catch @panic("out of memory");
                    if (try self.eat(.rparen)) break;
                    _ = try self.take(.comma);
                }
                current = self.make(current.at, .{ .call = .{ .callee = current, .args = args.items } });
            } else if (try self.eat(.lbracket)) {
                const start = try self.expr(0);
                if (try self.eat(.dot_dot)) {
                    const end = if (self.token.tag == .rbracket) null else try self.expr(0);
                    _ = try self.take(.rbracket);
                    current = self.make(current.at, .{ .subslice = .{ .base = current, .start = start, .end = end } });
                } else {
                    _ = try self.take(.rbracket);
                    current = self.make(current.at, .{ .index = .{ .base = current, .index = start } });
                }
            } else if (objects and self.token.tag == .lbrace) {
                current = try self.initializer(current.at, current);
            } else return current;
        }
    }

    /// 递归解析一元前缀，区分类型前缀后再处理基本表达式的后缀。
    fn prefix(self: *Parser) Error!*Expr {
        const token = self.token;
        if (token.tag == .question) return self.typeExpr();
        if (token.tag == .minus or token.tag == .plus or token.tag == .amp or token.tag == .tilde) {
            try self.next();
            return self.make(token.at, .{ .unary = .{ .op = token.tag, .operand = try self.prefix() } });
        }
        if (token.tag == .lbracket or token.tag == .star) return self.postfix(try self.typeExpr(), true);
        return self.postfix(try self.primary(), true);
    }

    /// 用优先级爬升组合二元表达式，单独处理 not 并拒绝无括号的连续比较。
    fn expr(self: *Parser, min: u8) Error!*Expr {
        var left = if (self.token.tag == .kw_not and min <= 3) blk: {
            const token = try self.take(.kw_not);
            break :blk self.make(token.at, .{ .unary = .{ .op = .kw_not, .operand = try self.expr(3) } });
        } else try self.prefix();
        var compared = false;
        while (true) {
            const op = self.token.tag;
            const precedence: u8 = switch (op) {
                .kw_or => 1,
                .kw_and => 2,
                .equal_equal, .not_equal, .less, .less_equal, .greater, .greater_equal => 4,
                .pipe => 5,
                .caret => 6,
                .amp => 7,
                .shift_left, .shift_right => 8,
                .plus, .minus => 9,
                .star, .slash, .percent => 10,
                else => 0,
            };
            if (precedence == 0 or precedence < min) return left;
            if (precedence == 4) {
                if (compared) return self.fail(self.token.at, "comparison chains require parentheses or and", .{});
                compared = true;
            }
            try self.next();
            left = self.make(left.at, .{ .binary = .{ .op = op, .left = left, .right = try self.expr(precedence + 1) } });
        }
    }
};

test "array and slice syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const source =
        \\const a: []const [2]u8 = [2]u8 {1, 2};
        \\const b: [][]u8 = .{.{1, 2}, .{3, 4}};
        \\const c = a[0..1][0].field;
        \\const d = a[1..];
        \\const e = .{ .field = 1 };
        \\const f = .{};
    ;
    var parser: Parser = .{ .a = a, .diag = &diag, .lexer = .{ .a = a, .source = source, .diag = &diag } };
    const stmts = try parser.parse();
    const slice = stmts[0].data.binding.ty.?.data.slice;
    try std.testing.expect(slice.is_const and slice.element.data == .array_type);
    try std.testing.expectEqual(@as(usize, 2), stmts[0].data.binding.value.data.array_init.elements.len);
    try std.testing.expect(!stmts[1].data.binding.ty.?.data.slice.is_const);
    try std.testing.expect(stmts[1].data.binding.value.data.array_init.elements[0].data == .array_init);
    const index = stmts[2].data.binding.value.data.member.base.data.index;
    try std.testing.expect(index.base.data.subslice.end != null);
    try std.testing.expect(stmts[3].data.binding.value.data.subslice.end == null);
    try std.testing.expect(stmts[4].data.binding.value.data == .object);
    try std.testing.expect(stmts[5].data.binding.value.data == .object);
}

test "enum and match syntax" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const source =
        \\const Message = enum { Quit, Text: []const u8, };
        \\match (message) { .Quit => { return; }, .Text(name) => { use_name(name); }, .Text(_) => {}, default => {}, }
        \\const result = match (message) { .Quit => { 0 }, .Text(name) => { name }, .Text(_) => { 1 }, default => { 2 }, };
        \\const nested = if (true) { match (message) { default => {} } 3 } else { 4 };
    ;
    var parser: Parser = .{ .a = a, .diag = &diag, .lexer = .{ .a = a, .source = source, .diag = &diag } };
    const stmts = try parser.parse();
    const variants = stmts[0].data.binding.value.data.enumeration;
    try std.testing.expectEqual(@as(usize, 2), variants.len);
    try std.testing.expect(variants[0].ty == null);
    try std.testing.expect(variants[1].ty.?.data == .slice);
    const statement_match = stmts[1].data.matching;
    try std.testing.expectEqualStrings("message", statement_match.subject.data.name);
    try std.testing.expect(statement_match.arms[0].pattern.variant.payload == null);
    try std.testing.expectEqualStrings("name", statement_match.arms[1].pattern.variant.payload.?.binding.text);
    try std.testing.expect(statement_match.arms[2].pattern.variant.payload.? == .discard);
    try std.testing.expect(statement_match.arms[3].pattern == .default);
    try std.testing.expect(statement_match.arms[0].branch.tail == null);
    const value_match = stmts[2].data.binding.value.data.matching;
    try std.testing.expectEqualStrings("name", value_match.arms[1].branch.tail.?.data.name);
    const yes = stmts[3].data.binding.value.data.conditional.yes;
    try std.testing.expect(yes.body[0].data == .matching);
    try std.testing.expectEqualStrings("3", yes.tail.?.data.number);
}

test "invalid enum and match syntax" {
    const sources = [_][]const u8{
        "const E = enum { A B };",
        "const E = enum { A: };",
        "match (x) { .A -> {} }",
        "match (x) { .A() => {} }",
        "match (x) { .A(a, b) => {} }",
        "match (x) { .A => {} .B => {} }",
        "match (x) { default => 1 }",
        "match x { default => {} }",
    };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var diag: Diagnostic = .{};
        var parser: Parser = .{ .a = a, .diag = &diag, .lexer = .{ .a = a, .source = source, .diag = &diag } };
        try std.testing.expectError(error.InvalidSource, parser.parse());
    }
}

test "invalid array and slice syntax" {
    const sources = [_][]const u8{ "const x = a[];", "const x = a[..1];", "const x = a[1..2..3];", "const x = .{1, .field = 2};" };
    for (sources) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var diag: Diagnostic = .{};
        var parser: Parser = .{ .a = a, .diag = &diag, .lexer = .{ .a = a, .source = source, .diag = &diag } };
        try std.testing.expectError(error.InvalidSource, parser.parse());
    }
}
