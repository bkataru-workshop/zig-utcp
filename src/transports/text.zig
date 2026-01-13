//! Text transport implementation
//! Simple text-based request/response transport

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const TextCallTemplate = @import("../core/tool.zig").TextCallTemplate;
const TextFormat = @import("../core/tool.zig").TextFormat;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const UtcpError = @import("../core/errors.zig").UtcpError;
const substitute = @import("../core/substitution.zig").substitute;

pub const TextTransport = struct {
    allocator: std.mem.Allocator,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) TextTransport {
        return .{
            .allocator = allocator,
            .env_map = null,
        };
    }

    pub fn deinit(self: *TextTransport) void {
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *TextTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a tool via text-based endpoint
    pub fn call(
        self: *TextTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        const text_template = switch (tool.call_template) {
            .text => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in endpoint
        const endpoint = try substitute(
            aa,
            text_template.endpoint,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        // Parse endpoint URL
        const uri = std.Uri.parse(endpoint) catch return error.InvalidUrl;

        const port: u16 = uri.port orelse 80;
        const host = switch (uri.host.?) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };

        // Connect to server
        var stream = std.net.tcpConnectToHost(self.allocator, host, port) catch {
            return error.ConnectionFailed;
        };
        defer stream.close();

        // Format the request based on format type
        const payload = try self.formatRequest(aa, request.inputs, text_template.format);

        // Add auth if provided
        var full_request = std.ArrayList(u8).empty;
        defer full_request.deinit(aa);

        try self.applyAuth(&full_request, aa, provider);
        try full_request.appendSlice(aa, payload);

        // Send request
        _ = stream.write(full_request.items) catch return error.SendFailed;

        // Read response
        var response_buf: [16384]u8 = undefined;
        const response_len = stream.read(&response_buf) catch return error.ReceiveFailed;

        if (response_len == 0) {
            return ToolCallResponse{
                .allocator = self.allocator,
                .success = false,
                .output = try self.allocator.dupe(u8, "Empty response"),
                .metadata = null,
            };
        }

        return ToolCallResponse{
            .allocator = self.allocator,
            .success = true,
            .output = try self.allocator.dupe(u8, response_buf[0..response_len]),
            .metadata = null,
        };
    }

    fn formatRequest(self: *TextTransport, allocator: std.mem.Allocator, inputs: std.json.Value, format: TextFormat) ![]const u8 {
        _ = self;
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        switch (format) {
            .plain => {
                // Serialize as key=value pairs
                switch (inputs) {
                    .object => |obj| {
                        var first = true;
                        var iter = obj.iterator();
                        while (iter.next()) |entry| {
                            if (!first) {
                                try output.appendSlice(allocator, "\n");
                            }
                            first = false;
                            try output.appendSlice(allocator, entry.key_ptr.*);
                            try output.appendSlice(allocator, "=");
                            switch (entry.value_ptr.*) {
                                .string => |s| try output.appendSlice(allocator, s),
                                .integer => |i| try std.fmt.format(output.writer(allocator), "{d}", .{i}),
                                .float => |f| try std.fmt.format(output.writer(allocator), "{d}", .{f}),
                                .bool => |b| try output.appendSlice(allocator, if (b) "true" else "false"),
                                .null => try output.appendSlice(allocator, "null"),
                                else => {
                                    const json_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                                    defer allocator.free(json_str);
                                    try output.appendSlice(allocator, json_str);
                                },
                            }
                        }
                    },
                    .string => |s| try output.appendSlice(allocator, s),
                    else => {
                        const json_str = try std.json.Stringify.valueAlloc(allocator, inputs, .{});
                        defer allocator.free(json_str);
                        try output.appendSlice(allocator, json_str);
                    },
                }
            },
            .json => {
                const json_str = try std.json.Stringify.valueAlloc(allocator, inputs, .{});
                defer allocator.free(json_str);
                try output.appendSlice(allocator, json_str);
            },
            .xml => {
                // Basic XML serialization
                try output.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
                try output.appendSlice(allocator, "<request>\n");
                switch (inputs) {
                    .object => |obj| {
                        var iter = obj.iterator();
                        while (iter.next()) |entry| {
                            try std.fmt.format(output.writer(allocator), "  <{s}>", .{entry.key_ptr.*});
                            switch (entry.value_ptr.*) {
                                .string => |s| {
                                    // Escape XML special chars
                                    for (s) |c| {
                                        switch (c) {
                                            '<' => try output.appendSlice(allocator, "&lt;"),
                                            '>' => try output.appendSlice(allocator, "&gt;"),
                                            '&' => try output.appendSlice(allocator, "&amp;"),
                                            '"' => try output.appendSlice(allocator, "&quot;"),
                                            '\'' => try output.appendSlice(allocator, "&apos;"),
                                            else => try output.append(allocator, c),
                                        }
                                    }
                                },
                                .integer => |i| try std.fmt.format(output.writer(allocator), "{d}", .{i}),
                                .float => |f| try std.fmt.format(output.writer(allocator), "{d}", .{f}),
                                .bool => |b| try output.appendSlice(allocator, if (b) "true" else "false"),
                                .null => {},
                                else => {
                                    const json_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                                    defer allocator.free(json_str);
                                    try output.appendSlice(allocator, json_str);
                                },
                            }
                            try std.fmt.format(output.writer(allocator), "</{s}>\n", .{entry.key_ptr.*});
                        }
                    },
                    else => {
                        try output.appendSlice(allocator, "  <value>");
                        const json_str = try std.json.Stringify.valueAlloc(allocator, inputs, .{});
                        defer allocator.free(json_str);
                        try output.appendSlice(allocator, json_str);
                        try output.appendSlice(allocator, "</value>\n");
                    },
                }
                try output.appendSlice(allocator, "</request>");
            },
        }

        return try allocator.dupe(u8, output.items);
    }

    fn applyAuth(self: *TextTransport, request: *std.ArrayList(u8), aa: std.mem.Allocator, provider: ?Provider) !void {
        const prov = provider orelse return;
        const auth = prov.auth orelse return;
        _ = self;

        switch (auth) {
            .api_key => |api_key| {
                const header_name = api_key.header orelse "X-API-Key";
                try std.fmt.format(request.writer(aa), "{s}: {s}\n", .{ header_name, api_key.key });
            },
            .basic => |basic| {
                const creds = try std.fmt.allocPrint(aa, "{s}:{s}", .{ basic.username, basic.password });
                const encoded = std.base64.standard.Encoder.encode(creds) catch unreachable;
                try std.fmt.format(request.writer(aa), "Authorization: Basic {s}\n", .{encoded});
            },
            .bearer => |bearer| {
                try std.fmt.format(request.writer(aa), "Authorization: Bearer {s}\n", .{bearer.token});
            },
            .oauth2 => |oauth2| {
                if (oauth2.access_token) |token| {
                    try std.fmt.format(request.writer(aa), "Authorization: Bearer {s}\n", .{token});
                }
            },
        }
    }
};

test "text format plain" {
    const allocator = std.testing.allocator;
    var transport = TextTransport.init(allocator);
    defer transport.deinit();

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("name", .{ .string = "Alice" });
    try obj.put("age", .{ .integer = 30 });

    const result = try transport.formatRequest(allocator, .{ .object = obj }, .plain);
    defer allocator.free(result);

    // Should contain key=value pairs (order may vary)
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "name=Alice"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "age=30"));
}

test "text format json" {
    const allocator = std.testing.allocator;
    var transport = TextTransport.init(allocator);
    defer transport.deinit();

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("message", .{ .string = "hello" });

    const result = try transport.formatRequest(allocator, .{ .object = obj }, .json);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", result);
}

test "text format xml" {
    const allocator = std.testing.allocator;
    var transport = TextTransport.init(allocator);
    defer transport.deinit();

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("item", .{ .string = "test" });

    const result = try transport.formatRequest(allocator, .{ .object = obj }, .xml);
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "<?xml version=\"1.0\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "<request>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "<item>test</item>"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "</request>"));
}

test "text format xml escaping" {
    const allocator = std.testing.allocator;
    var transport = TextTransport.init(allocator);
    defer transport.deinit();

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("data", .{ .string = "<script>&test</script>" });

    const result = try transport.formatRequest(allocator, .{ .object = obj }, .xml);
    defer allocator.free(result);

    try std.testing.expect(std.mem.containsAtLeast(u8, result, 1, "&lt;script&gt;&amp;test&lt;/script&gt;"));
}
