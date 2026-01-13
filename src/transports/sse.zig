//! SSE (Server-Sent Events) transport implementation
//! Connects to SSE endpoints and processes event streams

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const SseCallTemplate = @import("../core/tool.zig").SseCallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const substitute = @import("../core/substitution.zig").substitute;

/// SSE Event structure
pub const SseEvent = struct {
    event_type: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// SSE Transport for Server-Sent Events
pub const SseTransport = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    env_map: ?std.process.EnvMap,

    pub fn init(allocator: std.mem.Allocator) SseTransport {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .env_map = null,
        };
    }

    pub fn deinit(self: *SseTransport) void {
        self.client.deinit();
        if (self.env_map) |*map| {
            map.deinit();
        }
    }

    pub fn loadEnv(self: *SseTransport) !void {
        self.env_map = try std.process.getEnvMap(self.allocator);
    }

    /// Call a tool via SSE - connects and reads first complete event
    pub fn call(
        self: *SseTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
    ) !ToolCallResponse {
        const sse_template = switch (tool.call_template) {
            .sse => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        // Substitute variables in URL
        const url = try substitute(
            aa,
            sse_template.url,
            request.inputs,
            if (self.env_map) |*map| map else null,
        );

        const uri = try std.Uri.parse(url);

        // Build headers
        var header_list: std.ArrayList(std.http.Header) = .empty;
        try header_list.append(aa, .{ .name = "Accept", .value = "text/event-stream" });
        try header_list.append(aa, .{ .name = "Cache-Control", .value = "no-cache" });

        // Add custom headers
        if (sse_template.headers) |tmpl_headers| {
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

        // Apply auth
        if (provider) |p| {
            if (p.auth) |auth| {
                try applyAuth(aa, &header_list, auth);
            }
        }

        // Make request
        const method = std.meta.stringToEnum(std.http.Method, sse_template.method) orelse .GET;
        var req = try self.client.request(method, uri, .{
            .extra_headers = header_list.items,
        });
        defer req.deinit();

        try req.sendBodiless();

        var buf: [8192]u8 = undefined;
        var head = try req.receiveHead(&buf);

        // Check content type
        const status = head.head.status;
        if (@intFromEnum(status) >= 400) {
            return ToolCallResponse{
                .output = .null,
                .error_msg = try std.fmt.allocPrint(
                    self.allocator,
                    "HTTP {d}: {s}",
                    .{ @intFromEnum(status), @tagName(status) },
                ),
                .exit_code = @intFromEnum(status),
            };
        }

        // Read SSE stream and collect first event matching filter
        var response_buf: std.ArrayList(u8) = .empty;
        var transfer_buf: [4096]u8 = undefined;
        var reader = head.reader(&transfer_buf);
        const max_size = std.io.Limit.limited(1024 * 1024); // 1MB
        try reader.appendRemaining(aa, &response_buf, max_size);

        // Parse SSE events
        const events = try parseSseEvents(aa, response_buf.items);

        // Find matching event
        for (events) |event| {
            if (sse_template.event_type) |filter| {
                if (event.event_type) |et| {
                    if (!std.mem.eql(u8, et, filter)) continue;
                }
            }

            // Try to parse as JSON
            const parsed = std.json.parseFromSlice(
                std.json.Value,
                self.allocator,
                event.data,
                .{},
            ) catch {
                return ToolCallResponse{
                    .output = std.json.Value{ .string = try self.allocator.dupe(u8, event.data) },
                };
            };

            return ToolCallResponse{
                .output = parsed.value,
            };
        }

        return ToolCallResponse{
            .output = .null,
            .error_msg = "No matching SSE event found",
        };
    }

    /// Stream events from SSE endpoint (returns iterator-like interface)
    pub fn stream(
        self: *SseTransport,
        tool: Tool,
        request: ToolCallRequest,
        provider: ?Provider,
        callback: *const fn (SseEvent) bool,
    ) !void {
        const sse_template = switch (tool.call_template) {
            .sse => |t| t,
            else => return error.UnsupportedTransport,
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const url = try substitute(
            aa,
            sse_template.url,
            request.inputs,
            if (self.env_map) |*map| map else null,
        );

        const uri = try std.Uri.parse(url);

        var header_list: std.ArrayList(std.http.Header) = .empty;
        try header_list.append(aa, .{ .name = "Accept", .value = "text/event-stream" });

        if (provider) |p| {
            if (p.auth) |auth| {
                try applyAuth(aa, &header_list, auth);
            }
        }

        const method = std.meta.stringToEnum(std.http.Method, sse_template.method) orelse .GET;
        var req = try self.client.request(method, uri, .{
            .extra_headers = header_list.items,
        });
        defer req.deinit();

        try req.sendBodiless();

        var buf: [8192]u8 = undefined;
        var head = try req.receiveHead(&buf);

        // Stream and parse events
        var line_buf: std.ArrayList(u8) = .empty;
        var current_event: SseEvent = .{ .data = "" };
        var data_buf: std.ArrayList(u8) = .empty;

        var transfer_buf: [4096]u8 = undefined;
        var reader = head.reader(&transfer_buf);

        while (true) {
            const chunk = reader.read() catch break;
            if (chunk.len == 0) break;

            try line_buf.appendSlice(aa, chunk);

            // Process complete lines
            while (std.mem.indexOf(u8, line_buf.items, "\n")) |nl| {
                const line = line_buf.items[0..nl];
                
                if (line.len == 0 or (line.len == 1 and line[0] == '\r')) {
                    // Empty line = dispatch event
                    if (data_buf.items.len > 0) {
                        current_event.data = data_buf.items;
                        if (!callback(current_event)) return;
                        data_buf.clearRetainingCapacity();
                    }
                    current_event = .{ .data = "" };
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    const data = std.mem.trim(u8, line[5..], " \r");
                    if (data_buf.items.len > 0) {
                        try data_buf.append(aa, '\n');
                    }
                    try data_buf.appendSlice(aa, data);
                } else if (std.mem.startsWith(u8, line, "event:")) {
                    current_event.event_type = std.mem.trim(u8, line[6..], " \r");
                } else if (std.mem.startsWith(u8, line, "id:")) {
                    current_event.id = std.mem.trim(u8, line[3..], " \r");
                }

                // Remove processed line
                const remaining = line_buf.items[nl + 1 ..];
                std.mem.copyForwards(u8, line_buf.items[0..remaining.len], remaining);
                line_buf.shrinkRetainingCapacity(remaining.len);
            }
        }
    }
};

/// Parse SSE event stream into individual events
fn parseSseEvents(allocator: std.mem.Allocator, data: []const u8) ![]SseEvent {
    var events: std.ArrayList(SseEvent) = .empty;
    var current_data: std.ArrayList(u8) = .empty;
    defer current_data.deinit(allocator);
    var current_event_type: ?[]const u8 = null;
    var current_id: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");

        if (trimmed.len == 0) {
            // Empty line = dispatch event
            if (current_data.items.len > 0) {
                try events.append(allocator, .{
                    .event_type = current_event_type,
                    .data = try allocator.dupe(u8, current_data.items),
                    .id = current_id,
                });
                current_data.clearRetainingCapacity();
                current_event_type = null;
                current_id = null;
            }
        } else if (std.mem.startsWith(u8, trimmed, "data:")) {
            const value = std.mem.trim(u8, trimmed[5..], " ");
            if (current_data.items.len > 0) {
                try current_data.append(allocator, '\n');
            }
            try current_data.appendSlice(allocator, value);
        } else if (std.mem.startsWith(u8, trimmed, "event:")) {
            current_event_type = std.mem.trim(u8, trimmed[6..], " ");
        } else if (std.mem.startsWith(u8, trimmed, "id:")) {
            current_id = std.mem.trim(u8, trimmed[3..], " ");
        }
    }

    // Handle final event if no trailing newline
    if (current_data.items.len > 0) {
        try events.append(allocator, .{
            .event_type = current_event_type,
            .data = try allocator.dupe(u8, current_data.items),
            .id = current_id,
        });
    }

    return events.toOwnedSlice(allocator);
}

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
            const credentials = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ basic.username, basic.password });
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
            // Use access token if available
            if (oauth2.access_token) |token| {
                const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
                try headers.append(allocator, .{ .name = "Authorization", .value = auth_value });
            }
        },
        .none => {},
    }
}

test "parseSseEvents basic" {
    const allocator = std.testing.allocator;
    const data = "event: message\ndata: hello world\n\nevent: update\ndata: line1\ndata: line2\n\n";
    const events = try parseSseEvents(allocator, data);
    defer {
        for (events) |e| {
            allocator.free(e.data);
        }
        allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("message", events[0].event_type.?);
    try std.testing.expectEqualStrings("hello world", events[0].data);
    try std.testing.expectEqualStrings("update", events[1].event_type.?);
    try std.testing.expectEqualStrings("line1\nline2", events[1].data);
}
