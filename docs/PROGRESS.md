
## Phase 2: HTTP Transport - COMPLETED

### Implementation Details

**Core Files:**
- `src/core/substitution.zig` - Variable substitution for {input.field} and {env.VAR}
- `src/transports/http.zig` - HTTP transport using std.http.Client
- `examples/http_client.zig` - Working example using wttr.in weather API

**Features Implemented:**
1. ✅ HTTP GET/POST/PUT/PATCH support
2. ✅ Variable substitution in URLs, headers, and body templates
3. ✅ Authentication: API key, Basic, Bearer (OAuth2 placeholder)
4. ✅ JSON request/response handling
5. ✅ Custom headers and query parameters
6. ✅ Timeout support
7. ✅ Arena allocator for request/response lifetime
8. ✅ Environment variable substitution

**Zig 0.15.2 API Changes Handled:**
- `ArrayList(T)` no longer has `.init()` - use `.empty` instead
- All ArrayList methods now take allocator as first argument
- `std.json.stringify()` replaced with `std.json.Stringify.valueAlloc()`
- Reader methods take allocator: `reader().readAllArrayList(&list, alloc, max)`

**Testing:**
- All unit tests pass (substitution, InMemoryToolRepository)
- HTTP example compiles successfully
- Build system includes `zig build run-http` for easy testing

**Technical Patterns:**
- Template substitution via simple state machine (scan for `{...}`)
- Separate applyAuth() helper for clean auth handling
- Error responses include HTTP status codes
- 10MB response size limit for safety
