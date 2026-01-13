//! Batch request support
//! Execute multiple tool calls in parallel

const std = @import("std");
const Tool = @import("tool.zig").Tool;
const ToolCallRequest = @import("tool.zig").ToolCallRequest;
const ToolCallResponse = @import("tool.zig").ToolCallResponse;

/// Batch request configuration
pub const BatchConfig = struct {
    /// Maximum concurrent requests
    max_concurrency: u32 = 10,

    /// Stop on first error
    fail_fast: bool = false,

    /// Overall timeout for batch (ms)
    timeout_ms: ?u64 = null,
};

/// Individual result in a batch
pub const BatchResult = struct {
    index: usize,
    tool_id: []const u8,
    response: ?ToolCallResponse,
    err: ?anyerror,
    duration_ms: i64,

    pub fn isSuccess(self: *const BatchResult) bool {
        return self.err == null and self.response != null;
    }
};

/// Batch execution results
pub const BatchResults = struct {
    allocator: std.mem.Allocator,
    results: []BatchResult,
    total_duration_ms: i64,
    succeeded: u32,
    failed: u32,

    pub fn deinit(self: *BatchResults) void {
        self.allocator.free(self.results);
    }

    /// Get all successful results
    pub fn successes(self: *const BatchResults) []const BatchResult {
        var count: usize = 0;
        for (self.results) |r| {
            if (r.isSuccess()) count += 1;
        }

        var result = self.allocator.alloc(BatchResult, count) catch return &.{};
        var i: usize = 0;
        for (self.results) |r| {
            if (r.isSuccess()) {
                result[i] = r;
                i += 1;
            }
        }
        return result;
    }

    /// Get all failed results
    pub fn failures(self: *const BatchResults) []const BatchResult {
        var count: usize = 0;
        for (self.results) |r| {
            if (!r.isSuccess()) count += 1;
        }

        var result = self.allocator.alloc(BatchResult, count) catch return &.{};
        var i: usize = 0;
        for (self.results) |r| {
            if (!r.isSuccess()) {
                result[i] = r;
                i += 1;
            }
        }
        return result;
    }
};

/// Batch request item
pub const BatchItem = struct {
    tool: Tool,
    request: ToolCallRequest,
};

/// Batch executor for parallel tool calls
pub const BatchExecutor = struct {
    allocator: std.mem.Allocator,
    config: BatchConfig,

    pub fn init(allocator: std.mem.Allocator, config: BatchConfig) BatchExecutor {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Execute multiple tool calls
    /// Note: This is a sequential implementation. True parallelism requires async I/O.
    pub fn execute(
        self: *BatchExecutor,
        items: []const BatchItem,
        executor_fn: *const fn (Tool, ToolCallRequest) anyerror!ToolCallResponse,
    ) !BatchResults {
        const start_time = std.time.milliTimestamp();

        var results = try self.allocator.alloc(BatchResult, items.len);
        errdefer self.allocator.free(results);

        var succeeded: u32 = 0;
        var failed: u32 = 0;

        for (items, 0..) |item, i| {
            const item_start = std.time.milliTimestamp();

            if (executor_fn(item.tool, item.request)) |response| {
                results[i] = .{
                    .index = i,
                    .tool_id = item.tool.id,
                    .response = response,
                    .err = null,
                    .duration_ms = std.time.milliTimestamp() - item_start,
                };
                succeeded += 1;
            } else |err| {
                results[i] = .{
                    .index = i,
                    .tool_id = item.tool.id,
                    .response = null,
                    .err = err,
                    .duration_ms = std.time.milliTimestamp() - item_start,
                };
                failed += 1;

                if (self.config.fail_fast) {
                    // Fill remaining with errors
                    for (i + 1..items.len) |j| {
                        results[j] = .{
                            .index = j,
                            .tool_id = items[j].tool.id,
                            .response = null,
                            .err = error.BatchAborted,
                            .duration_ms = 0,
                        };
                        failed += 1;
                    }
                    break;
                }
            }
        }

        return BatchResults{
            .allocator = self.allocator,
            .results = results,
            .total_duration_ms = std.time.milliTimestamp() - start_time,
            .succeeded = succeeded,
            .failed = failed,
        };
    }
};

/// Builder for batch requests
pub const BatchBuilder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(BatchItem),

    pub fn init(allocator: std.mem.Allocator) BatchBuilder {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *BatchBuilder) void {
        self.items.deinit(self.allocator);
    }

    /// Add a tool call to the batch
    pub fn add(self: *BatchBuilder, tool: Tool, request: ToolCallRequest) !*BatchBuilder {
        try self.items.append(self.allocator, .{
            .tool = tool,
            .request = request,
        });
        return self;
    }

    /// Get batch items
    pub fn build(self: *const BatchBuilder) []const BatchItem {
        return self.items.items;
    }

    /// Clear all items
    pub fn clear(self: *BatchBuilder) void {
        self.items.clearRetainingCapacity();
    }

    /// Get count
    pub fn count(self: *const BatchBuilder) usize {
        return self.items.items.len;
    }
};

test "batch builder" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = BatchBuilder.init(allocator);
    defer builder.deinit();

    const tool = Tool{
        .id = "test",
        .name = "Test",
        .description = "Test tool",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    _ = try builder.add(tool, .{ .tool_id = "test", .inputs = .null });
    _ = try builder.add(tool, .{ .tool_id = "test", .inputs = .null });

    try testing.expectEqual(@as(usize, 2), builder.count());
}

test "batch executor" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var executor = BatchExecutor.init(allocator, .{});

    const tool = Tool{
        .id = "test",
        .name = "Test",
        .description = "Test tool",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    const items = [_]BatchItem{
        .{ .tool = tool, .request = .{ .tool_id = "test", .inputs = .null } },
        .{ .tool = tool, .request = .{ .tool_id = "test", .inputs = .null } },
    };

    // Mock executor that always succeeds
    const mockExecutor = struct {
        fn exec(_: Tool, _: ToolCallRequest) anyerror!ToolCallResponse {
            return ToolCallResponse{ .output = .null };
        }
    };

    var results = try executor.execute(&items, mockExecutor.exec);
    defer results.deinit();

    try testing.expectEqual(@as(u32, 2), results.succeeded);
    try testing.expectEqual(@as(u32, 0), results.failed);
}
