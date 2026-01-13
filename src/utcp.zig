//! zig-utcp: Universal Tool Calling Protocol implementation for Zig
//! 
//! This library provides a vendor-agnostic standard for LLM-tool integration
//! supporting HTTP, CLI, MCP, SSE, WebSocket, and more.

const std = @import("std");

// Core types
pub const Tool = @import("core/tool.zig").Tool;
pub const ToolCallRequest = @import("core/tool.zig").ToolCallRequest;
pub const ToolCallResponse = @import("core/tool.zig").ToolCallResponse;
pub const CallTemplate = @import("core/tool.zig").CallTemplate;
pub const HttpCallTemplate = @import("core/tool.zig").HttpCallTemplate;
pub const CliCallTemplate = @import("core/tool.zig").CliCallTemplate;
pub const McpCallTemplate = @import("core/tool.zig").McpCallTemplate;
pub const SseCallTemplate = @import("core/tool.zig").SseCallTemplate;
pub const WebSocketCallTemplate = @import("core/tool.zig").WebSocketCallTemplate;
pub const TextCallTemplate = @import("core/tool.zig").TextCallTemplate;
pub const Provider = @import("core/provider.zig").Provider;
pub const Auth = @import("core/provider.zig").Auth;
pub const UtcpError = @import("core/errors.zig").UtcpError;

// Repository
pub const InMemoryToolRepository = @import("repository/memory.zig").InMemoryToolRepository;

// Transports
pub const HttpTransport = @import("transports/http.zig").HttpTransport;
pub const OAuth2TokenResponse = @import("transports/http.zig").HttpTransport.OAuth2TokenResponse;
pub const CliTransport = @import("transports/cli.zig").CliTransport;
pub const McpTransport = @import("transports/mcp.zig").McpTransport;
pub const SseTransport = @import("transports/sse.zig").SseTransport;
pub const SseEvent = @import("transports/sse.zig").SseEvent;
pub const WebSocketTransport = @import("transports/websocket.zig").WebSocketTransport;
pub const TextTransport = @import("transports/text.zig").TextTransport;
pub const TextFormat = @import("core/tool.zig").TextFormat;
pub const JsonRpcRequest = @import("transports/mcp.zig").JsonRpcRequest;
pub const JsonRpcResponse = @import("transports/mcp.zig").JsonRpcResponse;
pub const JsonRpcError = @import("transports/mcp.zig").JsonRpcError;

// Auth types
pub const ApiKeyAuth = @import("core/provider.zig").ApiKeyAuth;
pub const BasicAuth = @import("core/provider.zig").BasicAuth;
pub const BearerAuth = @import("core/provider.zig").BearerAuth;
pub const OAuth2Auth = @import("core/provider.zig").OAuth2Auth;

// Loaders
pub const JsonLoader = @import("loaders/json.zig").JsonLoader;
pub const LoadResult = @import("loaders/json.zig").LoadResult;

// Utilities
pub const substitute = @import("core/substitution.zig").substitute;

test {
    std.testing.refAllDecls(@This());
}
