const std = @import("std");

fn emsdk(b: *std.Build, sub_path: []const u8) []const u8 {
    return b.dependency("emsdk", .{}).path(sub_path).getPath(b);
}

fn activateEmsdk(b: *std.Build) void {
    const version = b.option([]const u8, "version", "emsdk version to activate") orelse "4.0.15";

    const install = b.addSystemCommand(&.{ emsdk(b, "emsdk"), "install", version });
    const activate = b.addSystemCommand(&.{ emsdk(b, "emsdk"), "activate", version });

    activate.step.dependOn(&install.step);

    const step = b.step("activate", "Activate emsdk");
    step.dependOn(&activate.step);
}

pub fn build(b: *std.Build) void {
    activateEmsdk(b);

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

    const emcc = b.addSystemCommand(&.{
        std.fs.path.join(b.allocator, &.{
            emsdk(b, "upstream"),
            "emscripten",
            "emcc",
        }) catch unreachable,
        "-mtail-call",
        "-pthread",
        "-sPROXY_TO_PTHREAD",
        "-sEXPORTED_FUNCTIONS=_malloc,_main",
        "--js-library=node_modules/xterm-pty/emscripten-pty.js",
    });
    const out_file = emcc.addPrefixedOutputFileArg("-o", "zorth.mjs");
    emcc.addArtifactArg(lib);

    const install = b.addInstallDirectory(.{
        .source_dir = out_file.dirname(),
        .install_dir = .prefix,
        .install_subdir = "",
    });
    install.step.dependOn(&emcc.step);

    const index = b.addInstallFile(b.path("demo/index.html"), "index.html");
    install.step.dependOn(&index.step);

    const service = b.addInstallFile(b.path("node_modules/coi-serviceworker/coi-serviceworker.min.js"), "coi-serviceworker.min.js");
    install.step.dependOn(&service.step);

    const bootstrap = b.addInstallFile(b.path("jonesforth/jonesforth.f"), "jonesforth.f");
    install.step.dependOn(&bootstrap.step);

    b.getInstallStep().dependOn(&install.step);
}
