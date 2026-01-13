//! Streaming response support
//! Enables incremental processing of large responses

const std = @import("std");

/// A chunk of streaming data
pub const StreamChunk = struct {
    data: []const u8,
    is_final: bool = false,
    sequence: u64 = 0,
    metadata: ?std.json.Value = null,
};

/// Iterator for streaming responses
pub const StreamIterator = struct {
    allocator: std.mem.Allocator,
    source: StreamSource,
    buffer: std.ArrayListAligned(u8, null),
    chunk_size: usize,
    sequence: u64,
    finished: bool,

    pub const StreamSource = union(enum) {
        reader: std.io.AnyReader,
        static: StaticSource,
        callback: *const fn (*StreamIterator) ?StreamChunk,
    };

    pub const StaticSource = struct {
        data: []const u8,
        offset: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, source: StreamSource) StreamIterator {
        return .{
            .allocator = allocator,
            .source = source,
            .buffer = .empty,
            .chunk_size = 4096,
            .sequence = 0,
            .finished = false,
        };
    }

    pub fn deinit(self: *StreamIterator) void {
        self.buffer.deinit(self.allocator);
    }

    /// Get the next chunk of data
    pub fn next(self: *StreamIterator) ?StreamChunk {
        if (self.finished) return null;

        switch (self.source) {
            .reader => |reader| {
                self.buffer.clearRetainingCapacity();
                self.buffer.ensureTotalCapacity(self.allocator, self.chunk_size) catch return null;

                const n = reader.read(self.buffer.unusedCapacitySlice()) catch return null;
                if (n == 0) {
                    self.finished = true;
                    return StreamChunk{
                        .data = "",
                        .is_final = true,
                        .sequence = self.sequence,
                    };
                }

                self.buffer.items.len = n;
                self.sequence += 1;
                return StreamChunk{
                    .data = self.buffer.items,
                    .is_final = false,
                    .sequence = self.sequence,
                };
            },
            .static => |*static| {
                if (static.offset >= static.data.len) {
                    self.finished = true;
                    return StreamChunk{
                        .data = "",
                        .is_final = true,
                        .sequence = self.sequence,
                    };
                }

                const end = @min(static.offset + self.chunk_size, static.data.len);
                const chunk = static.data[static.offset..end];
                static.offset = end;
                self.sequence += 1;

                return StreamChunk{
                    .data = chunk,
                    .is_final = static.offset >= static.data.len,
                    .sequence = self.sequence,
                };
            },
            .callback => |cb| {
                const result = cb(self);
                if (result) |r| {
                    if (r.is_final) self.finished = true;
                }
                return result;
            },
        }
    }

    /// Collect all remaining chunks into a single buffer
    pub fn collectAll(self: *StreamIterator) ![]const u8 {
        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(self.allocator);

        while (self.next()) |chunk| {
            try result.appendSlice(self.allocator, chunk.data);
            if (chunk.is_final) break;
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// Set the chunk size for reading
    pub fn setChunkSize(self: *StreamIterator, size: usize) void {
        self.chunk_size = size;
    }
};

/// Streaming response wrapper
pub const StreamingResponse = struct {
    iterator: StreamIterator,
    content_type: ?[]const u8 = null,
    total_size: ?usize = null,

    pub fn init(allocator: std.mem.Allocator, source: StreamIterator.StreamSource) StreamingResponse {
        return .{
            .iterator = StreamIterator.init(allocator, source),
        };
    }

    pub fn deinit(self: *StreamingResponse) void {
        self.iterator.deinit();
    }

    pub fn next(self: *StreamingResponse) ?StreamChunk {
        return self.iterator.next();
    }

    pub fn collectAll(self: *StreamingResponse) ![]const u8 {
        return self.iterator.collectAll();
    }
};

/// Create a streaming response from static data
pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) StreamingResponse {
    return StreamingResponse.init(allocator, .{
        .static = .{ .data = data },
    });
}

/// Create a streaming response from a reader
pub fn fromReader(allocator: std.mem.Allocator, reader: std.io.AnyReader) StreamingResponse {
    return StreamingResponse.init(allocator, .{ .reader = reader });
}

test "stream iterator static source" {
    const allocator = std.testing.allocator;
    const data = "Hello, streaming world!";

    var stream = fromBytes(allocator, data);
    defer stream.deinit();
    stream.iterator.chunk_size = 5;

    var chunks = std.ArrayList([]const u8).empty;
    defer chunks.deinit(allocator);

    while (stream.next()) |chunk| {
        if (chunk.data.len > 0) {
            try chunks.append(allocator, try allocator.dupe(u8, chunk.data));
        }
        if (chunk.is_final) break;
    }

    defer {
        for (chunks.items) |c| allocator.free(c);
    }

    // Should have multiple chunks
    try std.testing.expect(chunks.items.len > 1);
}

test "stream iterator collect all" {
    const allocator = std.testing.allocator;
    const data = "Hello, streaming world!";

    var stream = fromBytes(allocator, data);
    defer stream.deinit();

    const result = try stream.collectAll();
    defer allocator.free(result);

    try std.testing.expectEqualStrings(data, result);
}
