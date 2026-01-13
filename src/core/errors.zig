//! Error types for zig-utcp

pub const UtcpError = error{
    /// Tool not found in repository
    ToolNotFound,
    
    /// Transport-level error (network, process spawn, etc.)
    TransportError,
    
    /// JSON serialization/deserialization error
    SerializationError,
    
    /// Schema validation error
    ValidationError,
    
    /// Authentication/authorization error
    AuthenticationError,
    
    /// Operation timed out
    Timeout,
    
    /// Invalid tool configuration
    InvalidConfiguration,
    
    /// Unsupported transport type
    UnsupportedTransport,
    
    /// Memory allocation failed
    OutOfMemory,
};
