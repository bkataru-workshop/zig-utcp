//! Post-processor example
//! Demonstrates response transformation and validation

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== UTCP Post-Processor Example ===\n\n", .{});

    // Create a post-processor chain
    var chain = utcp.PostProcessorChain.init(allocator);
    defer chain.deinit();

    // Add built-in processors
    try chain.addFn("trim", utcp.trimProcessor);
    try chain.add(.{
        .name = "validate_json",
        .processor = utcp.jsonValidateProcessor,
        .priority = 5,
    });
    try chain.add(.{
        .name = "log",
        .processor = utcp.logProcessor,
        .priority = 100, // Run last
    });

    std.debug.print("Processor chain has {d} processors\n\n", .{chain.count()});

    // Example 1: Process a string response
    std.debug.print("1. Processing string response:\n", .{});
    {
        const original = try allocator.dupe(u8, "  \n  Hello, World!  \n  ");
        var response = utcp.ToolCallResponse{
            .output = .{ .string = original },
        };

        std.debug.print("   Before: '{s}'\n", .{original});
        try chain.process(&response);
        std.debug.print("   After:  '{s}'\n\n", .{response.output.string});

        allocator.free(response.output.string);
    }

    // Example 2: Validate JSON
    std.debug.print("2. JSON validation:\n", .{});
    {
        // Valid JSON
        const valid_json = try allocator.dupe(u8, "{\"status\": \"ok\", \"count\": 42}");
        var response1 = utcp.ToolCallResponse{
            .output = .{ .string = valid_json },
        };

        try chain.process(&response1);
        std.debug.print("   Valid JSON - Error: {?s}\n", .{response1.error_msg});
        allocator.free(valid_json);

        // Invalid JSON
        const invalid_json = try allocator.dupe(u8, "{invalid json}");
        var response2 = utcp.ToolCallResponse{
            .output = .{ .string = invalid_json },
        };

        try chain.process(&response2);
        std.debug.print("   Invalid JSON - Error: {?s}\n\n", .{response2.error_msg});
        allocator.free(invalid_json);
    }

    // Example 3: Mask sensitive data
    std.debug.print("3. Masking sensitive data:\n", .{});
    {
        var mask_chain = utcp.PostProcessorChain.init(allocator);
        defer mask_chain.deinit();
        try mask_chain.addFn("mask", utcp.maskProcessor);

        const sensitive = try allocator.dupe(u8, "API key is sk-1234567890abcdef");
        var response = utcp.ToolCallResponse{
            .output = .{ .string = sensitive },
        };

        std.debug.print("   Before: '{s}'\n", .{sensitive});
        try mask_chain.process(&response);
        std.debug.print("   After:  '{s}'\n\n", .{response.output.string});

        allocator.free(response.output.string);
    }

    // Example 4: Extract field from JSON
    std.debug.print("4. Extract field from JSON:\n", .{});
    {
        var extract_chain = utcp.PostProcessorChain.init(allocator);
        defer extract_chain.deinit();

        // Create context for field extraction
        const field_name: []const u8 = "data";
        try extract_chain.add(.{
            .name = "extract",
            .processor = utcp.extractFieldProcessor,
            .context = @ptrCast(@constCast(&field_name)),
        });

        // Parse JSON into response
        const json_str = "{\"data\": \"extracted value\", \"other\": 123}";
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        defer parsed.deinit();

        var response = utcp.ToolCallResponse{
            .output = parsed.value,
        };

        std.debug.print("   Before: {s}\n", .{json_str});
        try extract_chain.process(&response);

        switch (response.output) {
            .string => |s| std.debug.print("   After:  '{s}'\n", .{s}),
            else => std.debug.print("   After:  (non-string value)\n", .{}),
        }
    }

    std.debug.print("\n=== Post-Processor Example Complete ===\n", .{});
}
