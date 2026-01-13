//! JSON Schema validation for tool inputs
//! Validates inputs against tool input_schema

const std = @import("std");

/// Validation error details
pub const ValidationError = struct {
    path: []const u8,
    message: []const u8,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
};

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    errors: []ValidationError,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ValidationResult) void {
        for (self.errors) |err| {
            self.allocator.free(err.path);
            self.allocator.free(err.message);
            if (err.expected) |e| self.allocator.free(e);
            if (err.actual) |a| self.allocator.free(a);
        }
        self.allocator.free(self.errors);
    }
};

/// JSON Schema validator
pub const SchemaValidator = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayListUnmanaged(ValidationError),

    pub fn init(allocator: std.mem.Allocator) SchemaValidator {
        return .{
            .allocator = allocator,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *SchemaValidator) void {
        self.errors.deinit(self.allocator);
    }

    /// Validate a value against a JSON Schema
    pub fn validate(self: *SchemaValidator, schema: std.json.Value, value: std.json.Value) !ValidationResult {
        self.errors.clearRetainingCapacity();
        try self.validateValue("$", schema, value);

        const errors = try self.errors.toOwnedSlice(self.allocator);
        return ValidationResult{
            .valid = errors.len == 0,
            .errors = errors,
            .allocator = self.allocator,
        };
    }

    /// Validate a tool's inputs against its schema
    pub fn validateToolInputs(
        self: *SchemaValidator,
        input_schema: ?std.json.Value,
        inputs: std.json.Value,
    ) !ValidationResult {
        if (input_schema == null) {
            // No schema = accept anything
            return ValidationResult{
                .valid = true,
                .errors = &.{},
                .allocator = self.allocator,
            };
        }

        return self.validate(input_schema.?, inputs);
    }

    fn validateValue(
        self: *SchemaValidator,
        path: []const u8,
        schema: std.json.Value,
        value: std.json.Value,
    ) std.mem.Allocator.Error!void {
        switch (schema) {
            .object => |schema_obj| {
                // Check type
                if (schema_obj.get("type")) |type_val| {
                    try self.validateType(path, type_val, value);
                }

                // Check required properties
                if (schema_obj.get("required")) |required| {
                    try self.validateRequired(path, required, value);
                }

                // Check properties
                if (schema_obj.get("properties")) |properties| {
                    try self.validateProperties(path, properties, value);
                }

                // Check enum
                if (schema_obj.get("enum")) |enum_values| {
                    try self.validateEnum(path, enum_values, value);
                }

                // Check minimum/maximum for numbers
                if (value == .integer or value == .float) {
                    try self.validateNumberConstraints(path, schema_obj, value);
                }

                // Check string constraints
                if (value == .string) {
                    try self.validateStringConstraints(path, schema_obj, value);
                }

                // Check array constraints
                if (value == .array) {
                    try self.validateArrayConstraints(path, schema_obj, value);
                }
            },
            else => {},
        }
    }

    fn validateType(
        self: *SchemaValidator,
        path: []const u8,
        type_val: std.json.Value,
        value: std.json.Value,
    ) !void {
        const expected_type = switch (type_val) {
            .string => |s| s,
            else => return,
        };

        const actual_type = getTypeName(value);
        const matches = typeMatches(expected_type, value);

        if (!matches) {
            try self.addError(path, "Type mismatch", expected_type, actual_type);
        }
    }

    fn validateRequired(
        self: *SchemaValidator,
        path: []const u8,
        required: std.json.Value,
        value: std.json.Value,
    ) !void {
        const required_arr = switch (required) {
            .array => |a| a.items,
            else => return,
        };

        const obj = switch (value) {
            .object => |o| o,
            else => return,
        };

        for (required_arr) |req| {
            const prop_name = switch (req) {
                .string => |s| s,
                else => continue,
            };

            if (obj.get(prop_name) == null) {
                const prop_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, prop_name });
                try self.addError(prop_path, "Required property missing", null, null);
            }
        }
    }

    fn validateProperties(
        self: *SchemaValidator,
        path: []const u8,
        properties: std.json.Value,
        value: std.json.Value,
    ) !void {
        const props_obj = switch (properties) {
            .object => |o| o,
            else => return,
        };

        const value_obj = switch (value) {
            .object => |o| o,
            else => return,
        };

        var iter = props_obj.iterator();
        while (iter.next()) |entry| {
            const prop_name = entry.key_ptr.*;
            const prop_schema = entry.value_ptr.*;

            if (value_obj.get(prop_name)) |prop_value| {
                const prop_path = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ path, prop_name });
                defer self.allocator.free(prop_path);
                try self.validateValue(prop_path, prop_schema, prop_value);
            }
        }
    }

    fn validateEnum(
        self: *SchemaValidator,
        path: []const u8,
        enum_values: std.json.Value,
        value: std.json.Value,
    ) !void {
        const allowed = switch (enum_values) {
            .array => |a| a.items,
            else => return,
        };

        for (allowed) |allowed_val| {
            if (jsonEquals(allowed_val, value)) return;
        }

        try self.addError(path, "Value not in enum", null, null);
    }

    fn validateNumberConstraints(
        self: *SchemaValidator,
        path: []const u8,
        schema_obj: std.json.ObjectMap,
        value: std.json.Value,
    ) !void {
        const num: f64 = switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            else => return,
        };

        if (schema_obj.get("minimum")) |min_val| {
            const min: f64 = switch (min_val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => return,
            };
            if (num < min) {
                try self.addError(path, "Value below minimum", null, null);
            }
        }

        if (schema_obj.get("maximum")) |max_val| {
            const max: f64 = switch (max_val) {
                .integer => |i| @floatFromInt(i),
                .float => |f| f,
                else => return,
            };
            if (num > max) {
                try self.addError(path, "Value above maximum", null, null);
            }
        }
    }

    fn validateStringConstraints(
        self: *SchemaValidator,
        path: []const u8,
        schema_obj: std.json.ObjectMap,
        value: std.json.Value,
    ) !void {
        const str = switch (value) {
            .string => |s| s,
            else => return,
        };

        if (schema_obj.get("minLength")) |min_len| {
            const min: usize = switch (min_len) {
                .integer => |i| @intCast(i),
                else => return,
            };
            if (str.len < min) {
                try self.addError(path, "String too short", null, null);
            }
        }

        if (schema_obj.get("maxLength")) |max_len| {
            const max: usize = switch (max_len) {
                .integer => |i| @intCast(i),
                else => return,
            };
            if (str.len > max) {
                try self.addError(path, "String too long", null, null);
            }
        }
    }

    fn validateArrayConstraints(
        self: *SchemaValidator,
        path: []const u8,
        schema_obj: std.json.ObjectMap,
        value: std.json.Value,
    ) !void {
        const arr = switch (value) {
            .array => |a| a.items,
            else => return,
        };

        if (schema_obj.get("minItems")) |min_items| {
            const min: usize = switch (min_items) {
                .integer => |i| @intCast(i),
                else => return,
            };
            if (arr.len < min) {
                try self.addError(path, "Array too short", null, null);
            }
        }

        if (schema_obj.get("maxItems")) |max_items| {
            const max: usize = switch (max_items) {
                .integer => |i| @intCast(i),
                else => return,
            };
            if (arr.len > max) {
                try self.addError(path, "Array too long", null, null);
            }
        }

        // Validate items schema
        if (schema_obj.get("items")) |items_schema| {
            for (arr, 0..) |item, i| {
                const item_path = try std.fmt.allocPrint(self.allocator, "{s}[{d}]", .{ path, i });
                defer self.allocator.free(item_path);
                try self.validateValue(item_path, items_schema, item);
            }
        }
    }

    fn addError(
        self: *SchemaValidator,
        path: []const u8,
        message: []const u8,
        expected: ?[]const u8,
        actual: ?[]const u8,
    ) !void {
        try self.errors.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .message = try self.allocator.dupe(u8, message),
            .expected = if (expected) |e| try self.allocator.dupe(u8, e) else null,
            .actual = if (actual) |a| try self.allocator.dupe(u8, a) else null,
        });
    }
};

fn getTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float => "number",
        .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn typeMatches(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "null")) return value == .null;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "integer")) return value == .integer;
    if (std.mem.eql(u8, expected, "number")) return value == .integer or value == .float;
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "array")) return value == .array;
    if (std.mem.eql(u8, expected, "object")) return value == .object;
    return false;
}

fn jsonEquals(a: std.json.Value, b: std.json.Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) return false;

    return switch (a) {
        .null => true,
        .bool => |av| av == b.bool,
        .integer => |av| av == b.integer,
        .float => |av| av == b.float,
        .string => |av| std.mem.eql(u8, av, b.string),
        else => false,
    };
}

test "schema validator type checking" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = SchemaValidator.init(allocator);
    defer validator.deinit();

    // Create schema: { "type": "string" }
    var schema_obj = std.json.ObjectMap.init(allocator);
    defer schema_obj.deinit();
    try schema_obj.put("type", .{ .string = "string" });
    const schema = std.json.Value{ .object = schema_obj };

    // Valid: string value
    var result = try validator.validate(schema, .{ .string = "hello" });
    defer result.deinit();
    try testing.expect(result.valid);

    // Invalid: number value
    var result2 = try validator.validate(schema, .{ .integer = 42 });
    defer result2.deinit();
    try testing.expect(!result2.valid);
    try testing.expectEqual(@as(usize, 1), result2.errors.len);
}

test "schema validator required properties" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var validator = SchemaValidator.init(aa);

    // Create schema with required property
    var schema_obj = std.json.ObjectMap.init(aa);
    var required_arr = std.json.Array.init(aa);
    try required_arr.append(.{ .string = "name" });
    try schema_obj.put("type", .{ .string = "object" });
    try schema_obj.put("required", .{ .array = required_arr });
    const schema = std.json.Value{ .object = schema_obj };

    // Invalid: missing required property
    var value_obj = std.json.ObjectMap.init(aa);
    try value_obj.put("age", .{ .integer = 30 });

    const result = try validator.validate(schema, .{ .object = value_obj });
    try testing.expect(!result.valid);
}

test "schema validator enum" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var validator = SchemaValidator.init(aa);

    // Create schema with enum
    var schema_obj = std.json.ObjectMap.init(aa);
    var enum_arr = std.json.Array.init(aa);
    try enum_arr.append(.{ .string = "red" });
    try enum_arr.append(.{ .string = "green" });
    try enum_arr.append(.{ .string = "blue" });
    try schema_obj.put("enum", .{ .array = enum_arr });
    const schema = std.json.Value{ .object = schema_obj };

    // Valid: value in enum
    const result = try validator.validate(schema, .{ .string = "red" });
    try testing.expect(result.valid);

    // Invalid: value not in enum
    const result2 = try validator.validate(schema, .{ .string = "yellow" });
    try testing.expect(!result2.valid);
}
