//! Debug mode and verbose logging support
//! Provides configurable logging for troubleshooting

const std = @import("std");

/// Log level for debug output
pub const LogLevel = enum {
    none,
    @"error",
    warn,
    info,
    debug,
    trace,

    pub fn shouldLog(self: LogLevel, target: LogLevel) bool {
        return @intFromEnum(self) >= @intFromEnum(target);
    }
};

/// Global debug configuration
pub const DebugConfig = struct {
    level: LogLevel = .none,
    log_requests: bool = false,
    log_responses: bool = false,
    log_timing: bool = false,
    output: ?std.fs.File = null,

    /// Get the output writer
    pub fn writer(self: *const DebugConfig) std.fs.File.Writer {
        return (self.output orelse std.io.getStdErr()).writer();
    }
};

/// Thread-local debug configuration
var debug_config: DebugConfig = .{};

/// Enable debug mode with specified level
pub fn enable(level: LogLevel) void {
    debug_config.level = level;
}

/// Enable all debug options
pub fn enableAll() void {
    debug_config = .{
        .level = .trace,
        .log_requests = true,
        .log_responses = true,
        .log_timing = true,
    };
}

/// Disable debug mode
pub fn disable() void {
    debug_config = .{};
}

/// Get current debug configuration
pub fn getConfig() *DebugConfig {
    return &debug_config;
}

/// Check if debug logging is enabled at the given level
pub fn isEnabled(level: LogLevel) bool {
    return debug_config.level.shouldLog(level);
}

/// Log a debug message
pub fn log(comptime level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (!debug_config.level.shouldLog(level)) return;

    const prefix = switch (level) {
        .none => "",
        .@"error" => "[ERROR]",
        .warn => "[WARN] ",
        .info => "[INFO] ",
        .debug => "[DEBUG]",
        .trace => "[TRACE]",
    };

    const w = debug_config.writer();
    const timestamp = std.time.timestamp();
    w.print("{d} {s} " ++ fmt ++ "\n", .{timestamp} ++ .{prefix} ++ args) catch {};
}

/// Log an error
pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.@"error", fmt, args);
}

/// Log a warning
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

/// Log info
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

/// Log debug message
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

/// Log trace message
pub fn trace(comptime fmt: []const u8, args: anytype) void {
    log(.trace, fmt, args);
}

/// Timer for measuring operation duration
pub const Timer = struct {
    start_time: i64,
    name: []const u8,

    pub fn start(name: []const u8) Timer {
        return .{
            .start_time = std.time.milliTimestamp(),
            .name = name,
        };
    }

    pub fn stop(self: *const Timer) void {
        if (!debug_config.log_timing) return;
        const elapsed_ms = std.time.milliTimestamp() - self.start_time;
        log(.debug, "{s} completed in {d}ms", .{ self.name, elapsed_ms });
    }

    pub fn elapsed(self: *const Timer) i64 {
        return std.time.milliTimestamp() - self.start_time;
    }
};

/// Log an HTTP request (if enabled)
pub fn logRequest(method: []const u8, url: []const u8, body: ?[]const u8) void {
    if (!debug_config.log_requests) return;
    log(.debug, "HTTP {s} {s}", .{ method, url });
    if (body) |b| {
        if (b.len > 0 and b.len < 1024) {
            log(.trace, "Request body: {s}", .{b});
        } else if (b.len >= 1024) {
            log(.trace, "Request body: ({d} bytes)", .{b.len});
        }
    }
}

/// Log an HTTP response (if enabled)
pub fn logResponse(status: u16, body: ?[]const u8) void {
    if (!debug_config.log_responses) return;
    log(.debug, "HTTP Response: {d}", .{status});
    if (body) |b| {
        if (b.len > 0 and b.len < 1024) {
            log(.trace, "Response body: {s}", .{b});
        } else if (b.len >= 1024) {
            log(.trace, "Response body: ({d} bytes)", .{b.len});
        }
    }
}

test "debug logging levels" {
    const testing = std.testing;

    disable();
    try testing.expect(!isEnabled(.debug));

    enable(.debug);
    try testing.expect(isEnabled(.debug));
    try testing.expect(isEnabled(.info));
    try testing.expect(!isEnabled(.trace));

    disable();
}

test "timer" {
    var timer = Timer.start("test_operation");
    std.Thread.sleep(1_000_000); // 1ms
    const elapsed_val = timer.elapsed();
    try std.testing.expect(elapsed_val >= 1);
}
