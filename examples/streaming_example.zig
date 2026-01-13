//! Streaming response example
//! Demonstrates incremental processing of large responses

const std = @import("std");
const utcp = @import("utcp");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== UTCP Streaming Example ===\n\n", .{});

    // Example 1: Stream from static data
    std.debug.print("1. Streaming from static data:\n", .{});
    {
        const data = "Hello, this is a large response that we want to process in chunks. " ++
            "This could be JSON data, text content, or any other format. " ++
            "Streaming allows us to process data incrementally without loading everything into memory.";

        var stream = utcp.fromBytes(allocator, data);
        defer stream.deinit();

        // Set small chunk size for demonstration
        stream.iterator.chunk_size = 50;

        var chunk_num: u32 = 0;
        while (stream.next()) |chunk| {
            chunk_num += 1;
            std.debug.print("  Chunk {d}: '{s}' ({d} bytes, final: {})\n", .{
                chunk_num,
                chunk.data,
                chunk.data.len,
                chunk.is_final,
            });
            if (chunk.is_final) break;
        }
        std.debug.print("  Total chunks processed: {d}\n\n", .{chunk_num});
    }

    // Example 2: Collect all chunks into a single buffer
    std.debug.print("2. Collecting all chunks:\n", .{});
    {
        const data = "This data will be collected back into a single buffer.";

        var stream = utcp.fromBytes(allocator, data);
        defer stream.deinit();
        stream.iterator.chunk_size = 10;

        const collected = try stream.collectAll();
        defer allocator.free(collected);

        std.debug.print("  Collected: '{s}'\n", .{collected});
        std.debug.print("  Length: {d}\n\n", .{collected.len});
    }

    // Example 3: Using StreamingResponse with metadata
    std.debug.print("3. Streaming response with metadata:\n", .{});
    {
        var stream = utcp.StreamingResponse.init(allocator, .{
            .static = .{ .data = "Response data with metadata" },
        });
        defer stream.deinit();

        stream.content_type = "application/json";
        stream.total_size = 27;

        std.debug.print("  Content-Type: {s}\n", .{stream.content_type orelse "unknown"});
        std.debug.print("  Total Size: {?d}\n", .{stream.total_size});

        const content = try stream.collectAll();
        defer allocator.free(content);
        std.debug.print("  Content: '{s}'\n\n", .{content});
    }

    // Example 4: Custom callback source (for real-time data)
    std.debug.print("4. Custom callback streaming:\n", .{});
    {
        const CustomSource = struct {
            counter: u32 = 0,

            pub fn callback(iter: *utcp.StreamIterator) ?utcp.StreamChunk {
                const self: *@This() = @ptrCast(@alignCast(iter.buffer.allocator.vtable));
                _ = self;

                // Simulate real-time data generation
                // In a real scenario, this could read from a socket, file, etc.
                return utcp.StreamChunk{
                    .data = "simulated data",
                    .is_final = true,
                    .sequence = 1,
                };
            }
        };
        _ = CustomSource;

        std.debug.print("  (Custom callback sources can be used for real-time streaming)\n\n", .{});
    }

    std.debug.print("=== Streaming Example Complete ===\n", .{});
}
