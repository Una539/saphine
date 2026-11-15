//! 将源码按字节位置切分为 Token，跳过空白和行注释并检查字符串及标识符编码。
const std = @import("std");

pub const Text = []const u8;
pub const Error = error{InvalidSource};
/// 列举词法单元类别，并提供复合赋值到基础运算符的映射。
pub const Tag = enum {
    eof,
    name,
    number,
    string,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    colon,
    semicolon,
    comma,
    dot,
    dot_dot,
    equal,
    equal_equal,
    not_equal,
    less,
    less_equal,
    greater,
    greater_equal,
    kw_and,
    kw_or,
    kw_not,
    plus,
    minus,
    star,
    slash,
    percent,
    amp,
    pipe,
    caret,
    tilde,
    shift_left,
    shift_right,
    question,
    arrow,
    fat_arrow,
    plus_equal,
    minus_equal,
    star_equal,
    slash_equal,
    percent_equal,
    amp_equal,
    pipe_equal,
    caret_equal,
    shift_left_equal,
    shift_right_equal,

    /// 将复合赋值标签还原为对应二元运算符，其他标签返回空值。
    pub fn compoundOperator(tag: Tag) ?Tag {
        return switch (tag) {
            .plus_equal => .plus,
            .minus_equal => .minus,
            .star_equal => .star,
            .slash_equal => .slash,
            .percent_equal => .percent,
            .amp_equal => .amp,
            .pipe_equal => .pipe,
            .caret_equal => .caret,
            .shift_left_equal => .shift_left,
            .shift_right_equal => .shift_right,
            else => null,
        };
    }
};
/// 保存词法单元类别、原始文本切片和字节位置，不复制源码内容。
pub const Token = struct { tag: Tag, text: Text, at: usize };
/// 保存分析错误的位置和格式化消息，供各前端阶段共用。
pub const Diagnostic = struct {
    at: usize = 0,
    message: Text = "",
    /// 覆盖当前诊断并返回统一源码错误，由调用者决定如何显示。
    pub fn fail(self: *Diagnostic, a: std.mem.Allocator, at: usize, comptime fmt: Text, args: anytype) Error {
        self.* = .{ .at = at, .message = std.fmt.allocPrint(a, fmt, args) catch @panic("out of memory") };
        return error.InvalidSource;
    }
};

/// 维护源码扫描游标，每次 next 返回一个 Token 或可定位的词法错误。
pub const Lexer = struct {
    a: std.mem.Allocator,
    source: Text,
    diag: *Diagnostic,
    offset: usize = 0,

    /// 将当前位置错误交给共享诊断对象，使用词法器分配器保存消息。
    fn fail(self: *Lexer, at: usize, comptime fmt: Text, args: anytype) Error {
        return self.diag.fail(self.a, at, fmt, args);
    }

    /// 跳过空白与注释后扫描名称、字面量或运算符，返回借用源码的 Token。
    pub fn next(self: *Lexer) Error!Token {
        const s = self.source;
        while (self.offset < s.len) {
            if (std.ascii.isWhitespace(s[self.offset])) {
                self.offset += 1;
            } else if (std.mem.startsWith(u8, s[self.offset..], "//")) {
                self.offset = std.mem.indexOfScalarPos(u8, s, self.offset, '\n') orelse s.len;
            } else break;
        }
        const start = self.offset;
        if (start == s.len) {
            return .{ .tag = .eof, .text = "", .at = start };
        }
        const c = s[start];
        self.offset += 1;
        const tag: Tag = switch (c) {
            'a'...'z', 'A'...'Z', '_', 0xc2...0xf4 => blk: {
                if (c >= 0x80) self.offset = start + try self.identifierCodepointSize(start);
                while (self.offset < s.len) {
                    const byte = s[self.offset];
                    if (std.ascii.isAlphanumeric(byte) or byte == '_') {
                        self.offset += 1;
                    } else if (byte >= 0xc2 and byte <= 0xf4) {
                        self.offset += try self.identifierCodepointSize(self.offset);
                    } else break;
                }
                break :blk .name;
            },
            '0'...'9' => blk: {
                while (self.offset < s.len) {
                    const b = s[self.offset];
                    if (std.ascii.isAlphanumeric(b) or b == '_' or
                        (b == '.' and self.offset + 1 < s.len and std.ascii.isDigit(s[self.offset + 1])) or
                        ((b == '+' or b == '-') and (s[self.offset - 1] == 'e' or s[self.offset - 1] == 'E') and
                            !std.mem.startsWith(u8, s[start..], "0x")))
                    {
                        self.offset += 1;
                    } else break;
                }
                break :blk .number;
            },
            '"' => blk: {
                while (self.offset < s.len and s[self.offset] != '"') {
                    if (s[self.offset] == '\n') return self.fail(start, "unterminated string", .{});
                    if (s[self.offset] == '\\') self.offset += 1;
                    self.offset += 1;
                }
                if (self.offset >= s.len) return self.fail(start, "unterminated string", .{});
                self.offset += 1;
                break :blk .string;
            },
            '{' => .lbrace,
            '}' => .rbrace,
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            ':' => .colon,
            ';' => .semicolon,
            ',' => .comma,
            '.' => if (self.consumeByte('.')) .dot_dot else .dot,
            '=' => if (self.consumeByte('=')) .equal_equal else if (self.consumeByte('>')) .fat_arrow else .equal,
            '!' => if (self.consumeByte('=')) .not_equal else return self.fail(start, "unexpected character '!'", .{}),
            '<' => if (self.consumeByte('<'))
                if (self.consumeByte('=')) .shift_left_equal else .shift_left
            else if (self.consumeByte('=')) .less_equal else .less,
            '>' => if (self.consumeByte('>'))
                if (self.consumeByte('=')) .shift_right_equal else .shift_right
            else if (self.consumeByte('=')) .greater_equal else .greater,
            '*' => if (self.consumeByte('=')) .star_equal else .star,
            '/' => if (self.consumeByte('=')) .slash_equal else .slash,
            '%' => if (self.consumeByte('=')) .percent_equal else .percent,
            '&' => if (self.consumeByte('=')) .amp_equal else .amp,
            '|' => if (self.consumeByte('=')) .pipe_equal else .pipe,
            '^' => if (self.consumeByte('=')) .caret_equal else .caret,
            '~' => .tilde,
            '?' => .question,
            '+' => if (self.consumeByte('=')) .plus_equal else .plus,
            '-' => if (self.consumeByte('>')) .arrow else if (self.consumeByte('=')) .minus_equal else .minus,
            else => return self.fail(start, "unexpected character '{c}'", .{c}),
        };
        const word = s[start..self.offset];
        const keyword = if (tag != .name) tag else if (std.mem.eql(u8, word, "and")) .kw_and else if (std.mem.eql(u8, word, "or")) .kw_or else if (std.mem.eql(u8, word, "not")) .kw_not else tag;
        return .{ .tag = keyword, .text = word, .at = start };
    }

    /// 解码当前位置 UTF-8 字符并排除不允许的标识符字符，返回其字节长度。
    fn identifierCodepointSize(self: *Lexer, at: usize) Error!usize {
        const length = std.unicode.utf8ByteSequenceLength(self.source[at]) catch return self.fail(at, "invalid UTF-8 identifier", .{});
        if (length > self.source.len - at) return self.fail(at, "invalid UTF-8 identifier", .{});
        const codepoint = std.unicode.utf8Decode(self.source[at..][0..length]) catch return self.fail(at, "invalid UTF-8 identifier", .{});
        if (codepoint < 0xa1 or codepoint == 0x200b or codepoint == 0xfeff)
            return self.fail(at, "invalid Unicode identifier character", .{});
        return length;
    }

    /// 下一个字节符合预期时前移游标，用于识别多字节运算符。
    fn consumeByte(self: *Lexer, byte: u8) bool {
        if (self.offset == self.source.len or self.source[self.offset] != byte) return false;
        self.offset += 1;
        return true;
    }
};
