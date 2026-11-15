# 语言语法速览

本文介绍语言语法和当前实现的主要限制。代码块中没有 `main` 的示例是片段，可以放入相应的程序或函数中。更多完整程序见[示例导航](../examples/README.md)，基础语法示例位于 [`examples/basics/`](../examples/basics/)。

## 第一个程序

```text
// 单行注释
const main = fn() -> void {
    print("你好，世界！");
};
```

程序入口必须是顶层的 `const main = fn() -> void { ... };`。普通语句和绑定以分号结尾；函数体作为绑定的值时，花括号后的分号属于这条绑定。

## 绑定、作用域和赋值

```text
const count = 3;        // 类型推断，不可重新赋值
var total: i32 = 10;    // 显式类型，可修改
total = total + count;
total += 1;

{
    const count = 5;    // 块内遮蔽外层名称
    print(count);
}
```

`const` 和 `var` 都必须初始化。同一作用域不能重复声明同名绑定。支持普通赋值 `=` 和复合赋值。赋值在语句中使用。

## 基本类型与字面量

| 类型 | 写法 | 示例 |
| --- | --- | --- |
| 有符号整数 | `i8`、`i16`、`i32`、`i64`、`i128` | `-128` |
| 无符号整数 | `u8`、`u16`、`u32`、`u64`、`u128`、`usize` | `0xff` |
| 浮点数 | `f16`、`f32`、`f64`、`f128` | `2.5` |
| 布尔值 | `bool` | `true`、`false` |
| 字节串 | `[]const u8` | `"你好"` |
| 无返回值 | `void` | 用作函数返回类型 |
| 类型值 | `type` | `i32`、结构体类型 |

整数字面量默认是 `i32`，浮点字面量默认是 `f64`；显式数值类型上下文可以指定其他位宽。字符串字面量使用 UTF-8，支持 `\n`、`\r`、`\t`、`\\` 和 `\"` 转义。

```text
const small: i8 = -128;
const mask: u16 = 0xff;
const fraction: f64 = 2.5;
const greeting: []const u8 = "hello\nworld";
const enabled: bool = true;
```

## 运算符

| 类别 | 运算符 | 说明 |
| --- | --- | --- |
| 一元 | `+`、`-`、`~`、`&` | 数值正负号、整数按位取反、取地址 |
| 算术 | `*`、`/`、`%`、`+`、`-` | 整数除法向零截断。余数的符号跟随左操作数 |
| 位运算 | `<<`、`>>`、`&`、`^`、`\|` | 用于整数。移位量可用不同整数类型，范围为零至左操作数位宽减一 |
| 比较 | `==`、`!=`、`<`、`<=`、`>`、`>=` | 数值比较，布尔值支持 `==` 和 `!=` |
| 逻辑 | `not`、`and`、`or` | `and` 和 `or` 对布尔值短路求值 |

优先级从高到低依次为前缀一元运算、乘除取余、加减、移位、按位与、按位异或、按位或、比较、`not`、`and`、`or`。比较需要用括号或 `and` 分组，例如 `a < b and b < c`。

复合赋值支持 `+=`、`-=`、`*=`、`/=`、`%=`、`&=`、`^=`、`|=`、`<<=`、`>>=`。左值位置只计算一次。结构体重载的写法见 [运算符重载](#运算符重载)。

## 条件

条件必须是 `bool`，且必须写在括号内。每个分支都有自己的块作用域；只执行分支而不取值时可以省略 `else`：

```text
if (score >= 90) {
    print("excellent");
} else if (score >= 60) {
    print("pass");
} else {
    print("retry");
}
```

`if` 也可以产生值。分支末尾的值表达式不写分号；所有继续执行的路径必须产生同一类型的值：

```text
const fee: i32 = if (is_member) {
    const discount = 5;
    20 - discount
} else {
    20
};
```

## 循环、数组与切片

```text
var n = 0;
while (n < 3) {
    n += 1;
    if (n == 2) { continue; }
    print(n);
}

do {
    n += 1;
    if (n == 5) { break; }
} while (n < 10);

const items: [5]i32 = range(0, 5);
for (item in items) {
    print(item);
}
```

- `[N]T` 是定长数组类型，长度必须在编译期可知。数组按值复制，修改副本不会修改原数组。
- `range(start, end)` 返回 `i32` 定长数组，区间左闭右开。端点必须是编译期可知且能装入 `i32` 的整数；常量绑定和整数四则运算可以用于计算端点。终点不大于起点时返回空数组。
- `for (item in items)` 遍历数组或切片，表达式只求值一次；`item` 是每次迭代的只读元素副本。
- `break` 和 `continue` 作用于最内层循环。`do while` 中的 `continue` 会继续执行后置条件检查。

```text
var a = [3]i32 {1, 2, 3};
var b: [3]i32 = .{1, 2, 3}; // 根据上下文确定数组类型
b[0] = 9;                     // 不影响 a
const all: []i32 = a[0..];
const part: []i32 = a[1..3]; // 左闭右开
part[0] = 7;                  // 同时修改 a[1] 和 all[1]
const view: []const i32 = all;
print(view.len);
```

数组和切片都支持下标读取和 `.len`；可变数组及可变切片支持下标写入。`[]T` 是可变元素切片，`[]const T` 是只读元素切片；切片共享底层存储，复制切片不会复制元素。字符串是只读 UTF-8 字节切片 `[]const u8`，下标和切片操作按字节而非字符计数。使用切片时须自行保证底层存储仍然有效；目前不要求生命周期检查。

## 函数

函数是值；参数和返回类型需要显式写出：

```text
const add = fn(a: i32, b: i32) -> i32 {
    return a + b;
};

const apply = fn(f: fn(x: i32) -> i32, x: i32) -> i32 {
    return f(x);
};

const double = fn(x: i32) -> i32 { return x * 2; };
const result = apply(double, 5);
```

`void` 函数可以不写 `return`，也可以写 `return;`。非 `void` 函数需要在所有继续执行的路径上返回值。函数值可以复制、重新赋值、传参和返回；当前不支持捕获外部局部变量的闭包。

## 结构体、字段和方法

```text
var Counter = struct {
    count: i32,
};

Counter.add = fn(self: *Self, amount: i32) -> void {
    self.count += amount;
};

const main = fn() -> void {
    var counter = Counter { .count = 0 };
    counter.add(5);
    print(counter.count);
};
```

- 结构体按值复制；修改副本不会修改原值。
- 初始化时使用 `.字段名 = 值`。类型已由上下文确定时，可使用 `.{ ... }`。
- 方法通过类型成员赋值定义，实例方法的接收者使用 `*Self`。
- 实例方法需要可变接收者；`Self` 表示方法所属的结构体类型。

### 指针和传参

```text
const increment = fn(counter: *Counter) -> void {
    counter.add(1);
};

var counter = Counter { .count = 0 };
increment(&counter);
increment(counter); // 传参时自动借用可变结构体
```

当前指针目标限于结构体，显式 `&` 要求可变结构体左值。指针可用于访问结构体字段和调用方法；目前没有通用的源语言解引用和普通值取址语法。按值传递结构体会传入副本。

## 类型值与类型演化

类型可以通过 `type` 参数在编译期传递，也可以从函数返回：

```text
const box = fn(T: type) -> type {
    return struct { value: T };
};
const IntBox = box(i32);
const item = IntBox { .value = 42 };
```

`struct { ... }` 是构造结构体类型值的表达式。可变 `type` 绑定可以改存其他类型值；普通字段和变量的赋值仍必须保持原类型。

可变结构体类型绑定可以通过 `+= 名称:类型;` 扩展。保存旧类型值或已构造对象会保留原来的版本：

```text
var Point = struct { x: i32 };
const OldPoint = Point;
Point += y:i32;

const old = OldPoint { .x = 1 };
const current = Point { .x = 1, .y = 2 };
```

`OldPoint` 和演化后的 `Point` 是不同版本，不能互相当作同一类型赋值。旧对象不会获得新字段。类型也可以拥有函数和静态值成员；旧式 `Point.y = i32;` 仍可添加成员，但不能替换本层已有成员。

```text
var T = struct { x:i32 };
T += take:fn(self:*Self, xs:[1]Self)->i32 { return xs[0].x; };
T = struct { .., y:i32 };
// 等价扩展简写：T += y:i32;
```

`..` 只能出现在直接赋给现有结构体类型绑定的结构表达式中，从目标原类型补入成员声明，包括默认值和方法 AST。无目标、原值不是结构体或重复 `..` 均报错。不能用它替换同名成员或改变成员类型。扩展不允许用于实例。

保留声明使用其原词法环境；在内层同名常量作用域扩展，不改变旧数组长度、默认值或显式别名的含义。只有直接赋值的结构表达式能使用展开目标，函数调用、调用参数和嵌套结构不能继承该目标。

方法中的 `Self` 在新结构上下文解析，包括 `[1]Self` 等嵌套类型；显式写出的旧类型名称不等同于 `Self`。可以将上述新类型构造为 `var t = T { .x = 1, .y = 2 };`，然后调用 `t.take([1]T {t})`。

**类型扩展在编译期完成，不能在运行时修改类型。** 运行时条件分支中的类型修改会被拒绝；IR 和原生后端仍按版本生成固定 Zig 布局。成员名称查找使用真正的 bitmap-indexed HAMT，声明顺序另行保留，但这本身不提供运行时类型值或动态对象存储。扩展导入类型后，默认值若需要无法沿新实例环境访问的其他容器运行时成员，当前会明确报捕获错误，不支持这类跨容器运行时环境。详见 [动态后端评估](DYNAMIC_BACKEND.md)。

## `use`：组合与静态多态

`use` 声明一个真实的具名子对象，并提升其可访问成员。文件也会被规范化为结构体，因此通过文件路径引入时仍使用同一套嵌入语义。

```text
var Printable = struct { x: i32 };
Printable.draw = fn(self: *Self) -> void { self.x += 1; };

var Fancy = struct { use printable: Printable; };
Fancy.draw = fn(self: *Self) -> void { self.x += 10; };

const draw = fn(p: *Printable) -> void { p.draw(); };

const main = fn() -> void {
    var value = Fancy { .printable = .{ .x = 0 } };
    draw(&value);              // 通过 use 路径传递，使用 Fancy 的实现
    print(value.x);            // 提升字段，与 value.printable.x 共享存储
    value.printable.draw();    // 从显式子对象开始解析方法
};
```

外层可覆盖内嵌类型的方法；没有覆盖时可以使用默认实现。也可以在结构体中声明抽象方法，由使用该类型的外层实现：

```text
const Drawable = struct { draw: fn(self: *Self) -> void, };
var Circle = struct { use drawable: Drawable; };
Circle.draw = fn(self: *Self) -> void { print("circle"); };
```

多条路径能到达同一目标类型，或多个子对象提升了同名成员时，编译器会报告歧义；可通过具名子对象明确访问。当前多态通过编译期特化实现，不是运行时动态接口分发。

## 枚举与模式匹配

枚举可以同时包含无数据成员和携带数据的成员。带数据的成员携带一个运行时值；该值可以是数值、结构体、数组、切片、函数值或其他支持作为运行时值的类型。

```text
const Message = enum {
    Quit,
    Text: []const u8,
    Number: i32,
};

const quit = Message.Quit;
const text = Message.Text("hello");
const number = Message.Number(42);
```

枚举是独立类型，不会转换为整数。枚举按值复制；携带切片时复制的是视图，而非底层元素。

`match` 支持枚举、可空类型和受支持的 Zig error union。枚举分支通过 `.成员` 匹配。带数据的成员用 `(名称)` 绑定，或用 `(_)` 忽略。绑定是只读值，仅在该分支中可见。

```text
match (message) {
    .Quit => { print("quit"); },
    .Text(text) => { print(text); },
    .Number(_) => { print("number"); },
}
```

`match` 也可以产生值。分支末尾的值表达式不写分号，各条继续执行的分支必须产生同一类型的值：

```text
const description: []const u8 = match (message) {
    .Text(text) => { text },
    default => { "other" },
};
```

`default` 匹配所有未列出的成员，最多出现一次，且必须位于最后。没有 `default` 时必须覆盖所有成员；重复成员或不属于目标枚举的成员会报错。`match` 目标只求值一次。

可空类型写作 `?T`。通过类型名的 `.Some(value)` 和 `.None` 构造，分支使用相同成员名匹配。

```text
const MaybeNumber = ?i32;
const n = MaybeNumber.Some(42);
match (n) {
    .Some(value) => { print(value); },
    .None => { print("empty"); },
}
```

## 运算符重载

沿用 `Type.OperatorAdd = fn(...)` 的写法。二元重载接收同一个具体结构体类型的两个值，一元重载接收一个值。声明也可以放在结构体中。

| 运算符 | 重载名 | 签名 |
| --- | --- | --- |
| `+`、`-`、`*`、`/`、`%` | `OperatorAdd`、`OperatorSub`、`OperatorMul`、`OperatorDiv`、`OperatorRem` | `fn(Self, Self) -> Self` |
| `&`、`\|`、`^`、`<<`、`>>` | `OperatorBitAnd`、`OperatorBitOr`、`OperatorBitXor`、`OperatorShl`、`OperatorShr` | `fn(Self, Self) -> Self` |
| `==`、`!=`、`<`、`<=`、`>`、`>=` | `OperatorEq`、`OperatorNe`、`OperatorLt`、`OperatorLe`、`OperatorGt`、`OperatorGe` | `fn(Self, Self) -> bool` |
| 一元 `+`、`-`、`~` | `OperatorPos`、`OperatorNeg`、`OperatorBitNot` | `fn(Self) -> Self` |
| `not` | `OperatorNot` | `fn(Self) -> bool` |

```text
var Vec = struct { x: i32, y: i32 };
Vec.OperatorSub = fn(a: Self, b: Self) -> Self {
    return .{ .x = a.x - b.x, .y = a.y - b.y };
};

var a = Vec { .x = 5, .y = 7 };
a -= Vec { .x = 2, .y = 3 };
```

每个比较运算符有独立的重载名。复合赋值调用对应的二元运算。完整用例见 [examples/basics/operators.saph](../examples/basics/operators.saph)。

## 内建功能

- `print(value)` 通过隐式导入的 saphine 标准库输出一行，也可以用 `use std: "std";` 后调用 `std.print(value)`。支持字节串、数值和布尔值，浮点数使用科学计数法。
- `range(start, end)`：生成编译期确定长度的 `i32` 数组。

标准库的参数、文件和输出接口见[标准库说明](../src/stdlib/README.md)。

## 文件模块与可见性

每个源文件先规范化为一个隐式结构体：文件顶层声明成为结构体成员，随后使用普通结构体的成员解析、访问控制和 `use`。文件本身不需要显式包裹在 `struct` 中。例如：

```text
use math: "math.saph";
use geometry: "geometry";
```

`math` 和 `geometry` 是嵌入成员的名称；路径相对于包含该 `use` 的源文件解析。路径可以写 `.saph` 扩展名，也可以省略；目录使用其中的 `mod.saph`。例如 `"geometry"` 可以指向 `geometry.saph` 或 `geometry/mod.saph`，但两者都存在时会报歧义，必须明确写出文件路径，或用 `"geometry/"` 明确选择目录。找不到目标和循环导入都会报错。

同一个文件复用结构体类型，但每条 `use` 都拥有独立子对象，不共享一份模块变量。文件和显式结构体中的 `const`、`var` 声明使用相同规则：类型及具名函数定义是声明成员，运行时值是实例字段，初始化按源码顺序执行。遇到具有默认初始化的嵌入结构体时，先完成子对象初始化，再继续父对象。

显式结构体也可以包含成员绑定：

```text
const Counter = struct {
    var count: i32 = 0;
    const increment = fn(self: *Self) -> void {
        self.count += 1;
    };
};
```

带初始化表达式的成员在每个实例中初始化；只有类型声明、没有默认值的普通字段仍需在构造时提供。构造时先按初始化列表顺序写入显式字段，再按声明顺序执行其余成员的默认初始化；已显式提供的字段不会再执行默认表达式或默认嵌入初始化。结构体扩展保留已有成员的默认初始化，旧版本不受影响；不允许同名替换。

结构体定义可以使用外层编译期已知的整数常量，例如用局部 `const n = 3;` 指定 `[n]i32` 的长度；这不意味着允许捕获运行时局部变量。

文件作用域的 `use name: T;` 和结构体内部一样接受结构体类型；自动构造文件实例时，其嵌入字段必须具备默认初始化。

成员默认 `public`，也可以显式写出。`private` 只允许声明结构体内部访问，私有嵌入的内容不能被外部通过提升绕过限制。`internal` 允许通过 `use` 多级提升，并在组合后的结构体内部使用，但对外仍然不可见。

外层可以显式重设提升成员的可见性：

```text
public value;
public base.value;
```

第一种按提升后的名称指定成员；第二种通过具名路径指定成员。同名成员经多条路径提升时，未限定的 `public value;` 会报告歧义，可以用限定路径消歧。也可用 `private value;` 或 `internal value;` 调整提升成员在当前层的可见性；不修改源结构体，也不复制字段。本层直接声明的成员不能再次声明可见性，例如 `private x:i32, public x;` 报重复声明。显式公开不能绕过原声明或嵌入路径的 `private` 限制。

目录中的 `mod.saph` 是普通文件结构体，可以通过 `use` 组织子文件，并用上述可见性声明重新导出成员；不存在另一套模块导出机制。

结构体、数组、枚举及其副本使用普通值存储，不隐式分配到堆，也不在复制时重写内部指针。普通函数值绑定结构体实例时保存实例地址，复制函数值只复制该引用。普通指针、切片和实例函数值引用的对象由程序员保证有效。ARC 和 GC 指针以及其派生视图按内存管理规则保活。

## 内存分配与清理

通过 `use std: "std";` 可访问 `std.memory`。Heap 和 Arena 支持 `create(value)`，分配失败时程序终止。Heap 的 `destroy(ptr)` 归还对象存储，内部资源由对象自己的清理逻辑处理。Arena 的 `deinit()` 批量归还存储。

`defer expression;` 在退出所在块时执行一个返回 `void` 的表达式。多条 `defer` 按登记的逆序执行。

函数可声明一个 `context mem: *T` 结构体指针参数。完整实参列表显式传入它，少一个实参时在对应位置填入最近的 `using manager;`。该声明从当前位置生效，内层块可以覆盖。函数体初始使用它自己的 context 参数。

### Manager 和只读 Ptr

`*memory.Manager` 是静态函数参数约束。可以传入四种标准 manager，也可以传入通过唯一可见 `use` 路径包含它们之一的结构体。多个路径可用显式的具名字段选择。编译器按实际 manager 特化函数，`mem.Ptr(T)` 表示该实例的 `create` 返回类型。Heap 和 Arena 的结果沿用普通指针表示，ARC 和 GC 的结果各自保留运行时句柄。

```text
const make_node = fn(context mem: *memory.Manager, value: i32) -> mem.Ptr(Node) {
    return mem.create(Node { .value = value });
};

const inspect = fn(p: *memory.Ptr(Node)) -> void {
    print(p.value);
};
```

`*memory.Ptr(Node)` 只读。它接受普通指针、强 ARC 指针、GC 指针和对象地址视图。如果目标结构通过一条唯一可见的 `use` 路径包含 `Node`，可协变地读取这个子对象。ARC 和 GC 的投影保留原对象。可写指针依然按原目标类型检查。作为参数传入的静态已知回调支持普通结构体指针及只读 `Ptr` 的逆变。例如接收 `*Node` 的回调可用于只传入 `*SpecialNode` 的位置，编译器会生成子对象投影适配器。

Heap 对同一块直线代码中反复 `destroy` 同一变量，或直接释放与 `defer` 重叠的情况给出警告。该检查只覆盖直接可辨认的变量和释放语句。

完整示例见 [examples/memory/interfaces.saph](../examples/memory/interfaces.saph)。

### ARC 与 GC 智能指针

`arc.create(value)` 返回 `memory.ArcPtr(T)`，`gc.create(value)` 返回 `memory.GcPtr(T)`，其中 `T` 由初始值推断。两者都可以直接访问对象字段和方法。可以用 `?memory.GcPtr(Self)` 声明递归字段。可空类型使用 `.None`、`.Some(value)` 和 `match`。

复制 ARC 智能指针会增加强计数。最后一个强引用消失时，先调用可选的 `Type.arc_deinit(self: *Self) -> void`，再清理托管字段。强指针的 `weak()` 得到 `memory.WeakPtr(T)`，弱指针的 `upgrade()` 返回 `?memory.ArcPtr(T)`。ARC 强引用环需要用弱引用断开。

GC 可以回收没有根的循环图。局部变量、参数、全局字段和跨分配存活的临时值由编译器登记。手动存储要长期保活对象时，可以用 `gc.root(ptr)` 登记并调用根句柄的 `deinit()` 解除。

托管对象的切片、内部地址和绑定方法使用 `memory.View(T)` 保留原对象。视图支持复制、传参和返回。对于地址，`T` 是原本的指针类型。对于绑定方法，`T` 是省略接收者的函数类型。将视图传给期待裸指针或裸切片的函数会报类型错误。

目前统一的视图类型可以持有 ARC 或 GC 对象。托管载荷需满足对应的清理规则，通用视图可以放在普通值、局部变量和全局变量中。GC 对象拒绝需要 ARC 清理的字段，手动 Heap 和 Arena 拒绝需要自动计数或追踪的字段。

四种 manager 的 Zig allocator 互操作见 [互操作说明](ZIG_INTEROP.md#zig-allocator-互操作)。完整示例见 [examples/memory/main.saph](../examples/memory/main.saph)。

## Zig 互操作


```text
use math: "./math.zig";
use std: "std";
use zig_std: "zig:std";
use image: "zig:module/image";

const main = fn() -> void {
    std.print(math.add(1, 2));
};
```

Zig 文件的公开声明可通过命名空间访问，也参与 `use` 成员提升。多个导入共享同一 Zig 模块的可变状态。Zig 类型沿用原始类型身份，外部结构体的字段、默认值和方法可直接使用。

```sh
saphine check app.saph --zig-module image=vendor/image/root.zig
saphine emit-zig app.saph -o app.zig --zig-config packages.json
sh app.deps/build.sh -femit-bin=app
saphine check app.saph --target aarch64-linux --optimize ReleaseSafe
```

`check` 编译可达的 Zig 调用及特化，交叉目标只编译。`emit-zig` 生成源码映射。含外部依赖或构建选项时，将 `app.zig` 与 `app.deps/` 一起搬移即可用目录内的构建脚本重建。`SAPHINE_ZIG` 可指定 Zig 0.17.1 可执行文件。

`--zig-config` 接收版本 1 的 JSON。每个模块的 `package_root` 相对于配置文件，`root`、`resources` 和 `library_dirs` 相对于包根。命名依赖通过 `imports` 显式映射，链接选项使用 `libraries`、`library_dirs` 和 `libc`。

```json
{
  "version": 1,
  "modules": [
    {
      "name": "image",
      "package_root": "vendor/image",
      "root": "root.zig",
      "imports": [],
      "resources": ["assets/default.bin"]
    }
  ]
}
```

Saphine 的 `?T` 和导入的 Zig optional 可用 `.Some(value)`、`.None` 构造并通过 `match` 解包。受支持的 Zig error union 通过导入的类型别名使用 `.Ok(value)` 和 `.Err(err)`。更多类型支持情况见 [实现状态](ZIG_INTEROP.md#实现状态)。

## 暂不支持的功能

当前不支持函数局部的 `use` 声明、生命周期检查、任意类型的模式匹配、通用错误处理、任意局部变量的闭包捕获、运行时动态接口分发或字符串插值。声明和初始化按源码顺序处理，不提供任意的顶层前向引用。涉及 `type` 参数或导入转换的调用要求静态已知的函数；抽象参数函数体和分阶段方法体在调用或取函数地址时检查。

导入的 Zig optional 和 error union 支持通过 `match` 匹配 `.Some/.None` 和 `.Ok/.Err`。互操作覆盖范围见 [功能与进度](FEATURES.md)。
