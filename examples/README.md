# 示例导航

在项目根目录运行编译器，例如：

```sh
zig build run -- build examples/basics/hello.saph -o hello
./hello
```

| 分类 | 内容 |
| --- | --- |
| [basics/](basics/README.md) | 22 个基础语言示例：绑定、控制流、函数、类型、结构体与组合等 |
| [modules/](modules/README.md) | 文件模块、可见性、初始化、类型身份与演化；入口 `.saph` 位于该目录根层 |
| [memory/](memory/) | Heap、Arena、ARC、GC 与静态管理接口 |
| [find/](find/README.md) | 文本搜索 CLI，入口为 `main.saph` |
| [word-count/](word-count/README.md) | 词频 CLI、对象生命周期基准及跨语言对照 |
| [zig-interop/](zig-interop/README.md) | Zig 调用、标准库、外部类型与命名模块配置 |

`modules/lib/` 存放供入口导入的辅助模块，不要求有 `main`。各分类中的 `outputs/` 保存预期输出，其中基础示例的输出位于 `basics/outputs/`。辅助模块、配置、资源和预期输出不都是独立入口。

各分类的 README 提供运行说明。测试脚本位于项目根目录的 `tests/`。
