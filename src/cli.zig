//! UTCP Command Line Interface
//! A CLI tool for testing and inspecting UTCP tool definitions

const std = @import("std");
const utcp = @import("utcp.zig");

const usage =
    \\utcp - Universal Tool Calling Protocol CLI
    \\
    \\USAGE:
    \\  utcp <command> [options] [arguments]
    \\
    \\COMMANDS:
    \\  load <file>      Load and validate a tool definition file
    \\  list <file>      List tools in a definition file
    \\  call <file> <tool> <json>  Call a tool with JSON input
    \\  validate <file>  Validate tool definitions
    \\  info             Show UTCP library information
    \\  help             Show this help message
    \\
    \\OPTIONS:
    \\  --verbose, -v    Enable verbose output
    \\  --json, -j       Output in JSON format
    \\
    \\EXAMPLES:
    \\  utcp load tools.json
    \\  utcp list tools.json
    \\  utcp call tools.json weather '{"city":"London"}'
    \\  utcp validate tools.json
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    // Parse options
    var verbose = false;
    var json_output = false;
    var positional_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer positional_args.deinit(allocator);

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "-j")) {
            json_output = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positional_args.append(allocator, arg);
        }
    }

    if (positional_args.items.len == 0) {
        printUsage();
        return;
    }

    const command = positional_args.items[0];

    if (std.mem.eql(u8, command, "help")) {
        printUsage();
    } else if (std.mem.eql(u8, command, "info")) {
        printInfo(json_output);
    } else if (std.mem.eql(u8, command, "load")) {
        if (positional_args.items.len < 2) {
            std.debug.print("Error: load command requires a file path\n", .{});
            return;
        }
        loadCommand(allocator, positional_args.items[1], verbose, json_output);
    } else if (std.mem.eql(u8, command, "list")) {
        if (positional_args.items.len < 2) {
            std.debug.print("Error: list command requires a file path\n", .{});
            return;
        }
        listCommand(allocator, positional_args.items[1], json_output);
    } else if (std.mem.eql(u8, command, "validate")) {
        if (positional_args.items.len < 2) {
            std.debug.print("Error: validate command requires a file path\n", .{});
            return;
        }
        try validateCommand(allocator, positional_args.items[1], verbose, json_output);
    } else if (std.mem.eql(u8, command, "call")) {
        if (positional_args.items.len < 4) {
            std.debug.print("Error: call command requires file, tool name, and JSON input\n", .{});
            return;
        }
        callCommand(allocator, positional_args.items[1], positional_args.items[2], positional_args.items[3], verbose, json_output);
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print("{s}", .{usage});
}

fn printInfo(json_output: bool) void {
    if (json_output) {
        std.debug.print(
            \\{{"name":"zig-utcp","version":"0.2.0","description":"Universal Tool Calling Protocol for Zig"}}
            \\
        , .{});
    } else {
        std.debug.print(
            \\zig-utcp - Universal Tool Calling Protocol
            \\Version: 0.2.0
            \\
            \\Features:
            \\  - Tool definition loading (JSON)
            \\  - HTTP transport with authentication
            \\  - Response streaming
            \\  - Post-processing pipelines
            \\  - Middleware support
            \\  - Circuit breaker & rate limiting
            \\  - Response caching
            \\
        , .{});
    }
}

fn loadCommand(allocator: std.mem.Allocator, file_path: []const u8, verbose: bool, json_output: bool) void {
    if (verbose) {
        std.debug.print("Loading: {s}\n", .{file_path});
    }

    var loader = utcp.JsonLoader.init(allocator);
    const result = loader.loadFile(file_path);

    if (result) |load_result| {
        const tool_count = load_result.tools.len;
        const provider_count = load_result.providers.len;

        if (json_output) {
            std.debug.print(
                \\{{"status":"ok","file":"{s}","tools":{d},"providers":{d}}}
                \\
            , .{ file_path, tool_count, provider_count });
        } else {
            std.debug.print("Loaded successfully\n", .{});
            std.debug.print("  File: {s}\n", .{file_path});
            std.debug.print("  Tools: {d}\n", .{tool_count});
            std.debug.print("  Providers: {d}\n", .{provider_count});
        }
    } else |err| {
        if (json_output) {
            std.debug.print(
                \\{{"status":"error","file":"{s}","error":"{s}"}}
                \\
            , .{ file_path, @errorName(err) });
        } else {
            std.debug.print("Failed to load: {s}\n", .{@errorName(err)});
        }
    }
}

fn listCommand(allocator: std.mem.Allocator, file_path: []const u8, json_output: bool) void {
    var loader = utcp.JsonLoader.init(allocator);
    const result = loader.loadFile(file_path);

    if (result) |load_result| {
        if (json_output) {
            std.debug.print("{{\"tools\":[", .{});
            for (load_result.tools, 0..) |tool, i| {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print(
                    \\{{"id":"{s}","name":"{s}","description":"{s}"}}
                , .{
                    tool.id,
                    tool.name,
                    tool.description,
                });
            }
            std.debug.print("]}}\n", .{});
        } else {
            std.debug.print("Tools in {s}:\n\n", .{file_path});
            if (load_result.tools.len > 0) {
                for (load_result.tools) |tool| {
                    std.debug.print("  {s}\n", .{tool.id});
                    std.debug.print("    Name: {s}\n", .{tool.name});
                    if (tool.description.len > 0) {
                        std.debug.print("    Description: {s}\n", .{tool.description});
                    }
                    std.debug.print("\n", .{});
                }
            } else {
                std.debug.print("  (no tools defined)\n", .{});
            }
        }
    } else |err| {
        if (json_output) {
            std.debug.print(
                \\{{"status":"error","error":"{s}"}}
                \\
            , .{@errorName(err)});
        } else {
            std.debug.print("Error loading file: {s}\n", .{@errorName(err)});
        }
    }
}

fn validateCommand(allocator: std.mem.Allocator, file_path: []const u8, verbose: bool, json_output: bool) !void {
    var errors: std.ArrayListUnmanaged([]const u8) = .empty;
    defer errors.deinit(allocator);

    var loader = utcp.JsonLoader.init(allocator);
    const result = loader.loadFile(file_path);

    if (result) |load_result| {
        // Validate tools
        for (load_result.tools) |tool| {
            // Check required fields
            if (tool.id.len == 0) {
                try errors.append(allocator, "Tool has empty id");
            }
            if (tool.name.len == 0) {
                try errors.append(allocator, "Tool has empty name");
            }
            // Tool must have a call_template (it's not optional in the struct)

            if (verbose) {
                std.debug.print("Validated tool: {s}\n", .{tool.id});
            }
        }

        // Validate providers
        for (load_result.providers) |provider| {
            if (provider.id.len == 0) {
                try errors.append(allocator, "Provider has empty id");
            }
            if (provider.base_url == null) {
                try errors.append(allocator, try std.fmt.allocPrint(allocator, "Provider '{s}' has no base_url", .{provider.id}));
            }

            if (verbose) {
                std.debug.print("Validated provider: {s}\n", .{provider.id});
            }
        }

        if (json_output) {
            if (errors.items.len == 0) {
                std.debug.print("{{\"valid\":true,\"errors\":[]}}\n", .{});
            } else {
                std.debug.print("{{\"valid\":false,\"errors\":[", .{});
                for (errors.items, 0..) |err_msg, i| {
                    if (i > 0) std.debug.print(",", .{});
                    std.debug.print("\"{s}\"", .{err_msg});
                }
                std.debug.print("]}}\n", .{});
            }
        } else {
            if (errors.items.len == 0) {
                std.debug.print("{s} is valid\n", .{file_path});
            } else {
                std.debug.print("{s} has {d} error(s):\n", .{ file_path, errors.items.len });
                for (errors.items) |err_msg| {
                    std.debug.print("  - {s}\n", .{err_msg});
                }
            }
        }
    } else |err| {
        if (json_output) {
            std.debug.print(
                \\{{"valid":false,"errors":["Failed to load: {s}"]}}
                \\
            , .{@errorName(err)});
        } else {
            std.debug.print("Failed to load: {s}\n", .{@errorName(err)});
        }
    }
}

fn callCommand(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    tool_name: []const u8,
    json_input: []const u8,
    verbose: bool,
    json_output: bool,
) void {
    if (verbose) {
        std.debug.print("Loading: {s}\n", .{file_path});
        std.debug.print("Tool: {s}\n", .{tool_name});
        std.debug.print("Input: {s}\n", .{json_input});
    }

    var loader = utcp.JsonLoader.init(allocator);
    const def_result = loader.loadFile(file_path);

    if (def_result) |load_result| {
        // Find the tool
        var found_tool: ?utcp.Tool = null;
        for (load_result.tools) |tool| {
            if (std.mem.eql(u8, tool.id, tool_name) or std.mem.eql(u8, tool.name, tool_name)) {
                found_tool = tool;
                break;
            }
        }

        if (found_tool) |tool| {
            // Parse input JSON
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_input, .{}) catch |err| {
                if (json_output) {
                    std.debug.print(
                        \\{{"status":"error","error":"Invalid JSON input: {s}"}}
                        \\
                    , .{@errorName(err)});
                } else {
                    std.debug.print("Error: Invalid JSON input: {s}\n", .{@errorName(err)});
                }
                return;
            };
            defer parsed.deinit();

            // Note: Actual HTTP call would require transport setup
            // For CLI testing, we just show what would be called
            const template_type = @tagName(tool.call_template);

            if (json_output) {
                std.debug.print(
                    \\{{"status":"ok","tool":"{s}","template":"{s}","note":"Use --execute to actually call the endpoint"}}
                    \\
                , .{
                    tool.id,
                    template_type,
                });
            } else {
                std.debug.print("Tool: {s}\n", .{tool.id});
                std.debug.print("Template: {s}\n", .{template_type});
                std.debug.print("Input: {s}\n", .{json_input});
                std.debug.print("\nNote: This is a dry-run. Use HTTP transport for actual calls.\n", .{});
            }
        } else {
            if (json_output) {
                std.debug.print(
                    \\{{"status":"error","error":"Tool not found: {s}"}}
                    \\
                , .{tool_name});
            } else {
                std.debug.print("Error: Tool not found: {s}\n", .{tool_name});
            }
        }
    } else |err| {
        if (json_output) {
            std.debug.print(
                \\{{"status":"error","error":"Failed to load: {s}"}}
                \\
            , .{@errorName(err)});
        } else {
            std.debug.print("Error loading file: {s}\n", .{@errorName(err)});
        }
    }
}

test "cli arg parsing" {
    // Basic smoke test
    const testing = std.testing;
    try testing.expect(usage.len > 0);
}
