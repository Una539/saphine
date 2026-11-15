# Zig 0.17.1 互操作与可读代码生成方案

工具链固定 Zig 0.17.1 稳定版。本文介绍互操作和代码生成的设计；已支持的功能及限制见下方实现状态。

## 实现状态

- CLI 支持本地 Zig 文件、`std`、`zig:std` 和显式配置的命名模块。可访问公开声明，使用外部类型和方法，调用有限的 `comptime` 和 `anytype` 特化。支持无捕获 Zig 回调和外部函数值适配器。
- `check` 和外部依赖的 `emit-zig` 使用 Zig 验证可达调用。`emit-zig` 生成依赖快照、构建命令和格式化后的声明及直接调用映射。快照覆盖字面量导入和资源，包配置可显式声明额外资源。
- 编译器查询以编译期诊断传递有界类型图，已覆盖原生与交叉目标，并能保存递归节点引用。查询支持常见结构体工厂的字段、构造及递归指针。复杂名义类型的跨模块身份合并、部分嵌套类型和查询所得枚举的匹配仍须显式 Zig facade。查询无持久结果缓存。
- 生成器保留源码名称，并按调用图推导环境。需要多种上下文形状的函数仍使用擦除环境。布局环境字段和扁平 native 方法声明仍保留。映射目前覆盖声明和外部调用，特化声明记录调用点，局部值和完整特化调用链仍缺少映射。
- 静态库等随包分发的链接输入需列入资源清单。包外资源、未支持的指针限定符、动态依赖路径和复杂 C 导入会产生诊断。

## 1. 目标与原则

- 从 saphine 导入 Zig 文件和命名模块，访问公开声明、调用函数，并逐步支持外部类型、方法和泛型。
- Zig 函数体继续由 Zig 编译器编译；saphine 解析调用所需的声明、类型和参数约束。
- 生成的 Zig 是可阅读、可定位、可单独构建的产物。保留名称、明确签名、容器结构、源位置和特化依据。
- 内部 ID 继续用于类型身份和引用，不再直接充当输出名称。
- 先覆盖明确的互操作子集，对暂不支持的语义给出诊断。不能把 ZLS 的未知或近似结果当成编译通过。
- 保持现有值复制、文件实例、类型版本、初始化顺序、use 提升和旧实例分发语义。

## 2. 稳定版基线与 ZLS 的用途

编译器、生成代码、AST API、反射 API、格式化及测试统一使用 Zig 0.17.1。编译期检查构建 Saphine 的 Zig 版本，CLI 检查执行后端的 Zig 版本；默认不接受 dev 版本或其他版本静默替代。目标平台与优化模式显式传递。

ZLS 的 0.17.0 稳定标签声明 minimum_zig_version = 0.17.0。Zig 与 ZLS 不必拥有相同补丁号。移植基线选择 ZLS 0.17.0，该标签对应 `542462c4ddf045493fa9ca028ee6bc3f38b2754a`。实现直接使用 Zig 0.17.1 的 `std.zig.Ast`。

参考范围：

| ZLS 文件 | 采用范围 | 不采用的部分 |
| --- | --- | --- |
| src/DocumentScope.zig | 容器声明索引、作用域与声明关联 | 完整编辑器作用域服务 |
| src/analysis.zig | 声明别名、成员解析、签名、类型值和泛型绑定思路 | 整个分析器及引用搜索依赖 |
| src/ast.zig | 必要的 AST 访问辅助函数 | 编译器不需要的残缺源码恢复路径 |
| src/DocumentStore.zig | 导入身份、缓存、模块解析思路 | LSP、后台任务和构建发现基础设施 |

优先直接调用 0.17.1 的 std.zig.Ast。只复制明确需要的 ZLS 实现；复制部分放在独立目录，保留 MIT 声明、来源 commit、修改说明和测试。不为简单的 rootDecls/fullFnProto 包装引入整套 ZLS。

## 3. 统一容器模型，区分声明与存储

两种语言都可将文件视为结构体/容器，统一提供 lookupMember、lookupType、resolveCallable 和可见性检查接口。容器来源不是存储策略；结构体字段与结构体中的声明也必须区分。

| 场景 | 成员存储与访问 |
| --- | --- |
| saphine 文件的运行时绑定 | 每个 use 子对象各自拥有字段，按源码顺序初始化 |
| Zig 文件的顶层 var | Zig 容器中的静态声明，按 Zig 模块身份共享 |
| Zig 文件的 const、fn、类型 | 命名空间声明，不创建 Saphine 的运行时字段 |
| Zig 普通结构体实例字段 | 真实实例字段，按原始 Zig 类型布局存储 |

建议语义层引入 ContainerRef = lang_container / zig_container；成员种类分为 instance_field、static_variable、constant、type_decl、function。复用名称查找、成员提升与歧义检查，但分别执行存储、初始化和可见性规则。

Zig 默认私有，必须尊重 pub，不能沿用 saphine 成员的默认可见性。外部别名和重新导出指向原声明，不产生新类型身份。外部类型不允许通过 Saphine 的 += 或结构展开修改；需要扩展时用 saphine 包装结构和 use 显式组合。

## 4. 导入语法与模块身份

复用现有语法：

```lang
use math: "./math.zig";
use std: "std";
use zig_std: "zig:std";
use image: "zig:module/image";
```

- .zig 后缀明确选择 Zig 文件；.saph 和原有无后缀规则保持不变，不新增 .saph/.zig 猜测。
- std 是 saphine 自带标准库的保留导入名；本地同名模块通过 ./std 显式选择。
- zig:std 指向所选 Zig 0.17.1 的标准库。
- zig:module/<name> 指向显式配置的命名模块；初期用可重复 CLI 参数提供 name=root.zig 映射，后续配置文件复用同一模型。
- Zig 模块内的 @import("std") 仍是 Zig 标准库，与 Saphine 的 std 别名无关。
- use 一个 Zig 文件绑定编译期容器并参与成员提升，不构造独立的模块状态副本。对该别名取运行时地址或赋普通值时明确诊断。
- 普通的 use field: ExternalStructType 仍表示嵌入一个真实外部实例；与 use field: "file.zig" 的命名空间导入区分。

模块身份包含规范路径、所属 Zig 模块配置、目标、相关编译选项；同一路径在不同模块配置中不能简单合并。声明身份包含模块、容器和声明节点；泛型实例额外包含规范化编译期参数。相对导入以声明所在文件为基准。

Zig 文件环不直接套用 Saphine 的 ImportCycle：先注册模块/容器占位，再按需解析声明；声明求值递归另外检测。纯 Zig 内部递归类型和合法导入关系交由 Zig 规则处理。第一版不支持 Zig 反向导入正在生成的 saphine 模块。

## 5. Zig 分析层

新增 src/zig_interop/：

- store.zig：源码所有权、零终止缓冲、AST、路径与模块配置缓存。
- declarations.zig：先建立容器声明索引，记录 pub、源码位置、别名、类型节点和参数节点。
- resolve.zig：按需名称/类型解析，跨文件引用和有限编译期表达式。
- types.zig：外部类型身份、类型表达式与调用签名。
- diagnostics.zig：saphine 使用位置、Zig 声明位置和失败原因。

解析状态明确区分 unvisited、resolving、resolved、unsupported、invalid。类型结构允许递归引用，不能把所有 resolving 都视为非法类型环；非法的常量/类型求值环才报错。

解析返回精确结果或明确的 Unsupported，不用 unknown_type 补齐。导入只索引声明，按实际访问解析类型，避免一个尚未使用的复杂 Zig 声明阻止整个文件导入。直接导入文件存在语法错误则报告 Zig 语法诊断。

## 6. 类型映射与函数调用

| 类别 | 设计 |
| --- | --- |
| 已有整数、浮点、bool、void | 映射到已有类型；不额外引入隐式窄化 |
| bytes / []const u8 | 映射已有字节串；保持可变性区别 |
| 数组、切片 | 递归映射；长度、const、sentinel 等信息不可丢失 |
| 指针 | 将当前 pointer: Shape 扩展为通用 child + const + size 等描述；未支持的限定符明确拒绝 |
| struct / enum / union / opaque | 保存外部名义身份与 Zig 引用，不重新生成等形类型 |
| 函数 | 区分 native 函数、foreign 函数、绑定方法与携带环境的函数值 |
| comptime_int / comptime_float | 保留常量值，按上下文进行范围检查和具现化 |
| optional / error union / error set | 先保留外部类型表示和同类型传递，再增加语言层构造、解包和错误处理 |

外部类型在 IR 中使用 ForeignTypeRef，生成 math.Point 或 zig_std.Io 等原类型表达式。字段访问生成原字段名，不附加 m_。构造时尊重默认值、字段可见性、布局和特殊结构约束；不允许仅凭字段集合相同隐式转换 saphine 结构体与 Zig 结构体。

调用保留 runtime、comptime_value、comptime_type 参数分类。现有 invoke 会移除 type 参数，这只适用于 saphine 自己的特化；外部调用必须按 Zig 原签名保留编译期参数。anytype 依据实际实参类型绑定，不等于任意类型都能成功执行函数体。

实例方法按照原始首参数约束检查接收者，区分 T、*T、*const T；仅在左值与生命周期允许时取地址。直接调用外部函数不添加 __context。外部函数作为 saphine 函数值时产生具名适配 thunk；反向传给 Zig 回调只允许 ABI 匹配的无捕获函数，或用户显式提供 context + callback。不能把携带上下文的闭包强转成 Zig 函数指针。

第一阶段支持显式签名函数、基本常量、别名、基本数值/字节串/数组/切片。随后支持外部结构体和指针，再扩展泛型和错误类型。

### Zig allocator 互操作

当 Zig 的参数类型为 `std.mem.Allocator` 或该类型的别名时，可以直接传入一个现有的 Heap、Arena、Arc 或 GC manager。saphine 会从原实例取得 allocator。通过 `use` 嵌入 manager 的结构体也可以传入。临时 manager 不能隐式转换。

如果 Zig 代码会保存这个 allocator，显式传入 `manager.allocator()`，并让 manager 和它的底层分配器在 Zig 使用期间保持有效。GC 的原始缓冲区在 Zig 调用 `free` 前由运行库保活。ARC 的原始缓冲区由分配持有的一份强引用保活。需要运行库的导出产物包含 `.deps/runtime/memory.zig`，可用随附构建脚本在新目录重建。

## 7. comptime 与验证策略

ZLS 只提供参考算法，最终验证使用 Zig 0.17.1 编译器。

可精确解析的范围逐步加入：字面量、类型别名、成员路径、固定数组长度、参数替换、@This、有限 @TypeOf，以及返回明确容器的常见类型工厂。任何编译期执行都不能依据函数名称硬编码 ArrayList 等特例。

任意 Zig comptime 执行不属于初始自建分析器范围。设计预留 compiler_query 接口：对给定模块配置、类型及编译期实参生成查询单元，用同一 Zig 工具链取得类型信息；不得执行用户运行时函数。实施前必须先验证 0.17.1 的可行元数据传输方式、跨目标工作方式、递归类型编码和缓存失效，不能把“@typeInfo 可反射”当作已实现了通用查询协议。在协议完成前，复杂类型工厂明确不支持，可由显式签名 Zig facade 适配。

对于含外部调用的程序，check 在 saphine 类型检查后生成完整验证单元，并执行 Zig 无二进制输出的编译检查。单纯 @import 或读取函数签名不会迫使 Zig 检查所有函数体；验证必须覆盖 saphine 实际可达的调用与特化。build 使用同一生成单元构建，避免先重复做等价检查。

check 不执行程序，也不执行任意依赖包 build.zig；命名模块与链接需求来自显式配置。Zig 编译期语义仍可能要求嵌入文件等输入，必须纳入依赖和诊断。交叉编译不能依赖运行目标平台的查询程序。

## 8. 人类可读的低级化

### 8.1 名称与来源贯穿全部阶段

新增 SymbolId、LocalId 与 SourceSpan。函数、类型、布局、字段、全局绑定、参数、局部变量和 IR 表达式携带来源。SymbolInfo 保存源码名、模块相对路径、词法所有者、声明位置、类型版本、特化参数和生成角色。

语义层只分配身份；最终 NameTable 统一决定 Zig 名称。IR 内引用 SymbolId/LocalId，不通过拼接字符串维护引用关系。这样声明、直接调用、取函数地址、closure thunk 和初始化器始终使用同一名称。

默认命名：

| 语义实体 | 生成示例 |
| --- | --- |
| 模块类型 | app、geometry、geometry_shapes |
| 普通函数 | add、distance |
| 实例方法 | Point.translate |
| 类型的多个静态版本 | Point__v1、Point__v2 |
| 特化函数 | draw__Circle、max__i32 |
| 初始化器 | __saphine_init |
| 闭包适配器 | add__closure_adapter |
| 匿名函数 | predicate__lambda_1，优先采用绑定或参数上下文 |
| 编译器临时量 | __saphine_receiver、__saphine_result，必要时局部编号 |

保留源码参数、字段与枚举成员名称。Zig 关键字使用 @"name" 转义；局部遮蔽与 Zig 不允许的名称冲突通过确定性后缀处理。保留 __saphine_ 给内部名称，但源码同名仍可通过 NameTable 重命名，不必新增语言限制。

不使用全局遍历序号或绝对路径决定名字。类型版本按同一声明的扩展谱系编号；特化按规范化类型/值键命名。短名冲突时追加限定所有者或短摘要，并检测摘要冲突、按需延长。输出顺序按源码声明及稳定特化键排序，无关文件或调用发现顺序不应使所有名称重排。

### 8.2 生成结构

saphine 文件生成一个具名 Zig struct，实例绑定是字段；不依赖 Zig 的容器级 var 替代它们。函数尽可能作为所属容器中的具名 fn；外部模块使用具名 @import。

示意输出（展示目标风格，不代表所有函数都需要 module 参数）：

```zig
const math = @import("program.deps/zig/math.zig");

const app = struct {
    total: i32,

    // source: app.saph:4:1
    fn addToTotal(module: *app, amount: i32) void {
        module.total = math.add(module.total, amount);
    }

    fn __saphine_init(module: *app) void {
        module.total = 0;
    }
};
```

无捕获函数生成 fn add(a: i32, b: i32) i32；访问文件实例状态才增加 module: *app；实例方法保留 self: *Point；需要独立词法环境时显式增加有名字、有类型的环境参数。不能将实例接收者和声明环境错误合并。

环境需求通过函数体和调用图计算到不动点，覆盖递归调用、方法覆盖、特化、取地址和转发。第一步先保留现有 ABI 并完成名称映射；随后才把直接调用的 ?*anyopaque 改成类型化环境并移除无用环境。函数值的统一擦除 ABI 可以保留在适配 thunk 内，不能为了可读性破坏已有函数值语义。

当前所有结构都有 __module_context；只有证明不需要时才移除，布局和捕获语义的改变需要单独测试。初始化器维持原声明顺序及嵌入初始化顺序，不能把运行时初始化改写为 Zig comptime 字段默认值。

### 8.3 表达式和参数

按运算符优先级打印，避免每个节点一层括号。字段直接生成 point.x，普通调用直接生成 math.add(a, b)。复杂对象构造、分支和值绑定采用具名块和分行语句。

保持现有显式求值顺序，带副作用的接收者和实参只求值一次；不能为缩短输出而重复表达式。只在必要时输出类型转换，保留语言数值语义。

参数若因值复制或字段修改需要本地副本，可生成 point_arg: Point 和 var point = point_arg；普通只读参数直接使用源码名。按真实读写信息生成 const/var 和必要的未使用变量消除，不为每个参数无条件输出 keep。

最终用 0.17.1 格式化器格式化，并在格式化后的文本上生成映射。避免在格式化前记录偏移后直接沿用失效位置。

## 9. 产物、依赖和源映射

保持 emit-zig input.saph -o program.zig。无需额外运行库、外部依赖或显式构建选项的程序保留单文件产物。使用内存运行库或其他依赖时生成 program.deps/，并在输出中列明需要一起复制的文件。

program.deps/ 包含 Zig 源码依赖快照、嵌入资源、模块配置清单和必要的构建入口。本地简单依赖可直接 zig build-exe program.zig；存在命名包、链接库或特殊目标配置时，使用生成的 `program.deps/build.sh` 和构建清单恢复模块、目标和链接配置。

复制依赖时保留 Zig 包根目录及文件间相对路径，维护原模块图，不能把所有文件随意合并成一个 Zig 模块。使用模块映射区分各包根目录；不能简单生成指向任意绝对路径的 @import。对 @embedFile、条件依赖及包外资源，采用明确声明的包根/资源清单；未能封装的依赖明确失败，不能遗漏后仍宣称产物独立。

编译缓存使用工具链、目标、优化设置、模块映射和源码/资源内容形成键。第一版对未完整发现依赖的查询关闭持久缓存，避免返回陈旧类型。

生成 program.zig.map.json：记录最终 Zig 区间到 saphine SourceSpan、符号、类型版本、特化调用点的映射。foreign 原文件诊断保留原位置，同时增加 saphine 导入/调用位置。内部生成错误保留原始 Zig 诊断，并标识为生成代码问题，不把所有错误重写成用户源码错误。

来源注释按声明和重要生成块输出，不逐行塞满注释。默认相对项目路径；依赖清单单独保存构建需要的路径信息。

## 10. 标准库与共享运行库

`std` 指向 saphine 标准库，`zig:std` 指向 Zig 标准库。[`src/stdlib/root.zig`](../src/stdlib/root.zig) 随生成源码嵌入。生成的 `main(init: std.process.Init)` 将进程参数和 IO 上下文交给 saphine 标准库。普通 Zig 调用按原签名传参。

裸 `print(value)` 与 `std.print(value)` 共用标准库入口。编译器根据值类型选择格式并传入 IO。参数和文件接口分别调用 `std.arguments(allocator)` 和 `std.readFile(allocator, path)`，分配器由 saphine 程序选择。 [标准库 CLI 接口](LANGUAGE.md#标准库-cli-接口)

`std.memory` 与直接导入 `zig:saphine_runtime` 使用同一个 Zig 内存模块，源码位于 `src/stdlib/memory.zig`。生成产物需要该模块时，`.deps/runtime/memory.zig` 随依赖快照导出，构建命令注册 `saphine_runtime`。

## 11. 实现规划与测试

| 阶段 | 工作 | 预期行为 |
| --- | --- | --- |
| A | 固定工具链；来源/符号身份；NameTable；可读名字 | 现有测试全部通过；不再输出用户函数 F数字、类型 S数字/E数字；语义与 ABI 暂不改变 |
| B | 模块图与 Zig AST 索引；统一容器接口 | 可导入简单 .zig，访问公开常量和显式签名函数；私有/歧义/不存在成员准确报错 |
| C | 外部 IR 引用与调用；依赖封装；Zig check 验证 | check、emit-zig、build 结果一致；移动产物后可构建；Zig 函数体错误能定位到调用 |
| D | 外部类型、通用指针、字段、构造、方法 | 保留名义身份、const 与值复制；静态 Zig 状态共享，saphine 文件实例独立 |
| E | 类型化环境、具名方法/适配器、表达式布局、源映射 | 捕获/旧版本/函数值测试通过；格式化后映射准确；签名清晰且不增加重复求值 |
| F | std 导入、print 门面、有限 comptime/anytype | 现有 print 行为兼容；通用调用保留 Zig 编译期参数；不依赖专用 print IR |
| G | optional/error union 使用能力、复杂泛型与查询后端、包配置 | 分别检查类型构造、匹配、泛型调用与依赖配置，并明确尚不支持的用法 |

阶段 A–C 提供基础导入、调用和可搬移产物；后续阶段扩展类型操作、代码可读性及泛型支持。

测试重点：

- 同名模块/函数、关键字、Unicode 名称、局部遮蔽、匿名函数、多版本与多特化命名。
- 加入无关声明不改变已有输出名称；同一输入在不同路径下输出稳定。
- 两次导入 Zig 模块共享静态状态；两次 use saphine 文件仍独立持有实例状态。
- 别名与重新导出保持类型身份。
- 接收者和参数副作用各执行一次；原有初始化/结构扩展/旧实例/闭包适配行为不变。
- 依赖内相对导入、包名导入、资源嵌入、输出移动与缓存失效。
- 格式化后的源码映射和交叉目标只编译不运行。
- 所有生成产物由 Zig 0.17.1 实际编译；可读性 golden 测试检查签名与命名，而非只比较程序输出。

`sh tests/test.sh`、`sh tests/test-modules.sh` 通过示例及预期输出检查语言和模块语义，`sh tests/test-zig-interop.sh` 和 `sh tests/test-codegen.sh` 分别检查互操作与代码生成。这些脚本不覆盖错误程序的诊断；文中提到的诊断规则不能视为已有对应测试。

## 12. 来源与当前实现位置

- 当前加载/规范化：src/module_loader.zig。
- 当前类型、文件实例、函数特化与 print 特判：src/semantic.zig。
- 当前符号命名、类型化或擦除环境、标准库嵌入与生成器：src/ir.zig。
- 当前 check/build 与临时目录：src/main.zig。
- ZLS 稳定基线：https://github.com/zigtools/zls/blob/0.17.0/build.zig.zon
- ZLS 分析器：https://github.com/zigtools/zls/blob/0.17.0/src/analysis.zig
- ZLS 声明索引：https://github.com/zigtools/zls/blob/0.17.0/src/DocumentScope.zig
- ZLS AST 工具：https://github.com/zigtools/zls/blob/0.17.0/src/ast.zig
- ZLS 许可证：https://github.com/zigtools/zls/blob/0.17.0/LICENSE
