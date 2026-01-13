//! Middleware system for request/response interceptors
//! Provides hooks for logging, metrics, auth injection, and more

const std = @import("std");
const Tool = @import("tool.zig").Tool;
const ToolCallRequest = @import("tool.zig").ToolCallRequest;
const ToolCallResponse = @import("tool.zig").ToolCallResponse;

/// Context passed through the middleware chain
pub const MiddlewareContext = struct {
    allocator: std.mem.Allocator,
    tool: Tool,
    request: ToolCallRequest,
    response: ?ToolCallResponse = null,
    metadata: std.StringHashMap([]const u8),
    start_time: i64,
    aborted: bool = false,
    abort_reason: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, tool: Tool, request: ToolCallRequest) MiddlewareContext {
        return .{
            .allocator = allocator,
            .tool = tool,
            .request = request,
            .metadata = std.StringHashMap([]const u8).init(allocator),
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *MiddlewareContext) void {
        self.metadata.deinit();
    }

    /// Set metadata value
    pub fn set(self: *MiddlewareContext, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }

    /// Get metadata value
    pub fn get(self: *const MiddlewareContext, key: []const u8) ?[]const u8 {
        return self.metadata.get(key);
    }

    /// Abort the request chain
    pub fn abort(self: *MiddlewareContext, reason: []const u8) void {
        self.aborted = true;
        self.abort_reason = reason;
    }

    /// Get elapsed time in milliseconds
    pub fn elapsed(self: *const MiddlewareContext) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }
};

/// Middleware function type - called before the request
pub const BeforeMiddlewareFn = *const fn (*MiddlewareContext) anyerror!void;

/// Middleware function type - called after the response
pub const AfterMiddlewareFn = *const fn (*MiddlewareContext) anyerror!void;

/// Middleware entry with metadata
pub const Middleware = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    before: ?BeforeMiddlewareFn = null,
    after: ?AfterMiddlewareFn = null,
    priority: i32 = 0, // Lower runs first for before, last for after
};

/// Middleware chain manager
pub const MiddlewareChain = struct {
    allocator: std.mem.Allocator,
    middlewares: std.ArrayListUnmanaged(Middleware),

    pub fn init(allocator: std.mem.Allocator) MiddlewareChain {
        return .{
            .allocator = allocator,
            .middlewares = .empty,
        };
    }

    pub fn deinit(self: *MiddlewareChain) void {
        self.middlewares.deinit(self.allocator);
    }

    /// Add middleware to the chain
    pub fn use(self: *MiddlewareChain, middleware: Middleware) !void {
        try self.middlewares.append(self.allocator, middleware);
        // Sort by priority
        std.mem.sort(Middleware, self.middlewares.items, {}, struct {
            fn lessThan(_: void, a: Middleware, b: Middleware) bool {
                return a.priority < b.priority;
            }
        }.lessThan);
    }

    /// Add a simple before middleware
    pub fn useBefore(self: *MiddlewareChain, name: []const u8, handler: BeforeMiddlewareFn) !void {
        try self.use(.{ .name = name, .before = handler });
    }

    /// Add a simple after middleware
    pub fn useAfter(self: *MiddlewareChain, name: []const u8, handler: AfterMiddlewareFn) !void {
        try self.use(.{ .name = name, .after = handler });
    }

    /// Run all before middlewares
    pub fn runBefore(self: *MiddlewareChain, ctx: *MiddlewareContext) !void {
        for (self.middlewares.items) |mw| {
            if (ctx.aborted) break;
            if (mw.before) |before_fn| {
                try before_fn(ctx);
            }
        }
    }

    /// Run all after middlewares (in reverse order)
    pub fn runAfter(self: *MiddlewareChain, ctx: *MiddlewareContext) !void {
        var i = self.middlewares.items.len;
        while (i > 0) {
            i -= 1;
            if (self.middlewares.items[i].after) |after_fn| {
                try after_fn(ctx);
            }
        }
    }

    /// Get middleware count
    pub fn count(self: *const MiddlewareChain) usize {
        return self.middlewares.items.len;
    }
};

// --- Built-in Middlewares ---

/// Logging middleware - logs request/response details
pub fn loggingMiddleware(ctx: *MiddlewareContext) !void {
    std.debug.print("[Middleware] Tool: {s}, Elapsed: {d}ms\n", .{
        ctx.tool.name,
        ctx.elapsed(),
    });
}

/// Timing middleware - records execution time
pub fn timingBeforeMiddleware(ctx: *MiddlewareContext) !void {
    try ctx.set("_timing_start", "set");
}

pub fn timingAfterMiddleware(ctx: *MiddlewareContext) !void {
    const elapsed = ctx.elapsed();
    std.debug.print("[Timing] {s}: {d}ms\n", .{ ctx.tool.name, elapsed });
}

/// Request ID middleware - adds unique request ID
var request_counter: u64 = 0;

pub fn requestIdMiddleware(ctx: *MiddlewareContext) !void {
    request_counter += 1;
    var buf: [32]u8 = undefined;
    const id = std.fmt.bufPrint(&buf, "req-{d}", .{request_counter}) catch "req-unknown";
    try ctx.set("request_id", id);
}

/// Create a timing middleware pair
pub fn createTimingMiddleware() Middleware {
    return .{
        .name = "timing",
        .description = "Records execution time",
        .before = timingBeforeMiddleware,
        .after = timingAfterMiddleware,
    };
}

/// Create a logging middleware
pub fn createLoggingMiddleware() Middleware {
    return .{
        .name = "logging",
        .description = "Logs request details",
        .after = loggingMiddleware,
        .priority = 100, // Run last
    };
}

/// Create a request ID middleware
pub fn createRequestIdMiddleware() Middleware {
    return .{
        .name = "request_id",
        .description = "Adds unique request ID",
        .before = requestIdMiddleware,
        .priority = -100, // Run first
    };
}

test "middleware chain" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var chain = MiddlewareChain.init(allocator);
    defer chain.deinit();

    try chain.use(createTimingMiddleware());
    try chain.use(createLoggingMiddleware());
    try chain.use(createRequestIdMiddleware());

    try testing.expectEqual(@as(usize, 3), chain.count());

    // Request ID should be first (priority -100)
    try testing.expectEqualStrings("request_id", chain.middlewares.items[0].name);
}

test "middleware context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const tool = Tool{
        .id = "test",
        .name = "Test Tool",
        .description = "Test",
        .call_template = .{ .http = .{ .method = "GET", .url = "http://test" } },
    };

    var ctx = MiddlewareContext.init(allocator, tool, .{
        .tool_id = "test",
        .inputs = .null,
    });
    defer ctx.deinit();

    try ctx.set("key", "value");
    try testing.expectEqualStrings("value", ctx.get("key").?);

    ctx.abort("test reason");
    try testing.expect(ctx.aborted);
    try testing.expectEqualStrings("test reason", ctx.abort_reason.?);
}
