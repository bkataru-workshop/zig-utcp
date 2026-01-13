//! Circuit breaker pattern implementation
//! Prevents cascading failures by failing fast when a service is unhealthy

const std = @import("std");

/// Circuit breaker states
pub const CircuitState = enum {
    closed, // Normal operation, requests flow through
    open, // Failure threshold exceeded, requests fail fast
    half_open, // Testing if service recovered
};

/// Circuit breaker configuration
pub const CircuitBreakerConfig = struct {
    /// Number of failures before opening the circuit
    failure_threshold: u32 = 5,

    /// Number of successes in half-open state to close circuit
    success_threshold: u32 = 2,

    /// Time to wait before transitioning from open to half-open (ms)
    reset_timeout_ms: u64 = 30000,

    /// Window size for counting failures (ms)
    failure_window_ms: u64 = 60000,

    /// Maximum concurrent requests in half-open state
    half_open_max_requests: u32 = 1,
};

/// Circuit breaker implementation
pub const CircuitBreaker = struct {
    config: CircuitBreakerConfig,
    state: CircuitState,
    failure_count: u32,
    success_count: u32,
    last_failure_time: i64,
    last_state_change: i64,
    consecutive_successes: u32,
    half_open_requests: u32,
    mutex: std.Thread.Mutex,

    pub fn init(config: CircuitBreakerConfig) CircuitBreaker {
        return .{
            .config = config,
            .state = .closed,
            .failure_count = 0,
            .success_count = 0,
            .last_failure_time = 0,
            .last_state_change = std.time.milliTimestamp(),
            .consecutive_successes = 0,
            .half_open_requests = 0,
            .mutex = .{},
        };
    }

    /// Check if a request can be made
    pub fn canExecute(self: *CircuitBreaker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();

        switch (self.state) {
            .closed => return true,
            .open => {
                // Check if we should transition to half-open
                if (now - self.last_state_change >= @as(i64, @intCast(self.config.reset_timeout_ms))) {
                    self.transitionTo(.half_open);
                    return true;
                }
                return false;
            },
            .half_open => {
                // Allow limited requests in half-open state
                if (self.half_open_requests < self.config.half_open_max_requests) {
                    self.half_open_requests += 1;
                    return true;
                }
                return false;
            },
        }
    }

    /// Record a successful request
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.success_count += 1;
        self.consecutive_successes += 1;

        switch (self.state) {
            .half_open => {
                if (self.consecutive_successes >= self.config.success_threshold) {
                    self.transitionTo(.closed);
                }
            },
            .closed => {
                // Reset failure count on success
                self.failure_count = 0;
            },
            .open => {},
        }
    }

    /// Record a failed request
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
        self.failure_count += 1;
        self.last_failure_time = now;
        self.consecutive_successes = 0;

        switch (self.state) {
            .closed => {
                // Check if failures are within the window
                if (now - self.last_state_change < @as(i64, @intCast(self.config.failure_window_ms))) {
                    if (self.failure_count >= self.config.failure_threshold) {
                        self.transitionTo(.open);
                    }
                } else {
                    // Reset window
                    self.failure_count = 1;
                    self.last_state_change = now;
                }
            },
            .half_open => {
                // Any failure in half-open state trips the circuit
                self.transitionTo(.open);
            },
            .open => {},
        }
    }

    /// Get current state
    pub fn getState(self: *CircuitBreaker) CircuitState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }

    /// Get statistics
    pub fn getStats(self: *CircuitBreaker) CircuitBreakerStats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .state = self.state,
            .failure_count = self.failure_count,
            .success_count = self.success_count,
            .last_failure_time = self.last_failure_time,
        };
    }

    /// Force reset the circuit breaker
    pub fn reset(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.state = .closed;
        self.failure_count = 0;
        self.success_count = 0;
        self.consecutive_successes = 0;
        self.half_open_requests = 0;
        self.last_state_change = std.time.milliTimestamp();
    }

    fn transitionTo(self: *CircuitBreaker, new_state: CircuitState) void {
        self.state = new_state;
        self.last_state_change = std.time.milliTimestamp();
        self.half_open_requests = 0;

        if (new_state == .closed) {
            self.failure_count = 0;
        }
        if (new_state == .half_open) {
            self.consecutive_successes = 0;
        }
    }
};

/// Circuit breaker statistics
pub const CircuitBreakerStats = struct {
    state: CircuitState,
    failure_count: u32,
    success_count: u32,
    last_failure_time: i64,
};

/// Circuit breaker registry for managing multiple breakers
pub const CircuitBreakerRegistry = struct {
    allocator: std.mem.Allocator,
    breakers: std.StringHashMap(*CircuitBreaker),
    default_config: CircuitBreakerConfig,

    pub fn init(allocator: std.mem.Allocator) CircuitBreakerRegistry {
        return .{
            .allocator = allocator,
            .breakers = std.StringHashMap(*CircuitBreaker).init(allocator),
            .default_config = .{},
        };
    }

    pub fn deinit(self: *CircuitBreakerRegistry) void {
        var iter = self.breakers.valueIterator();
        while (iter.next()) |breaker| {
            self.allocator.destroy(breaker.*);
        }
        self.breakers.deinit();
    }

    /// Get or create a circuit breaker for a service
    pub fn getBreaker(self: *CircuitBreakerRegistry, name: []const u8) !*CircuitBreaker {
        if (self.breakers.get(name)) |breaker| {
            return breaker;
        }

        const breaker = try self.allocator.create(CircuitBreaker);
        breaker.* = CircuitBreaker.init(self.default_config);
        try self.breakers.put(name, breaker);
        return breaker;
    }

    /// Get or create with custom config
    pub fn getBreakerWithConfig(
        self: *CircuitBreakerRegistry,
        name: []const u8,
        config: CircuitBreakerConfig,
    ) !*CircuitBreaker {
        if (self.breakers.get(name)) |breaker| {
            return breaker;
        }

        const breaker = try self.allocator.create(CircuitBreaker);
        breaker.* = CircuitBreaker.init(config);
        try self.breakers.put(name, breaker);
        return breaker;
    }

    /// Remove a circuit breaker
    pub fn removeBreaker(self: *CircuitBreakerRegistry, name: []const u8) bool {
        if (self.breakers.fetchRemove(name)) |kv| {
            self.allocator.destroy(kv.value);
            return true;
        }
        return false;
    }
};

/// Execute a function with circuit breaker protection
pub fn withCircuitBreaker(
    breaker: *CircuitBreaker,
    comptime T: type,
    context: anytype,
    func: fn (@TypeOf(context)) anyerror!T,
) !T {
    if (!breaker.canExecute()) {
        return error.CircuitOpen;
    }

    if (func(context)) |result| {
        breaker.recordSuccess();
        return result;
    } else |err| {
        breaker.recordFailure();
        return err;
    }
}

test "circuit breaker basic flow" {
    const testing = std.testing;

    var breaker = CircuitBreaker.init(.{
        .failure_threshold = 3,
        .success_threshold = 2,
        .reset_timeout_ms = 100,
    });

    // Initially closed
    try testing.expectEqual(CircuitState.closed, breaker.getState());
    try testing.expect(breaker.canExecute());

    // Record failures
    breaker.recordFailure();
    breaker.recordFailure();
    try testing.expectEqual(CircuitState.closed, breaker.getState());

    breaker.recordFailure();
    try testing.expectEqual(CircuitState.open, breaker.getState());
    try testing.expect(!breaker.canExecute());
}

test "circuit breaker half-open transition" {
    const testing = std.testing;

    var breaker = CircuitBreaker.init(.{
        .failure_threshold = 2,
        .success_threshold = 2,
        .reset_timeout_ms = 10,
    });

    // Trip the circuit
    breaker.recordFailure();
    breaker.recordFailure();
    try testing.expectEqual(CircuitState.open, breaker.getState());

    // Wait for timeout
    std.Thread.sleep(15 * std.time.ns_per_ms);

    // Should transition to half-open on next check
    try testing.expect(breaker.canExecute());
    try testing.expectEqual(CircuitState.half_open, breaker.getState());

    // Success should eventually close the circuit
    breaker.recordSuccess();
    breaker.recordSuccess();
    try testing.expectEqual(CircuitState.closed, breaker.getState());
}

test "circuit breaker registry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = CircuitBreakerRegistry.init(allocator);
    defer registry.deinit();

    const breaker1 = try registry.getBreaker("service1");
    const breaker2 = try registry.getBreaker("service2");
    const breaker1_again = try registry.getBreaker("service1");

    try testing.expect(breaker1 == breaker1_again);
    try testing.expect(breaker1 != breaker2);
}
