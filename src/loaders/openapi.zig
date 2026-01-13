//! OpenAPI to UTCP converter
//! Converts OpenAPI 3.0 specifications into UTCP tools

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const HttpCallTemplate = @import("../core/tool.zig").HttpCallTemplate;
const CallTemplate = @import("../core/tool.zig").CallTemplate;
const Provider = @import("../core/provider.zig").Provider;
const Auth = @import("../core/provider.zig").Auth;
const ApiKeyAuth = @import("../core/provider.zig").ApiKeyAuth;
const BasicAuth = @import("../core/provider.zig").BasicAuth;
const OAuth2Auth = @import("../core/provider.zig").OAuth2Auth;

pub const OpenApiConverter = struct {
    allocator: std.mem.Allocator,
    spec: std.json.Value,
    base_url: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator, spec: std.json.Value) OpenApiConverter {
        return .{
            .allocator = allocator,
            .spec = spec,
            .base_url = null,
        };
    }
    
    pub fn deinit(self: *OpenApiConverter) void {
        _ = self;
        // Spec is owned by caller
    }
    
    /// Set a custom base URL override
    pub fn setBaseUrl(self: *OpenApiConverter, url: []const u8) void {
        self.base_url = url;
    }
    
    /// Convert OpenAPI spec to UTCP tools
    pub fn convert(self: *OpenApiConverter) !ConvertResult {
        var tools = std.ArrayList(Tool).empty;
        var provider: ?Provider = null;
        
        const spec_obj = switch (self.spec) {
            .object => |o| o,
            else => return error.InvalidSpec,
        };
        
        // Get base URL
        const base_url = self.getBaseUrl(spec_obj);
        
        // Get provider info from spec info
        if (spec_obj.get("info")) |info_val| {
            if (info_val == .object) {
                const info = info_val.object;
                const title = if (info.get("title")) |t| switch (t) {
                    .string => |s| s,
                    else => "openapi",
                } else "openapi";
                
                const description = if (info.get("description")) |d| switch (d) {
                    .string => |s| s,
                    else => null,
                } else null;
                
                const version = if (info.get("version")) |v| switch (v) {
                    .string => |s| s,
                    else => null,
                } else null;
                
                provider = Provider{
                    .id = try self.sanitizeId(title),
                    .name = title,
                    .description = description,
                    .version = version,
                    .base_url = base_url,
                    .auth = try self.extractAuth(spec_obj),
                };
            }
        }
        
        // Process paths
        const paths = switch (spec_obj.get("paths") orelse return error.InvalidSpec) {
            .object => |p| p,
            else => return error.InvalidSpec,
        };
        
        var paths_iter = paths.iterator();
        while (paths_iter.next()) |path_entry| {
            const path = path_entry.key_ptr.*;
            const path_item = switch (path_entry.value_ptr.*) {
                .object => |o| o,
                else => continue,
            };
            
            // Process each HTTP method
            var path_iter = path_item.iterator();
            while (path_iter.next()) |method_entry| {
                const method_str = method_entry.key_ptr.*;
                if (!isValidHttpMethod(method_str)) continue;
                
                const operation = switch (method_entry.value_ptr.*) {
                    .object => |o| o,
                    else => continue,
                };
                
                if (try self.createTool(path, method_str, operation, base_url)) |tool| {
                    try tools.append(self.allocator, tool);
                }
            }
        }
        
        return ConvertResult{
            .tools = try tools.toOwnedSlice(self.allocator),
            .provider = provider,
        };
    }
    
    fn getBaseUrl(self: *OpenApiConverter, spec_obj: std.json.ObjectMap) ?[]const u8 {
        // 1. Check for explicit base_url override
        if (self.base_url) |url| return url;
        
        // 2. Check OpenAPI 3.0 servers field
        if (spec_obj.get("servers")) |servers_val| {
            switch (servers_val) {
                .array => |servers| {
                    if (servers.items.len > 0) {
                        const first = servers.items[0];
                        if (first == .object) {
                            if (first.object.get("url")) |url_val| {
                                if (url_val == .string) {
                                    return url_val.string;
                                }
                            }
                        }
                    }
                },
                else => {},
            }
        }
        
        // 3. Check OpenAPI 2.0 host/basePath
        if (spec_obj.get("host")) |host_val| {
            if (host_val == .string) {
                // Would need to construct URL from host + basePath
                // For now just return the host
                return host_val.string;
            }
        }
        
        return null;
    }
    
    fn extractAuth(self: *OpenApiConverter, spec_obj: std.json.ObjectMap) !?Auth {
        _ = self;
        // Check securityDefinitions (OpenAPI 2.0) or components.securitySchemes (3.0)
        var security_schemes: ?std.json.ObjectMap = null;
        
        if (spec_obj.get("components")) |components| {
            if (components == .object) {
                if (components.object.get("securitySchemes")) |schemes| {
                    if (schemes == .object) {
                        security_schemes = schemes.object;
                    }
                }
            }
        }
        
        if (security_schemes == null) {
            if (spec_obj.get("securityDefinitions")) |defs| {
                if (defs == .object) {
                    security_schemes = defs.object;
                }
            }
        }
        
        const schemes = security_schemes orelse return null;
        
        // Get the first security scheme
        var iter = schemes.iterator();
        if (iter.next()) |entry| {
            const scheme = switch (entry.value_ptr.*) {
                .object => |o| o,
                else => return null,
            };
            
            const type_str = if (scheme.get("type")) |t| switch (t) {
                .string => |s| s,
                else => return null,
            } else return null;
            
            if (std.mem.eql(u8, type_str, "apiKey")) {
                const in_field = if (scheme.get("in")) |i| switch (i) {
                    .string => |s| s,
                    else => "header",
                } else "header";
                
                if (std.mem.eql(u8, in_field, "header")) {
                    const name = if (scheme.get("name")) |n| switch (n) {
                        .string => |s| s,
                        else => "X-API-Key",
                    } else "X-API-Key";
                    
                    return Auth{ .api_key = ApiKeyAuth{
                        .key = "${API_KEY}",
                        .header_name = name,
                    } };
                }
            } else if (std.mem.eql(u8, type_str, "http")) {
                const scheme_name = if (scheme.get("scheme")) |s| switch (s) {
                    .string => |str| str,
                    else => "bearer",
                } else "bearer";
                
                if (std.mem.eql(u8, scheme_name, "basic")) {
                    return Auth{ .basic = BasicAuth{
                        .username = "${USERNAME}",
                        .password = "${PASSWORD}",
                    } };
                } else {
                    return Auth{ .bearer = .{ .token = "${TOKEN}" } };
                }
            } else if (std.mem.eql(u8, type_str, "oauth2")) {
                // Extract OAuth2 flow details
                var token_url: []const u8 = "${TOKEN_URL}";
                
                if (scheme.get("flows")) |flows| {
                    if (flows == .object) {
                        if (flows.object.get("clientCredentials")) |cc| {
                            if (cc == .object) {
                                if (cc.object.get("tokenUrl")) |tu| {
                                    if (tu == .string) {
                                        token_url = tu.string;
                                    }
                                }
                            }
                        }
                    }
                }
                
                return Auth{ .oauth2 = OAuth2Auth{
                    .client_id = "${CLIENT_ID}",
                    .client_secret = "${CLIENT_SECRET}",
                    .token_url = token_url,
                } };
            }
        }
        
        return null;
    }
    
    fn createTool(self: *OpenApiConverter, path: []const u8, method: []const u8, operation: std.json.ObjectMap, base_url: ?[]const u8) !?Tool {
        // Get operation ID or generate one
        const operation_id = if (operation.get("operationId")) |oid| switch (oid) {
            .string => |s| s,
            else => null,
        } else null;
        
        const name = operation_id orelse try self.generateOperationId(path, method);
        
        // Get summary/description
        const summary = if (operation.get("summary")) |s| switch (s) {
            .string => |str| str,
            else => null,
        } else null;
        
        const description = if (operation.get("description")) |d| switch (d) {
            .string => |str| str,
            else => summary orelse "",
        } else summary orelse "";
        
        // Build full URL
        const url = if (base_url) |base|
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ base, path })
        else
            try self.allocator.dupe(u8, path);
        
        // Extract input schema from parameters and requestBody
        const input_schema = try self.extractInputSchema(operation);
        
        // Extract tags
        var tags: ?[]const []const u8 = null;
        if (operation.get("tags")) |tags_val| {
            if (tags_val == .array) {
                var tag_list = std.ArrayList([]const u8).empty;
                for (tags_val.array.items) |tag_item| {
                    if (tag_item == .string) {
                        try tag_list.append(self.allocator, tag_item.string);
                    }
                }
                if (tag_list.items.len > 0) {
                    tags = try tag_list.toOwnedSlice(self.allocator);
                }
            }
        }
        
        return Tool{
            .id = try self.sanitizeId(name),
            .name = name,
            .description = description,
            .input_schema = input_schema,
            .output_schema = null,
            .tags = tags orelse &.{},
            .call_template = CallTemplate{ .http = HttpCallTemplate{
                .url = url,
                .method = method,
                .headers = null,
                .body_template = null,
            } },
        };
    }
    
    fn extractInputSchema(self: *OpenApiConverter, operation: std.json.ObjectMap) !?std.json.Value {
        var properties = std.json.ObjectMap.init(self.allocator);
        var required = std.json.Array.init(self.allocator);
        
        // Process parameters
        if (operation.get("parameters")) |params_val| {
            if (params_val == .array) {
                for (params_val.array.items) |param_item| {
                    if (param_item == .object) {
                        const param = param_item.object;
                        const param_name = if (param.get("name")) |n| switch (n) {
                            .string => |s| s,
                            else => continue,
                        } else continue;
                        
                        // Get schema or type
                        var param_schema: std.json.Value = .{ .object = std.json.ObjectMap.init(self.allocator) };
                        if (param.get("schema")) |s| {
                            param_schema = s;
                        } else if (param.get("type")) |t| {
                            var schema_obj = std.json.ObjectMap.init(self.allocator);
                            try schema_obj.put("type", t);
                            param_schema = .{ .object = schema_obj };
                        }
                        
                        try properties.put(param_name, param_schema);
                        
                        // Check if required
                        if (param.get("required")) |r| {
                            if (r == .bool and r.bool) {
                                try required.append(.{ .string = param_name });
                            }
                        }
                    }
                }
            }
        }
        
        // Process requestBody (OpenAPI 3.0)
        if (operation.get("requestBody")) |body_val| {
            if (body_val == .object) {
                const body = body_val.object;
                if (body.get("content")) |content| {
                    if (content == .object) {
                        // Try application/json first
                        const media_type = content.object.get("application/json") orelse content.object.get("*/*");
                        if (media_type) |mt| {
                            if (mt == .object) {
                                if (mt.object.get("schema")) |schema| {
                                    try properties.put("body", schema);
                                }
                            }
                        }
                    }
                }
            }
        }
        
        if (properties.count() == 0) {
            return null;
        }
        
        var schema_obj = std.json.ObjectMap.init(self.allocator);
        try schema_obj.put("type", .{ .string = "object" });
        try schema_obj.put("properties", .{ .object = properties });
        if (required.items.len > 0) {
            try schema_obj.put("required", std.json.Value{ .array = required });
        }
        
        return .{ .object = schema_obj };
    }
    
    fn generateOperationId(self: *OpenApiConverter, path: []const u8, method: []const u8) ![]const u8 {
        // Convert path to camelCase-ish name
        var result = std.ArrayList(u8).empty;
        try result.appendSlice(self.allocator, method);
        
        var capitalize_next = true;
        for (path) |c| {
            if (c == '/' or c == '{' or c == '}' or c == '-' or c == '_') {
                capitalize_next = true;
            } else if (capitalize_next) {
                try result.append(self.allocator, std.ascii.toUpper(c));
                capitalize_next = false;
            } else {
                try result.append(self.allocator, c);
            }
        }
        
        return try result.toOwnedSlice(self.allocator);
    }
    
    fn sanitizeId(self: *OpenApiConverter, name: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        for (name) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
                try result.append(self.allocator, std.ascii.toLower(c));
            } else if (c == ' ') {
                try result.append(self.allocator, '_');
            }
        }
        return try result.toOwnedSlice(self.allocator);
    }
    
    fn isValidHttpMethod(method: []const u8) bool {
        return std.mem.eql(u8, method, "get") or
            std.mem.eql(u8, method, "post") or
            std.mem.eql(u8, method, "put") or
            std.mem.eql(u8, method, "delete") or
            std.mem.eql(u8, method, "patch") or
            std.mem.eql(u8, method, "head") or
            std.mem.eql(u8, method, "options");
    }
};

pub const ConvertResult = struct {
    tools: []Tool,
    provider: ?Provider,
};

/// Load and convert an OpenAPI spec from a JSON string
pub fn convertFromString(allocator: std.mem.Allocator, json_str: []const u8) !ConvertResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    // Note: Don't deinit parsed - the tools reference strings in it
    
    var converter = OpenApiConverter.init(allocator, parsed.value);
    return converter.convert();
}

test "openapi converter basic" {
    const allocator = std.testing.allocator;
    
    const openapi_json =
        \\{
        \\  "openapi": "3.0.0",
        \\  "info": {
        \\    "title": "Pet Store",
        \\    "version": "1.0.0"
        \\  },
        \\  "servers": [{"url": "https://api.petstore.com"}],
        \\  "paths": {
        \\    "/pets": {
        \\      "get": {
        \\        "operationId": "listPets",
        \\        "summary": "List all pets",
        \\        "tags": ["pets"],
        \\        "parameters": [
        \\          {"name": "limit", "in": "query", "schema": {"type": "integer"}}
        \\        ]
        \\      }
        \\    }
        \\  }
        \\}
    ;
    
    // Use arena to manage memory
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    const result = try convertFromString(arena.allocator(), openapi_json);
    
    try std.testing.expectEqual(@as(usize, 1), result.tools.len);
    try std.testing.expectEqualStrings("listpets", result.tools[0].id);
    try std.testing.expectEqualStrings("listPets", result.tools[0].name);
    try std.testing.expect(result.provider != null);
    try std.testing.expectEqualStrings("Pet Store", result.provider.?.name);
}

test "openapi converter with auth" {
    const allocator = std.testing.allocator;
    
    const openapi_json =
        \\{
        \\  "openapi": "3.0.0",
        \\  "info": {"title": "Secure API", "version": "1.0.0"},
        \\  "components": {
        \\    "securitySchemes": {
        \\      "apiKey": {
        \\        "type": "apiKey",
        \\        "in": "header",
        \\        "name": "X-API-Token"
        \\      }
        \\    }
        \\  },
        \\  "paths": {
        \\    "/data": {
        \\      "get": {
        \\        "operationId": "getData"
        \\      }
        \\    }
        \\  }
        \\}
    ;
    
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    const result = try convertFromString(arena.allocator(), openapi_json);
    
    try std.testing.expect(result.provider != null);
    try std.testing.expect(result.provider.?.auth != null);
    
    const auth = result.provider.?.auth.?;
    switch (auth) {
        .api_key => |api_key| {
            try std.testing.expectEqualStrings("X-API-Token", api_key.header_name);
        },
        else => return error.UnexpectedAuth,
    }
}
