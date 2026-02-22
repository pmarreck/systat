const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");

    // --- TOML dependency (shared) ---
    const toml_dep = b.dependency("toml", .{});

    // --- Testing backend (for headless TDD) ---
    {
        const dvui_dep = b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = .testing,
        });

        const mod = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        });

        mod.addImport("dvui", dvui_dep.module("dvui_testing"));
        mod.addImport("backend", dvui_dep.module("testing"));
        mod.addImport("toml", toml_dep.module("toml"));

        const unit_tests = b.addTest(.{
            .root_module = mod,
            .name = "systat-tests",
        });
        const run_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_tests.step);
    }

    // --- SDL3 backend (for actual GUI) ---
    {
        const dvui_dep = b.dependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = .sdl3,
        });

        const mod = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        });

        mod.addImport("dvui", dvui_dep.module("dvui_sdl3"));
        mod.addImport("backend", dvui_dep.module("sdl3"));
        mod.addImport("toml", toml_dep.module("toml"));

        const exe = b.addExecutable(.{
            .name = "systat",
            .root_module = mod,
        });

        const compile_step = b.step("compile", "Compile the app");
        compile_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
        b.getInstallStep().dependOn(compile_step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(compile_step);
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run systat");
        run_step.dependOn(&run_cmd.step);

        // --- Smoke test: launch binary, verify no crash, kill ---
        const smoke_cmd = b.addSystemCommand(&.{
            "bash", "scripts/smoke_test.sh",
        });
        smoke_cmd.addArtifactArg(exe);
        smoke_cmd.step.dependOn(compile_step);
        const smoke_step = b.step("smoke", "Smoke test: launch app, verify no crash, kill");
        smoke_step.dependOn(&smoke_cmd.step);
    }
}
