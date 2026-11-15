# Zig 互操作示例

| 示例 | 覆盖内容 |
| --- | --- |
| [text.saph](text.saph) | 从 saphine 调用 Zig 封装的 `std.mem.startsWith` |
| [stdlib.saph](stdlib.saph) | 显式 `std.print`、隐式 `print` 和局部遮蔽 |
| [main.saph](main.saph) | 外部结构体、指针方法、共享模块状态、泛型、回调、错误类型与嵌入资源 |
| [named.saph](named.saph) | 通过 [packages.json](packages.json) 配置命名模块和依赖 |

在仓库根目录运行，例如：

```sh
zig build run -- build examples/zig-interop/text.saph -o text-example
./text-example
zig build run -- check examples/zig-interop/named.saph --zig-config examples/zig-interop/packages.json
```

运行 `sh tests/test-zig-interop.sh` 可编译示例并与[预期输出](outputs/)比对，同时检查交叉编译、依赖搬移等互操作功能。

辅助 Zig 模块、配置和资源供表中的入口程序使用，不单独运行。构建与搬移测试在临时目录执行，资源变化测试只修改示例的临时副本。
