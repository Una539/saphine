# 词频与对象生命周期基准

## 命令行程序

词频程序按单词累计出现次数并排序输出，可选择 `heap`、`arena`、`arc` 或 `gc`，末尾添加 `smp` 可使用 Zig SMP 底层分配器。在项目根目录运行：

```sh
zig build run -- build examples/word-count/main.saph -o word-count --optimize ReleaseFast
./word-count arena input.txt
```

[词频与生命周期示例](../examples/word-count/README.md)介绍源码和运行参数。[文本搜索示例](../examples/find/README.md)则演示参数解析、文件读取和字节串搜索，不参与下面的计时比较。

## 工作负载

| 实验 | 输入 | 计时范围 |
|---|---|---|
| A | 2,147,483,646 字节，339,241,877 个词，8 个不同词 | 以 32 KiB 块读入，跨块拼词，累计词频，按词排序并输出 |
| B | 12,000,000 字节，1,000,000 个不同词，每词出现一次 | 同 A，词频表从空表扩容到 100 万个键 |
| C | 32,768 批，每批 4,096 个对象，每对象 64 字节有效载荷 | 每批先创建全部对象，再读取并累计校验和，最后释放整批 |

C 共创建 134,217,728 个对象。每个对象由一个递增的 64 位 ID 和 56 个取 ID 低字节的字节组成。校验和为 `9007216300392448`。A、B 的排序输出逐字节与 Python 生成测试文件时计算的参考答案比较。

## 环境和口径

- AMD Ryzen 9 7940H，x86-64 Linux 7.3.3-300.fc45.x86_64。Zig 0.17.1 `ReleaseFast`，rustc 1.99.1 `-O`，GCC 16.2.1 `-std=c++20 -O3 -DNDEBUG`，CPython 3.15.2。
- 每个组合运行 3 次。各组合串行运行，每轮改变顺序。GNU `time` 测量进程墙钟时间和峰值 RSS，汇总取中位数。计时覆盖启动、读入、计算、输出和清理；编译、数据生成和输出比对在计时范围之外。
- A、B 复用同一份磁盘数据，运行之间不清空操作系统文件缓存。B 的排序和百万行输出也包含在结果中。
- Zig 原生入口与 saphine 共用 A、B 的 Zig 词法及哈希表实现，C 共用 Heap 的批次实现。Zig 原生和 Saphine 四种 manager 都以 Zig `smp_allocator` 为底层分配器。Rust 使用标准 `HashMap` 和 `Box`，C++ 使用 `unordered_map` 和 `unique_ptr`，Python 使用 `bytes.split`、`Counter`，并以 `struct.pack` 创建 64 字节载荷的 `bytes` 对象。Python 对象头另占内存。
- C 的 saphine ARC 在批末逐个释放，GC 在撤掉整批根后显式收集，并检查存活对象数归零。C 对象没有相互引用，也没有自定义析构器。A、B 的 saphine ARC 和 GC 通过 Zig allocator 路径运行。

## 测量结果

Zig、Rust、C++、Python 的 36 次新测量全部通过输出校验。下表同时收录同一台机器上先前通过校验的 36 次 saphine 测量。

### 墙钟时间中位数（秒）

| 实现 | A | B | C |
|---|---:|---:|---:|
| Zig | **3.35** | 0.95 | **0.75** |
| Rust | 5.62 | 0.86 | 3.99 |
| C++ | 4.48 | 0.74 | 2.02 |
| Python | 21.69 | **0.44** | 17.43 |
| saphine Heap | 4.16 | 1.04 | 0.76 |
| saphine Arena | 4.17 | 0.88 | 0.77 |
| saphine ARC | 5.16 | 1.28 | 0.98 |
| saphine GC | 5.34 | 1.44 | 2.25 |

### 峰值 RSS 中位数（MiB）

| 实现 | A | B | C |
|---|---:|---:|---:|
| Zig | 0.93 | 88.41 | 1.18 |
| Rust | 2.23 | 129.34 | 2.46 |
| C++ | 4.23 | **83.20** | 4.34 |
| Python | 10.97 | 103.81 | 10.59 |
| saphine Heap | **0.80** | 88.14 | **1.02** |
| saphine Arena | **0.80** | 137.68 | 1.10 |
| saphine ARC | **0.80** | 126.92 | 1.27 |
| saphine GC | 9.18 | 219.27 | 1.27 |

### 三次墙钟时间（秒）

| 实现 | A | B | C |
|---|---:|---:|---:|
| Zig | 3.34 / 3.35 / 3.39 | 0.94 / 0.95 / 1.03 | 0.75 / 0.75 / 0.73 |
| Rust | 5.51 / 5.62 / 5.65 | 0.82 / 0.87 / 0.86 | 4.04 / 3.99 / 3.95 |
| C++ | 4.48 / 4.44 / 4.51 | 0.74 / 0.77 / 0.69 | 2.02 / 2.03 / 2.00 |
| Python | 21.03 / 23.02 / 21.69 | 0.51 / 0.44 / 0.42 | 17.77 / 17.43 / 17.41 |
| saphine Heap | 4.25 / 4.07 / 4.16 | 1.04 / 1.00 / 1.08 | 0.78 / 0.76 / 0.76 |
| saphine Arena | 4.19 / 4.14 / 4.17 | 0.95 / 0.88 / 0.78 | 0.77 / 0.79 / 0.77 |
| saphine ARC | 5.25 / 5.14 / 5.16 | 1.34 / 1.24 / 1.28 | 0.98 / 1.01 / 0.95 |
| saphine GC | 5.43 / 5.34 / 5.20 | 1.52 / 1.42 / 1.44 | 2.13 / 2.25 / 2.30 |

B 的单词以字典序倒序写入文件。各实现的哈希表迭代顺序和排序算法不同，这会影响 B 的端到端时间。C 的各语言采用各自的内存分配接口，因此结果反映整条分配、访问和释放路径。

当前工作区的 [跨语言原始 CSV](../.saphine-cache/word-count-benchmark/cross-language.csv) 和 [saphine 原始 CSV](../.saphine-cache/word-count-benchmark/experiments-final.csv) 包含各次 CPU 时间、RSS 和缺页次数。

## 实现与复现

- saphine [词频入口](../examples/word-count/main.saph) · [生命周期入口](../examples/word-count/lifecycle.saph)
- Zig [原生入口](../examples/word-count/benchmark.zig) · [共享词频实现](../examples/word-count/support.zig) · [共享生命周期实现](../examples/word-count/lifecycle.zig)
- [Rust](../examples/word-count/comparison/rust_main.rs) · [C++](../examples/word-count/comparison/cpp_main.cpp) · [Python](../examples/word-count/comparison/python_main.py)
- [输入生成器](../examples/word-count/generate.py)

在仓库根目录构建和生成输入。

```sh
bench=.saphine-cache/word-count-benchmark
bin="$bench/cross-bin"
mkdir -p "$bin"

zig build
zig-out/bin/saphine build examples/word-count/main.saph -o "$bin/saphine-words" --optimize ReleaseFast
zig-out/bin/saphine build examples/word-count/lifecycle.saph -o "$bin/saphine-life" --optimize ReleaseFast
zig build-exe -O ReleaseFast --dep saphine_runtime \
  -Mroot=examples/word-count/benchmark.zig \
  -O ReleaseFast -Msaphine_runtime=src/stdlib/memory.zig -femit-bin="$bin/zig"
rustc -O examples/word-count/comparison/rust_main.rs -o "$bin/rust"
g++ -std=c++20 -O3 -DNDEBUG examples/word-count/comparison/cpp_main.cpp -o "$bin/cpp"

python3 examples/word-count/generate.py "$bench/corpus.txt" "$bench/expected.txt" --gib 2
python3 examples/word-count/generate.py "$bench/unique.txt" "$bench/unique.expected" --unique 1000000
```

Zig、Rust、C++ 和 Python 都接受 `words <file>` 或 `lifecycle`。saphine 词频入口接受 `<heap|arena|arc|gc> <file> smp`，生命周期入口接受 `<heap|arena|arc|gc>`。将输出重定向到文件后用 `cmp` 与参考答案比较。
