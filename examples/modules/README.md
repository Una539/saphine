# 模块系统示例

在项目根目录运行：

```sh
sh tests/test-modules.sh
```

示例按用途组织：

- 本目录的 `.saph` 文件：应该编译并运行成功的入口程序。
- [`lib/`](lib/)：被导入的辅助文件和目录，不要求有 `main`，不是独立入口。
- [`outputs/`](outputs/)：入口程序的预期标准输出，不是程序入口。

脚本对每个入口程序执行 `check`，再分别通过 `emit-zig` 后独立编译和 `build` 两种方式生成并运行程序，将两份输出与预期比对。

## 入口程序

| 程序 | 检查内容 |
| --- | --- |
| `basic.saph` | 显式扩展名、具名访问和成员提升 |
| `instances.saph` | 同文件重复嵌入的独立存储、绑定函数值、私有成员内部访问 |
| `type_identity.saph` | 不同路径写法指向同文件时复用类型身份 |
| `reexport.saph` | 目录 `mod.saph`、相对路径和公开提升成员 |
| `explicit_paths.saph` | 同名文件和目录通过明确路径消歧 |
| `struct_use.saph` | 结构体内文件嵌入、文件作用域普通类型 `use` |
| `internal_layers.saph` | 多级 `internal` 提升、层内访问、显式公开 |
| `private_inside.saph` | 私有嵌入在本层方法中仍可使用 |
| `init_order.saph` | 父文件和子对象的初始化顺序 |
| `defaults.saph` | 显式字段跳过默认副作用，后续默认值读取显式字段 |
| `embedded_override.saph` | 显式嵌入值不重复执行默认子对象初始化 |
| `evolution.saph` | 连续类型演化保留默认初始化和方法，旧类型独立 |
| `constants.saph` | 局部编译期整数用于结构体字段类型和默认值 |

`explicit_paths.saph` 分别导入 `lib/ambiguous.saph` 和 `lib/ambiguous/mod.saph`，展示如何用明确路径区分同名文件和目录模块。

出现失败时脚本保留 `.zig-cache/modules.*` 中的生成代码和程序输出等信息，方便定位；全部通过时自动清理。
