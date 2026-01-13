//! Benchmarks for zig-utcp
//! Run with: zig build bench

const std = @import("std");
const utcp = @import("utcp");

const ITERATIONS = 10000;
const WARMUP = 100;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== zig-utcp Benchmarks ===\n\n", .{});

    try benchSubstitution(allocator);
    try benchJsonParsing(allocator);
    try benchPostProcessors(allocator);
    try benchStreaming(allocator);
    try benchCache(allocator);
    try benchRateLimiter(allocator);

    std.debug.print("\n=== Benchmarks Complete ===\n", .{});
}

fn benchSubstitution(allocator: std.mem.Allocator) !void {
    std.debug.print("Substitution:\n", .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var obj = std.json.ObjectMap.init(aa);
    try obj.put("city", .{ .string = "London" });
    try obj.put("units", .{ .string = "metric" });
    try obj.put("key", .{ .string = "abc123" });
    const inputs = std.json.Value{ .object = obj };

    const template = "https://api.example.com/weather?city={city}&units={units}&key={key}";

    // Warmup
    for (0..WARMUP) |_| {
        const result = try utcp.substitute(aa, template, inputs, null);
        _ = result;
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        const result = try utcp.substitute(aa, template, inputs, null);
        _ = result;
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  substitute: {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}

fn benchJsonParsing(allocator: std.mem.Allocator) !void {
    std.debug.print("JSON Parsing:\n", .{});

    const json_str =
        \\{"tools":[{"name":"weather","description":"Get weather data","call_template":{"http":{"method":"GET","url":"https://api.example.com/weather"}}}]}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Warmup
    for (0..WARMUP) |_| {
        var loader = utcp.JsonLoader.init(aa);
        const result = try loader.loadString(json_str);
        _ = result;
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        var loader = utcp.JsonLoader.init(aa);
        const result = try loader.loadString(json_str);
        _ = result;
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  loadString: {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}

fn benchPostProcessors(allocator: std.mem.Allocator) !void {
    std.debug.print("Post-processors:\n", .{});

    var chain = utcp.PostProcessorChain.init(allocator);
    defer chain.deinit();

    try chain.addFn("trim", utcp.trimProcessor);

    // Warmup
    for (0..WARMUP) |_| {
        const str = try allocator.dupe(u8, "  test string  ");
        var response = utcp.ToolCallResponse{
            .output = .{ .string = str },
        };
        try chain.process(&response);
        allocator.free(response.output.string);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        const str = try allocator.dupe(u8, "  test string  ");
        var response = utcp.ToolCallResponse{
            .output = .{ .string = str },
        };
        try chain.process(&response);
        allocator.free(response.output.string);
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  process (trim): {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}

fn benchStreaming(allocator: std.mem.Allocator) !void {
    std.debug.print("Streaming:\n", .{});

    const data = "a" ** 10000; // 10KB of data

    // Warmup
    for (0..WARMUP) |_| {
        var stream = utcp.fromBytes(allocator, data);
        defer stream.deinit();
        const result = try stream.collectAll();
        allocator.free(result);
    }

    // Benchmark
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        var stream = utcp.fromBytes(allocator, data);
        defer stream.deinit();
        const result = try stream.collectAll();
        allocator.free(result);
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  collectAll (10KB): {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}

fn benchCache(allocator: std.mem.Allocator) !void {
    std.debug.print("Cache:\n", .{});

    var cache = utcp.ResponseCache.init(allocator, .{
        .max_entries = 10000,
    });
    defer cache.deinit();

    const response = utcp.ToolCallResponse{
        .output = .{ .string = "cached response" },
    };

    // Pre-populate cache
    for (0..1000) |i| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{i}) catch "key";
        try cache.put(key, response);
    }

    // Benchmark get
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |i| {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "key_{d}", .{i % 1000}) catch "key";
        _ = cache.get(key);
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  cache get: {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}

fn benchRateLimiter(_: std.mem.Allocator) !void {
    std.debug.print("Rate Limiter:\n", .{});

    var bucket = utcp.TokenBucket.init(.{
        .burst_size = 1000000,
        .refill_rate = 1000000.0,
    });

    // Benchmark tryAcquire
    const start = std.time.nanoTimestamp();
    for (0..ITERATIONS) |_| {
        _ = bucket.tryAcquire();
    }
    const elapsed = std.time.nanoTimestamp() - start;

    const ns_per_op = @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(ITERATIONS));
    std.debug.print("  tryAcquire: {d:.2} ns/op ({d} ops/sec)\n", .{
        ns_per_op,
        @as(u64, @intFromFloat(1e9 / ns_per_op)),
    });
}
