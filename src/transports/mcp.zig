//! MCP (Model Context Protocol) transport implementation
//! Supports JSON-RPC 2.0 over stdio (subprocess) and HTTP modes

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const ToolCallRequest = @import("../core/tool.zig").ToolCallRequest;
const ToolCallResponse = @import("../core/tool.zig").ToolCallResponse;
const McpCallTemplate = @import("../core/tool.zig").McpCallTemplate;
const McpMode = @import("../core/tool.zig").McpMode;
const UtcpError = @import("../core/errors.zig").UtcpError;
const substitute = @import("../core/substitution.zig").substitute;

/// JSON-RPC 2.0 request structure
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
    id: u64,
};

/// JSON-RPC 2.0 response structure
pub const JsonRpcResponse = struct {
    jsonrpc: []const u8,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
    id: ?u64 = null,
};

/// JSON-RPC 2.0 error object
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// MCP Transport for JSON-RPC 2.0 communication
pub const McpTransport = struct {
    allocator: std.mem.Allocator,
    request_id: u64 = 0,
    
    // For stdio mode - child process handle
    child: ?std.process.Child = null,
    
    // For HTTP mode
    http_client: ?std.http.Client = null,
    
    pub fn init(allocator: std.mem.Allocator) McpTransport {
        return .{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *McpTransport) void {
        if (self.child) |*child| {
            // Close stdin to signal EOF
            if (child.stdin) |stdin| {
                stdin.close();
            }
            _ = child.wait() catch {};
        }
        if (self.http_client) |*client| {
            client.deinit();
        }
    }
    
    /// Connect to an MCP server via stdio (spawn subprocess)
    pub fn connectStdio(self: *McpTransport, command: []const u8, args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);
        
        try argv.append(self.allocator, command);
        for (args) |arg| {
            try argv.append(self.allocator, arg);
        }
        
        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        self.child = child;
        
        // Send initialize request
        try self.initialize();
    }
    
    /// Connect to an MCP server via HTTP
    pub fn connectHttp(self: *McpTransport) !void {
        self.http_client = std.http.Client{ .allocator = self.allocator };
    }
    
    /// Send JSON-RPC initialize request
    fn initialize(self: *McpTransport) !void {
        var params = std.json.ObjectMap.init(self.allocator);
        defer params.deinit();
        
        // Build capabilities object
        var capabilities = std.json.ObjectMap.init(self.allocator);
        defer capabilities.deinit();
        
        // Build client info
        var client_info = std.json.ObjectMap.init(self.allocator);
        defer client_info.deinit();
        try client_info.put("name", std.json.Value{ .string = "zig-utcp" });
        try client_info.put("version", std.json.Value{ .string = "0.1.0" });
        
        try params.put("protocolVersion", std.json.Value{ .string = "2024-11-05" });
        try params.put("capabilities", std.json.Value{ .object = capabilities });
        try params.put("clientInfo", std.json.Value{ .object = client_info });
        
        const response = try self.sendRequest("initialize", std.json.Value{ .object = params });
        _ = response; // TODO: validate server capabilities
        
        // Send initialized notification
        try self.sendNotification("notifications/initialized", null);
    }
    
    /// Call a tool via MCP
    pub fn call(
        self: *McpTransport,
        tool: Tool,
        request: ToolCallRequest,
    ) !ToolCallResponse {
        const mcp_template = switch (tool.call_template) {
            .mcp => |t| t,
            else => return error.UnsupportedTransport,
        };
        
        // Build tool call params
        var params = std.json.ObjectMap.init(self.allocator);
        defer params.deinit();
        
        try params.put("name", std.json.Value{ .string = tool.name });
        try params.put("arguments", request.inputs);
        
        // Send tools/call request based on mode
        const result = switch (mcp_template.mode) {
            .stdio => try self.sendRequest("tools/call", std.json.Value{ .object = params }),
            .http => try self.sendHttpRequest(mcp_template.endpoint orelse return error.InvalidConfiguration, "tools/call", std.json.Value{ .object = params }),
            .sse => return error.NotImplemented, // SSE requires async streaming
        };
        
        // Parse MCP tool result
        if (result) |r| {
            switch (r) {
                .object => |obj| {
                    // MCP returns { content: [...], isError?: bool }
                    if (obj.get("isError")) |is_err| {
                        if (is_err == .bool and is_err.bool) {
                            const content = obj.get("content") orelse return ToolCallResponse{
                                .output = .null,
                                .error_msg = "Tool execution failed",
                            };
                            return ToolCallResponse{
                                .output = content,
                                .error_msg = "Tool returned error",
                            };
                        }
                    }
                    if (obj.get("content")) |content| {
                        return ToolCallResponse{ .output = content };
                    }
                    return ToolCallResponse{ .output = r };
                },
                else => return ToolCallResponse{ .output = r },
            }
        }
        
        return ToolCallResponse{ .output = .null };
    }
    
    /// List available tools from the MCP server
    pub fn listTools(self: *McpTransport) ![]Tool {
        const result = try self.sendRequest("tools/list", null);
        
        if (result) |r| {
            switch (r) {
                .object => |obj| {
                    if (obj.get("tools")) |tools_val| {
                        switch (tools_val) {
                            .array => |arr| {
                                var tools: std.ArrayList(Tool) = .empty;
                                for (arr.items) |tool_val| {
                                    if (tool_val == .object) {
                                        const tool_obj = tool_val.object;
                                        const name = if (tool_obj.get("name")) |n| switch (n) {
                                            .string => |s| s,
                                            else => continue,
                                        } else continue;
                                        
                                        const desc = if (tool_obj.get("description")) |d| switch (d) {
                                            .string => |s| s,
                                            else => "",
                                        } else "";
                                        
                                        try tools.append(self.allocator, Tool{
                                            .id = name,
                                            .name = name,
                                            .description = desc,
                                            .input_schema = tool_obj.get("inputSchema"),
                                            .call_template = .{ .mcp = .{ .method = "tools/call" } },
                                        });
                                    }
                                }
                                return tools.toOwnedSlice(self.allocator);
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        
        return &.{};
    }
    
    /// Send a JSON-RPC request and wait for response
    fn sendRequest(self: *McpTransport, method: []const u8, params: ?std.json.Value) !?std.json.Value {
        const child = self.child orelse return error.NotConnected;
        
        self.request_id += 1;
        const id = self.request_id;
        
        // Build request
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        var request_obj = std.json.ObjectMap.init(aa);
        try request_obj.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try request_obj.put("method", std.json.Value{ .string = method });
        if (params) |p| {
            try request_obj.put("params", p);
        }
        try request_obj.put("id", std.json.Value{ .integer = @intCast(id) });
        
        // Serialize and send
        const request_value = std.json.Value{ .object = request_obj };
        const json_str = try std.json.Stringify.valueAlloc(aa, request_value, .{});
        
        if (child.stdin) |stdin| {
            try stdin.writeAll(json_str);
            try stdin.writeAll("\n");
        }
        
        // Read response line-by-line
        if (child.stdout) |stdout| {
            // Use readToEndAlloc with a reasonable limit for a single JSON-RPC response
            const response_data = stdout.readToEndAlloc(aa, 1024 * 1024) catch |err| {
                std.debug.print("Read error: {}\n", .{err});
                return null;
            };
            
            // Find the first complete JSON line (newline-delimited)
            const newline_pos = std.mem.indexOf(u8, response_data, "\n");
            const response_line = if (newline_pos) |pos| response_data[0..pos] else response_data;
            
            if (response_line.len == 0) return null;
            
            const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_line, .{});
                
                switch (parsed.value) {
                    .object => |obj| {
                        // Check for error
                        if (obj.get("error")) |err_val| {
                            switch (err_val) {
                                .object => |err_obj| {
                                    const msg = if (err_obj.get("message")) |m| switch (m) {
                                        .string => |s| s,
                                        else => "Unknown error",
                                    } else "Unknown error";
                                    std.debug.print("JSON-RPC error: {s}\n", .{msg});
                                    return error.JsonRpcError;
                                },
                                else => {},
                            }
                        }
                        return obj.get("result");
                    },
                    else => return null,
                }
        }
        
        return null;
    }
    
    /// Send a JSON-RPC notification (no response expected)
    fn sendNotification(self: *McpTransport, method: []const u8, params: ?std.json.Value) !void {
        const child = self.child orelse return error.NotConnected;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        var request_obj = std.json.ObjectMap.init(aa);
        try request_obj.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try request_obj.put("method", std.json.Value{ .string = method });
        if (params) |p| {
            try request_obj.put("params", p);
        }
        
        const request_value = std.json.Value{ .object = request_obj };
        const json_str = try std.json.Stringify.valueAlloc(aa, request_value, .{});
        
        if (child.stdin) |stdin| {
            try stdin.writeAll(json_str);
            try stdin.writeAll("\n");
        }
    }
    
    /// Send request over HTTP (for HTTP mode)
    fn sendHttpRequest(self: *McpTransport, endpoint: []const u8, method: []const u8, params: ?std.json.Value) !?std.json.Value {
        const client = self.http_client orelse return error.NotConnected;
        _ = client;
        
        self.request_id += 1;
        const id = self.request_id;
        
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        
        // Build JSON-RPC request body
        var request_obj = std.json.ObjectMap.init(aa);
        try request_obj.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try request_obj.put("method", std.json.Value{ .string = method });
        if (params) |p| {
            try request_obj.put("params", p);
        }
        try request_obj.put("id", std.json.Value{ .integer = @intCast(id) });
        
        const request_value = std.json.Value{ .object = request_obj };
        const body = try std.json.Stringify.valueAlloc(aa, request_value, .{});
        
        // Make HTTP request
        const uri = try std.Uri.parse(endpoint);
        var req = try self.http_client.?.request(.POST, uri, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        defer req.deinit();
        
        try req.sendBodyComplete(@constCast(body));
        
        var buf: [8192]u8 = undefined;
        var head = try req.receiveHead(&buf);
        
        var response_buf: std.ArrayList(u8) = .empty;
        var transfer_buf: [4096]u8 = undefined;
        var reader = head.reader(&transfer_buf);
        const max_size = std.io.Limit.limited(10 * 1024 * 1024);
        try reader.appendRemaining(aa, &response_buf, max_size);
        
        // Parse response
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_buf.items, .{});
        
        switch (parsed.value) {
            .object => |obj| {
                if (obj.get("error")) |_| {
                    return error.JsonRpcError;
                }
                return obj.get("result");
            },
            else => return null,
        }
    }
};

// Standard JSON-RPC error codes
pub const JsonRpcErrorCode = struct {
    pub const ParseError = -32700;
    pub const InvalidRequest = -32600;
    pub const MethodNotFound = -32601;
    pub const InvalidParams = -32602;
    pub const InternalError = -32603;
};

test "McpTransport init/deinit" {
    const allocator = std.testing.allocator;
    var transport = McpTransport.init(allocator);
    defer transport.deinit();
    
    try std.testing.expectEqual(@as(u64, 0), transport.request_id);
}
