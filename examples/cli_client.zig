//! Example: CLI transport - calling local commands as tools

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create CLI transport
    var transport = utcp.CliTransport.init(allocator);
    defer transport.deinit();
    try transport.loadEnv();

    // Define a tool that lists files (cross-platform)
    const list_files_tool = utcp.Tool{
        .id = "list-files",
        .name = "List Files",
        .description = "List files in a directory",
        .call_template = .{
            .cli = .{
                .command = if (@import("builtin").os.tag == .windows) "cmd" else "ls",
                .args = if (@import("builtin").os.tag == .windows) &.{ "/c", "dir", "/b" } else &.{"-la"},
            },
        },
    };

    // Call the tool
    const request = utcp.ToolCallRequest{
        .tool_id = "list-files",
        .inputs = .null,
    };

    std.debug.print("Calling CLI tool: {s}\n", .{list_files_tool.name});

    const response = try transport.call(list_files_tool, request);

    // Print results
    if (response.error_msg) |err| {
        std.debug.print("Error: {s}\n", .{err});
    }

    std.debug.print("Exit code: {?d}\n", .{response.exit_code});

    switch (response.output) {
        .string => |s| {
            std.debug.print("Output:\n{s}\n", .{s});
            allocator.free(s);
        },
        .null => std.debug.print("No output\n", .{}),
        else => std.debug.print("Unexpected output type\n", .{}),
    }
}
