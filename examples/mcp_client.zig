//! Example: MCP transport - connecting to an MCP server
//!
//! This example demonstrates how to connect to an MCP server via stdio
//! and call tools through the JSON-RPC 2.0 protocol.
//!
//! Usage: zig build run-mcp -- <mcp-server-command> [args...]
//! Example: zig build run-mcp -- npx -y @modelcontextprotocol/server-everything

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line args for MCP server
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <mcp-server-command> [args...]\n", .{args[0]});
        std.debug.print("\nExample:\n", .{});
        std.debug.print("  {s} npx -y @modelcontextprotocol/server-everything\n", .{args[0]});
        std.debug.print("  {s} python -m mcp_server\n", .{args[0]});
        return;
    }

    // Create MCP transport
    var transport = utcp.McpTransport.init(allocator);
    defer transport.deinit();

    // Connect to MCP server via stdio
    std.debug.print("Connecting to MCP server: {s}\n", .{args[1]});
    transport.connectStdio(args[1], args[2..]) catch |err| {
        std.debug.print("Failed to connect: {}\n", .{err});
        return;
    };

    std.debug.print("Connected! Listing available tools...\n\n", .{});

    // List available tools
    const tools = transport.listTools() catch |err| {
        std.debug.print("Failed to list tools: {}\n", .{err});
        return;
    };

    if (tools.len == 0) {
        std.debug.print("No tools available from this server.\n", .{});
        return;
    }

    std.debug.print("Available tools ({d}):\n", .{tools.len});
    for (tools) |tool| {
        std.debug.print("  - {s}: {s}\n", .{ tool.name, tool.description });
    }

    // Try calling the first tool with empty args (as a demo)
    if (tools.len > 0) {
        const first_tool = tools[0];
        std.debug.print("\nCalling tool: {s}\n", .{first_tool.name});

        const request = utcp.ToolCallRequest{
            .tool_id = first_tool.id,
            .inputs = .null,  // Empty inputs
        };

        const response = transport.call(first_tool, request) catch |err| {
            std.debug.print("Tool call failed: {}\n", .{err});
            return;
        };

        if (response.error_msg) |err| {
            std.debug.print("Tool error: {s}\n", .{err});
        }

        std.debug.print("Result: ", .{});
        switch (response.output) {
            .string => |s| std.debug.print("{s}\n", .{s}),
            .object => std.debug.print("<object>\n", .{}),
            .array => std.debug.print("<array>\n", .{}),
            .null => std.debug.print("null\n", .{}),
            else => std.debug.print("<value>\n", .{}),
        }
    }
}
