# 基础语法示例

在项目根目录运行：

```sh
zig build run -- build examples/basics/hello.saph -o hello
./hello
```

| 示例 | 内容 |
| --- | --- |
| `hello.saph` | 入口、注释、标准输出 |
| `bindings.saph` | 绑定、类型标注和赋值 |
| `numbers.saph` | 整数和浮点数 |
| `arithmetic.saph` | 算术运算 |
| `strings_and_bools.saph` | 字节串和布尔值 |
| `arrays.saph` | 数组、下标和切片 |
| `enums.saph` | 枚举、数据成员和模式匹配 |
| `loops.saph` | 数组遍历和循环 |
| `conditionals.saph` | 条件、比较和逻辑运算 |
| `blocks.saph` | 块作用域和遮蔽 |
| `functions.saph` | 函数和顶层绑定 |
| `function_values.saph` | 函数值和传参 |
| `structs.saph` | 结构体和字段 |
| `pointers_and_methods.saph` | 指针和方法 |
| `namespaces.saph` | 类型上的静态成员 |
| `type_values.saph` | 类型值 |
| `operators.saph` | 算术、比较、位运算、一元符号和复合赋值的重载 |
| `use_fields.saph` | 嵌入字段和共享存储 |
| `snapshots.saph` | 类型值重新绑定和旧版本分发 |
| `struct_extension.saph` | `..`、`+=` 声明扩展、默认值、嵌套 `Self` 和旧实例 |
| `struct_extension_scopes.saph` | 扩展的词法捕获、默认初始化变体、显式旧别名和 `Self` 区分 |
| `use.saph` | 方法覆盖和静态多态 |

