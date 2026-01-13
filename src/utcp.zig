//! zig-utcp: Universal Tool Calling Protocol implementation for Zig
//! 
//! This library provides a vendor-agnostic standard for LLM-tool integration
//! supporting HTTP, CLI, MCP, SSE, WebSocket, GraphQL, gRPC, UDP, and more.

const std = @import("std");

// Core types
pub const Tool = @import("core/tool.zig").Tool;
pub const ToolCallRequest = @import("core/tool.zig").ToolCallRequest;
pub const ToolCallResponse = @import("core/tool.zig").ToolCallResponse;
pub const CallTemplate = @import("core/tool.zig").CallTemplate;
pub const HttpCallTemplate = @import("core/tool.zig").HttpCallTemplate;
pub const CliCallTemplate = @import("core/tool.zig").CliCallTemplate;
pub const McpCallTemplate = @import("core/tool.zig").McpCallTemplate;
pub const SseCallTemplate = @import("core/tool.zig").SseCallTemplate;
pub const WebSocketCallTemplate = @import("core/tool.zig").WebSocketCallTemplate;
pub const TextCallTemplate = @import("core/tool.zig").TextCallTemplate;
pub const UdpCallTemplate = @import("core/tool.zig").UdpCallTemplate;
pub const GrpcCallTemplate = @import("core/tool.zig").GrpcCallTemplate;
pub const GraphqlCallTemplate = @import("core/tool.zig").GraphqlCallTemplate;
pub const Provider = @import("core/provider.zig").Provider;
pub const Auth = @import("core/provider.zig").Auth;
pub const UtcpError = @import("core/errors.zig").UtcpError;

// Repository
pub const InMemoryToolRepository = @import("repository/memory.zig").InMemoryToolRepository;

// Transports
pub const HttpTransport = @import("transports/http.zig").HttpTransport;
pub const OAuth2TokenResponse = @import("transports/http.zig").HttpTransport.OAuth2TokenResponse;
pub const CliTransport = @import("transports/cli.zig").CliTransport;
pub const McpTransport = @import("transports/mcp.zig").McpTransport;
pub const SseTransport = @import("transports/sse.zig").SseTransport;
pub const SseEvent = @import("transports/sse.zig").SseEvent;
pub const WebSocketTransport = @import("transports/websocket.zig").WebSocketTransport;
pub const TextTransport = @import("transports/text.zig").TextTransport;
pub const TextFormat = @import("core/tool.zig").TextFormat;
pub const UdpTransport = @import("transports/udp.zig").UdpTransport;
pub const GraphqlTransport = @import("transports/graphql.zig").GraphqlTransport;
pub const GrpcTransport = @import("transports/grpc.zig").GrpcTransport;
pub const GrpcStatus = @import("transports/grpc.zig").GrpcStatus;
pub const JsonRpcRequest = @import("transports/mcp.zig").JsonRpcRequest;
pub const JsonRpcResponse = @import("transports/mcp.zig").JsonRpcResponse;
pub const JsonRpcError = @import("transports/mcp.zig").JsonRpcError;

// Auth types
pub const ApiKeyAuth = @import("core/provider.zig").ApiKeyAuth;
pub const BasicAuth = @import("core/provider.zig").BasicAuth;
pub const BearerAuth = @import("core/provider.zig").BearerAuth;
pub const OAuth2Auth = @import("core/provider.zig").OAuth2Auth;

// Loaders
pub const JsonLoader = @import("loaders/json.zig").JsonLoader;
pub const LoadResult = @import("loaders/json.zig").LoadResult;
pub const OpenApiConverter = @import("loaders/openapi.zig").OpenApiConverter;
pub const ConvertResult = @import("loaders/openapi.zig").ConvertResult;
pub const convertFromString = @import("loaders/openapi.zig").convertFromString;

// Streaming
pub const StreamChunk = @import("core/streaming.zig").StreamChunk;
pub const StreamIterator = @import("core/streaming.zig").StreamIterator;
pub const StreamingResponse = @import("core/streaming.zig").StreamingResponse;
pub const fromBytes = @import("core/streaming.zig").fromBytes;
pub const fromReader = @import("core/streaming.zig").fromReader;

// Post-processors
pub const PostProcessor = @import("core/postprocessor.zig").PostProcessor;
pub const PostProcessorFn = @import("core/postprocessor.zig").PostProcessorFn;
pub const PostProcessorChain = @import("core/postprocessor.zig").PostProcessorChain;
pub const logProcessor = @import("core/postprocessor.zig").logProcessor;
pub const trimProcessor = @import("core/postprocessor.zig").trimProcessor;
pub const jsonValidateProcessor = @import("core/postprocessor.zig").jsonValidateProcessor;
pub const extractFieldProcessor = @import("core/postprocessor.zig").extractFieldProcessor;
pub const maskProcessor = @import("core/postprocessor.zig").maskProcessor;

// Debug mode
pub const debug = @import("core/debug.zig");
pub const LogLevel = @import("core/debug.zig").LogLevel;
pub const DebugConfig = @import("core/debug.zig").DebugConfig;
pub const Timer = @import("core/debug.zig").Timer;

// Retry policies
pub const retry = @import("core/retry.zig");
pub const RetryPolicy = @import("core/retry.zig").RetryPolicy;
pub const RetryContext = @import("core/retry.zig").RetryContext;

// Middleware
pub const middleware = @import("core/middleware.zig");
pub const Middleware = @import("core/middleware.zig").Middleware;
pub const MiddlewareChain = @import("core/middleware.zig").MiddlewareChain;
pub const MiddlewareContext = @import("core/middleware.zig").MiddlewareContext;

// Circuit breaker
pub const circuit_breaker = @import("core/circuit_breaker.zig");
pub const CircuitBreaker = @import("core/circuit_breaker.zig").CircuitBreaker;
pub const CircuitBreakerConfig = @import("core/circuit_breaker.zig").CircuitBreakerConfig;
pub const CircuitBreakerRegistry = @import("core/circuit_breaker.zig").CircuitBreakerRegistry;
pub const CircuitState = @import("core/circuit_breaker.zig").CircuitState;

// Rate limiting
pub const rate_limit = @import("core/rate_limit.zig");
pub const RateLimitConfig = @import("core/rate_limit.zig").RateLimitConfig;
pub const TokenBucket = @import("core/rate_limit.zig").TokenBucket;
pub const SlidingWindow = @import("core/rate_limit.zig").SlidingWindow;
pub const FixedWindow = @import("core/rate_limit.zig").FixedWindow;
pub const RateLimiterRegistry = @import("core/rate_limit.zig").RateLimiterRegistry;

// Caching
pub const cache = @import("core/cache.zig");
pub const ResponseCache = @import("core/cache.zig").ResponseCache;
pub const CacheConfig = @import("core/cache.zig").CacheConfig;
pub const CacheEntry = @import("core/cache.zig").CacheEntry;
pub const CacheStats = @import("core/cache.zig").CacheStats;

// Batch requests
pub const batch = @import("core/batch.zig");
pub const BatchExecutor = @import("core/batch.zig").BatchExecutor;
pub const BatchBuilder = @import("core/batch.zig").BatchBuilder;
pub const BatchConfig = @import("core/batch.zig").BatchConfig;
pub const BatchResult = @import("core/batch.zig").BatchResult;
pub const BatchResults = @import("core/batch.zig").BatchResults;

// Validation
pub const validation = @import("core/validation.zig");
pub const SchemaValidator = @import("core/validation.zig").SchemaValidator;
pub const ValidationResult = @import("core/validation.zig").ValidationResult;
pub const ValidationError = @import("core/validation.zig").ValidationError;

// Mock transport for testing
pub const mock = @import("core/mock.zig");
pub const MockTransport = @import("core/mock.zig").MockTransport;
pub const MockResponse = @import("core/mock.zig").MockResponse;
pub const MockTransportBuilder = @import("core/mock.zig").MockTransportBuilder;

// Utilities
pub const substitute = @import("core/substitution.zig").substitute;
pub const buildQuery = @import("transports/graphql.zig").buildQuery;

test {
    std.testing.refAllDecls(@This());
}
