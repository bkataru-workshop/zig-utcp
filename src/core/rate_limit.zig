//! Rate limiting implementation
//! Provides token bucket and sliding window rate limiters

const std = @import("std");

/// Rate limiter algorithm type
pub const RateLimitAlgorithm = enum {
    token_bucket,
    sliding_window,
    fixed_window,
};

/// Rate limiter configuration
pub const RateLimitConfig = struct {
    /// Maximum requests per window
    max_requests: u32 = 100,

    /// Window size in milliseconds
    window_ms: u64 = 60000,

    /// For token bucket: refill rate (tokens per second)
    refill_rate: f64 = 10.0,

    /// For token bucket: burst size (max tokens)
    burst_size: u32 = 100,

    /// Algorithm to use
    algorithm: RateLimitAlgorithm = .token_bucket,
};

/// Token bucket rate limiter
pub const TokenBucket = struct {
    config: RateLimitConfig,
    tokens: f64,
    last_refill: i64,
    mutex: std.Thread.Mutex,

    pub fn init(config: RateLimitConfig) TokenBucket {
        return .{
            .config = config,
            .tokens = @floatFromInt(config.burst_size),
            .last_refill = std.time.milliTimestamp(),
            .mutex = .{},
        };
    }

    /// Try to acquire a token
    pub fn tryAcquire(self: *TokenBucket) bool {
        return self.tryAcquireN(1);
    }

    /// Try to acquire N tokens
    pub fn tryAcquireN(self: *TokenBucket, n: u32) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refill();

        const needed: f64 = @floatFromInt(n);
        if (self.tokens >= needed) {
            self.tokens -= needed;
            return true;
        }
        return false;
    }

    /// Get current token count
    pub fn available(self: *TokenBucket) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refill();
        return @intFromFloat(self.tokens);
    }

    /// Calculate wait time for next available token (ms)
    pub fn waitTime(self: *TokenBucket) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.refill();

        if (self.tokens >= 1.0) return 0;

        const needed = 1.0 - self.tokens;
        const seconds_to_wait = needed / self.config.refill_rate;
        return @intFromFloat(seconds_to_wait * 1000.0);
    }

    fn refill(self: *TokenBucket) void {
        const now = std.time.milliTimestamp();
        const elapsed_ms = now - self.last_refill;
        if (elapsed_ms <= 0) return;

        const elapsed_seconds: f64 = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const new_tokens = elapsed_seconds * self.config.refill_rate;

        self.tokens = @min(self.tokens + new_tokens, @as(f64, @floatFromInt(self.config.burst_size)));
        self.last_refill = now;
    }
};

/// Sliding window rate limiter
pub const SlidingWindow = struct {
    config: RateLimitConfig,
    requests: std.ArrayListUnmanaged(i64),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, config: RateLimitConfig) SlidingWindow {
        return .{
            .config = config,
            .requests = .empty,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *SlidingWindow) void {
        self.requests.deinit(self.allocator);
    }

    /// Try to make a request
    pub fn tryAcquire(self: *SlidingWindow) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.cleanup(now);

        if (self.requests.items.len >= self.config.max_requests) {
            return false;
        }

        self.requests.append(self.allocator, now) catch return false;
        return true;
    }

    /// Get remaining requests in current window
    pub fn remaining(self: *SlidingWindow) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.cleanup(now);

        const used: u32 = @intCast(self.requests.items.len);
        if (used >= self.config.max_requests) return 0;
        return self.config.max_requests - used;
    }

    /// Calculate time until next request is allowed (ms)
    pub fn waitTime(self: *SlidingWindow) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.requests.items.len < self.config.max_requests) {
            return 0;
        }

        const now = std.time.milliTimestamp();
        const oldest = self.requests.items[0];
        const window_end = oldest + @as(i64, @intCast(self.config.window_ms));

        if (window_end <= now) return 0;
        return @intCast(window_end - now);
    }

    fn cleanup(self: *SlidingWindow, now: i64) void {
        const window_start = now - @as(i64, @intCast(self.config.window_ms));

        var write_idx: usize = 0;
        for (self.requests.items) |timestamp| {
            if (timestamp >= window_start) {
                self.requests.items[write_idx] = timestamp;
                write_idx += 1;
            }
        }
        self.requests.shrinkRetainingCapacity(write_idx);
    }
};

/// Fixed window rate limiter (simpler, less accurate)
pub const FixedWindow = struct {
    config: RateLimitConfig,
    count: u32,
    window_start: i64,
    mutex: std.Thread.Mutex,

    pub fn init(config: RateLimitConfig) FixedWindow {
        return .{
            .config = config,
            .count = 0,
            .window_start = std.time.milliTimestamp(),
            .mutex = .{},
        };
    }

    /// Try to make a request
    pub fn tryAcquire(self: *FixedWindow) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.maybeResetWindow(now);

        if (self.count >= self.config.max_requests) {
            return false;
        }

        self.count += 1;
        return true;
    }

    /// Get remaining requests in current window
    pub fn remaining(self: *FixedWindow) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.maybeResetWindow(now);

        if (self.count >= self.config.max_requests) return 0;
        return self.config.max_requests - self.count;
    }

    fn maybeResetWindow(self: *FixedWindow, now: i64) void {
        if (now - self.window_start >= @as(i64, @intCast(self.config.window_ms))) {
            self.window_start = now;
            self.count = 0;
        }
    }
};

/// Rate limiter registry for managing per-provider limits
pub const RateLimiterRegistry = struct {
    allocator: std.mem.Allocator,
    limiters: std.StringHashMap(*TokenBucket),
    default_config: RateLimitConfig,

    pub fn init(allocator: std.mem.Allocator) RateLimiterRegistry {
        return .{
            .allocator = allocator,
            .limiters = std.StringHashMap(*TokenBucket).init(allocator),
            .default_config = .{},
        };
    }

    pub fn deinit(self: *RateLimiterRegistry) void {
        var iter = self.limiters.valueIterator();
        while (iter.next()) |limiter| {
            self.allocator.destroy(limiter.*);
        }
        self.limiters.deinit();
    }

    /// Get or create a rate limiter for a provider
    pub fn getLimiter(self: *RateLimiterRegistry, provider_id: []const u8) !*TokenBucket {
        if (self.limiters.get(provider_id)) |limiter| {
            return limiter;
        }

        const limiter = try self.allocator.create(TokenBucket);
        limiter.* = TokenBucket.init(self.default_config);
        try self.limiters.put(provider_id, limiter);
        return limiter;
    }

    /// Get or create with custom config
    pub fn getLimiterWithConfig(
        self: *RateLimiterRegistry,
        provider_id: []const u8,
        config: RateLimitConfig,
    ) !*TokenBucket {
        if (self.limiters.get(provider_id)) |limiter| {
            return limiter;
        }

        const limiter = try self.allocator.create(TokenBucket);
        limiter.* = TokenBucket.init(config);
        try self.limiters.put(provider_id, limiter);
        return limiter;
    }
};

test "token bucket basic" {
    const testing = std.testing;

    var bucket = TokenBucket.init(.{
        .burst_size = 10,
        .refill_rate = 10.0,
    });

    // Should have initial tokens
    try testing.expect(bucket.available() == 10);

    // Acquire some tokens
    try testing.expect(bucket.tryAcquire());
    try testing.expect(bucket.available() == 9);

    // Acquire multiple
    try testing.expect(bucket.tryAcquireN(5));
    try testing.expect(bucket.available() == 4);

    // Can't acquire more than available
    try testing.expect(!bucket.tryAcquireN(10));
}

test "sliding window rate limiter" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var limiter = SlidingWindow.init(allocator, .{
        .max_requests = 3,
        .window_ms = 1000,
    });
    defer limiter.deinit();

    // Should allow initial requests
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());
    try testing.expect(limiter.tryAcquire());

    // Should deny 4th request
    try testing.expect(!limiter.tryAcquire());
    try testing.expectEqual(@as(u32, 0), limiter.remaining());
}

test "fixed window rate limiter" {
    const testing = std.testing;

    var limiter = FixedWindow.init(.{
        .max_requests = 5,
        .window_ms = 1000,
    });

    // Use all requests
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try testing.expect(limiter.tryAcquire());
    }

    // Should be denied
    try testing.expect(!limiter.tryAcquire());
}

test "rate limiter registry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = RateLimiterRegistry.init(allocator);
    defer registry.deinit();

    const limiter1 = try registry.getLimiter("openai");
    const limiter2 = try registry.getLimiter("anthropic");
    const limiter1_again = try registry.getLimiter("openai");

    try testing.expect(limiter1 == limiter1_again);
    try testing.expect(limiter1 != limiter2);
}
