# Saphine

Saphine 是一门实验性编程语言，使用 Zig 0.17.1 实现，将源码转换为 Zig，再编译成原生程序。

语言围绕结构体组合、静态多态和可在编译期演化的类型展开，并支持直接调用 Zig 代码。标准库提供 Heap、Arena、ARC 和 GC，让程序按需要选择内存管理方式。

**Work In Progress** · 语言仍在开发中，语法和接口可能发生变化。

## 快速开始

安装 Zig 0.17.1，在项目根目录运行：

```sh
zig build run -- build examples/basics/hello.saph -o hello
./hello
```

当然，也可以先用 `zig build` 构建编译器。

## 继续了解

- [语言手册](docs/LANGUAGE.md)：语法、类型、模块和 Zig 互操作。
- [标准库](src/stdlib/README.md)：输出、文件、命令行参数和内存管理。
- [示例](examples/README.md)：从基础语法到完整命令行程序。
- [性能实验](docs/BENCHMARK.md)：词频统计和对象生命周期的跨语言比较。
- [功能与计划](docs/FEATURES.md)：已支持的功能和后续方向。
