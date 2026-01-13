//! Response caching with TTL
//! Provides optional caching for tool responses

const std = @import("std");
const ToolCallResponse = @import("tool.zig").ToolCallResponse;

/// Cache entry
pub const CacheEntry = struct {
    response: ToolCallResponse,
    created_at: i64,
    ttl_ms: u64,
    hits: u32,

    pub fn isExpired(self: *const CacheEntry) bool {
        const now = std.time.milliTimestamp();
        return now - self.created_at >= @as(i64, @intCast(self.ttl_ms));
    }

    pub fn age(self: *const CacheEntry) i64 {
        return std.time.milliTimestamp() - self.created_at;
    }
};

/// Cache configuration
pub const CacheConfig = struct {
    /// Default TTL for entries (ms)
    default_ttl_ms: u64 = 300000, // 5 minutes

    /// Maximum number of entries
    max_entries: usize = 1000,

    /// Enable automatic cleanup
    auto_cleanup: bool = true,

    /// Cleanup interval (ms)
    cleanup_interval_ms: u64 = 60000,
};

/// Response cache implementation
pub const ResponseCache = struct {
    allocator: std.mem.Allocator,
    config: CacheConfig,
    entries: std.StringHashMap(CacheEntry),
    keys: std.ArrayListUnmanaged([]const u8),
    total_hits: u64,
    total_misses: u64,
    last_cleanup: i64,

    pub fn init(allocator: std.mem.Allocator, config: CacheConfig) ResponseCache {
        return .{
            .allocator = allocator,
            .config = config,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .keys = .empty,
            .total_hits = 0,
            .total_misses = 0,
            .last_cleanup = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        // Free all keys
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        self.keys.deinit(self.allocator);
        self.entries.deinit();
    }

    /// Generate cache key from tool ID and inputs
    pub fn generateKey(self: *ResponseCache, tool_id: []const u8, inputs: std.json.Value) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(tool_id);
        hasher.update(":");

        // Hash the inputs JSON
        const inputs_str = std.json.stringifyAlloc(self.allocator, inputs, .{}) catch |e| {
            std.debug.print("Failed to stringify inputs: {}\n", .{e});
            return error.SerializationError;
        };
        defer self.allocator.free(inputs_str);
        hasher.update(inputs_str);

        const hash = hasher.final();
        return std.fmt.allocPrint(self.allocator, "{s}:{x}", .{ tool_id, hash });
    }

    /// Get a cached response
    pub fn get(self: *ResponseCache, key: []const u8) ?ToolCallResponse {
        if (self.config.auto_cleanup) {
            self.maybeCleanup();
        }

        if (self.entries.getPtr(key)) |entry| {
            if (entry.isExpired()) {
                self.total_misses += 1;
                return null;
            }
            entry.hits += 1;
            self.total_hits += 1;
            return entry.response;
        }

        self.total_misses += 1;
        return null;
    }

    /// Put a response in the cache
    pub fn put(self: *ResponseCache, key: []const u8, response: ToolCallResponse) !void {
        try self.putWithTtl(key, response, self.config.default_ttl_ms);
    }

    /// Put a response with custom TTL
    pub fn putWithTtl(self: *ResponseCache, key: []const u8, response: ToolCallResponse, ttl_ms: u64) !void {
        // Evict if at capacity
        if (self.entries.count() >= self.config.max_entries) {
            self.evictOldest();
        }

        // Duplicate key if not already present
        const owned_key = if (self.entries.contains(key))
            key
        else blk: {
            const k = try self.allocator.dupe(u8, key);
            try self.keys.append(self.allocator, k);
            break :blk k;
        };

        try self.entries.put(owned_key, .{
            .response = response,
            .created_at = std.time.milliTimestamp(),
            .ttl_ms = ttl_ms,
            .hits = 0,
        });
    }

    /// Remove an entry
    pub fn remove(self: *ResponseCache, key: []const u8) bool {
        return self.entries.remove(key);
    }

    /// Clear all entries
    pub fn clear(self: *ResponseCache) void {
        for (self.keys.items) |key| {
            self.allocator.free(key);
        }
        self.keys.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
    }

    /// Get cache statistics
    pub fn stats(self: *const ResponseCache) CacheStats {
        var expired: u32 = 0;
        var total_age: i64 = 0;
        var total_entry_hits: u32 = 0;

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                expired += 1;
            }
            total_age += entry.value_ptr.age();
            total_entry_hits += entry.value_ptr.hits;
        }

        const count = self.entries.count();
        return .{
            .entries = count,
            .max_entries = self.config.max_entries,
            .hits = self.total_hits,
            .misses = self.total_misses,
            .expired = expired,
            .avg_age_ms = if (count > 0) @divTrunc(total_age, @as(i64, @intCast(count))) else 0,
        };
    }

    /// Clean up expired entries
    pub fn cleanup(self: *ResponseCache) void {
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(self.allocator);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }

        for (to_remove.items) |key| {
            _ = self.entries.remove(key);
        }

        self.last_cleanup = std.time.milliTimestamp();
    }

    fn maybeCleanup(self: *ResponseCache) void {
        const now = std.time.milliTimestamp();
        if (now - self.last_cleanup >= @as(i64, @intCast(self.config.cleanup_interval_ms))) {
            self.cleanup();
        }
    }

    fn evictOldest(self: *ResponseCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.created_at < oldest_time) {
                oldest_time = entry.value_ptr.created_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            _ = self.entries.remove(key);
        }
    }
};

/// Cache statistics
pub const CacheStats = struct {
    entries: usize,
    max_entries: usize,
    hits: u64,
    misses: u64,
    expired: u32,
    avg_age_ms: i64,

    pub fn hitRate(self: *const CacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Cache key builder for common patterns
pub const CacheKeyBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CacheKeyBuilder {
        return .{ .allocator = allocator };
    }

    /// Build key from tool ID and inputs
    pub fn build(self: *const CacheKeyBuilder, tool_id: []const u8, inputs: std.json.Value) ![]const u8 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(tool_id);

        const inputs_str = std.json.stringifyAlloc(self.allocator, inputs, .{}) catch {
            return error.SerializationError;
        };
        defer self.allocator.free(inputs_str);

        hasher.update(inputs_str);
        return std.fmt.allocPrint(self.allocator, "{s}:{x}", .{ tool_id, hasher.final() });
    }
};

test "response cache basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = ResponseCache.init(allocator, .{
        .default_ttl_ms = 1000,
        .max_entries = 10,
    });
    defer cache.deinit();

    const response = ToolCallResponse{
        .output = .{ .string = "test output" },
    };

    try cache.put("key1", response);

    const cached = cache.get("key1");
    try testing.expect(cached != null);
    try testing.expectEqual(std.json.Value{ .string = "test output" }, cached.?.output);

    // Non-existent key
    try testing.expect(cache.get("nonexistent") == null);
}

test "response cache TTL expiration" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = ResponseCache.init(allocator, .{
        .default_ttl_ms = 10, // 10ms TTL
        .auto_cleanup = false,
    });
    defer cache.deinit();

    const response = ToolCallResponse{
        .output = .null,
    };

    try cache.put("key1", response);
    try testing.expect(cache.get("key1") != null);

    // Wait for expiration
    std.Thread.sleep(15 * std.time.ns_per_ms);

    // Should be expired
    try testing.expect(cache.get("key1") == null);
}

test "response cache eviction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = ResponseCache.init(allocator, .{
        .max_entries = 2,
    });
    defer cache.deinit();

    const response = ToolCallResponse{ .output = .null };

    try cache.put("key1", response);
    try cache.put("key2", response);
    try cache.put("key3", response); // Should evict key1

    try testing.expectEqual(@as(usize, 2), cache.entries.count());
}

test "cache stats" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var cache = ResponseCache.init(allocator, .{});
    defer cache.deinit();

    const response = ToolCallResponse{ .output = .null };
    try cache.put("key1", response);

    _ = cache.get("key1"); // hit
    _ = cache.get("key1"); // hit
    _ = cache.get("key2"); // miss

    const s = cache.stats();
    try testing.expectEqual(@as(u64, 2), s.hits);
    try testing.expectEqual(@as(u64, 1), s.misses);
}
