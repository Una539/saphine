# 文本搜索

在文件中搜索字节串，输出从 1 开始的行号和字节列号，也会找到重叠匹配。

在项目根目录运行：

```sh
zig build run -- build examples/find/main.saph -o find-text
./find-text 'ana' input.txt
```

[`main.saph`](main.saph) 展示命令行参数、文件读取、optional 匹配和字节串搜索。程序用 Arena 管理参数与文件缓冲区，通过 `defer` 清理资源。

相关接口见[标准库说明](../../src/stdlib/README.md)。
