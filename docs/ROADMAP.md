# zig-utcp Development Roadmap

## Phase 1: Foundation
- [x] Research + documentation
- [x] Core types (tool.zig, errors.zig, provider.zig)
- [x] InMemoryToolRepository (with search by tag/provider/query)
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

## Phase 5: SSE, JSON Loader, Enhanced Repository
- [x] SSE transport (sse.zig)
- [x] JSON tool loader (loaders/json.zig)
- [x] Repository: searchByTags, searchByProvider, search (text query)
- [x] Bulk operations: addTools, addProviders, clear

## Phase 6: WebSocket + Text Transports
- [x] WebSocket transport (websocket.zig)
- [x] Text transport (text.zig) with plain/json/xml formats
- [x] XML serialization with proper escaping

## Phase 7: Polish + Release
- [x] CI/CD (GitHub Actions)
- [x] Package as Zig module (build.zig.zon)
- [ ] OAuth2 token refresh flow
- [ ] OpenAPI converter/loader
- [ ] Streaming responses
- [ ] Documentation polish (README/API docs)
- [ ] v0.1.0 release

## Feature Parity Status vs Go/Rust/TypeScript

### Transports
| Transport | Go | Rust | TS | Zig |
|-----------|:--:|:----:|:--:|:---:|
| HTTP | ✓ | ✓ | ✓ | ✓ |
| CLI | ✓ | ✓ | ✓ | ✓ |
| MCP (stdio) | ✓ | ✓ | ✓ | ✓ |
| MCP (HTTP) | ✓ | ✓ | ✓ | ✓ |
| SSE | ✓ | ✓ | ✓ | ✓ |
| WebSocket | ✓ | ✓ | ✓ | ✓ |
| Text | - | - | - | ✓ |
| gRPC | ✓ | - | - | - |
| GraphQL | - | ✓ | - | - |
| UDP | ✓ | - | - | - |

### Authentication
| Auth Type | Go | Rust | TS | Zig |
|-----------|:--:|:----:|:--:|:---:|
| API Key | ✓ | ✓ | ✓ | ✓ |
| Basic | ✓ | ✓ | ✓ | ✓ |
| Bearer | ✓ | ✓ | ✓ | ✓ |
| OAuth2 | ✓ | ✓ | ✓ | partial |

### Tool Loaders
| Loader | Go | Rust | TS | Zig |
|--------|:--:|:----:|:--:|:---:|
| JSON | ✓ | ✓ | ✓ | ✓ |
| OpenAPI | ✓ | ✓ | ✓ | - |

### Repository Features
| Feature | Go | Rust | TS | Zig |
|---------|:--:|:----:|:--:|:---:|
| In-memory | ✓ | ✓ | ✓ | ✓ |
| Tag search | ✓ | ✓ | ✓ | ✓ |
| Provider filter | ✓ | ✓ | ✓ | ✓ |
| Text search | ✓ | ✓ | ✓ | ✓ |

**Current Parity: ~80%** (main gaps: OAuth2 token flow, OpenAPI loader)