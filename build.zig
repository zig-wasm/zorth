const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                .tail_call,
            }),
        },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Zig's own linker produces a standalone `_start` command directly, so
    // the browser demo drives it the same way as any other WASI command: a
    // Worker blocks stdin on a uwasi SharedInputChannel instead of a real
    // pty (see demo/wasi-worker.js). `openFlags`'s `.wasi` branch and
    // `main`'s `std.Io.File.stdin()`/`stdout()` (src/zorth.zig) already
    // needed no changes for this -- only the build target did.
    const exe = b.addExecutable(.{
        .name = "zorth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zorth.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const install_exe = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .prefix } });
    b.getInstallStep().dependOn(&install_exe.step);

    inline for (.{
        "demo/index.html",
        "demo/wasi-repl.mjs",
        "demo/wasi-worker.js",
        "node_modules/coi-serviceworker/coi-serviceworker.min.js",
        "jonesforth/jonesforth.f",
    }) |sub_path| {
        const file = b.addInstallFile(
            b.path(sub_path),
            std.fs.path.basename(sub_path),
        );
        b.getInstallStep().dependOn(&file.step);
    }

    const test_step = b.step("test", "Run unit tests");

    const native_tests = b.addTest(.{
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zorth.zig"),
            .target = b.resolveTargetQuery(.{}),
            .link_libc = true,
        }),
    });
    const run_native_tests = b.addRunArtifact(native_tests);
    test_step.dependOn(&run_native_tests.step);

    const wasm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zorth.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .wasi,
                .cpu_features_add = std.Target.wasm.featureSet(&.{
                    .tail_call,
                }),
            }),
            .link_libc = true,
        }),
    });
    const run_wasm_tests = b.addRunArtifact(wasm_tests);
    // Run with `-fwasmtime` to have the wasm32-wasi binary executed under
    // wasmtime; `Compile.setExecCmd` was removed in Zig 0.17.0.
    test_step.dependOn(&run_wasm_tests.step);
}
