# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2025-01-XX

### Added
- **CLI Tool** (`src/cli.zig`) - Command-line tool for testing and inspecting tool definitions
  - `utcp load <file>` - Load and validate tool definitions
  - `utcp list <file>` - List tools in a definition file
  - `utcp call <file> <tool> <json>` - Dry-run tool call
  - `utcp validate <file>` - Validate tool definitions
  - `utcp info` - Show library information
  - Supports `--verbose` and `--json` output modes
- **Debug mode** (`src/core/debug.zig`) - Verbose logging with request/response timing
- **Retry policies** (`src/core/retry.zig`) - Exponential backoff with jitter for transient failures
- **Middleware system** (`src/core/middleware.zig`) - Request/response interceptors for logging, metrics, auth injection
- **Circuit breaker** (`src/core/circuit_breaker.zig`) - Prevent cascading failures with automatic recovery
- **Rate limiting** (`src/core/rate_limit.zig`) - Token bucket, sliding window, and fixed window algorithms
- **Response caching** (`src/core/cache.zig`) - TTL-based caching with configurable max entries
- **Batch requests** (`src/core/batch.zig`) - Execute multiple tool calls in parallel
- **JSON Schema validation** (`src/core/validation.zig`) - Validate tool inputs against JSON Schema
- **Mock transport** (`src/core/mock.zig`) - Unit testing without network calls
- **Streaming example** (`examples/streaming_example.zig`)
- **Post-processor example** (`examples/postprocessor_example.zig`)
- **OAuth2 flow example** (`examples/oauth2_example.zig`)
- **API documentation** - `zig build docs` command for generating std.zig style docs
- **Performance benchmarks** - `zig build bench` command for regression testing
- **Release automation** - GitHub Actions workflow for creating releases with checksums
- Extended unit tests for substitution.zig, postprocessor.zig, streaming.zig

### Changed
- Updated build.zig with new build steps (docs, bench, cli, run-utcp)
- Updated README.md with comprehensive documentation for new features
- Improved test coverage for core modules

## [0.1.0] - 2024-01-15

### Added
- Initial release
- Core types: Tool, ToolCallRequest, ToolCallResponse, Provider
- HTTP transport with OAuth2 support
- CLI transport for subprocess execution
- MCP transport (Model Context Protocol) with stdio and HTTP modes
- SSE transport for Server-Sent Events
- WebSocket transport
- Text transport (plain/json/xml)
- UDP transport
- GraphQL transport over HTTP
- gRPC-Web compatible transport
- Authentication: API Key, Basic, Bearer, OAuth2
- JSON tool loader
- OpenAPI spec converter
- Streaming response support
- Post-processor chain for response transformation
- In-memory tool repository with search
- Variable substitution in templates
- CI/CD with GitHub Actions (Ubuntu + Windows)

### Security
- Mask processor for hiding sensitive data in responses

[0.2.0]: https://github.com/bkataru/zig-utcp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/bkataru/zig-utcp/releases/tag/v0.1.0
