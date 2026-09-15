//! Test coordinator that bridges the Zig build system and Godot processes.
//!
//! This executable:
//! 1. Speaks the std.zig.Server protocol with the build system (via stdin/stdout)
//! 2. Spawns Godot processes for each test folder
//! 3. Communicates with test harnesses via JSON IPC over stdin/stdout pipes
//!
//! The coordinator maintains a mapping from global test indices to (folder, local_index) pairs.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const options = @import("runner_options");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ZigServer = std.zig.Server;

/// Mapping from global test index to folder and local index
const TestMapping = struct {
    folder_index: u32,
    local_index: u32,
};

/// State for the test runner
const Runner = struct {
    allocator: Allocator,
    io: Io,
    base_environ: *const std.process.Environ.Map,
    server: ZigServer,
    test_mappings: std.ArrayListUnmanaged(TestMapping),
    string_bytes: std.ArrayListUnmanaged(u8),
    test_name_indices: std.ArrayListUnmanaged(u32),

    fn init(allocator: Allocator, io: Io, base_environ: *const std.process.Environ.Map, in: *Io.Reader, out: *Io.Writer) !Runner {
        const server = try ZigServer.init(.{
            .in = in,
            .out = out,
            .zig_version = builtin.zig_version_string,
        });

        return .{
            .allocator = allocator,
            .io = io,
            .base_environ = base_environ,
            .server = server,
            .test_mappings = .empty,
            .string_bytes = .empty,
            .test_name_indices = .empty,
        };
    }

    fn deinit(self: *Runner) void {
        self.test_mappings.deinit(self.allocator);
        self.string_bytes.deinit(self.allocator);
        self.test_name_indices.deinit(self.allocator);
    }

    fn run(self: *Runner) !void {
        while (true) {
            const header = self.server.receiveMessage() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            switch (header.tag) {
                .exit => break,
                .query_test_metadata => try self.handleQueryTestMetadata(),
                .run_test => {
                    const index = try self.server.receiveBody_u32();
                    try self.handleRunTest(index);
                },
                else => {
                    _ = try self.server.in.discard(Io.Limit.limited(header.bytes_len));
                },
            }
        }
    }

    fn handleQueryTestMetadata(self: *Runner) !void {
        // Clear previous state
        self.test_mappings.clearRetainingCapacity();
        self.string_bytes.clearRetainingCapacity();
        self.test_name_indices.clearRetainingCapacity();

        // Collect metadata from each test folder
        for (options.test_folders, 0..) |folder, folder_idx| {
            try self.collectFolderMetadata(folder, @intCast(folder_idx));
        }

        // Build expected_panic_msgs (all zeros - we don't use panic expectations)
        const expected_panic_msgs = try self.allocator.alloc(u32, self.test_name_indices.items.len);
        defer self.allocator.free(expected_panic_msgs);
        @memset(expected_panic_msgs, 0);

        // Send metadata to build system
        try self.server.serveTestMetadata(.{
            .names = self.test_name_indices.items,
            .expected_panic_msgs = expected_panic_msgs,
            .string_bytes = self.string_bytes.items,
        });
    }

    fn collectFolderMetadata(self: *Runner, folder: []const u8, folder_idx: u32) !void {
        const folder_name = std.fs.path.basename(folder);

        // Spawn Redot with stdin/stdout piped
        var child = try self.spawnRedot(folder);
        defer {
            _ = child.wait(self.io) catch {};
        }

        // Send query_metadata command
        try self.sendCommand(&child, .query_metadata);

        // Read response from stdout, filtering out Godot noise
        var godot_output: std.ArrayListUnmanaged(u8) = .empty;
        defer godot_output.deinit(self.allocator);

        const response = try self.readResponse(&child, &godot_output);
        if (response) |resp| {
            defer {
                var r = resp;
                protocol.freeResponse(self.allocator, &r);
            }

            switch (resp) {
                .metadata => |tests| {
                    for (tests, 0..) |name, i| {
                        // Record the string index before adding the prefixed name
                        const string_idx: u32 = @intCast(self.string_bytes.items.len);
                        try self.test_name_indices.append(self.allocator, string_idx);

                        // Add prefixed name: "folder.test name\0"
                        try self.string_bytes.appendSlice(self.allocator, folder_name);
                        try self.string_bytes.append(self.allocator, '.');
                        try self.string_bytes.appendSlice(self.allocator, name);
                        try self.string_bytes.append(self.allocator, 0);

                        // Record mapping
                        try self.test_mappings.append(self.allocator, .{
                            .folder_index = folder_idx,
                            .local_index = @intCast(i),
                        });
                    }
                },
                .result => return error.UnexpectedResponse,
            }
        } else {
            if (godot_output.items.len > 0) {
                std.debug.print("Godot output:\n{s}\n", .{godot_output.items});
            }
            return error.NoResponse;
        }

        // Send exit command
        try self.sendCommand(&child, .exit);
    }

    fn handleRunTest(self: *Runner, global_index: u32) !void {
        // Notify the build runner that the requested test is starting.
        // Required since Zig 0.16: without test_started the runner cannot
        // attribute the following test_results message and panics.
        try self.server.serveMessageHeader(.{ .tag = .test_started, .bytes_len = 0 });
        try self.server.out.flush();

        if (global_index >= self.test_mappings.items.len) {
            try self.server.serveTestResults(.{
                .index = global_index,
                .flags = .{ .status = .fail, .fuzz = false, .log_err_count = 0, .leak_count = 0 },
            });
            return;
        }

        const mapping = self.test_mappings.items[global_index];
        const folder = options.test_folders[mapping.folder_index];

        // Spawn Redot
        var child = try self.spawnRedot(folder);
        defer {
            _ = child.wait(self.io) catch {};
        }

        // Send run_test command
        try self.sendCommand(&child, .{ .run_test = mapping.local_index });

        // Read response, collecting Godot output
        var godot_output: std.ArrayListUnmanaged(u8) = .empty;
        defer godot_output.deinit(self.allocator);

        var failed = true;
        const response = try self.readResponse(&child, &godot_output);
        if (response) |resp| {
            defer {
                var r = resp;
                protocol.freeResponse(self.allocator, &r);
            }

            switch (resp) {
                .result => |result| {
                    failed = !result.passed;
                },
                .metadata => {},
            }
        }

        // Send exit command (the deferred wait reaps the child;
        // Child.wait is not idempotent, so wait exactly once).
        self.sendCommand(&child, .exit) catch {};

        // If test failed, print Redot's output to stderr so user sees stack trace
        if (failed and godot_output.items.len > 0) {
            var err_buf: [4096]u8 = undefined;
            var err_writer = std.Io.File.stderr().writer(self.io, &err_buf);
            err_writer.interface.writeAll(godot_output.items) catch {};
            err_writer.interface.flush() catch {};
        }

        // Send result to build system
        try self.server.serveTestResults(.{
            .index = global_index,
            .flags = .{
                .status = if (failed) .fail else .pass,
                .fuzz = false,
                .log_err_count = 0,
                .leak_count = 0,
            },
        });
    }

    /// Send a command to the child process stdin
    fn sendCommand(self: *Runner, child: *std.process.Child, cmd: protocol.Command) !void {
        const stdin = child.stdin orelse return error.NoStdin;
        var buf: [4096]u8 = undefined;
        var writer = stdin.writer(self.io, &buf);
        try protocol.writeCommand(&writer.interface, cmd);
        try writer.interface.flush();
    }

    /// Read lines from Redot's stdout until we get an IPC response.
    /// Non-IPC lines are collected in godot_output for error display.
    /// Uses direct read() to avoid Windows pipe issues with pread/overlapped I/O.
    /// See: https://github.com/ziglang/zig/issues/25291
    fn readResponse(self: *Runner, child: *std.process.Child, godot_output: *std.ArrayListUnmanaged(u8)) !?protocol.Response {
        const stdout = child.stdout orelse return null;
        var line_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        var read_buf: [4096]u8 = undefined;
        var buf_start: usize = 0;
        var buf_end: usize = 0;

        while (true) {
            // Read bytes until we find a newline
            line_buf.clearRetainingCapacity();
            while (true) {
                // Refill buffer if empty
                if (buf_start >= buf_end) {
                    const n = stdout.readStreaming(self.io, &.{&read_buf}) catch return null;
                    if (n == 0) return null; // EOF
                    buf_start = 0;
                    buf_end = n;
                }

                const byte = read_buf[buf_start];
                buf_start += 1;

                if (byte == '\n') break;
                try line_buf.append(self.allocator, byte);
            }

            const line = line_buf.items;

            // Check if this is an IPC message
            if (protocol.isIpcMessage(line)) {
                if (try protocol.parseResponse(self.allocator, line)) |resp| {
                    return resp;
                }
            } else {
                // Collect non-IPC output
                try godot_output.appendSlice(self.allocator, line);
                try godot_output.append(self.allocator, '\n');
            }
        }
    }

    fn spawnRedot(self: *Runner, folder: []const u8) !std.process.Child {
        // Copy existing environment and add test mode flag
        var env_map = try self.base_environ.clone(self.allocator);
        defer env_map.deinit();

        try env_map.put("GDZIG_TEST_MODE", "1");

        const child = try std.process.spawn(self.io, .{
            .argv = &.{ options.redot_exe, "--headless", "--path", folder, "--quit-after", "60" },
            .environ_map = &env_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });

        return child;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var stdin_buf: [4096]u8 = undefined;
    var stdout_buf: [4096]u8 = undefined;

    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);

    var runner = try Runner.init(allocator, io, init.environ_map, &stdin_reader.interface, &stdout_writer.interface);
    defer runner.deinit();

    try runner.run();
}
