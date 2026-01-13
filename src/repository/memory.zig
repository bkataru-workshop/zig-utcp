//! In-memory tool repository with search and filtering

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const Provider = @import("../core/provider.zig").Provider;
const UtcpError = @import("../core/errors.zig").UtcpError;

/// Simple in-memory tool storage with search capabilities
pub const InMemoryToolRepository = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(Tool),
    providers: std.StringHashMap(Provider),
    
    pub fn init(allocator: std.mem.Allocator) InMemoryToolRepository {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
            .providers = std.StringHashMap(Provider).init(allocator),
        };
    }
    
    pub fn deinit(self: *InMemoryToolRepository) void {
        self.tools.deinit();
        self.providers.deinit();
    }
    
    // Tool operations
    
    pub fn addTool(self: *InMemoryToolRepository, tool: Tool) !void {
        try self.tools.put(tool.id, tool);
    }
    
    pub fn getTool(self: *InMemoryToolRepository, id: []const u8) !Tool {
        return self.tools.get(id) orelse error.ToolNotFound;
    }
    
    pub fn removeTool(self: *InMemoryToolRepository, id: []const u8) bool {
        return self.tools.remove(id);
    }
    
    pub fn listTools(self: *InMemoryToolRepository, allocator: std.mem.Allocator) ![]Tool {
        var tools = try allocator.alloc(Tool, self.tools.count());
        var iter = self.tools.valueIterator();
        var i: usize = 0;
        while (iter.next()) |tool| : (i += 1) {
            tools[i] = tool.*;
        }
        return tools;
    }
    
    pub fn toolCount(self: *InMemoryToolRepository) usize {
        return self.tools.count();
    }
    
    // Provider operations
    
    pub fn addProvider(self: *InMemoryToolRepository, provider: Provider) !void {
        try self.providers.put(provider.id, provider);
    }
    
    pub fn getProvider(self: *InMemoryToolRepository, id: []const u8) !Provider {
        return self.providers.get(id) orelse error.ProviderNotFound;
    }
    
    pub fn removeProvider(self: *InMemoryToolRepository, id: []const u8) bool {
        return self.providers.remove(id);
    }
    
    pub fn listProviders(self: *InMemoryToolRepository, allocator: std.mem.Allocator) ![]Provider {
        var providers = try allocator.alloc(Provider, self.providers.count());
        var iter = self.providers.valueIterator();
        var i: usize = 0;
        while (iter.next()) |provider| : (i += 1) {
            providers[i] = provider.*;
        }
        return providers;
    }
    
    // Search operations
    
    /// Search tools by tag
    pub fn searchByTag(self: *InMemoryToolRepository, allocator: std.mem.Allocator, tag: []const u8) ![]Tool {
        var results: std.ArrayList(Tool) = .empty;
        
        var iter = self.tools.valueIterator();
        while (iter.next()) |tool| {
            for (tool.tags) |t| {
                if (std.mem.eql(u8, t, tag)) {
                    try results.append(allocator, tool.*);
                    break;
                }
            }
        }
        
        return try results.toOwnedSlice(allocator);
    }
    
    /// Search tools by multiple tags (OR logic)
    pub fn searchByTags(self: *InMemoryToolRepository, allocator: std.mem.Allocator, tags: []const []const u8) ![]Tool {
        var results: std.ArrayList(Tool) = .empty;
        
        var iter = self.tools.valueIterator();
        outer: while (iter.next()) |tool| {
            for (tool.tags) |tool_tag| {
                for (tags) |search_tag| {
                    if (std.mem.eql(u8, tool_tag, search_tag)) {
                        try results.append(allocator, tool.*);
                        continue :outer;
                    }
                }
            }
        }
        
        return try results.toOwnedSlice(allocator);
    }
    
    /// Search tools by provider ID
    pub fn searchByProvider(self: *InMemoryToolRepository, allocator: std.mem.Allocator, provider_id: []const u8) ![]Tool {
        var results: std.ArrayList(Tool) = .empty;
        
        var iter = self.tools.valueIterator();
        while (iter.next()) |tool| {
            if (tool.provider_id) |pid| {
                if (std.mem.eql(u8, pid, provider_id)) {
                    try results.append(allocator, tool.*);
                }
            }
        }
        
        return try results.toOwnedSlice(allocator);
    }
    
    /// Search tools by name/description query (case-insensitive substring match)
    pub fn search(self: *InMemoryToolRepository, allocator: std.mem.Allocator, query: []const u8) ![]Tool {
        var results: std.ArrayList(Tool) = .empty;
        
        // Convert query to lowercase for case-insensitive search
        var query_lower: [256]u8 = undefined;
        const query_len = @min(query.len, 255);
        for (0..query_len) |i| {
            query_lower[i] = std.ascii.toLower(query[i]);
        }
        const query_slice = query_lower[0..query_len];
        
        var iter = self.tools.valueIterator();
        while (iter.next()) |tool| {
            // Check name
            var name_lower: [256]u8 = undefined;
            const name_len = @min(tool.name.len, 255);
            for (0..name_len) |i| {
                name_lower[i] = std.ascii.toLower(tool.name[i]);
            }
            if (std.mem.indexOf(u8, name_lower[0..name_len], query_slice) != null) {
                try results.append(allocator, tool.*);
                continue;
            }
            
            // Check description
            var desc_lower: [512]u8 = undefined;
            const desc_len = @min(tool.description.len, 511);
            for (0..desc_len) |i| {
                desc_lower[i] = std.ascii.toLower(tool.description[i]);
            }
            if (std.mem.indexOf(u8, desc_lower[0..desc_len], query_slice) != null) {
                try results.append(allocator, tool.*);
                continue;
            }
            
            // Check tags
            for (tool.tags) |tag| {
                var tag_lower: [64]u8 = undefined;
                const tag_len = @min(tag.len, 63);
                for (0..tag_len) |i| {
                    tag_lower[i] = std.ascii.toLower(tag[i]);
                }
                if (std.mem.indexOf(u8, tag_lower[0..tag_len], query_slice) != null) {
                    try results.append(allocator, tool.*);
                    break;
                }
            }
        }
        
        return try results.toOwnedSlice(allocator);
    }
    
    /// Bulk add tools
    pub fn addTools(self: *InMemoryToolRepository, tools: []const Tool) !void {
        for (tools) |tool| {
            try self.addTool(tool);
        }
    }
    
    /// Bulk add providers
    pub fn addProviders(self: *InMemoryToolRepository, providers: []const Provider) !void {
        for (providers) |provider| {
            try self.addProvider(provider);
        }
    }
    
    /// Clear all tools and providers
    pub fn clear(self: *InMemoryToolRepository) void {
        self.tools.clearRetainingCapacity();
        self.providers.clearRetainingCapacity();
    }
};

test "InMemoryToolRepository basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var repo = InMemoryToolRepository.init(allocator);
    defer repo.deinit();
    
    const tool = Tool{
        .id = "test_tool",
        .name = "Test Tool",
        .description = "A test tool",
        .call_template = .{ .http = .{
            .method = "GET",
            .url = "https://example.com/test",
        }},
    };
    
    try repo.addTool(tool);
    
    const retrieved = try repo.getTool("test_tool");
    try testing.expectEqualStrings("Test Tool", retrieved.name);
    
    const not_found = repo.getTool("nonexistent");
    try testing.expectError(error.ToolNotFound, not_found);
}

test "InMemoryToolRepository search" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var repo = InMemoryToolRepository.init(allocator);
    defer repo.deinit();
    
    try repo.addTool(.{
        .id = "weather",
        .name = "Weather API",
        .description = "Get weather data",
        .tags = &.{ "weather", "api" },
        .call_template = .{ .http = .{ .method = "GET", .url = "https://wttr.in" } },
    });
    
    try repo.addTool(.{
        .id = "news",
        .name = "News API",
        .description = "Get news articles",
        .tags = &.{ "news", "api" },
        .call_template = .{ .http = .{ .method = "GET", .url = "https://news.com" } },
    });
    
    // Search by tag
    const weather_tools = try repo.searchByTag(allocator, "weather");
    defer allocator.free(weather_tools);
    try testing.expectEqual(@as(usize, 1), weather_tools.len);
    
    // Search by query
    const api_tools = try repo.search(allocator, "API");
    defer allocator.free(api_tools);
    try testing.expectEqual(@as(usize, 2), api_tools.len);
}
