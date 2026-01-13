//! HTTP transport example
//! Demonstrates calling a weather API using UTCP HTTP transport

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create HTTP transport
    var transport = utcp.HttpTransport.init(allocator);
    defer transport.deinit();
    
    // Optional: load environment variables for {env.VAR} substitution
    try transport.loadEnv();
    
    // Create a weather API tool
    const weather_tool = utcp.Tool{
        .id = "weather_api",
        .name = "Get Weather",
        .description = "Get weather for a city",
        .call_template = .{
            .http = .{
                .method = "GET",
                .url = "https://wttr.in/{city}?format=j1",
                .headers = null,
                .body_template = null,
                .query_params = null,
                .timeout_ms = 30000,
            },
        },
        .input_schema = .null,
        .output_schema = .null,
        .tags = &.{},
    };
    
    // Create a request
    var inputs_obj = std.json.ObjectMap.init(allocator);
    defer inputs_obj.deinit();
    try inputs_obj.put("city", .{ .string = "London" });
    
    const request = utcp.ToolCallRequest{
        .tool_id = "weather_api",
        .inputs = .{ .object = inputs_obj },
    };
    
    // Call the tool
    std.debug.print("Calling weather API for London...\n", .{});
    const response = try transport.call(weather_tool, request, null);
    defer {
        // Free JSON output
        switch (response.output) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }
    
    if (response.error_msg) |err| {
        std.debug.print("Error: {s}\n", .{err});
        allocator.free(err);
    } else {
        std.debug.print("Weather data received\n", .{});
        
        // Pretty print the response
        switch (response.output) {
            .string => |s| std.debug.print("Response (raw): {s}\n", .{s}),
            else => std.debug.print("Response: {any}\n", .{response.output}),
        }
    }
}
