//! UDP transport implementation
//! Simple datagram-based request/response

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const UdpCallTemplate = @import("../core/tool.zig").UdpCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const substitute = @import("../core/substitution.zig").substitute;

pub const UdpTransport = struct {
    allocator: std.mem.Allocator,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) UdpTransport {
        return .{
            .allocator = allocator,
            .env_map = null,
        };
    }

    pub fn deinit(self: *UdpTransport) void {
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    /// Load environment variables (call once at startup)
    pub fn loadEnv(self: *UdpTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a tool via UDP
    pub fn call(
        self: *UdpTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        _ = provider; // UDP typically doesn't use auth

        const udp_template = switch (tool.call_template) {
            .udp => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in host
        const host = try substitute(
            aa,
            udp_template.host,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        // Serialize request inputs to JSON
        const payload = try std.json.Stringify.valueAlloc(aa, request.inputs, .{});

        // Create UDP socket
        const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "Failed to create UDP socket") },
                .error_msg = try self.allocator.dupe(u8, "socket creation failed"),
            };
        };
        defer std.posix.close(sock);

        // Set receive timeout
        const timeout_sec = udp_template.timeout_ms / 1000;
        const timeout_usec = (udp_template.timeout_ms % 1000) * 1000;
        const timeout = std.posix.timeval{
            .sec = @intCast(timeout_sec),
            .usec = @intCast(timeout_usec),
        };
        std.posix.setsockopt(sock, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};

        // Resolve host address
        const addr = std.net.Address.parseIp4(host, udp_template.port) catch {
            // Try DNS lookup
            const list = std.net.getAddressList(self.allocator, host, udp_template.port) catch {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, "Failed to resolve host") },
                    .error_msg = try self.allocator.dupe(u8, "DNS resolution failed"),
                };
            };
            defer list.deinit();

            if (list.addrs.len == 0) {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, "No addresses found") },
                    .error_msg = try self.allocator.dupe(u8, "DNS returned no addresses"),
                };
            }

            // Use first address
            _ = std.posix.sendto(sock, payload, 0, list.addrs[0].any, @sizeOf(@TypeOf(list.addrs[0].any))) catch {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, "Failed to send UDP packet") },
                    .error_msg = try self.allocator.dupe(u8, "sendto failed"),
                };
            };

            // Receive response
            var recv_buf: [65535]u8 = undefined;
            const recv_len = std.posix.recvfrom(sock, &recv_buf, 0, null, null) catch |err| {
                if (err == error.WouldBlock) {
                    return ToolCallResponse{
                        .output = .{ .string = try self.allocator.dupe(u8, "UDP receive timeout") },
                        .error_msg = try self.allocator.dupe(u8, "timeout"),
                    };
                }
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, "Failed to receive UDP response") },
                    .error_msg = try self.allocator.dupe(u8, "recvfrom failed"),
                };
            };

            // Try to parse response as JSON
            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, recv_buf[0..recv_len], .{}) catch {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, recv_buf[0..recv_len]) },
                };
            };

            return ToolCallResponse{
                .output = parsed.value,
            };
        };

        // Send to resolved IP directly
        _ = std.posix.sendto(sock, payload, 0, &addr.any, @sizeOf(@TypeOf(addr.any))) catch {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "Failed to send UDP packet") },
                .error_msg = try self.allocator.dupe(u8, "sendto failed"),
            };
        };

        // Receive response
        var recv_buf: [65535]u8 = undefined;
        const recv_len = std.posix.recvfrom(sock, &recv_buf, 0, null, null) catch |err| {
            if (err == error.WouldBlock) {
                return ToolCallResponse{
                    .output = .{ .string = try self.allocator.dupe(u8, "UDP receive timeout") },
                    .error_msg = try self.allocator.dupe(u8, "timeout"),
                };
            }
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, "Failed to receive UDP response") },
                .error_msg = try self.allocator.dupe(u8, "recvfrom failed"),
            };
        };

        // Try to parse response as JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, recv_buf[0..recv_len], .{}) catch {
            return ToolCallResponse{
                .output = .{ .string = try self.allocator.dupe(u8, recv_buf[0..recv_len]) },
            };
        };

        return ToolCallResponse{
            .output = parsed.value,
        };
    }

    /// Send a UDP message without waiting for response (fire-and-forget)
    pub fn send(
        self: *UdpTransport,
        tool: Tool,
        request: ToolCallRequest,
    ) !void {
        const udp_template = switch (tool.call_template) {
            .udp => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const host = try substitute(
            aa,
            udp_template.host,
            request.inputs,
            if (self.env_map) |*m| m else null,
        );

        const payload = try std.json.Stringify.valueAlloc(aa, request.inputs, .{});

        const sock = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        defer std.posix.close(sock);

        const addr = std.net.Address.parseIp4(host, udp_template.port) catch {
            const list = try std.net.getAddressList(self.allocator, host, udp_template.port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.NoAddressFound;
            _ = try std.posix.sendto(sock, payload, 0, list.addrs[0].any, @sizeOf(@TypeOf(list.addrs[0].any)));
            return;
        };

        _ = try std.posix.sendto(sock, payload, 0, &addr.any, @sizeOf(@TypeOf(addr.any)));
    }
};

test "udp template creation" {
    const template = UdpCallTemplate{
        .host = "127.0.0.1",
        .port = 9999,
        .timeout_ms = 1000,
    };

    try std.testing.expectEqual(@as(u16, 9999), template.port);
    try std.testing.expectEqual(@as(u32, 1000), template.timeout_ms);
}
