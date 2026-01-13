//! Provider metadata and configuration

const std = @import("std");

/// Provider represents a source of tools (e.g., an API, CLI program, MCP server)
pub const Provider = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    version: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    auth: ?Auth = null,
    metadata: ?std.json.Value = null,
};

/// Authentication configuration
pub const Auth = union(enum) {
    api_key: ApiKeyAuth,
    basic: BasicAuth,
    bearer: BearerAuth,
    oauth2: OAuth2Auth,
    none: void,
};

pub const ApiKeyAuth = struct {
    key: []const u8,
    header_name: []const u8 = "X-API-Key",
};

pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,
};

pub const BearerAuth = struct {
    token: []const u8,
};

pub const OAuth2Auth = struct {
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    token_url: []const u8,
    scope: ?[]const u8 = null,
    // Runtime token storage (mutable)
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};
