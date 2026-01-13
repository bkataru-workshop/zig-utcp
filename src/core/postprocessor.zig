//! Post-processor interface
//! Transform or validate tool call responses

const std = @import("std");
const ToolCallResponse = @import("tool.zig").ToolCallResponse;

/// Post-processor function signature
pub const PostProcessorFn = *const fn (
    allocator: std.mem.Allocator,
    response: *ToolCallResponse,
    context: ?*anyopaque,
) anyerror!void;

/// Post-processor entry with metadata
pub const PostProcessor = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    processor: PostProcessorFn,
    context: ?*anyopaque = null,
    priority: i32 = 0, // Lower runs first
};

/// Chain of post-processors
pub const PostProcessorChain = struct {
    allocator: std.mem.Allocator,
    processors: std.ArrayListUnmanaged(PostProcessor),

    pub fn init(allocator: std.mem.Allocator) PostProcessorChain {
        return .{
            .allocator = allocator,
            .processors = .empty,
        };
    }

    pub fn deinit(self: *PostProcessorChain) void {
        self.processors.deinit(self.allocator);
    }

    /// Add a post-processor to the chain
    pub fn add(self: *PostProcessorChain, processor: PostProcessor) !void {
        try self.processors.append(self.allocator, processor);
        // Sort by priority
        std.mem.sort(PostProcessor, self.processors.items, {}, struct {
            fn lessThan(_: void, a: PostProcessor, b: PostProcessor) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
    }

    /// Add a simple processor function
    pub fn addFn(self: *PostProcessorChain, name: []const u8, processor: PostProcessorFn) !void {
        try self.add(.{
            .name = name,
            .processor = processor,
        });
    }

    /// Run all processors on a response
    pub fn process(self: *PostProcessorChain, response: *ToolCallResponse) !void {
        for (self.processors.items) |proc| {
            try proc.processor(self.allocator, response, proc.context);
        }
    }

    /// Get the number of processors
    pub fn count(self: *const PostProcessorChain) usize {
        return self.processors.items.len;
    }
};

// --- Built-in Post Processors ---

/// Log the response (for debugging)
pub fn logProcessor(allocator: std.mem.Allocator, response: *ToolCallResponse, context: ?*anyopaque) !void {
    _ = context;
    _ = allocator;
    const output_str = switch (response.output) {
        .string => |s| s,
        else => "[non-string output]",
    };
    std.debug.print("[PostProcessor] Output: {s}\n", .{output_str});
}

/// Trim whitespace from string output
pub fn trimProcessor(allocator: std.mem.Allocator, response: *ToolCallResponse, context: ?*anyopaque) !void {
    _ = context;
    switch (response.output) {
        .string => |s| {
            const trimmed = std.mem.trim(u8, s, " \t\n\r");
            if (trimmed.len != s.len) {
                const new_str = try allocator.dupe(u8, trimmed);
                allocator.free(s);
                response.output = .{ .string = new_str };
            }
        },
        else => {},
    }
}

/// Validate that output is valid JSON
pub fn jsonValidateProcessor(allocator: std.mem.Allocator, response: *ToolCallResponse, context: ?*anyopaque) !void {
    _ = context;
    switch (response.output) {
        .string => |s| {
            // Try to parse as JSON
            const is_valid = std.json.validate(allocator, s) catch false;
            if (!is_valid) {
                response.error_msg = "Invalid JSON in response";
                return;
            }
        },
        else => {},
    }
}

/// Extract a specific field from JSON output
pub fn extractFieldProcessor(allocator: std.mem.Allocator, response: *ToolCallResponse, context: ?*anyopaque) !void {
    const field_name: []const u8 = if (context) |ctx| @as(*const []const u8, @ptrCast(@alignCast(ctx))).* else return;

    switch (response.output) {
        .object => |obj| {
            if (obj.get(field_name)) |value| {
                response.output = value;
            }
        },
        .string => |s| {
            // Try to parse as JSON first
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, s, .{}) catch return;
            switch (parsed.value) {
                .object => |obj| {
                    if (obj.get(field_name)) |value| {
                        response.output = value;
                    }
                },
                else => {},
            }
        },
        else => {},
    }
}

/// Mask sensitive data in output
pub fn maskProcessor(allocator: std.mem.Allocator, response: *ToolCallResponse, context: ?*anyopaque) !void {
    _ = context;
    switch (response.output) {
        .string => |s| {
            // Look for common patterns to mask
            var result = std.ArrayList(u8).empty;
            errdefer result.deinit(allocator);

            var i: usize = 0;
            while (i < s.len) {
                // Simple API key pattern detection (sk-... or key-...)
                if (i + 3 < s.len and (std.mem.eql(u8, s[i .. i + 3], "sk-") or std.mem.eql(u8, s[i .. i + 4], "key-"))) {
                    try result.appendSlice(allocator, "***MASKED***");
                    // Skip to next space or end
                    while (i < s.len and s[i] != ' ' and s[i] != '\n' and s[i] != '"') : (i += 1) {}
                } else {
                    try result.append(allocator, s[i]);
                    i += 1;
                }
            }

            if (result.items.len != s.len) {
                const new_str = try result.toOwnedSlice(allocator);
                allocator.free(s);
                response.output = .{ .string = new_str };
            }
        },
        else => {},
    }
}

test "post processor chain" {
    const allocator = std.testing.allocator;

    var chain = PostProcessorChain.init(allocator);
    defer chain.deinit();

    try chain.addFn("trim", trimProcessor);
    try chain.add(.{
        .name = "log",
        .processor = logProcessor,
        .priority = 10, // Run after trim
    });

    try std.testing.expectEqual(@as(usize, 2), chain.count());
    // First should be trim (priority 0), then log (priority 10)
    try std.testing.expectEqualStrings("trim", chain.processors.items[0].name);
    try std.testing.expectEqualStrings("log", chain.processors.items[1].name);
}

test "trim processor" {
    const allocator = std.testing.allocator;

    const original = try allocator.dupe(u8, "  hello world  ");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try trimProcessor(allocator, &response, null);

    try std.testing.expectEqualStrings("hello world", response.output.string);
    allocator.free(response.output.string);
}

test "trim processor no change needed" {
    const allocator = std.testing.allocator;

    const original = try allocator.dupe(u8, "no-whitespace");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try trimProcessor(allocator, &response, null);

    try std.testing.expectEqualStrings("no-whitespace", response.output.string);
    allocator.free(response.output.string);
}

test "trim processor empty string" {
    const allocator = std.testing.allocator;

    const original = try allocator.dupe(u8, "   ");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try trimProcessor(allocator, &response, null);

    try std.testing.expectEqualStrings("", response.output.string);
    allocator.free(response.output.string);
}

test "processor chain execution order" {
    const allocator = std.testing.allocator;

    var chain = PostProcessorChain.init(allocator);
    defer chain.deinit();

    // Add with different priorities - higher priority number runs later
    try chain.add(.{
        .name = "third",
        .processor = logProcessor,
        .priority = 30,
    });
    try chain.add(.{
        .name = "first",
        .processor = logProcessor,
        .priority = 10,
    });
    try chain.add(.{
        .name = "second",
        .processor = logProcessor,
        .priority = 20,
    });

    try std.testing.expectEqualStrings("first", chain.processors.items[0].name);
    try std.testing.expectEqualStrings("second", chain.processors.items[1].name);
    try std.testing.expectEqualStrings("third", chain.processors.items[2].name);
}

test "json validate processor valid json" {
    const allocator = std.testing.allocator;

    const original = try allocator.dupe(u8, "{\"key\":\"value\"}");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try jsonValidateProcessor(allocator, &response, null);

    try std.testing.expect(response.error_msg == null);
    allocator.free(response.output.string);
}

test "json validate processor invalid json" {
    const allocator = std.testing.allocator;

    const original = try allocator.dupe(u8, "{invalid json}");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try jsonValidateProcessor(allocator, &response, null);

    try std.testing.expect(response.error_msg != null);
    allocator.free(response.output.string);
}

test "processor with non-string output" {
    const allocator = std.testing.allocator;

    // Trim should be no-op for non-string output
    var response = ToolCallResponse{
        .output = .{ .integer = 42 },
    };

    try trimProcessor(allocator, &response, null);

    try std.testing.expectEqual(@as(i64, 42), response.output.integer);
}

test "empty processor chain" {
    const allocator = std.testing.allocator;

    var chain = PostProcessorChain.init(allocator);
    defer chain.deinit();

    const original = try allocator.dupe(u8, "test");
    var response = ToolCallResponse{
        .output = .{ .string = original },
    };

    try chain.process(&response);

    try std.testing.expectEqualStrings("test", response.output.string);
    allocator.free(response.output.string);
}
