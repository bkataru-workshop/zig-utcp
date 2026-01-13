//! JSON Tool Loader - Load tools and providers from JSON files
//!
//! Supports loading tool definitions from JSON files in UTCP format.

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const CallTemplate = @import("../core/tool.zig").CallTemplate;
const HttpCallTemplate = @import("../core/tool.zig").HttpCallTemplate;
const CliCallTemplate = @import("../core/tool.zig").CliCallTemplate;
const McpCallTemplate = @import("../core/tool.zig").McpCallTemplate;
const McpMode = @import("../core/tool.zig").McpMode;
const SseCallTemplate = @import("../core/tool.zig").SseCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;

/// Result of loading a JSON file
pub const LoadResult = struct {
    tools: []Tool,
    providers: []Provider,
};

/// JSON Tool Loader
pub const JsonLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JsonLoader {
        return .{ .allocator = allocator };
    }

    /// Load tools from a JSON file
    pub fn loadFile(self: *JsonLoader, path: []const u8) !LoadResult {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        return self.loadString(content);
    }

    /// Load tools from a JSON string
    /// Note: The returned LoadResult contains references to data owned by the parser.
    /// Caller must use an arena allocator or duplicate strings if needed.
    pub fn loadString(self: *JsonLoader, json_str: []const u8) !LoadResult {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{});
        // Don't deinit - the Tool structs reference strings owned by the parser
        // The caller's allocator (preferably an arena) owns this memory

        return self.loadValue(parsed.value);
    }

    /// Load tools from a parsed JSON value
    pub fn loadValue(self: *JsonLoader, value: std.json.Value) !LoadResult {
        var tools: std.ArrayList(Tool) = .empty;
        var providers: std.ArrayList(Provider) = .empty;

        switch (value) {
            .object => |obj| {
                // Check for "tools" array
                if (obj.get("tools")) |tools_val| {
                    switch (tools_val) {
                        .array => |arr| {
                            for (arr.items) |tool_val| {
                                if (try self.parseTool(tool_val)) |tool| {
                                    try tools.append(self.allocator, tool);
                                }
                            }
                        },
                        else => {},
                    }
                }

                // Check for "providers" array
                if (obj.get("providers")) |providers_val| {
                    switch (providers_val) {
                        .array => |arr| {
                            for (arr.items) |provider_val| {
                                if (try self.parseProvider(provider_val)) |provider| {
                                    try providers.append(self.allocator, provider);
                                }
                            }
                        },
                        else => {},
                    }
                }

                // Single tool object
                if (obj.get("name") != null and (obj.get("call_template") != null or obj.get("callTemplate") != null)) {
                    if (try self.parseTool(value)) |tool| {
                        try tools.append(self.allocator, tool);
                    }
                }
            },
            .array => |arr| {
                // Array of tools
                for (arr.items) |item| {
                    if (try self.parseTool(item)) |tool| {
                        try tools.append(self.allocator, tool);
                    }
                }
            },
            else => {},
        }

        return LoadResult{
            .tools = try tools.toOwnedSlice(self.allocator),
            .providers = try providers.toOwnedSlice(self.allocator),
        };
    }

    /// Parse a single tool from JSON
    fn parseTool(self: *JsonLoader, value: std.json.Value) !?Tool {
        switch (value) {
            .object => |obj| {
                const id = self.getString(obj, "id") orelse self.getString(obj, "name") orelse return null;
                const name = self.getString(obj, "name") orelse return null;
                const description = self.getString(obj, "description") orelse "";

                const call_template = try self.parseCallTemplate(obj) orelse return null;

                // Parse tags
                var tags: []const []const u8 = &.{};
                if (obj.get("tags")) |tags_val| {
                    switch (tags_val) {
                        .array => |arr| {
                            var tag_list: std.ArrayList([]const u8) = .empty;
                            for (arr.items) |tag_item| {
                                switch (tag_item) {
                                    .string => |s| try tag_list.append(self.allocator, s),
                                    else => {},
                                }
                            }
                            tags = try tag_list.toOwnedSlice(self.allocator);
                        },
                        else => {},
                    }
                }

                return Tool{
                    .id = id,
                    .name = name,
                    .description = description,
                    .input_schema = obj.get("input_schema") orelse obj.get("inputSchema"),
                    .output_schema = obj.get("output_schema") orelse obj.get("outputSchema"),
                    .tags = tags,
                    .call_template = call_template,
                    .provider_id = self.getString(obj, "provider_id") orelse self.getString(obj, "providerId"),
                };
            },
            else => return null,
        }
    }

    /// Parse call template from JSON object
    fn parseCallTemplate(self: *JsonLoader, obj: std.json.ObjectMap) !?CallTemplate {
        // Check for call_template or callTemplate field
        const template_val = obj.get("call_template") orelse obj.get("callTemplate") orelse {
            // Check for inline transport type
            if (obj.get("transport")) |transport_val| {
                switch (transport_val) {
                    .string => |transport_type| {
                        return try self.parseInlineTemplate(obj, transport_type);
                    },
                    else => {},
                }
            }
            return null;
        };

        switch (template_val) {
            .object => |tmpl| {
                // Determine transport type
                if (tmpl.get("http") != null) {
                    return try self.parseHttpTemplate(tmpl.get("http").?);
                }
                if (tmpl.get("cli") != null) {
                    return try self.parseCliTemplate(tmpl.get("cli").?);
                }
                if (tmpl.get("mcp") != null) {
                    return try self.parseMcpTemplate(tmpl.get("mcp").?);
                }
                if (tmpl.get("sse") != null) {
                    return try self.parseSseTemplate(tmpl.get("sse").?);
                }

                // Check type field
                if (self.getString(tmpl, "type")) |typ| {
                    if (std.mem.eql(u8, typ, "http")) {
                        return try self.parseHttpTemplate(template_val);
                    } else if (std.mem.eql(u8, typ, "cli")) {
                        return try self.parseCliTemplate(template_val);
                    } else if (std.mem.eql(u8, typ, "mcp")) {
                        return try self.parseMcpTemplate(template_val);
                    } else if (std.mem.eql(u8, typ, "sse")) {
                        return try self.parseSseTemplate(template_val);
                    }
                }

                // Default to HTTP if url present
                if (tmpl.get("url") != null) {
                    return try self.parseHttpTemplate(template_val);
                }
                // Default to CLI if command present
                if (tmpl.get("command") != null) {
                    return try self.parseCliTemplate(template_val);
                }
            },
            else => {},
        }

        return null;
    }

    fn parseInlineTemplate(self: *JsonLoader, obj: std.json.ObjectMap, transport_type: []const u8) !?CallTemplate {
        if (std.mem.eql(u8, transport_type, "http")) {
            const url = self.getString(obj, "url") orelse return null;
            const method = self.getString(obj, "method") orelse "GET";
            return CallTemplate{
                .http = .{
                    .method = method,
                    .url = url,
                    .body_template = self.getString(obj, "body"),
                },
            };
        } else if (std.mem.eql(u8, transport_type, "cli")) {
            const command = self.getString(obj, "command") orelse return null;
            return CallTemplate{
                .cli = .{
                    .command = command,
                },
            };
        }
        return null;
    }

    fn parseHttpTemplate(self: *JsonLoader, value: std.json.Value) !?CallTemplate {
        switch (value) {
            .object => |obj| {
                const url = self.getString(obj, "url") orelse return null;
                const method = self.getString(obj, "method") orelse "GET";

                return CallTemplate{
                    .http = .{
                        .method = method,
                        .url = url,
                        .body_template = self.getString(obj, "body_template") orelse self.getString(obj, "body"),
                        .timeout_ms = self.getInt(obj, "timeout_ms") orelse self.getInt(obj, "timeout") orelse 30000,
                    },
                };
            },
            else => return null,
        }
    }

    fn parseCliTemplate(self: *JsonLoader, value: std.json.Value) !?CallTemplate {
        switch (value) {
            .object => |obj| {
                const command = self.getString(obj, "command") orelse return null;

                // Parse args array
                var args: []const []const u8 = &.{};
                if (obj.get("args")) |args_val| {
                    switch (args_val) {
                        .array => |arr| {
                            var arg_list: std.ArrayList([]const u8) = .empty;
                            for (arr.items) |arg| {
                                switch (arg) {
                                    .string => |s| try arg_list.append(self.allocator, s),
                                    else => {},
                                }
                            }
                            args = try arg_list.toOwnedSlice(self.allocator);
                        },
                        else => {},
                    }
                }

                return CallTemplate{
                    .cli = .{
                        .command = command,
                        .args = args,
                        .cwd = self.getString(obj, "cwd"),
                        .stdin_template = self.getString(obj, "stdin_template") orelse self.getString(obj, "stdin"),
                        .timeout_ms = self.getInt(obj, "timeout_ms") orelse self.getInt(obj, "timeout") orelse 60000,
                    },
                };
            },
            else => return null,
        }
    }

    fn parseMcpTemplate(self: *JsonLoader, value: std.json.Value) !?CallTemplate {
        switch (value) {
            .object => |obj| {
                const method = self.getString(obj, "method") orelse "tools/call";

                var mode: McpMode = .stdio;
                if (self.getString(obj, "mode")) |m| {
                    if (std.mem.eql(u8, m, "http")) mode = .http;
                    if (std.mem.eql(u8, m, "sse")) mode = .sse;
                }

                return CallTemplate{
                    .mcp = .{
                        .method = method,
                        .endpoint = self.getString(obj, "endpoint"),
                        .mode = mode,
                    },
                };
            },
            else => return null,
        }
    }

    fn parseSseTemplate(self: *JsonLoader, value: std.json.Value) !?CallTemplate {
        switch (value) {
            .object => |obj| {
                const url = self.getString(obj, "url") orelse return null;

                return CallTemplate{
                    .sse = .{
                        .url = url,
                        .method = self.getString(obj, "method") orelse "GET",
                        .event_type = self.getString(obj, "event_type") orelse self.getString(obj, "eventType"),
                    },
                };
            },
            else => return null,
        }
    }

    /// Parse a provider from JSON
    fn parseProvider(self: *JsonLoader, value: std.json.Value) !?Provider {
        switch (value) {
            .object => |obj| {
                const id = self.getString(obj, "id") orelse self.getString(obj, "name") orelse return null;
                const name = self.getString(obj, "name") orelse id;

                var auth: ?Auth = null;
                if (obj.get("auth")) |auth_val| {
                    auth = try self.parseAuth(auth_val);
                }

                return Provider{
                    .id = id,
                    .name = name,
                    .description = self.getString(obj, "description"),
                    .base_url = self.getString(obj, "base_url") orelse self.getString(obj, "baseUrl"),
                    .auth = auth,
                };
            },
            else => return null,
        }
    }

    /// Parse auth configuration
    fn parseAuth(self: *JsonLoader, value: std.json.Value) !?Auth {
        switch (value) {
            .object => |obj| {
                const auth_type = self.getString(obj, "type") orelse return null;

                if (std.mem.eql(u8, auth_type, "api_key") or std.mem.eql(u8, auth_type, "apiKey")) {
                    return Auth{
                        .api_key = .{
                            .key = self.getString(obj, "key") orelse self.getString(obj, "value") orelse return null,
                            .header_name = self.getString(obj, "header_name") orelse self.getString(obj, "headerName") orelse "X-API-Key",
                        },
                    };
                } else if (std.mem.eql(u8, auth_type, "basic")) {
                    return Auth{
                        .basic = .{
                            .username = self.getString(obj, "username") orelse return null,
                            .password = self.getString(obj, "password") orelse return null,
                        },
                    };
                } else if (std.mem.eql(u8, auth_type, "bearer")) {
                    return Auth{
                        .bearer = .{
                            .token = self.getString(obj, "token") orelse return null,
                        },
                    };
                } else if (std.mem.eql(u8, auth_type, "oauth2")) {
                    return Auth{
                        .oauth2 = .{
                            .client_id = self.getString(obj, "client_id") orelse self.getString(obj, "clientId") orelse return null,
                            .client_secret = self.getString(obj, "client_secret") orelse self.getString(obj, "clientSecret"),
                            .token_url = self.getString(obj, "token_url") orelse self.getString(obj, "tokenUrl") orelse return null,
                            .access_token = self.getString(obj, "access_token") orelse self.getString(obj, "accessToken"),
                        },
                    };
                }
            },
            else => {},
        }
        return null;
    }

    // Helper to get string from object
    fn getString(_: *JsonLoader, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
        if (obj.get(key)) |val| {
            switch (val) {
                .string => |s| return s,
                else => {},
            }
        }
        return null;
    }

    // Helper to get int from object
    fn getInt(_: *JsonLoader, obj: std.json.ObjectMap, key: []const u8) ?u32 {
        if (obj.get(key)) |val| {
            switch (val) {
                .integer => |i| return @intCast(i),
                else => {},
            }
        }
        return null;
    }
};

test "JsonLoader parse simple tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var loader = JsonLoader.init(allocator);

    const json =
        \\{
        \\  "tools": [
        \\    {
        \\      "name": "get-weather",
        \\      "description": "Get weather for a location",
        \\      "tags": ["weather", "api"],
        \\      "call_template": {
        \\        "http": {
        \\          "method": "GET",
        \\          "url": "https://wttr.in/{{location}}"
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const result = try loader.loadString(json);

    try std.testing.expectEqual(@as(usize, 1), result.tools.len);
    try std.testing.expectEqualStrings("get-weather", result.tools[0].name);
    try std.testing.expectEqual(@as(usize, 2), result.tools[0].tags.len);
}

test "JsonLoader parse provider with auth" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var loader = JsonLoader.init(allocator);

    const json =
        \\{
        \\  "providers": [
        \\    {
        \\      "id": "openai",
        \\      "name": "OpenAI",
        \\      "base_url": "https://api.openai.com",
        \\      "auth": {
        \\        "type": "bearer",
        \\        "token": "sk-test-token"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    const result = try loader.loadString(json);

    try std.testing.expectEqual(@as(usize, 1), result.providers.len);
    try std.testing.expectEqualStrings("openai", result.providers[0].id);
    try std.testing.expect(result.providers[0].auth != null);
}
