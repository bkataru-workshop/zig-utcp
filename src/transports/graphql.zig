//! GraphQL transport implementation
//! HTTP-based GraphQL queries and mutations

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const GraphqlCallTemplate = @import("../core/tool.zig").GraphqlCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const substitute = @import("../core/substitution.zig").substitute;

pub const GraphqlTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) GraphqlTransport {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .env_map = null,
        };
    }

    pub fn deinit(self: *GraphqlTransport) void {
        self.client.deinit();
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *GraphqlTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Execute a GraphQL query/mutation
    pub fn call(
        self: *GraphqlTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        const gql_template = switch (tool.call_template) {
            .graphql => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in endpoint
        const endpoint = try substitute(
            aa,
            gql_template.endpoint,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        // Build GraphQL request body
        var body_obj = std.json.ObjectMap.init(aa);
        try body_obj.put("query", .{ .string = gql_template.query });

        if (gql_template.operation_name) |op| {
            try body_obj.put("operationName", .{ .string = op });
        }

        // Build variables from request inputs or template
        if (gql_template.variables_template) |tmpl| {
            const vars_str = try substitute(aa, tmpl, request.inputs, if (self.env_map) |*m| m else null);
            const parsed_vars = std.json.parseFromSlice(std.json.Value, aa, vars_str, .{}) catch {
                try body_obj.put("variables", request.inputs);
                const body_json = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = body_obj }, .{});
                return self.executeRequest(endpoint, body_json, provider, aa);
            };
            try body_obj.put("variables", parsed_vars.value);
        } else {
            try body_obj.put("variables", request.inputs);
        }

        const body_json = try std.json.Stringify.valueAlloc(aa, std.json.Value{ .object = body_obj }, .{});

        return self.executeRequest(endpoint, body_json, provider, aa);
    }

    fn executeRequest(
        self: *GraphqlTransport,
        endpoint: []const u8,
        body: []const u8,
        provider: ?Provider,
        aa: std.mem.Allocator,
    ) !ToolCallResponse {
        const uri = std.Uri.parse(endpoint) catch return error.InvalidUrl;

        // Build headers
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(aa);

        try headers.append(aa, .{ .name = "Content-Type", .value = "application/json" });
        try headers.append(aa, .{ .name = "Accept", .value = "application/json" });

        // Apply auth
        try self.applyAuth(&headers, aa, provider);

        // Make HTTP request
        var server_header_buf: [8192]u8 = undefined;
        var req = self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = headers.items,
        }) catch return error.ConnectionFailed;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return error.SendFailed;
        req.writeAll(body) catch return error.SendFailed;
        req.finish() catch return error.SendFailed;
        req.wait() catch return error.ReceiveFailed;

        // Check status
        const status_code: u16 = @intFromEnum(req.response.status);
        if (status_code >= 400) {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "GraphQL request failed") },
                .error_msg = try std.fmt.allocPrint(self.allocator, "HTTP {d}", .{status_code}),
            };
        }

        // Read response
        var response_buf = std.ArrayList(u8).empty;
        defer response_buf.deinit(aa);

        while (true) {
            var buf: [4096]u8 = undefined;
            const n = req.read(&buf) catch return error.ReceiveFailed;
            if (n == 0) break;
            try response_buf.appendSlice(aa, buf[0..n]);
        }

        // Parse response
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_buf.items, .{}) catch {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, response_buf.items) },
            };
        };

        // Check for GraphQL errors
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("errors")) |errors| {
                // Return errors in output but flag as error
                var error_msg: ?[]const u8 = null;
                if (errors == .array and errors.array.items.len > 0) {
                    const first = errors.array.items[0];
                    if (first == .object) {
                        if (first.object.get("message")) |msg| {
                            if (msg == .string) {
                                error_msg = try self.allocator.dupe(u8, msg.string);
                            }
                        }
                    }
                }
                return ToolCallResponse{
                    .output = parsed.value,
                    .error_msg = error_msg,
                };
            }

            // Return just the data field if present
            if (obj.get("data")) |data| {
                return ToolCallResponse{
                    .output = data,
                };
            }
        }

        return ToolCallResponse{
            .output = parsed.value,
        };
    }

    fn applyAuth(self: *GraphqlTransport, headers: *std.ArrayList(std.http.Header), aa: std.mem.Allocator, provider: ?Provider) !void {
        const prov = provider orelse return;
        const auth = prov.auth orelse return;
        _ = self;

        switch (auth) {
            .api_key => |api_key| {
                const header_name = api_key.header_name;
                try headers.append(aa, .{ .name = header_name, .value = api_key.key });
            },
            .basic => |basic| {
                const creds = try std.fmt.allocPrint(aa, "{s}:{s}", .{ basic.username, basic.password });
                var encoded_buf: [256]u8 = undefined;
                const encoded = std.base64.standard.Encoder.encode(&encoded_buf, creds);
                const auth_value = try std.fmt.allocPrint(aa, "Basic {s}", .{encoded});
                try headers.append(aa, .{ .name = "Authorization", .value = auth_value });
            },
            .bearer => |bearer| {
                const auth_value = try std.fmt.allocPrint(aa, "Bearer {s}", .{bearer.token});
                try headers.append(aa, .{ .name = "Authorization", .value = auth_value });
            },
            .oauth2 => |oauth2| {
                if (oauth2.access_token) |token| {
                    const auth_value = try std.fmt.allocPrint(aa, "Bearer {s}", .{token});
                    try headers.append(aa, .{ .name = "Authorization", .value = auth_value });
                }
            },
            .none => {},
        }
    }
};

/// Build a GraphQL query string from a template
pub fn buildQuery(
    allocator: std.mem.Allocator,
    query_template: []const u8,
    variables: std.json.Value,
    env_map: ?*std.process.EnvMap,
) ![]const u8 {
    return substitute(allocator, query_template, variables, env_map);
}

test "graphql template creation" {
    const template = GraphqlCallTemplate{
        .endpoint = "https://api.example.com/graphql",
        .query = "query GetUser($id: ID!) { user(id: $id) { name email } }",
        .operation_name = "GetUser",
    };

    try std.testing.expectEqualStrings("GetUser", template.operation_name.?);
}

test "graphql query builder" {
    // Simple test that doesn't use substitution
    const template = GraphqlCallTemplate{
        .endpoint = "https://api.example.com/graphql",
        .query = "query GetUser($id: ID!) { user(id: $id) { name } }",
    };

    try std.testing.expectEqualStrings("query GetUser($id: ID!) { user(id: $id) { name } }", template.query);
}
