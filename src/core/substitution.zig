//! Variable substitution for templates (URL, body, headers)

const std = @import("std");

/// Substitute variables in a template string
/// Supports: {input.field}, {env.VAR}
pub fn substitute(
    allocator: std.mem.Allocator,
    template: []const u8,
    inputs: std.json.Value,
    env_map: ?*const std.process.EnvMap,
) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            // Find closing brace
            const start = i + 1;
            var end = start;
            while (end < template.len and template[end] != '}') : (end += 1) {}
            
            if (end < template.len) {
                const var_name = template[start..end];
                const value = try resolveVariable(allocator, var_name, inputs, env_map);
                defer allocator.free(value);
                
                try result.appendSlice(allocator, value);
                i = end + 1;
                continue;
            }
        }
        
        try result.append(allocator, template[i]);
        i += 1;
    }
    
    return try result.toOwnedSlice(allocator);
}

/// Resolve a variable name to its value
fn resolveVariable(
    allocator: std.mem.Allocator,
    var_name: []const u8,
    inputs: std.json.Value,
    env_map: ?*const std.process.EnvMap,
) ![]const u8 {
    // Check for env.VAR pattern
    if (std.mem.startsWith(u8, var_name, "env.")) {
        const env_var = var_name[4..];
        if (env_map) |map| {
            if (map.get(env_var)) |value| {
                return try allocator.dupe(u8, value);
            }
        }
        return error.VariableNotFound;
    }
    
    // Check for input.field pattern
    if (std.mem.startsWith(u8, var_name, "input.")) {
        const field_name = var_name[6..];
        return try getInputField(allocator, inputs, field_name);
    }
    
    // Direct input field (no prefix)
    return try getInputField(allocator, inputs, var_name);
}

/// Extract a field from the inputs JSON
fn getInputField(allocator: std.mem.Allocator, inputs: std.json.Value, field: []const u8) ![]const u8 {
    switch (inputs) {
        .object => |obj| {
            if (obj.get(field)) |value| {
                return try valueToString(allocator, value);
            }
            return error.VariableNotFound;
        },
        else => return error.VariableNotFound,
    }
}

/// Convert a JSON value to a string
fn valueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .string => |s| return try allocator.dupe(u8, s),
        .integer => |i| return try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
        .null => return try allocator.dupe(u8, "null"),
        else => {
            // For objects/arrays, use JSON stringify
            return try std.json.Stringify.valueAlloc(allocator, value, .{});
        },
    }
}

test "substitute input variables" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    
    var obj = std.json.ObjectMap.init(aa);
    try obj.put("city", .{ .string = "London" });
    try obj.put("units", .{ .string = "metric" });
    
    const inputs = std.json.Value{ .object = obj };
    
    const template = "https://api.example.com/weather?city={city}&units={units}";
    const result = try substitute(allocator, template, inputs, null);
    defer allocator.free(result);
    
    try testing.expectEqualStrings(
        "https://api.example.com/weather?city=London&units=metric",
        result,
    );
}

test "substitute env variables" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("API_KEY", "secret123");
    
    const inputs = std.json.Value{ .object = std.json.ObjectMap.init(allocator) };
    
    const template = "https://api.example.com/data?key={env.API_KEY}";
    const result = try substitute(allocator, template, inputs, &env_map);
    defer allocator.free(result);
    
    try testing.expectEqualStrings(
        "https://api.example.com/data?key=secret123",
        result,
    );
}
