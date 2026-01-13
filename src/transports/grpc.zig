//! gRPC transport implementation
//! Simplified gRPC-like transport using HTTP with protobuf-like message framing

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const GrpcCallTemplate = @import("../core/tool.zig").GrpcCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const substitute = @import("../core/substitution.zig").substitute;

pub const GrpcTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) GrpcTransport {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .env_map = null,
        };
    }

    pub fn deinit(self: *GrpcTransport) void {
        self.client.deinit();
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables
    pub fn loadEnv(self: *GrpcTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a gRPC service method
    /// Note: This is a simplified implementation using gRPC-Web compatible JSON encoding.
    /// For full gRPC support with protobuf binary encoding, consider using a native gRPC library.
    pub fn call(
        self: *GrpcTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        const grpc_template = switch (tool.call_template) {
            .grpc => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in endpoint
        const endpoint = try substitute(
            aa,
            grpc_template.endpoint,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        // Build gRPC path: /package.Service/Method
        const path = try std.fmt.allocPrint(aa, "{s}/{s}/{s}", .{
            endpoint,
            grpc_template.service,
            grpc_template.method,
        });

        // Serialize request as JSON (gRPC-Web JSON mode)
        const body = try std.json.Stringify.valueAlloc(aa, request.inputs, .{});

        const uri = std.Uri.parse(path) catch return error.InvalidUrl;

        // Build headers for gRPC-Web
        var headers = std.ArrayList(std.http.Header).empty;
        defer headers.deinit(aa);

        try headers.append(aa, .{ .name = "Content-Type", .value = "application/grpc-web+json" });
        try headers.append(aa, .{ .name = "Accept", .value = "application/grpc-web+json" });
        try headers.append(aa, .{ .name = "X-Grpc-Web", .value = "1" });

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
                .output = .{ .string = try self.allocator.dupe(u8, "gRPC request failed") },
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

        // Check for gRPC status in trailers
        // In gRPC-Web, trailers are sent as base64-encoded data at the end
        // For simplicity, we just check if the response is valid JSON

        // Parse response as JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_buf.items, .{}) catch {
            // Check for gRPC-Web trailer format
            if (std.mem.startsWith(u8, response_buf.items, "\x80")) {
                // This is a trailer frame, extract status
                return self.parseGrpcTrailer(response_buf.items);
            }
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, response_buf.items) },
            };
        };

        return ToolCallResponse{
            .output = parsed.value,
        };
    }

    fn parseGrpcTrailer(self: *GrpcTransport, data: []const u8) !ToolCallResponse {
        // gRPC-Web trailer format: 0x80 | length (4 bytes BE) | trailer data
        if (data.len < 5) {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "Invalid gRPC trailer") },
                .error_msg = try self.allocator.dupe(u8, "malformed trailer"),
            };
        }

        const trailer_len = (@as(u32, data[1]) << 24) |
            (@as(u32, data[2]) << 16) |
            (@as(u32, data[3]) << 8) |
            @as(u32, data[4]);

        if (data.len < 5 + trailer_len) {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "Incomplete gRPC trailer") },
                .error_msg = try self.allocator.dupe(u8, "truncated trailer"),
            };
        }

        const trailer_data = data[5 .. 5 + trailer_len];

        // Parse trailer headers (key: value\r\n format)
        var status: ?[]const u8 = null;
        var message: ?[]const u8 = null;

        var lines = std.mem.splitSequence(u8, trailer_data, "\r\n");
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "grpc-status:")) {
                status = std.mem.trim(u8, line["grpc-status:".len..], " ");
            } else if (std.mem.startsWith(u8, line, "grpc-message:")) {
                message = std.mem.trim(u8, line["grpc-message:".len..], " ");
            }
        }

        if (status) |s| {
            if (!std.mem.eql(u8, s, "0")) {
                // Non-zero status means error
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, message orelse "gRPC error") },
                    .error_msg = try std.fmt.allocPrint(self.allocator, "gRPC status: {s}", .{s}),
                };
            }
        }

        return ToolCallResponse{
            .output = .{ .string = try self.allocator.dupe(u8, "OK") },
        };
    }

    fn applyAuth(self: *GrpcTransport, headers: *std.ArrayList(std.http.Header), aa: std.mem.Allocator, provider: ?Provider) !void {
        const prov = provider orelse return;
        const auth = prov.auth orelse return;
        _ = self;

        switch (auth) {
            .api_key => |api_key| {
                try headers.append(aa, .{ .name = api_key.header_name, .value = api_key.key });
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

/// gRPC status codes
pub const GrpcStatus = enum(u8) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,
};

test "grpc template creation" {
    const template = GrpcCallTemplate{
        .endpoint = "https://grpc.example.com",
        .service = "example.UserService",
        .method = "GetUser",
    };

    try std.testing.expectEqualStrings("example.UserService", template.service);
    try std.testing.expectEqualStrings("GetUser", template.method);
}

test "grpc status codes" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(GrpcStatus.ok));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(GrpcStatus.not_found));
    try std.testing.expectEqual(@as(u8, 16), @intFromEnum(GrpcStatus.unauthenticated));
}
