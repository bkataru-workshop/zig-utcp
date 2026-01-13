//! Mock transport for testing without network calls
//! Provides configurable mock responses for unit testing

const std = @import("std");
const Tool = @import("tool.zig").Tool;
const ToolCallRequest = @import("tool.zig").ToolCallRequest;
const ToolCallResponse = @import("tool.zig").ToolCallResponse;

/// Mock response configuration
pub const MockResponse = struct {
    output: std.json.Value,
    error_msg: ?[]const u8 = null,
    exit_code: ?i32 = null,
    delay_ms: u64 = 0,
};

/// Mock call record
pub const MockCallRecord = struct {
    tool_id: []const u8,
    inputs: std.json.Value,
    timestamp: i64,
};

/// Mock transport for testing
pub const MockTransport = struct {
    allocator: std.mem.Allocator,
    responses: std.StringHashMap(MockResponse),
    default_response: ?MockResponse,
    call_history: std.ArrayListUnmanaged(MockCallRecord),
    call_count: u32,
    should_fail: bool,
    fail_error: ?anyerror,

    pub fn init(allocator: std.mem.Allocator) MockTransport {
        return .{
            .allocator = allocator,
            .responses = std.StringHashMap(MockResponse).init(allocator),
            .default_response = null,
            .call_history = .empty,
            .call_count = 0,
            .should_fail = false,
            .fail_error = null,
        };
    }

    pub fn deinit(self: *MockTransport) void {
        self.responses.deinit();
        self.call_history.deinit(self.allocator);
    }

    /// Set a mock response for a specific tool ID
    pub fn setResponse(self: *MockTransport, tool_id: []const u8, response: MockResponse) !void {
        try self.responses.put(tool_id, response);
    }

    /// Set the default response for unmatched tools
    pub fn setDefaultResponse(self: *MockTransport, response: MockResponse) void {
        self.default_response = response;
    }

    /// Configure the mock to fail all calls
    pub fn setFailing(self: *MockTransport, err: anyerror) void {
        self.should_fail = true;
        self.fail_error = err;
    }

    /// Reset to normal operation
    pub fn setSucceeding(self: *MockTransport) void {
        self.should_fail = false;
        self.fail_error = null;
    }

    /// Clear all mock responses
    pub fn clearResponses(self: *MockTransport) void {
        self.responses.clearRetainingCapacity();
        self.default_response = null;
    }

    /// Clear call history
    pub fn clearHistory(self: *MockTransport) void {
        self.call_history.clearRetainingCapacity();
        self.call_count = 0;
    }

    /// Call a tool (mock implementation)
    pub fn call(self: *MockTransport, tool: Tool, request: ToolCallRequest) !ToolCallResponse {
        // Record the call
        try self.call_history.append(self.allocator, .{
            .tool_id = tool.id,
            .inputs = request.inputs,
            .timestamp = std.time.milliTimestamp(),
        });
        self.call_count += 1;

        // Check if configured to fail
        if (self.should_fail) {
            return self.fail_error orelse error.MockError;
        }

        // Look up response
        const mock_response = self.responses.get(tool.id) orelse self.default_response orelse {
            return ToolCallResponse{
                .output = .null,
                .error_msg = "No mock response configured",
            };
        };

        // Simulate delay if configured
        if (mock_response.delay_ms > 0) {
            std.Thread.sleep(mock_response.delay_ms * std.time.ns_per_ms);
        }

        return ToolCallResponse{
            .output = mock_response.output,
            .error_msg = mock_response.error_msg,
            .exit_code = mock_response.exit_code,
        };
    }

    /// Get call count
    pub fn getCallCount(self: *const MockTransport) u32 {
        return self.call_count;
    }

    /// Get call history
    pub fn getHistory(self: *const MockTransport) []const MockCallRecord {
        return self.call_history.items;
    }

    /// Check if a specific tool was called
    pub fn wasToolCalled(self: *const MockTransport, tool_id: []const u8) bool {
        for (self.call_history.items) |record| {
            if (std.mem.eql(u8, record.tool_id, tool_id)) {
                return true;
            }
        }
        return false;
    }

    /// Get the number of times a specific tool was called
    pub fn toolCallCount(self: *const MockTransport, tool_id: []const u8) u32 {
        var count: u32 = 0;
        for (self.call_history.items) |record| {
            if (std.mem.eql(u8, record.tool_id, tool_id)) {
                count += 1;
            }
        }
        return count;
    }

    /// Assert that a tool was called with specific inputs
    pub fn assertCalledWith(
        self: *const MockTransport,
        tool_id: []const u8,
        expected_inputs: std.json.Value,
    ) !void {
        for (self.call_history.items) |record| {
            if (std.mem.eql(u8, record.tool_id, tool_id)) {
                // Simple equality check - could be enhanced
                if (jsonEquals(record.inputs, expected_inputs)) {
                    return;
                }
            }
        }
        return error.AssertionFailed;
    }
};

/// Mock transport builder for fluent configuration
pub const MockTransportBuilder = struct {
    transport: MockTransport,

    pub fn init(allocator: std.mem.Allocator) MockTransportBuilder {
        return .{
            .transport = MockTransport.init(allocator),
        };
    }

    pub fn withResponse(self: *MockTransportBuilder, tool_id: []const u8, response: MockResponse) *MockTransportBuilder {
        self.transport.setResponse(tool_id, response) catch {};
        return self;
    }

    pub fn withDefaultResponse(self: *MockTransportBuilder, response: MockResponse) *MockTransportBuilder {
        self.transport.setDefaultResponse(response);
        return self;
    }

    pub fn failing(self: *MockTransportBuilder, err: anyerror) *MockTransportBuilder {
        self.transport.setFailing(err);
        return self;
    }

    pub fn build(self: *MockTransportBuilder) MockTransport {
        return self.transport;
    }
};

fn jsonEquals(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    return switch (a) {
        .null => true,
        .bool => |av| av == b.bool,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .string => |av| std.mem.eql(u8, av, b.string),
        else => false, // Arrays and objects need deeper comparison
    };
}

test "mock transport basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    try mock.setResponse("test_tool", .{
        .output = .{ .string = "mock response" },
    });

    const tool = Tool{
        .id = "test_tool",
        .name = "Test Tool",
        .description = "Test",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    const request = ToolCallRequest{
        .tool_id = "test_tool",
        .inputs = .null,
    };

    const response = try mock.call(tool, request);

    try testing.expectEqual(std.json.Value{ .string = "mock response" }, response.output);
    try testing.expectEqual(@as(u32, 1), mock.getCallCount());
    try testing.expect(mock.wasToolCalled("test_tool"));
}

test "mock transport failure simulation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    mock.setFailing(error.ConnectionRefused);

    const tool = Tool{
        .id = "test_tool",
        .name = "Test Tool",
        .description = "Test",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    const result = mock.call(tool, .{ .tool_id = "test_tool", .inputs = .null });
    try testing.expectError(error.ConnectionRefused, result);
}

test "mock transport call history" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var mock = MockTransport.init(allocator);
    defer mock.deinit();

    mock.setDefaultResponse(.{ .output = .null });

    const tool1 = Tool{
        .id = "tool1",
        .name = "Tool 1",
        .description = "Test",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    const tool2 = Tool{
        .id = "tool2",
        .name = "Tool 2",
        .description = "Test",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    _ = try mock.call(tool1, .{ .tool_id = "tool1", .inputs = .null });
    _ = try mock.call(tool2, .{ .tool_id = "tool2", .inputs = .null });
    _ = try mock.call(tool1, .{ .tool_id = "tool1", .inputs = .null });

    try testing.expectEqual(@as(u32, 3), mock.getCallCount());
    try testing.expectEqual(@as(u32, 2), mock.toolCallCount("tool1"));
    try testing.expectEqual(@as(u32, 1), mock.toolCallCount("tool2"));
}
