//! 定义 Saphine 编译器的构建入口，固定 Zig 版本并提供安装与参数透传运行步骤。
const std = @import("std");

comptime {
    const version = @import("builtin").zig_version;
    if (version.major != 0 or version.minor != 17 or version.patch != 1 or version.pre != null or version.build != null)
        @compileError("saphine requires Zig 0.17.1 stable");
}

/// 使用指定目标和优化模式构建编译器，将同一产物注册到安装步骤与 run 步骤。
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "saphine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run saphine").dependOn(&run.step);
}
