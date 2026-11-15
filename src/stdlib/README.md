# Saphine 标准库

```saph
use std: "std";

const main = fn() -> void {
    std.print("Hello, Saphine!");
};
```


标准库入口在 [`root.zig`](root.zig)，通过 `use std: "std";` 导入。裸 `print(value)` 与 `std.print(value)` 共用入口，局部同名绑定优先。标准库还提供命令行参数迭代、文件读取、字节串搜索和输出。参数迭代和文件读取显式接收调用者选择的分配器。

`std.memory` 提供 Heap、Arena、ARC 和 GC。函数可以使用 `context mem: *std.memory.Manager` 接收具体 manager 或嵌入了 manager 的结构体。调用点可以通过 `using` 选择默认 manager。四种 manager 都能直接传给 Zig 的 `std.mem.Allocator` 参数。 [语言层内存管理](../../docs/LANGUAGE.md#内存分配与清理)

标准库源码嵌在生成的 Zig 文件中。程序用到 `std.memory` 时，导出产物还会带上 `.deps/runtime/memory.zig`，通过随附的 `.deps/build.sh` 注册并构建共享运行库。仅用内嵌标准库且无额外依赖或构建选项的程序可以单文件构建。

## 命令行、文件与输出

通过 `use std: "std";` 导入以下接口。分配器参数可直接接收已有的 Heap、Arena、ARC 或 GC 实例，也可显式传入 `manager.allocator()`。

| 接口 | 行为 |
| --- | --- |
| `std.arguments(allocator)` | 创建参数迭代器，跳过可执行文件名。`next()` 返回 `?[]const u8`，切片借用迭代器存储，使用完成后调用 `deinit()`。 |
| `std.readFile(allocator, path)` | 一次读入整个文件，返回 `?[]u8`。读取失败返回空值，成功返回的缓冲区由调用者负责释放。 |
| `std.freeBytes(allocator, buffer)` | 用创建缓冲区时的同一个分配器释放它。 |
| `std.find(haystack, needle, start)` | 从 `start` 起查找字节串，返回从零开始的匹配偏移 `?usize`。 |
| `std.write(text)` 和 `std.writeNumber(value)` | 写出字节串或 `usize`，不自动换行。 |
| `std.fail(message)` | 写到标准错误并以状态码 1 退出进程。 |

[搜索 CLI](../../examples/find/main.saph) 展示了调用者选择 Arena、清理迭代器并释放文件缓冲区的完整写法。

## 源码

- [`root.zig`](root.zig)：输出、命令行参数、文件与字节串接口。
- [`memory.zig`](memory.zig)：Heap、Arena、ARC、GC 和内存管理接口的运行时实现。
