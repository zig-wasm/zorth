const std = @import("std");
const zemscripten = @import("zemscripten");

pub fn build(b: *std.Build) !void {
    const activateEmsdk = zemscripten.activateEmsdkStep(b);
    const activate = b.step("activate", "Activate emsdk");
    activate.dependOn(activateEmsdk);

    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .wasm32,
            .os_tag = .emscripten,
            .cpu_features_add = std.Target.wasm.featureSet(&[_]std.Target.wasm.Feature{
                .atomics,
                .bulk_memory,
                .tail_call,
            }),
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const lib = b.addLibrary(.{
        .name = "zorth",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zorth.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.rdynamic = true;
    lib.linkLibC();

    var emcc_flags = zemscripten.emccDefaultFlags(b.allocator, .{
        .optimize = optimize,
        .fsanitize = false,
    });
    try emcc_flags.put("-mtail-call", {});
    try emcc_flags.put("-pthread", {});

    var emcc_settings = zemscripten.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
        .emsdk_allocator = .dlmalloc,
    });
    try emcc_settings.put("PROXY_TO_PTHREAD", "1");
    try emcc_settings.put("EXPORTED_FUNCTIONS", "_malloc,_main");

    const emcc_step = zemscripten.emccStep(b, lib, .{
        .optimize = optimize,
        .flags = emcc_flags,
        .settings = emcc_settings,
        .out_file_name = "zorth.mjs",
        .install_dir = .prefix,
        .js_library_path = b.path("node_modules/xterm-pty/emscripten-pty.js"),
    });

    inline for (.{
        "demo/index.html",
        "node_modules/coi-serviceworker/coi-serviceworker.min.js",
        "jonesforth/jonesforth.f",
    }) |sub_path| {
        const file = b.addInstallFile(
            b.path(sub_path),
            std.fs.path.basename(sub_path),
        );
        emcc_step.dependOn(&file.step);
    }
    b.getInstallStep().dependOn(emcc_step);

    const test_step = b.step("test", "Run unit tests");

    const native_tests = b.addTest(.{
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zorth.zig"),
            .target = b.resolveTargetQuery(.{}),
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
                    .atomics,
                    .bulk_memory,
                    .tail_call,
                }),
            }),
        }),
    });
    wasm_tests.setExecCmd(&.{ "wasmtime", null });
    const run_wasm_tests = b.addRunArtifact(wasm_tests);
    test_step.dependOn(&run_wasm_tests.step);
}
