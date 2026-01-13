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
        .oauth2 => {
            // TODO: Implement OAuth2 token flow
            return error.AuthenticationError;
        },
        .none => {},
    }
}
