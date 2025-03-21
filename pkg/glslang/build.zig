const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("glslang", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };
    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        b.installArtifact(test_exe.?);
    }

    if (b.systemIntegrationOption("glslang", .{})) {
        module.linkSystemLibrary("glslang", dynamic_link_opts);

        if (test_exe) |exe| {
            exe.linkSystemLibrary2("glslang", dynamic_link_opts);
        }
    } else {
        const lib = try buildGlslang(b, module, .{ .target = target, .optimize = optimize });

        if (test_exe) |exe| {
            exe.linkLibrary(lib);
        }
    }
}

fn buildGlslang(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const lib = b.addStaticLibrary(.{
        .name = "glslang",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, module);
    }

    if (b.lazyDependency("glslang", .{})) |upstream| {
        module.addIncludePath(upstream.path(""));
        module.addIncludePath(b.path("override"));
        lib.addIncludePath(upstream.path(""));
        lib.addIncludePath(b.path("override"));
        if (target.result.os.tag.isDarwin()) {
            const apple_sdk = @import("apple_sdk");
            try apple_sdk.addPaths(b, lib.root_module);
        }

        var flags = std.ArrayList([]const u8).init(b.allocator);
        defer flags.deinit();
        try flags.appendSlice(&.{
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
        });

        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                // GenericCodeGen
                "glslang/GenericCodeGen/CodeGen.cpp",
                "glslang/GenericCodeGen/Link.cpp",

                // MachineIndependent
                //"MachineIndependent/glslang.y",
                "glslang/MachineIndependent/glslang_tab.cpp",
                "glslang/MachineIndependent/attribute.cpp",
                "glslang/MachineIndependent/Constant.cpp",
                "glslang/MachineIndependent/iomapper.cpp",
                "glslang/MachineIndependent/InfoSink.cpp",
                "glslang/MachineIndependent/Initialize.cpp",
                "glslang/MachineIndependent/IntermTraverse.cpp",
                "glslang/MachineIndependent/Intermediate.cpp",
                "glslang/MachineIndependent/ParseContextBase.cpp",
                "glslang/MachineIndependent/ParseHelper.cpp",
                "glslang/MachineIndependent/PoolAlloc.cpp",
                "glslang/MachineIndependent/RemoveTree.cpp",
                "glslang/MachineIndependent/Scan.cpp",
                "glslang/MachineIndependent/ShaderLang.cpp",
                "glslang/MachineIndependent/SpirvIntrinsics.cpp",
                "glslang/MachineIndependent/SymbolTable.cpp",
                "glslang/MachineIndependent/Versions.cpp",
                "glslang/MachineIndependent/intermOut.cpp",
                "glslang/MachineIndependent/limits.cpp",
                "glslang/MachineIndependent/linkValidate.cpp",
                "glslang/MachineIndependent/parseConst.cpp",
                "glslang/MachineIndependent/reflection.cpp",
                "glslang/MachineIndependent/preprocessor/Pp.cpp",
                "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
                "glslang/MachineIndependent/preprocessor/PpContext.cpp",
                "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
                "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
                "glslang/MachineIndependent/propagateNoContraction.cpp",

                // C Interface
                "glslang/CInterface/glslang_c_interface.cpp",

                // ResourceLimits
                "glslang/ResourceLimits/ResourceLimits.cpp",
                "glslang/ResourceLimits/resource_limits_c.cpp",

                // SPIRV
                "SPIRV/GlslangToSpv.cpp",
                "SPIRV/InReadableOrder.cpp",
                "SPIRV/Logger.cpp",
                "SPIRV/SpvBuilder.cpp",
                "SPIRV/SpvPostProcess.cpp",
                "SPIRV/doc.cpp",
                "SPIRV/disassemble.cpp",
                "SPIRV/CInterface/spirv_c_interface.cpp",
            },
        });

        if (target.result.os.tag != .windows) {
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .flags = flags.items,
                .files = &.{
                    "glslang/OSDependent/Unix/ossource.cpp",
                },
            });
        } else {
            lib.addCSourceFiles(.{
                .root = upstream.path(""),
                .flags = flags.items,
                .files = &.{
                    "glslang/OSDependent/Windows/ossource.cpp",
                },
            });
        }

        lib.installHeadersDirectory(
            upstream.path("."),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}
