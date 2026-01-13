# zig-utcp Development Roadmap

## Phase 1: Foundation
- [x] Research + documentation
- [x] Core types (tool.zig, errors.zig, provider.zig)
- [x] InMemoryToolRepository
- [x] Basic build.zig + test harness

## Phase 2: HTTP Transport
- [x] http.zig transport using std.http.Client
- [x] Variable substitution (templates)
- [x] Auth: API key + Basic auth + Bearer (OAuth2 placeholder)
- [x] Example: calling a REST API tool
- [ ] Integration test against mock HTTP server

## Phase 3: CLI Transport
- [x] cli.zig transport using std.process.Child
- [x] Capture stdout/stderr -> JSON parsing
- [x] Example: calling a CLI tool

## Phase 4: MCP Transport
- [x] mcp.zig: JSON-RPC 2.0 stdio mode
- [x] MCP HTTP mode (JSON-RPC over HTTP)
- [x] Example: MCP client
- [ ] MCP SSE mode (HTTP + SSE for events)

## Phase 5: Polish + Release
- [x] CI/CD (GitHub Actions)
- [x] Package as Zig module (build.zig.zon)
- [ ] Documentation polish (README/API docs)
- [ ] v0.1.0 release