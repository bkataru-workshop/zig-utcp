# zig-utcp Architecture

## Overview
zig-utcp is a Zig implementation of the Universal Tool Calling Protocol (UTCP),
a vendor-agnostic standard for LLM-tool integration.

## Design Principles

1. **Zero Dependencies** - Pure Zig standard library only
2. **Explicit Error Handling** - Zig error unions (no exceptions)
3. **Comptime Polymorphism** - Generic transports via comptime
4. **Memory Efficient** - Arena allocators for request/response lifetimes
5. **Plugin Architecture** - Transport plugins, auth plugins

## Module Structure

```
zig-utcp/
├── src/
│   ├── core/
│   │   ├── tool.zig           # Tool, ToolCallRequest, ToolCallResponse
│   │   ├── provider.zig       # Provider, Auth types
│   │   ├── errors.zig         # Error types
│   │   ├── substitution.zig   # Variable substitution engine
│   │   ├── streaming.zig      # Streaming response support
│   │   └── postprocessor.zig  # Response post-processors
│   ├── repository/
│   │   └── memory.zig         # In-memory tool repository with search
│   ├── transports/
│   │   ├── http.zig           # HTTP transport + OAuth2
│   │   ├── cli.zig            # CLI subprocess transport
│   │   ├── mcp.zig            # MCP JSON-RPC transport
│   │   ├── sse.zig            # Server-Sent Events
│   │   ├── websocket.zig      # WebSocket transport
│   │   ├── text.zig           # Text output transport
│   │   ├── udp.zig            # UDP datagram transport
│   │   ├── graphql.zig        # GraphQL over HTTP
│   │   └── grpc.zig           # gRPC-Web transport
│   ├── loaders/
│   │   ├── json.zig           # JSON tool/provider loader
│   │   └── openapi.zig        # OpenAPI to UTCP converter
│   └── utcp.zig               # Public API (library entry point)
├── examples/
│   ├── http_client.zig
│   ├── cli_client.zig
│   └── mcp_client.zig
├── tests/
├── build.zig
├── build.zig.zon
└── README.md
```

## Core Types

### Tool
```zig
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
```

### CallTemplate
```zig
pub const CallTemplate = union(enum) {
    http: HttpCallTemplate,
    cli: CliCallTemplate,
    mcp: McpCallTemplate,
    sse: SseCallTemplate,
    websocket: WebSocketCallTemplate,
    text: TextCallTemplate,
    udp: UdpCallTemplate,
    grpc: GrpcCallTemplate,
    graphql: GraphqlCallTemplate,
};
```

### ToolCallRequest / ToolCallResponse
```zig
pub const ToolCallRequest = struct {
    tool_id: []const u8,
    inputs: std.json.Value,
    timeout_ms: ?u32 = null,
};

pub const ToolCallResponse = struct {
    output: std.json.Value,
    error_msg: ?[]const u8 = null,
    exit_code: ?i32 = null,
};
```

## Transport Interface

All transports follow a consistent interface:

```zig
pub fn init(allocator: std.mem.Allocator) Self
pub fn deinit(self: *Self) void
pub fn loadEnv(self: *Self) !void
pub fn call(self: *Self, tool: Tool, request: ToolCallRequest) !ToolCallResponse
```

## Memory Management

- **Arena Allocator** for request/response lifetimes (reset after each call)
- **GPA** for long-lived repository data
- **StringHashMap** for headers, query params, input substitution

## Error Handling

```zig
pub const UtcpError = error{
    ToolNotFound,
    TransportError,
    SerializationError,
    ValidationError,
    AuthenticationError,
    Timeout,
};
```

## Testing

Run all tests:
```bash
zig build test
```

Build examples:
```bash
zig build examples
```