//! WebSocket transport implementation
//! Uses HTTP upgrade for WebSocket connections

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const WebSocketCallTemplate = @import("../core/tool.zig").WebSocketCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const UtcpError = @import("../core/errors.zig").UtcpError;
const substitute = @import("../core/substitution.zig").substitute;

pub const WebSocketTransport = struct {
    allocator: std.mem.Allocator,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) WebSocketTransport {
        return .{
            .allocator = allocator,
            .env_map = null,
        };
    }

    pub fn deinit(self: *WebSocketTransport) void {
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *WebSocketTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a tool via WebSocket
    /// Note: This implementation uses a single request/response pattern.
    /// For full duplex streaming, use the stream() method.
    pub fn call(
        self: *WebSocketTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        const ws_template = switch (tool.call_template) {
            .websocket => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Parse URL to get host and path
        const url = try substitute(
            aa,
            ws_template.url,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        // Determine if using SSL
        const use_ssl = std.mem.eql(u8, uri.scheme, "wss");
        const port: u16 = uri.port orelse (if (use_ssl) 443 else 80);

        // Get host as slice
        const host = switch (uri.host.?) {
            .raw => |h| h,
            .percent_encoded => |h| h,
        };

        // Connect to server
        var stream = std.net.tcpConnectToHost(self.allocator, host, port) catch {
            return error.ConnectionFailed;
        };
        defer stream.close();

        // For WSS, we would need TLS here - not supported in std
        if (use_ssl) {
            return ToolCallResponse{
                .allocator = self.allocator,
                .success = false,
                .output = try self.allocator.dupe(u8, "WSS (TLS) not supported in std library"),
                .metadata = null,
            };
        }

        // Generate WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);
        const ws_key = std.base64.standard.Encoder.encode(&key_bytes) catch unreachable;

        // Build HTTP upgrade request
        const path = if (uri.path.len > 0) uri.path else "/";

        var upgrade_request = std.ArrayList(u8).empty;
        defer upgrade_request.deinit(aa);

        try std.fmt.format(upgrade_request.writer(aa), "GET {s} HTTP/1.1\r\n", .{path});
        try std.fmt.format(upgrade_request.writer(aa), "Host: {s}\r\n", .{host});
        try upgrade_request.appendSlice(aa, "Upgrade: websocket\r\n");
        try upgrade_request.appendSlice(aa, "Connection: Upgrade\r\n");
        try std.fmt.format(upgrade_request.writer(aa), "Sec-WebSocket-Key: {s}\r\n", .{ws_key});
        try upgrade_request.appendSlice(aa, "Sec-WebSocket-Version: 13\r\n");

        // Add subprotocol if specified
        if (ws_template.subprotocol) |proto| {
            try std.fmt.format(upgrade_request.writer(aa), "Sec-WebSocket-Protocol: {s}\r\n", .{proto});
        }

        // Add auth headers
        try self.applyAuth(&upgrade_request, aa, provider);

        try upgrade_request.appendSlice(aa, "\r\n");

        // Send upgrade request
        _ = stream.write(upgrade_request.items) catch return error.SendFailed;

        // Read response
        var response_buf: [1024]u8 = undefined;
        const response_len = stream.read(&response_buf) catch return error.ReceiveFailed;
        const response_str = response_buf[0..response_len];

        // Verify upgrade response
        if (!std.mem.containsAtLeast(u8, response_str, 1, "101 Switching Protocols")) {
            return ToolCallResponse{
                .allocator = self.allocator,
                .success = false,
                .output = try self.allocator.dupe(u8, "WebSocket upgrade failed"),
                .metadata = null,
            };
        }

        // Serialize request inputs to JSON
        const json_payload = try std.json.Stringify.valueAlloc(aa, request.inputs, .{});

        // Send WebSocket frame (text frame, no mask for simplicity)
        const frame = try self.createTextFrame(aa, json_payload);
        _ = stream.write(frame) catch return error.SendFailed;

        // Read WebSocket response frame
        var ws_response_buf: [8192]u8 = undefined;
        const ws_response_len = stream.read(&ws_response_buf) catch return error.ReceiveFailed;

        if (ws_response_len < 2) {
            return ToolCallResponse{
                .allocator = self.allocator,
                .success = false,
                .output = try self.allocator.dupe(u8, "Invalid WebSocket response"),
                .metadata = null,
            };
        }

        // Parse WebSocket frame
        const payload = self.parseFrame(ws_response_buf[0..ws_response_len]) catch {
            return ToolCallResponse{
                .allocator = self.allocator,
                .success = false,
                .output = try self.allocator.dupe(u8, "Failed to parse WebSocket frame"),
                .metadata = null,
            };
        };

        return ToolCallResponse{
            .allocator = self.allocator,
            .success = true,
            .output = try self.allocator.dupe(u8, payload),
            .metadata = null,
        };
    }

    fn applyAuth(self: *WebSocketTransport, request: *std.ArrayList(u8), aa: std.mem.Allocator, provider: ?Provider) !void {
        const prov = provider orelse return;
        const auth = prov.auth orelse return;
        _ = self;

        switch (auth) {
            .api_key => |api_key| {
                const header_name = api_key.header orelse "X-API-Key";
                try std.fmt.format(request.writer(aa), "{s}: {s}\r\n", .{ header_name, api_key.key });
            },
            .basic => |basic| {
                const creds = try std.fmt.allocPrint(aa, "{s}:{s}", .{ basic.username, basic.password });
                const encoded = std.base64.standard.Encoder.encode(creds) catch unreachable;
                try std.fmt.format(request.writer(aa), "Authorization: Basic {s}\r\n", .{encoded});
            },
            .bearer => |bearer| {
                try std.fmt.format(request.writer(aa), "Authorization: Bearer {s}\r\n", .{bearer.token});
            },
            .oauth2 => |oauth2| {
                if (oauth2.access_token) |token| {
                    try std.fmt.format(request.writer(aa), "Authorization: Bearer {s}\r\n", .{token});
                }
            },
        }
    }

    fn createTextFrame(self: *WebSocketTransport, allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
        _ = self;
        const len = payload.len;

        // Calculate frame size
        const header_size: usize = if (len <= 125) 2 else if (len <= 65535) 4 else 10;
        var frame = try allocator.alloc(u8, header_size + len);

        // FIN bit + text opcode (0x81)
        frame[0] = 0x81;

        // Payload length
        if (len <= 125) {
            frame[1] = @intCast(len);
        } else if (len <= 65535) {
            frame[1] = 126;
            frame[2] = @intCast((len >> 8) & 0xFF);
            frame[3] = @intCast(len & 0xFF);
        } else {
            frame[1] = 127;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                frame[2 + i] = @intCast((len >> @intCast(56 - i * 8)) & 0xFF);
            }
        }

        @memcpy(frame[header_size..], payload);
        return frame;
    }

    fn parseFrame(self: *WebSocketTransport, data: []const u8) ![]const u8 {
        _ = self;
        if (data.len < 2) return error.InvalidFrame;

        const payload_len_byte = data[1] & 0x7F;
        var header_size: usize = 2;
        var payload_len: usize = 0;

        if (payload_len_byte <= 125) {
            payload_len = payload_len_byte;
        } else if (payload_len_byte == 126) {
            if (data.len < 4) return error.InvalidFrame;
            payload_len = (@as(usize, data[2]) << 8) | @as(usize, data[3]);
            header_size = 4;
        } else {
            if (data.len < 10) return error.InvalidFrame;
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                payload_len = (payload_len << 8) | @as(usize, data[2 + i]);
            }
            header_size = 10;
        }

        // Check for mask bit
        const masked = (data[1] & 0x80) != 0;
        if (masked) {
            header_size += 4;
        }

        if (data.len < header_size + payload_len) return error.InvalidFrame;
        return data[header_size .. header_size + payload_len];
    }
};

test "websocket frame creation" {
    const allocator = std.testing.allocator;
    var transport = WebSocketTransport.init(allocator);
    defer transport.deinit();

    const payload = "Hello, WebSocket!";
    const frame = try transport.createTextFrame(allocator, payload);
    defer allocator.free(frame);

    // Verify frame header
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]); // FIN + text opcode
    try std.testing.expectEqual(@as(u8, payload.len), frame[1]); // Short length

    // Verify payload
    try std.testing.expectEqualStrings(payload, frame[2..]);
}

test "websocket frame parsing" {
    const allocator = std.testing.allocator;
    var transport = WebSocketTransport.init(allocator);
    defer transport.deinit();

    // Create a simple unmasked text frame
    const payload = "Test response";
    var frame: [15]u8 = undefined;
    frame[0] = 0x81; // FIN + text opcode
    frame[1] = @intCast(payload.len);
    @memcpy(frame[2..], payload);

    const parsed = try transport.parseFrame(&frame);
    try std.testing.expectEqualStrings(payload, parsed);
}
