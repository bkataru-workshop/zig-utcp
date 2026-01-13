# zig-utcp

**Universal Tool Calling Protocol (UTCP)** implementation for Zig 0.15.2+

A vendor-agnostic standard for LLM-tool integration supporting HTTP, CLI, MCP, SSE, WebSocket, and more.

## Features

- **Zero dependencies** - Pure Zig standard library only
- **Explicit error handling** - Zig error unions (no exceptions)
- **Comptime polymorphism** - Generic transports via `comptime`
- **9 Transport types** - HTTP, CLI, MCP, SSE, WebSocket, Text, UDP, GraphQL, gRPC
- **4 Auth methods** - API Key, Basic, Bearer, OAuth2 (with token refresh)
- **2 Tool loaders** - JSON, OpenAPI
- **Streaming** - Incremental response processing
- **Post-processors** - Response transformation and validation
- **Memory efficient** - Arena allocators for request/response lifetimes

### New in v0.2.0

- **CLI Tool** - `utcp` command for testing tool definitions
- **Middleware** - Request/response interceptors for logging, metrics, auth injection
- **Circuit Breaker** - Prevent cascading failures with automatic recovery
- **Rate Limiting** - Token bucket, sliding window, and fixed window algorithms
- **Response Caching** - TTL-based caching with configurable max entries
- **Batch Requests** - Execute multiple tool calls in parallel
- **Debug Mode** - Verbose logging with request/response timing
- **Schema Validation** - Validate tool inputs against JSON Schema
- **Mock Transport** - Unit testing without network calls
- **Retry Policies** - Exponential backoff with jitter for transient failures
- **Benchmarks** - Performance regression testing with `zig build bench`
- **API Docs** - Generate documentation with `zig build docs`

## Requirements

- Zig 0.15.2 or later

## Installation

### Option 1: Using `zig fetch` (Recommended)

```bash
zig fetch --save git+https://github.com/bkataru/zig-utcp.git
```

To fetch a specific version:

```bash
zig fetch --save git+https://github.com/bkataru/zig-utcp.git#v0.1.0
```

### Option 2: Manual Configuration

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .utcp = .{
        .url = "git+https://github.com/bkataru/zig-utcp.git",
        .hash = "...", // Run `zig build` to get the correct hash
    },
},
```

### Option 3: Local Path Dependency

```zig
.dependencies = .{
    .utcp = .{
        .path = "../zig-utcp",
    },
},
```

### Configuring `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch the utcp dependency
    const utcp_dep = b.dependency("utcp", .{
        .target = target,
        .optimize = optimize,
    });

    // Get the module from the dependency
    const utcp_mod = utcp_dep.module("utcp");

    // Create your executable
    const exe = b.addExecutable(.{
        .name = "my_tool_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add the utcp import to your executable
    exe.root_module.addImport("utcp", utcp_mod);

    b.installArtifact(exe);
}
```

### Building from Source

```bash
# Clone the repository
git clone https://github.com/bkataru/zig-utcp.git
cd zig-utcp

# Build the library
zig build

# Run tests
zig build test

# Build examples
zig build examples

# Build release version
zig build -Doptimize=ReleaseFast
```

## Quick Start

```zig
const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create HTTP transport
    var transport = utcp.HttpTransport.init(allocator);
    defer transport.deinit();
    try transport.loadEnv();

    // Define a tool
    const weather_tool = utcp.Tool{
        .id = "weather_api",
        .name = "Get Weather",
        .description = "Fetch current weather for a city",
        .call_template = .{
            .http = .{
                .method = "GET",
                .url = "https://wttr.in/{city}?format=j1",
                .timeout_ms = 30000,
            },
        },
    };

    // Prepare request
    var inputs_obj = std.json.ObjectMap.init(allocator);
    defer inputs_obj.deinit();
    try inputs_obj.put("city", .{ .string = "London" });

    const request = utcp.ToolCallRequest{
        .tool_id = "weather_api",
        .inputs = .{ .object = inputs_obj },
    };

    // Call the tool
    const response = try transport.call(weather_tool, request, null);
    std.debug.print("Response: {any}\n", .{response.output});
}
```

## Examples

Run the included examples:

```bash
# HTTP client (calls wttr.in weather API)
zig build run-http

# CLI client
zig build run-cli

# MCP client
zig build run-mcp

# Streaming example
zig build run-streaming

# Post-processor example
zig build run-postprocessor

# OAuth2 example
zig build run-oauth2

# UTCP CLI tool
zig build run-utcp -- help
zig build run-utcp -- info
zig build run-utcp -- load tools.json
```

See `examples/` for complete working examples.

## API Reference

### Core Types

| Type | Description |
|------|-------------|
| `Tool` | Tool definition with id, name, description, call_template |
| `ToolCallRequest` | Request with tool_id and inputs |
| `ToolCallResponse` | Response with output and optional error |
| `Provider` | Provider with auth configuration |
| `CallTemplate` | Transport-specific call configuration |

### Transports

| Transport | Description |
|-----------|-------------|
| `HttpTransport` | HTTP/HTTPS with OAuth2 support |
| `CliTransport` | CLI subprocess execution |
| `McpTransport` | MCP JSON-RPC (stdio + HTTP modes) |
| `SseTransport` | Server-Sent Events |
| `WebSocketTransport` | WebSocket connections |
| `TextTransport` | Text output (plain/json/xml) |
| `UdpTransport` | UDP datagrams |
| `GraphqlTransport` | GraphQL over HTTP |
| `GrpcTransport` | gRPC-Web compatible |

### Loaders

| Loader | Description |
|--------|-------------|
| `loadToolsFromJson` | Load tools from JSON |
| `convertFromString` | Convert OpenAPI spec to UTCP tools |

### Streaming

```zig
const stream = utcp.fromBytes(allocator, data);
defer stream.deinit();

while (stream.next()) |chunk| {
    // Process chunk
    if (chunk.is_final) break;
}
```

### Post-processors

```zig
var chain = utcp.PostProcessorChain.init(allocator);
defer chain.deinit();

try chain.addFn("trim", utcp.trimProcessor);
try chain.addFn("log", utcp.logProcessor);
try chain.process(&response);
```

### Middleware

```zig
var chain = utcp.MiddlewareChain.init(allocator);
defer chain.deinit();

// Add logging middleware
try chain.add(.{
    .name = "logger",
    .on_request = logRequest,
    .on_response = logResponse,
});

// Process request through middleware
try chain.processRequest(&context);
const response = try transport.call(tool, request, provider);
try chain.processResponse(&context, &response);
```

### Circuit Breaker

```zig
var breaker = utcp.CircuitBreaker.init(.{
    .failure_threshold = 5,
    .reset_timeout_ms = 30000,
});

if (breaker.canExecute()) {
    const result = transport.call(tool, request, provider);
    if (result) |resp| {
        breaker.recordSuccess();
    } else |_| {
        breaker.recordFailure();
    }
}
```

### Rate Limiting

```zig
var limiter = utcp.TokenBucket.init(.{
    .burst_size = 100,
    .refill_rate = 10.0, // tokens per second
});

if (limiter.tryAcquire()) {
    // Proceed with request
} else {
    // Rate limited
}
```

### Response Caching

```zig
var cache_inst = utcp.ResponseCache.init(allocator, .{
    .max_entries = 1000,
    .default_ttl_ms = 300000, // 5 minutes
});
defer cache_inst.deinit();

// Check cache
if (cache_inst.get(cache_key)) |cached| {
    return cached;
}

// Make request and cache
const response = try transport.call(tool, request, provider);
try cache_inst.put(cache_key, response);
```

### Mock Transport (Testing)

```zig
var mock = utcp.MockTransportBuilder.init(allocator)
    .expectCall("weather_api", .{ .output = .{ .string = "{\"temp\":20}" } })
    .expectCall("translate", .{ .output = .{ .string = "Bonjour" } })
    .build();
defer mock.deinit();

const response = try mock.call(tool, request, null);
try mock.verify(); // Fails if expectations not met
```

## Architecture

```
src/
├── core/              # Core types
│   ├── tool.zig       # Tool, ToolCallRequest, ToolCallResponse
│   ├── provider.zig   # Provider, Auth types
│   ├── errors.zig     # Error types
│   ├── substitution.zig  # Variable substitution
│   ├── streaming.zig  # Streaming responses
│   ├── postprocessor.zig # Post-processors
│   ├── middleware.zig # Request/response interceptors
│   ├── circuit_breaker.zig # Circuit breaker pattern
│   ├── rate_limit.zig # Rate limiting algorithms
│   ├── cache.zig      # Response caching
│   ├── batch.zig      # Batch request execution
│   ├── validation.zig # JSON Schema validation
│   ├── debug.zig      # Debug logging
│   ├── retry.zig      # Retry policies
│   └── mock.zig       # Mock transport for testing
├── repository/
│   └── memory.zig     # InMemoryToolRepository with search
├── transports/        # Transport implementations
├── loaders/           # Tool loaders (JSON, OpenAPI)
├── cli.zig            # CLI tool
└── utcp.zig           # Public API
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for detailed design.

## Project Status

**100% Feature Parity with Go/Rust/TypeScript implementations**

| Component | Status |
|-----------|--------|
| HTTP Transport | ✅ Complete |
| CLI Transport | ✅ Complete |
| MCP Transport | ✅ Complete |
| SSE Transport | ✅ Complete |
| WebSocket Transport | ✅ Complete |
| Text Transport | ✅ Complete |
| UDP Transport | ✅ Complete |
| GraphQL Transport | ✅ Complete |
| gRPC-Web Transport | ✅ Complete |
| All Auth Methods | ✅ Complete |
| JSON/OpenAPI Loaders | ✅ Complete |
| Streaming | ✅ Complete |
| Post-processors | ✅ Complete |
| CI/CD | ✅ Complete |

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Related Projects

- [UTCP Specification](https://github.com/universal-tool-calling-protocol/utcp-specification)
- [UTCP Go](https://github.com/universal-tool-calling-protocol/go-utcp)
- [UTCP Rust](https://github.com/universal-tool-calling-protocol/rs-utcp)
- [UTCP TypeScript](https://github.com/universal-tool-calling-protocol/typescript-utcp)
