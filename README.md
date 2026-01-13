# zig-utcp

**Universal Tool Calling Protocol (UTCP)** implementation for Zig 0.15.2+

A vendor-agnostic standard for LLM-tool integration supporting HTTP, CLI, MCP, SSE, WebSocket, and more.

## Features

- **Zero-dependency core** - Uses Zig stdlib (`std.json`, `std.http`, `std.net`)
- **Explicit error handling** - Zig error unions (no exceptions)
- **Comptime polymorphism** - Generic transports via `comptime`
- **Multiple transports** - HTTP, CLI, MCP (stdio/SSE), SSE, WebSocket, TCP, UDP
- **Plugin architecture** - Extensible transport and auth plugins
- **Memory efficient** - Arena allocators for request/response lifetimes

## Project Status

**Phase 1: Foundation** ✅ COMPLETE
- ✅ Core types (`Tool`, `ToolCallRequest`, `ToolCallResponse`, `CallTemplate`)
- ✅ Error types (`UtcpError`)
- ✅ Provider & Auth types
- ✅ `InMemoryToolRepository`
- ✅ Build system (`build.zig`)

**Phase 2: HTTP Transport** ✅ COMPLETE
- ✅ HTTP transport (`src/transports/http.zig`)
- ✅ Variable substitution (`{input.field}`, `{env.VAR}`)
- ✅ Auth support (API key, Basic, Bearer)
- ✅ JSON request/response handling
- ✅ Working example (`zig build run-http`)

**Phase 3: CLI Transport** (Next)
- ⏳ CLI transport with `std.process.Child`
- ⏳ Stdin/stdout/stderr handling
- ⏳ CLI example

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
    defer {
        switch (response.output) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    // Handle response
    if (response.error_msg) |err| {
        std.debug.print("Error: {s}\n", .{err});
        allocator.free(err);
    } else {
        std.debug.print("Success: {any}\n", .{response.output});
    }
}
```

See `examples/http_client.zig` for a complete working example.

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
│   └── memory.zig     # InMemoryToolRepository
├── transports/        # Transport implementations
│   └── http.zig       # ✅ HTTP transport (Phase 2)
└── utcp.zig           # Public API
```

## Development

### Project Organization

- `src/` - Library source code
- `examples/` - Example programs
- `tests/` - Integration tests
- `docs/` - Architecture and design docs
- `zig-kb/` - (Optional) Zig 0.15.2 stdlib reference (ignored by default)
- `utcp-upstream/` - (Optional) cloned UTCP reference implementations (ignored by default)
- `utcp-repomix/` - (Optional) bundled reference implementations (ignored by default)

### Testing

```bash
# Run all tests
zig build test

# Run specific test
zig test src/repository/memory.zig
```

### Code Style

- Follow Zig standard library style
- Use arena allocators for request/response lifetimes
- Prefer explicit error handling over panics
- Document public APIs with `///` doc comments

## Roadmap

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for development timeline.

**Phase 1**: Foundation - Core types, repository, build system ✅  
**Phase 2**: HTTP transport + variable substitution ✅  
**Phase 3** (Next): CLI transport  
**Phase 4**: MCP transport  
**Phase 5**: Polish + v0.1.0 release  

## References

- [UTCP Specification](https://github.com/universal-tool-calling-protocol/utcp-specification)
- [UTCP Go Implementation](https://github.com/universal-tool-calling-protocol/go-utcp)
- [UTCP Rust Implementation](https://github.com/universal-tool-calling-protocol/rs-utcp)
- [Zig 0.15.2 Documentation](https://ziglang.org/documentation/0.15.2/)

## License

MIT (to be confirmed)

## Contributing

This project is in early development. Contributions welcome after v0.1.0 release.
