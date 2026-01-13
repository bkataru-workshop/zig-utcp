# zig-utcp Architecture Design

## Overview
zig-utcp is a Zig implementation of the Universal Tool Calling Protocol (UTCP),
a vendor-agnostic standard for LLM-tool integration supporting HTTP, CLI, MCP, SSE,
WebSocket, GraphQL, gRPC, TCP, UDP, and more.

## Core Design Principles
1. **Zero Allocations for Hot Paths** - Pool allocators, arena allocators for request/response lifetimes
2. **Explicit Error Handling** - Zig error unions (no exceptions)
3. **Comptime Polymorphism** - Generic transports/serializers via comptime
4. **Minimal Dependencies** - Use std.json, std.http, std.net; avoid third-party libs where possible
5. **Plugin Architecture** - Transport plugins, auth plugins, serializer plugins

## Module Structure
```
zig-utcp/
├── src/
│   ├── core/
│   │   ├── tool.zig
│   │   ├── provider.zig
│   │   ├── errors.zig
│   │   └── substitution.zig
│   ├── repository/
│   │   └── memory.zig
│   ├── transports/
│   │   └── http.zig
│   └── utcp.zig
├── examples/
│   └── http_client.zig
├── tests/                 # Reserved for integration tests
├── build.zig
├── build.zig.zon
└── README.md
```

Other transports (CLI/MCP/etc.) are planned; see `docs/ROADMAP.md`.

## Core Types (Zig)
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
### CallTemplate (union for transport-specific params)
```zig
pub const CallTemplate = union(enum) {
    http: HttpCallTemplate,
    cli: CliCallTemplate,
    mcp: McpCallTemplate,
    // ...
};

pub const HttpCallTemplate = struct {
    method: []const u8,
    url: []const u8,
    headers: ?std.StringHashMap([]const u8) = null,
    body_template: ?[]const u8 = null,
    query_params: ?std.StringHashMap([]const u8) = null,
};
```
### Transport Interface (comptime polymorphism)
```zig
pub fn Transport(comptime Config: type) type {
    return struct {
        const Self = @This();
        config: Config,
        allocator: std.mem.Allocator,

        pub fn call(
            self: *Self,
            tool: Tool,
            request: ToolCallRequest,
        ) !ToolCallResponse {
            // transport-specific implementation
        }

        pub fn discover(self: *Self) ![]Tool {
            // optional: auto-discover tools
        }
    };
}
```

## Key Implementation Details
### Memory Management
- **Arena Allocator** for request/response lifetimes (reset after each call)
- **GPA** or custom allocator for long-lived repository data
- **StringHashMap** for headers, query params, input substitution

### Error Handling
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

### JSON Handling
- Use `std.json.parseFromSlice` for deserialization
- Use `std.json.stringifyAlloc` for serialization
- Custom `@"type"` field mapping for UTCP schemas

### HTTP Transport
- Use `std.http.Client` (Zig 0.15.2+)
- Support TLS via std (no external deps)
- Connection pooling (reuse std.http.Client instance)
- Timeout via `std.time` + async cancel (if needed)

### CLI Transport
- Use `std.process.Child` to spawn processes
- Capture stdout/stderr
- Parse JSON output from tools

### MCP Transport
- stdio mode: JSON-RPC 2.0 over stdin/stdout
- SSE mode: JSON-RPC 2.0 over HTTP with SSE for server->client events

### Variable Substitution
- Template strings: `{input.field}`, `{env.VAR}`
- Environment variable loader: `std.process.getEnvMap`
- Input parameter injection into URL/body/headers

## Build Configuration (build.zig)
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const utcp_mod = b.addModule("utcp", .{
        .root_source_file = b.path("src/utcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Examples
    const http_client = b.addExecutable(.{
        .name = "http_client",
        .root_source_file = b.path("examples/http_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_client.root_module.addImport("utcp", utcp_mod);
    b.installArtifact(http_client);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/utcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
```

## Testing Strategy
- Unit tests: embedded in each module (test blocks)
- Integration tests: examples/ that exercise full client flow
- Mock transports for testing without network
- Validate against utcp-specification examples

## Minimal Viable Product (MVP)
### Phase 1: Core + HTTP
1. Core types (Tool, ToolCallRequest/Response)
2. InMemoryToolRepository + TagSearchStrategy
3. HTTP transport (std.http.Client)
4. JSON serialization (std.json)
5. Variable substitution (basic string replace)
6. Example: HTTP client calling a REST API tool

### Phase 2: CLI + MCP
1. CLI transport (std.process.Child)
2. MCP stdio transport (JSON-RPC 2.0)
3. Auth: API key, Basic auth
4. OpenAPI->UTCP converter (basic)

### Phase 3: Advanced
1. SSE, WebSocket, gRPC transports
2. OAuth2 auth flow
3. Schema validation (JSON Schema subset)
4. Plugin system for custom transports

## References
- UTCP Spec: utcp-repomix/utcp-specification.txt
- Go impl: utcp-repomix/go-utcp.txt
- Rust impl: utcp-repomix/rs-utcp.txt
- Zig stdlib: zig-kb/