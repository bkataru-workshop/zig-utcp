//! Core UTCP tool types

const std = @import("std");

/// Tool represents a callable function/API endpoint
pub const Tool = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema: ?std.json.Value = null,
    output_schema: ?std.json.Value = null,
    tags: []const []const u8 = &.{},
    call_template: CallTemplate,
    provider_id: ?[]const u8 = null,
};

/// Request to call a tool
pub const ToolCallRequest = struct {
    tool_id: []const u8,
    inputs: std.json.Value,
    timeout_ms: ?u32 = null,
};

/// Response from calling a tool
pub const ToolCallResponse = struct {
    output: std.json.Value,
    error_msg: ?[]const u8 = null,
    exit_code: ?i32 = null,
    metadata: ?std.json.Value = null,
};

/// Transport-specific call configuration (tagged union)
pub const CallTemplate = union(enum) {
    http: HttpCallTemplate,
    cli: CliCallTemplate,
    mcp: McpCallTemplate,
    sse: SseCallTemplate,
    websocket: WebSocketCallTemplate,
    text: TextCallTemplate,
};

// --- HTTP Transport ---

pub const HttpCallTemplate = struct {
    method: []const u8, // GET, POST, PUT, DELETE, etc.
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body_template: ?[]const u8 = null,
    query_params: ?std.StringHashMap([]const u8) = null,
    timeout_ms: u32 = 30000,
};

// --- CLI Transport ---

pub const CliCallTemplate = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.StringHashMap([]const u8) = null,
    cwd: ?[]const u8 = null,
    timeout_ms: u32 = 60000,
    stdin_template: ?[]const u8 = null,
};

// --- MCP Transport (Model Context Protocol) ---

pub const McpCallTemplate = struct {
    method: []const u8, // JSON-RPC method name
    endpoint: ?[]const u8 = null, // For HTTP-based MCP
    mode: McpMode = .stdio,
};

pub const McpMode = enum {
    stdio,   // JSON-RPC over stdin/stdout
    sse,     // JSON-RPC over HTTP + SSE
    http,    // JSON-RPC over plain HTTP
};

// --- SSE Transport ---

pub const SseCallTemplate = struct {
    url: []const u8,
    method: []const u8 = "GET",
    headers: ?std.StringHashMap([]const u8) = null,
    event_type: ?[]const u8 = null,
};

// --- WebSocket Transport ---

pub const WebSocketCallTemplate = struct {
    url: []const u8,
    subprotocol: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
};

// --- Text Transport (raw text in/out) ---

pub const TextCallTemplate = struct {
    endpoint: []const u8,
    format: TextFormat = .plain,
};

pub const TextFormat = enum {
    plain,
    json,
    xml,
};
