# 词频统计与对象生命周期

## 词频统计

在项目根目录构建并运行：

```sh
zig build run -- build examples/word-count/main.saph -o word-count --optimize ReleaseFast
./word-count arena input.txt
```

第一个参数选择 `heap`、`arena`、`arc` 或 `gc`。程序读取文件、统计词频，再按单词排序输出。添加末尾参数 `smp` 可选择 Zig SMP 底层分配器：

```sh
./word-count heap input.txt smp
```

## 对象生命周期

```sh
zig build run -- build examples/word-count/lifecycle.saph -o lifecycle --optimize ReleaseFast
./lifecycle gc
```

同样可选择 `heap`、`arena`、`arc` 或 `gc`。程序分批创建、访问和释放对象，输出校验和。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| [main.saph](main.saph) | 词频程序入口 |
| [support.zig](support.zig) | 分块读取和词频表实现 |
| [lifecycle.saph](lifecycle.saph) | 对象生命周期程序入口 |
| [lifecycle.zig](lifecycle.zig) | 生命周期实验的 Zig 实现 |
| [benchmark.zig](benchmark.zig) | Zig 原生对照入口 |
| [generate.py](generate.py) | 生成词频输入及参考输出 |
| [comparison/](comparison/) | Rust、C++ 和 Python 对照程序 |

实验环境、测量结果和完整复现命令见[性能实验](../../docs/BENCHMARK.md)。
