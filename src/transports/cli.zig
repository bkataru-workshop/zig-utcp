//! CLI transport implementation using std.process.Child

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const CliCallTemplate = @import("../core/tool.zig").CliCallTemplate;
const UtcpError = @import("../core/errors.zig").UtcpError;
const substitute = @import("../core/substitution.zig").substitute;

pub const CliTransport = struct {
    allocator: std.mem.Allocator,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) CliTransport {
        return .{
            .allocator = allocator,
            .env_map = null,
        };
    }

    pub fn deinit(self: *CliTransport) void {
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *CliTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a tool via CLI subprocess
    pub fn call(
        self: *CliTransport,
        tool: Tool,
        request: ToolCallRequest,
    ) !ToolCallResponse {
        // Extract CLI template
        const cli_template = switch (tool.call_template) {
            .cli => |t| t,
            else => return error.UnsupportedTransport,
        };

        // Create arena for request lifetime
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in command
        const command = try substitute(
            aa,
            cli_template.command,
            request.inputs,
            if (self.env_map) |*map| map else null,
        );

        // Build argv
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(aa, command);

        // Substitute variables in args
        for (cli_template.args) |arg| {
            const substituted = try substitute(
                aa,
                arg,
                request.inputs,
                if (self.env_map) |*map| map else null,
            );
            try argv.append(aa, substituted);
        }

        // Prepare environment
        var env_map: ?*const std.process.EnvMap = null;
        if (cli_template.env) |tmpl_env| {
            var new_map = try std.process.getEnvMap(aa);
            var iter = tmpl_env.iterator();
            while (iter.next()) |entry| {
                const value = try substitute(
                    aa,
                    entry.value_ptr.*,
                    request.inputs,
                    if (self.env_map) |*map| map else null,
                );
                try new_map.put(entry.key_ptr.*, value);
            }
            env_map = &new_map;
        }

        // Configure child process
        var child = std.process.Child.init(argv.items, aa);
        child.cwd = cli_template.cwd;
        if (env_map) |e| {
            child.env_map = e;
        }

        // Capture stdout and stderr
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = if (cli_template.stdin_template != null) .Pipe else .Ignore;

        // Spawn the process
        try child.spawn();

        // Write stdin if template provided
        if (cli_template.stdin_template) |stdin_template| {
            const stdin_data = try substitute(
                aa,
                stdin_template,
                request.inputs,
                if (self.env_map) |*map| map else null,
            );
            if (child.stdin) |stdin| {
                try stdin.writeAll(stdin_data);
                stdin.close();
                child.stdin = null;
            }
        }

        // Read stdout and stderr before waiting
        var stdout_data: []const u8 = &.{};
        var stderr_data: []const u8 = &.{};

        if (child.stdout) |stdout| {
            stdout_data = stdout.readToEndAlloc(aa, 10 * 1024 * 1024) catch &.{};
        }

        if (child.stderr) |stderr| {
            stderr_data = stderr.readToEndAlloc(aa, 10 * 1024 * 1024) catch &.{};
        }

        // Wait for completion
        const term = try child.wait();

        // Build response
        const exit_code: i32 = switch (term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| -@as(i32, @intCast(sig)),
            .Unknown => -1,
        };

        // Try to parse stdout as JSON, fallback to string
        const output: std.json.Value = blk: {
            if (stdout_data.len > 0) {
                const parsed = std.json.parseFromSlice(
                    std.json.Value,
                    self.allocator,
                    stdout_data,
                    .{},
                ) catch {
                    // Not JSON, return as string
                    break :blk .{ .string = try self.allocator.dupe(u8, stdout_data) };
                };
                break :blk parsed.value;
            }
            break :blk .null;
        };

        // Set error if non-zero exit or stderr
        var error_msg: ?[]const u8 = null;
        if (exit_code != 0 or stderr_data.len > 0) {
            if (stderr_data.len > 0) {
                error_msg = try self.allocator.dupe(u8, stderr_data);
            } else {
                error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "Process exited with code {d}",
                    .{exit_code},
                );
            }
        }

        return ToolCallResponse{
            .output = output,
            .error_msg = error_msg,
            .exit_code = exit_code,
        };
    }
};

test "CliTransport basic test" {
    const allocator = std.testing.allocator;
    var transport = CliTransport.init(allocator);
    defer transport.deinit();

    // Create a simple echo tool
    const tool = Tool{
        .id = "echo-test",
        .name = "echo",
        .description = "Echo a message",
        .call_template = .{
            .cli = .{
                .command = if (@import("builtin").os.tag == .windows) "cmd" else "echo",
                .args = if (@import("builtin").os.tag == .windows) &.{ "/c", "echo", "hello" } else &.{"hello"},
            },
        },
    };

    const request = ToolCallRequest{
        .tool_id = "echo-test",
        .inputs = .null,
    };

    const response = try transport.call(tool, request);

    // Should have output containing "hello"
    switch (response.output) {
        .string => |s| {
            try std.testing.expect(std.mem.indexOf(u8, s, "hello") != null);
            allocator.free(s);
        },
        else => {},
    }
    try std.testing.expectEqual(@as(i32, 0), response.exit_code.?);
}
