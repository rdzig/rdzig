const std = @import("std");

const codegen = @import("codegen.zig");
const Config = @import("Config.zig");
const Context = @import("Context.zig");
const GodotApi = @import("GodotApi.zig");

var verbose: bool = false;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!verbose and level != .err) return;
    if (!verbose and scope == .markdown_formatter) return;
    std.log.defaultLog(level, scope, format, args);
}

fn nowNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const args_const = try init.minimal.args.toSlice(allocator);
    const args = try allocator.alloc([:0]u8, args_const.len);
    for (args_const, 0..) |arg, i| {
        args[i] = @constCast(arg);
    }
    defer allocator.free(args);

    if (args.len < 6) {
        std.debug.print("Usage: bindgen <gdextension_interface.h> <extension_api.json> <mixins_root> <output_path> <float|double> <32|64> <quiet|verbose>\n", .{});
        return;
    }

    // Assemble the bindgen configuration
    var config = try Config.loadFromArgs(io, args);
    defer config.deinit();

    verbose = config.verbosity == .verbose;

    var buf: [4096]u8 = undefined;
    var reader = config.extension_api.reader(io, &buf);

    // Parse the extension_api.json
    const parser_start = nowNs(io);
    const godot_api = try GodotApi.parseFromReader(&arena, &reader.interface);
    defer godot_api.deinit();
    const parser_time = nowNs(io) - parser_start;

    // Build the codegen context
    const context_start = nowNs(io);
    var ctx = try Context.build(&arena, godot_api.value, config);
    const context_time = nowNs(io) - context_start;

    // Generate the code
    const codegen_start = nowNs(io);
    try codegen.generate(&ctx);
    const codegen_time = nowNs(io) - codegen_start;

    // Format the code
    const format_start = nowNs(io);
    var fmt_child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "fmt" },
        .cwd = .{ .dir = config.output },
        .stderr = .ignore,
        .stdout = .ignore,
    });
    _ = try fmt_child.wait(io);
    const format_time = nowNs(io) - format_start;

    if (config.verbosity == .verbose) {
        if (config.verbosity == .verbose) {
            const total_time = parser_time + context_time + codegen_time + format_time;
            std.debug.print("Parser time: {d:.2}ms\n", .{@as(f64, @floatFromInt(parser_time)) / 1_000_000.0});
            std.debug.print("Context time: {d:.2}ms\n", .{@as(f64, @floatFromInt(context_time)) / 1_000_000.0});
            std.debug.print("Codegen time: {d:.2}ms\n", .{@as(f64, @floatFromInt(codegen_time)) / 1_000_000.0});
            std.debug.print("Format time: {d:.2}ms\n", .{@as(f64, @floatFromInt(format_time)) / 1_000_000.0});
            std.debug.print("Total time: {d:.2}ms\n", .{@as(f64, @floatFromInt(total_time)) / 1_000_000.0});
        }
        std.debug.print("Output path: {s}\n", .{args[4]});
        std.debug.print("Interface: {s}\n", .{args[1]});
        std.debug.print("API JSON: {s}\n", .{args[2]});
    }
}

test {
    std.testing.log_level = .err;
    std.testing.refAllDecls(@This());
}
