//! HTTP transport implementation using std.http.Client

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const HttpCallTemplate = @import("../core/tool.zig").HttpCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const UtcpError = @import("../core/errors.zig").UtcpError;
const substitute = @import("../core/substitution.zig").substitute;

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    env_map: ?std.process.EnvMap,
    
    pub fn init(allocator: std.mem.Allocator) HttpTransport {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .env_map = null,
        };
    }
    
    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
        if (self.env_map) |*map| {
            map.deinit();
        }
    }
    
    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *HttpTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }
    
    /// Call a tool via HTTP
    pub fn call(
        self: *HttpTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        // Extract HTTP template
        const http_template = switch (tool.call_template) {
            .http => |t| t,
            else => return error.UnsupportedTransport,
        };
        
        // Create arena for request/response lifetime
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        // Substitute variables in URL
        const url = try substitute(
            aa,
            http_template.url,
            request.inputs,
            if (self.env_map) |*map| map else null,
        );
        
        // Parse URI
        const uri = try std.Uri.parse(url);
        
        // Prepare request body
        var body_buf: ?[]const u8 = null;
        if (http_template.body_template) |body_template| {
            body_buf = try substitute(
                aa,
                body_template,
                request.inputs,
                if (self.env_map) |*map| map else null,
            );
        } else if (std.mem.eql(u8, http_template.method, "POST") or
                   std.mem.eql(u8, http_template.method, "PUT") or
                   std.mem.eql(u8, http_template.method, "PATCH")) {
            // Default: send inputs as JSON body
            body_buf = try std.json.Stringify.valueAlloc(aa, request.inputs, .{});
        }
        
        // Build extra headers list
        var header_list: std.ArrayList(std.http.Header) = .empty;
        
        // Add custom headers from template
        if (http_template.headers) |tmpl_headers| {
            var iter = tmpl_headers.iterator();
            while (iter.next()) |entry| {
                const value = try substitute(
                    aa,
                    entry.value_ptr.*,
                    request.inputs,
                    if (self.env_map) |*map| map else null,
                );
                try header_list.append(aa, .{ .name = entry.key_ptr.*, .value = value });
            }
        }
        
        // Apply authentication
        if (provider) |p| {
            if (p.auth) |auth| {
                try applyAuth(aa, &header_list, auth);
            }
        }
        
        // Set Content-Type if body present
        if (body_buf != null) {
            var has_content_type = false;
            for (header_list.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                    has_content_type = true;
                    break;
                }
            }
            if (!has_content_type) {
                try header_list.append(aa, .{ .name = "Content-Type", .value = "application/json" });
            }
        }
        
        // Make HTTP request
        const method = std.meta.stringToEnum(std.http.Method, http_template.method) orelse .GET;
        
        var req = try self.client.request(method, uri, .{
            .extra_headers = header_list.items,
        });
        defer req.deinit();
        
        if (body_buf) |body| {
            try req.sendBodyComplete(@constCast(body));
        } else {
            try req.sendBodiless();
        }
        
        // Receive response
        var buf: [8192]u8 = undefined;
        var head = try req.receiveHead(&buf);
        
        // Read response body
        var response_buf: std.ArrayList(u8) = .empty;
        var transfer_buf: [4096]u8 = undefined;
        var reader = head.reader(&transfer_buf);
        const max_size = std.io.Limit.limited(10 * 1024 * 1024); // 10MB
        try reader.appendRemaining(aa, &response_buf, max_size);
        
        // Check status
        const status = head.head.status;
        if (@intFromEnum(status) >= 400) {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, response_buf.items) },
                .error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "HTTP {d}: {s}",
                    .{ @intFromEnum(status), @tagName(status) },
                ),
                .exit_code = @intFromEnum(status),
            };
        }
        
        // Parse JSON response
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_buf.items,
            .{},
        ) catch |err| {
            // If not JSON, return raw string
            if (err == error.UnexpectedToken or err == error.SyntaxError) {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, response_buf.items) },
                };
            }
            return err;
        };
        
        return ToolCallResponse{
            .output = parsed.value,
        };
    }
    
    /// OAuth2 token response structure
    pub const OAuth2TokenResponse = struct {
        access_token: []const u8,
        token_type: []const u8 = "Bearer",
        expires_in: ?i64 = null,
        refresh_token: ?[]const u8 = null,
        scope: ?[]const u8 = null,
    };
    
    /// Obtain OAuth2 access token using client credentials grant
    pub fn obtainOAuth2Token(self: *HttpTransport, oauth2: anytype) !OAuth2TokenResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        const uri = std.Uri.parse(oauth2.token_url) catch return error.InvalidUrl;
        
        // Build form-urlencoded body
        var body = std.ArrayList(u8).empty;
        defer body.deinit(aa);
        try body.appendSlice(aa, "grant_type=client_credentials");
        try std.fmt.format(body.writer(aa), "&client_id={s}", .{oauth2.client_id});
        if (oauth2.client_secret) |secret| {
            try std.fmt.format(body.writer(aa), "&client_secret={s}", .{secret});
        }
        if (oauth2.scope) |scope| {
            try std.fmt.format(body.writer(aa), "&scope={s}", .{scope});
        }
        
        // Build headers
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(aa);
        try headers.append(aa, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
        try headers.append(aa, .{ .name = "Accept", .value = "application/json" });
        
        // Make request
        var server_header_buf: [8192]u8 = undefined;
        var req = self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = headers.items,
        }) catch return error.ConnectionFailed;
        defer req.deinit();
        
        req.transfer_encoding = .{ .content_length = body.items.len };
        req.send() catch return error.SendFailed;
        req.writeAll(body.items) catch return error.SendFailed;
        req.finish() catch return error.SendFailed;
        req.wait() catch return error.ReceiveFailed;
        
        // Check response status
        const status_code: u16 = @intFromEnum(req.response.status);
        if (status_code >= 400) {
            return error.AuthenticationError;
        }
        
        // Read response body
        var response_buf = std.ArrayList(u8).empty;
        defer response_buf.deinit(aa);
        while (true) {
            var buf: [4096]u8 = undefined;
            const n = req.read(&buf) catch return error.ReceiveFailed;
            if (n == 0) break;
            try response_buf.appendSlice(aa, buf[0..n]);
        }
        
        // Parse JSON response
        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_buf.items, .{}) catch return error.ParseError;
        
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.ParseError,
        };
        
        const access_token = switch (obj.get("access_token") orelse return error.ParseError) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => return error.ParseError,
        };
        
        const token_type = if (obj.get("token_type")) |tt| switch (tt) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => "Bearer",
        } else "Bearer";
        
        const expires_in: ?i64 = if (obj.get("expires_in")) |ei| switch (ei) {
            .integer => |i| i,
            else => null,
        } else null;
        
        const refresh_token: ?[]const u8 = if (obj.get("refresh_token")) |rt| switch (rt) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => null,
        } else null;
        
        return OAuth2TokenResponse{
            .access_token = access_token,
            .token_type = token_type,
            .expires_in = expires_in,
            .refresh_token = refresh_token,
        };
    }
    
    /// Refresh OAuth2 access token using refresh token
    pub fn refreshOAuth2Token(self: *HttpTransport, oauth2: anytype, refresh_token_str: []const u8) !OAuth2TokenResponse {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        const uri = std.Uri.parse(oauth2.token_url) catch return error.InvalidUrl;
        
        // Build form-urlencoded body
        var body = std.ArrayList(u8).empty;
        defer body.deinit(aa);
        try body.appendSlice(aa, "grant_type=refresh_token");
        try std.fmt.format(body.writer(aa), "&client_id={s}", .{oauth2.client_id});
        if (oauth2.client_secret) |secret| {
            try std.fmt.format(body.writer(aa), "&client_secret={s}", .{secret});
        }
        try std.fmt.format(body.writer(aa), "&refresh_token={s}", .{refresh_token_str});
        
        // Build headers
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(aa);
        try headers.append(aa, .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" });
        try headers.append(aa, .{ .name = "Accept", .value = "application/json" });
        
        // Make request
        var server_header_buf: [8192]u8 = undefined;
        var req = self.client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buf,
            .extra_headers = headers.items,
        }) catch return error.ConnectionFailed;
        defer req.deinit();
        
        req.transfer_encoding = .{ .content_length = body.items.len };
        req.send() catch return error.SendFailed;
        req.writeAll(body.items) catch return error.SendFailed;
        req.finish() catch return error.SendFailed;
        req.wait() catch return error.ReceiveFailed;
        
        // Check response status
        const status_code: u16 = @intFromEnum(req.response.status);
        if (status_code >= 400) {
            return error.AuthenticationError;
        }
        
        // Read response body
        var response_buf = std.ArrayList(u8).empty;
        defer response_buf.deinit(aa);
        while (true) {
            var buf: [4096]u8 = undefined;
            const n = req.read(&buf) catch return error.ReceiveFailed;
            if (n == 0) break;
            try response_buf.appendSlice(aa, buf[0..n]);
        }
        
        // Parse JSON response
        const parsed = std.json.parseFromSlice(std.json.Value, aa, response_buf.items, .{}) catch return error.ParseError;
        
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return error.ParseError,
        };
        
        const access_token = switch (obj.get("access_token") orelse return error.ParseError) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => return error.ParseError,
        };
        
        const token_type = if (obj.get("token_type")) |tt| switch (tt) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => "Bearer",
        } else "Bearer";
        
        const expires_in: ?i64 = if (obj.get("expires_in")) |ei| switch (ei) {
            .integer => |i| i,
            else => null,
        } else null;
        
        const new_refresh_token: ?[]const u8 = if (obj.get("refresh_token")) |rt| switch (rt) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => null,
        } else null;
        
        return OAuth2TokenResponse{
            .access_token = access_token,
            .token_type = token_type,
            .expires_in = expires_in,
            .refresh_token = new_refresh_token,
        };
    }
};

/// Apply authentication to HTTP headers
fn applyAuth(
    allocator: std.mem.Allocator,
    headers: *std.ArrayList(std.http.Header),
    auth: Auth,
) !void {
    switch (auth) {
        .api_key => |api_key| {
            try headers.append(allocator, .{ .name = api_key.header_name, .value = api_key.key });
        },
        .basic => |basic| {
            const credentials = try std.fmt.allocPrint(
                allocator,
                "{s}:{s}",
                .{ basic.username, basic.password },
            );
            var encoded_buf: [256]u8 = undefined;
            const encoded = std.base64.standard.Encoder.encode(&encoded_buf, credentials);
            const auth_value = try std.fmt.allocPrint(allocator, "Basic {s}", .{encoded});
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        },
        .bearer => |bearer| {
            const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{bearer.token});
            try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
        },
        .oauth2 => |oauth2| {
            // Use existing access token if available
            if (oauth2.access_token) |token| {
                const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
                try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
            } else {
                // No access token - would need to call obtainOAuth2Token first
                return error.AuthenticationError;
            }
        },
        .none => {},
    }
}
