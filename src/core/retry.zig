//! Retry policies with exponential backoff
//! Provides configurable retry strategies for transient failures

const std = @import("std");

/// Retry policy configuration
pub const RetryPolicy = struct {
    /// Maximum number of retry attempts (0 = no retries)
    max_retries: u32 = 3,

    /// Initial delay between retries in milliseconds
    initial_delay_ms: u64 = 100,

    /// Maximum delay between retries in milliseconds
    max_delay_ms: u64 = 10000,

    /// Multiplier for exponential backoff
    backoff_multiplier: f64 = 2.0,

    /// Add random jitter to prevent thundering herd
    jitter: bool = true,

    /// Errors that should trigger a retry
    retryable_errors: []const anyerror = &default_retryable_errors,

    /// No retries policy
    pub const none: RetryPolicy = .{ .max_retries = 0 };

    /// Default policy with 3 retries and exponential backoff
    pub const default: RetryPolicy = .{};

    /// Aggressive retry policy for critical operations
    pub const aggressive: RetryPolicy = .{
        .max_retries = 5,
        .initial_delay_ms = 50,
        .max_delay_ms = 30000,
    };

    /// Calculate delay for a given attempt (0-indexed)
    pub fn delayForAttempt(self: *const RetryPolicy, attempt: u32) u64 {
        if (attempt == 0) return 0;

        var delay: f64 = @floatFromInt(self.initial_delay_ms);
        var i: u32 = 1;
        while (i < attempt) : (i += 1) {
            delay *= self.backoff_multiplier;
        }

        var final_delay = @min(@as(u64, @intFromFloat(delay)), self.max_delay_ms);

        if (self.jitter) {
            // Add up to 25% jitter
            var rng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
            const jitter_amount = rng.random().float(f64) * 0.25;
            final_delay = @intFromFloat(@as(f64, @floatFromInt(final_delay)) * (1.0 + jitter_amount));
        }

        return final_delay;
    }

    /// Check if an error should be retried
    pub fn shouldRetry(self: *const RetryPolicy, err: anyerror) bool {
        for (self.retryable_errors) |retryable| {
            if (err == retryable) return true;
        }
        return false;
    }
};

/// Default errors that trigger retries
const default_retryable_errors = [_]anyerror{
    error.ConnectionRefused,
    error.ConnectionResetByPeer,
    error.ConnectionTimedOut,
    error.NetworkUnreachable,
    error.TemporaryNameServerFailure,
    error.Timeout,
    error.BrokenPipe,
    error.EndOfStream,
};

/// Retry executor that runs a function with retry logic
pub fn RetryExecutor(comptime T: type, comptime E: type) type {
    return struct {
        policy: RetryPolicy,

        const Self = @This();
        const ResultType = if (E == void) T else E!T;

        pub fn init(policy: RetryPolicy) Self {
            return .{ .policy = policy };
        }

        /// Execute a function with retry logic
        pub fn execute(
            self: *const Self,
            context: anytype,
            func: fn (@TypeOf(context)) ResultType,
        ) ResultType {
            var attempt: u32 = 0;
            while (true) {
                const result = func(context);
                if (E == void) {
                    return result;
                } else {
                    if (result) |value| {
                        return value;
                    } else |err| {
                        if (attempt >= self.policy.max_retries or !self.policy.shouldRetry(err)) {
                            return err;
                        }
                        const delay = self.policy.delayForAttempt(attempt + 1);
                        std.time.sleep(delay * std.time.ns_per_ms);
                        attempt += 1;
                    }
                }
            }
        }
    };
}

/// Retry context for manual retry control
pub const RetryContext = struct {
    policy: RetryPolicy,
    attempt: u32 = 0,
    last_error: ?anyerror = null,

    pub fn init(policy: RetryPolicy) RetryContext {
        return .{ .policy = policy };
    }

    /// Check if we should retry after an error
    pub fn shouldRetry(self: *RetryContext, err: anyerror) bool {
        self.last_error = err;
        if (self.attempt >= self.policy.max_retries) return false;
        return self.policy.shouldRetry(err);
    }

    /// Wait before the next retry attempt
    pub fn wait(self: *RetryContext) void {
        const delay = self.policy.delayForAttempt(self.attempt + 1);
        std.time.sleep(delay * std.time.ns_per_ms);
        self.attempt += 1;
    }

    /// Reset the retry context
    pub fn reset(self: *RetryContext) void {
        self.attempt = 0;
        self.last_error = null;
    }

    /// Get remaining retries
    pub fn remainingRetries(self: *const RetryContext) u32 {
        if (self.attempt >= self.policy.max_retries) return 0;
        return self.policy.max_retries - self.attempt;
    }
};

/// Convenience function to retry a block with default policy
pub fn withRetry(
    comptime T: type,
    policy: RetryPolicy,
    context: anytype,
    func: fn (@TypeOf(context)) anyerror!T,
) anyerror!T {
    var ctx = RetryContext.init(policy);
    while (true) {
        if (func(context)) |result| {
            return result;
        } else |err| {
            if (!ctx.shouldRetry(err)) return err;
            ctx.wait();
        }
    }
}

test "retry policy delay calculation" {
    const testing = std.testing;

    var policy = RetryPolicy{
        .initial_delay_ms = 100,
        .backoff_multiplier = 2.0,
        .max_delay_ms = 1000,
        .jitter = false,
    };

    try testing.expectEqual(@as(u64, 0), policy.delayForAttempt(0));
    try testing.expectEqual(@as(u64, 100), policy.delayForAttempt(1));
    try testing.expectEqual(@as(u64, 200), policy.delayForAttempt(2));
    try testing.expectEqual(@as(u64, 400), policy.delayForAttempt(3));
    try testing.expectEqual(@as(u64, 800), policy.delayForAttempt(4));
    try testing.expectEqual(@as(u64, 1000), policy.delayForAttempt(5)); // capped
}

test "retry context" {
    const testing = std.testing;

    var ctx = RetryContext.init(.{ .max_retries = 2 });

    try testing.expectEqual(@as(u32, 2), ctx.remainingRetries());
    try testing.expect(ctx.shouldRetry(error.ConnectionRefused));

    ctx.attempt = 2;
    try testing.expectEqual(@as(u32, 0), ctx.remainingRetries());
    try testing.expect(!ctx.shouldRetry(error.ConnectionRefused));
}
