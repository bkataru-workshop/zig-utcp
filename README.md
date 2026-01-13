# zig-utcp

**Universal Tool Calling Protocol (UTCP)** implementation for Zig 0.15.2+

A vendor-agnostic standard for LLM-tool integration supporting HTTP, CLI, MCP, SSE, WebSocket, and more.

## Features

- **Zero-dependency core** - Uses Zig stdlib (`std.json`, `std.http`, `std.net`)
- **Explicit error handling** - Zig error unions (no exceptions)
- **Comptime polymorphism** - Generic transports via `comptime`
- **9 Transport types** - HTTP, CLI, MCP, SSE, WebSocket, Text, UDP, GraphQL, gRPC
- **4 Auth methods** - API Key, Basic, Bearer, OAuth2 (with token refresh)
- **2 Tool loaders** - JSON, OpenAPI
- **Streaming** - Incremental response processing
- **Post-processors** - Response transformation and validation
- **Memory efficient** - Arena allocators for request/response lifetimes

## Project Status

**100% Feature Parity with Go/Rust/TypeScript implementations**

| Component | Status |
|-----------|--------|
| HTTP Transport | ✅ Complete |
| CLI Transport | ✅ Complete |
| MCP Transport (stdio + HTTP) | ✅ Complete |
| SSE Transport | ✅ Complete |
| WebSocket Transport | ✅ Complete |
| Text Transport | ✅ Complete |
| UDP Transport | ✅ Complete |
| GraphQL Transport | ✅ Complete |
| gRPC-Web Transport | ✅ Complete |
| API Key / Basic / Bearer Auth | ✅ Complete |
| OAuth2 (client credentials + refresh) | ✅ Complete |
| JSON Tool Loader | ✅ Complete |
| OpenAPI Converter | ✅ Complete |
| Repository (search by tag/provider/query) | ✅ Complete |
| Streaming Responses | ✅ Complete |
| Post-processors | ✅ Complete |
| CI/CD (GitHub Actions) | ✅ Complete |

## Quick Start

### Prerequisites

- Zig 0.15.2+ (install via [scoop](https://scoop.sh/): `scoop install zig`)

### Build

```bash
zig build          # Build library
zig build test     # Run tests
zig build examples # Build example programs
```

### Run Examples

```bash
# HTTP client example (calls wttr.in weather API)
zig build run-http

# CLI client example
zig build run-cli

# MCP client example
zig build run-mcp
```

### Example Usage

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
    try transport.loadEnv(); // Load env vars for {env.VAR} substitution

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
        .input_schema = .null,
        .output_schema = .null,
    };

    // Prepare request with inputs
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

See `examples/` for complete working examples.

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for detailed design.

### Module Structure

```
src/
├── core/              # Core types
│   ├── tool.zig       # Tool, ToolCallRequest, ToolCallResponse
│   ├── provider.zig   # Provider, Auth types
│   ├── errors.zig     # Error types
│   └── substitution.zig  # Variable substitution engine
├── repository/        # Tool storage
│   └── memory.zig     # InMemoryToolRepository (with search)
├── transports/        # Transport implementations
│   ├── http.zig       # HTTP transport + OAuth2
│   ├── cli.zig        # CLI transport
│   ├── mcp.zig        # MCP transport (stdio + HTTP)
│   ├── sse.zig        # SSE transport
│   ├── websocket.zig  # WebSocket transport
│   └── text.zig       # Text transport (plain/json/xml)
├── loaders/           # Tool loaders
│   ├── json.zig       # JSON tool loader
│   └── openapi.zig    # OpenAPI converter
└── utcp.zig           # Public API
```

## Development

### Testing

```bash
# Run all tests
zig build test
```

### Code Style

- Follow Zig standard library style
- Use arena allocators for request/response lifetimes
- Prefer explicit error handling over panics
- Document public APIs with `///` doc comments

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for development timeline.

**Completed:**
- Phase 1: Foundation (core types, repository, build system)
- Phase 2: HTTP Transport + Auth
- Phase 3: CLI Transport
- Phase 4: MCP Transport
- Phase 5: SSE + JSON Loader + Enhanced Repository
- Phase 6: WebSocket + Text Transports
- Phase 7: OAuth2 + OpenAPI Converter

**Remaining:**
- Phase 8: Polish + v0.1.0 release

## References

- [UTCP Specification](https://github.com/universal-tool-calling-protocol/utcp-specification)
- [UTCP Go Implementation](https://github.com/universal-tool-calling-protocol/go-utcp)
- [UTCP Rust Implementation](https://github.com/universal-tool-calling-protocol/rs-utcp)
- [Zig 0.15.2 Documentation](https://ziglang.org/documentation/0.15.2/)

## License

MIT (to be confirmed)

## Contributing

This project is in early development. Contributions welcome after v0.1.0 release.
