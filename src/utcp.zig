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
pub const Provider = @import("core/provider.zig").Provider;
pub const Auth = @import("core/provider.zig").Auth;
pub const UtcpError = @import("core/errors.zig").UtcpError;

// Repository
pub const InMemoryToolRepository = @import("repository/memory.zig").InMemoryToolRepository;

// Transports
pub const HttpTransport = @import("transports/http.zig").HttpTransport;
pub const CliTransport = @import("transports/cli.zig").CliTransport;

// Utilities
pub const substitute = @import("core/substitution.zig").substitute;

test {
    std.testing.refAllDecls(@This());
}
