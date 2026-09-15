const latest_version = "26.2-stable";

pub fn build(b: *Build) !void {
    //
    // Options
    //

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const precision = b.option([]const u8, "precision", "Floating point precision, either `float` or `double` [default: `float`]") orelse "float";
    const architecture = b.option([]const u8, "arch", "32") orelse "64";
    const redot_version = b.option([]const u8, "redot-version", "Download and use this Redot version (e.g. `latest` or `26.2`)");
    const redot_path = b.option([]const u8, "redot-path", "Path to a Redot executable");

    //
    // Steps
    //

    const check_step = b.step("check", "Check the build without installing artifacts");
    const test_step = b.step("test", "Run unit tests");

    //
    // Dependencies
    //

    const casez = b.dependency("casez", .{});
    const oopz = b.dependency("oopz", .{});

    //
    // Redot
    //

    // Redot executable for the host (used for bindgen, running editor, etc.)
    const redot_exe_host: ?Build.LazyPath = blk: {
        if (redot_path) |p| {
            break :blk .{ .cwd_relative = p };
        }
        if (redot_version) |v| {
            break :blk redot.executable(b, b.graph.host, v);
        }
        if (b.findProgram(&.{"redot"}, &.{}) catch null) |p| {
            break :blk .{ .cwd_relative = p };
        }
        break :blk redot.executable(b, b.graph.host, latest_version);
    };

    // Redot executable for the target (used for running tests)
    // This enables cross-platform testing with -fwine
    const redot_exe_target: ?Build.LazyPath = blk: {
        if (redot_path) |p| {
            // If user specifies a path, assume it's for the target
            break :blk .{ .cwd_relative = p };
        }
        const tgt = if (target.result.cpu.arch.isWasm()) b.graph.host else target;
        if (redot_version) |v| {
            break :blk redot.executable(b, tgt, v);
        }
        break :blk redot.executable(b, tgt, latest_version);
    };

    const headers = blk: {
        const api_header_source: redot.HeaderSource = if (redot_path != null) .{ .exe = redot_exe_host.? } else if (redot_version) |v| .{ .version = v } else .{ .version = latest_version };
        const gdextension_interface_h = redot.headers(b, b.graph.host, api_header_source).path(b, "gdextension_interface.h");
        const extension_api_json = redot.headers(b, b.graph.host, api_header_source).path(b, "extension_api.json");

        const write = b.addWriteFiles();
        _ = write.addCopyFile(gdextension_interface_h, "gdextension_interface.h");
        _ = write.addCopyFile(extension_api_json, "extension_api.json");
        break :blk write.getDirectory();
    };

    if (redot_exe_target) |exe| {
        b.addNamedLazyPath("redot", exe);
    }
    b.addNamedLazyPath("gdextension_interface.h", headers.path(b, "gdextension_interface.h"));
    b.addNamedLazyPath("extension_api.json", headers.path(b, "extension_api.json"));

    //
    // GDExtension
    //

    const gdextension_mod = gdextension.build(b, .{
        .headers = headers,
        .target = target,
        .optimize = optimize,
    });

    //
    // Common
    //

    const common_mod = common.build(b, .{
        .target = target,
        .optimize = optimize,
        .casez = casez.module("casez"),
    });

    //
    // Bindgen
    //

    const bindgen_exe = bindgen.build(b, .{
        .headers = headers,
        .target = b.graph.host,
        .optimize = .Debug,
        .precision = precision,
        .architecture = architecture,
    });
    const bindings = bindgen.run(b, bindgen_exe, .{
        .headers = headers,
        .precision = precision,
        .architecture = architecture,
    });

    //
    // Library
    //

    const gdzig_files = b.addWriteFiles();
    const gdzig_combined = gdzig_files.addCopyDirectory(b.path("src"), "gdzig", .{
        .exclude_extensions = &.{".mixin.zig"},
    });
    _ = gdzig_files.addCopyDirectory(bindings, "gdzig", .{});

    const gdzig_options = b.addOptions();
    gdzig_options.addOption([]const u8, "architecture", architecture);
    gdzig_options.addOption([]const u8, "precision", precision);

    const gdzig_mod = b.addModule("gdzig", .{
        .root_source_file = gdzig_combined.path(b, "gdzig.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "build_options", .module = gdzig_options.createModule() },
            .{ .name = "casez", .module = casez.module("casez") },
            .{ .name = "gdextension", .module = gdextension_mod },
            .{ .name = "common", .module = common_mod },
            .{ .name = "oopz", .module = oopz.module("oopz") },
        },
    });
    gdzig_mod.addImport("gdzig", gdzig_mod);

    const gdzig_lib = b.addLibrary(.{
        .name = "gdzig",
        .root_module = gdzig_mod,
        .linkage = .static,
        .use_llvm = true,
    });

    //
    // Tests
    //
    var tests_gdzig_run: ?*Build.Step.Run = null;
    var tests_common_run: ?*Build.Step.Run = null;

    if (!target.result.cpu.arch.isWasm()) { // Do not add test for web targets.
        // NOTE: LLVM backend required - the 0.16 self-hosted linker chokes on
        // GCC 16 crt files (R_X86_64_PC64 in .sframe).
        const tests_gdzig = b.addTest(.{ .root_module = gdzig_mod, .use_llvm = true });
        const tests_common = b.addTest(.{ .root_module = common_mod, .use_llvm = true });
        tests_gdzig_run = b.addRunArtifact(tests_gdzig);
        tests_common_run = b.addRunArtifact(tests_common);

        var tests_dir = try std.Io.Dir.cwd().openDir(
            b.graph.io, 
            b.path("test").getPath2(b, null), 
            .{ .iterate = true }
        );
        defer tests_dir.close(b.graph.io);

        var iter = tests_dir.iterate();
        while (iter.next(b.graph.io) catch null) |entry| {
            if (entry.kind != .directory) continue;

            const test_mod = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}/root.zig", .{entry.name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gdzig", .module = gdzig_mod },
                },
            });

            const run_test = api.addTestImpl(b, .{ .b = b, .dep = null }, .{
                .name = b.dupe(entry.name),
                .root_module = test_mod,
                .target = target,
                .optimize = optimize,
            });
            test_step.dependOn(&run_test.step);
        }
    }

    //
    // Step dependencies
    //

    check_step.dependOn(&gdzig_lib.step);
    if (tests_gdzig_run) |r| test_step.dependOn(&r.step);
    if (tests_common_run) |r| test_step.dependOn(&r.step);

    //
    // Default step
    //

    // NOTE: the bindings install writes back into src/, which the lib
    // compile reads (WriteFiles copy). Order it after the lib so the two
    // don't race under parallel builds (ghost tmp files fail the
    // WriteFiles cache check). addInstallDirectory (manual wiring) is
    // used instead of installDirectory so the dependency can be set.
    const install_bindings = b.addInstallDirectory(.{
        .source_dir = bindings,
        .install_dir = .{ .custom = "../" },
        .install_subdir = "src",
    });
    install_bindings.step.dependOn(&gdzig_lib.step);
    b.getInstallStep().dependOn(&install_bindings.step);
    b.installArtifact(bindgen_exe);
    b.installDirectory(.{
        .source_dir = gdzig_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.installDirectory(.{
        .source_dir = headers,
        .install_dir = .prefix,
        .install_subdir = "vendor",
    });
}

const std = @import("std");
const Build = std.Build;

const redot = @import("redot");

const api = @import("build/api.zig");
pub const addExtension = api.addExtension;
pub const addTest = api.addTest;
pub const Extension = api.Extension;
pub const ExtensionOptions = api.ExtensionOptions;
pub const TestOptions = api.TestOptions;
pub const InitializationLevel = api.InitializationLevel;
const bindgen = @import("build/bindgen.zig");
const common = @import("build/common.zig");
const gdextension = @import("build/gdextension.zig");
