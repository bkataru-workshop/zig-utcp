//! In-memory tool repository

const std = @import("std");
const Tool = @import("../core/tool.zig").Tool;
const UtcpError = @import("../core/errors.zig").UtcpError;

/// Simple in-memory tool storage
pub const InMemoryToolRepository = struct {
    allocator: std.mem.Allocator,
    tools: std.StringHashMap(Tool),
    
    pub fn init(allocator: std.mem.Allocator) InMemoryToolRepository {
        return .{
            .allocator = allocator,
            .tools = std.StringHashMap(Tool).init(allocator),
        };
    }
    
    pub fn deinit(self: *InMemoryToolRepository) void {
        self.tools.deinit();
    }
    
    pub fn addTool(self: *InMemoryToolRepository, tool: Tool) !void {
        try self.tools.put(tool.id, tool);
    }
    
    pub fn getTool(self: *InMemoryToolRepository, id: []const u8) !Tool {
        return self.tools.get(id) orelse error.ToolNotFound;
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
    
    pub fn searchByTag(self: *InMemoryToolRepository, allocator: std.mem.Allocator, tag: []const u8) ![]Tool {
        var results = std.ArrayList(Tool).init(allocator);
        defer results.deinit();
        
        var iter = self.tools.valueIterator();
        while (iter.next()) |tool| {
            for (tool.tags) |t| {
                if (std.mem.eql(u8, t, tag)) {
                    try results.append(tool.*);
                    break;
                }
            }
        }
        
        return try results.toOwnedSlice();
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
