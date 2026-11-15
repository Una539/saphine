//! 演示通过配置别名导入 arithmetic 模块，而非直接依赖本地文件名。
const math = @import("arithmetic");
/// 调用映射到 math 模块的 add，展示具名依赖及共享模块状态。
pub fn value() i32 {
    return math.add(3);
}
