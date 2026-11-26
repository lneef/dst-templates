const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Hashtable = @import("hashtable.zig").Hashtable;
const wire = @import("wire.zig");

pub const StateMachine = struct {
    table: Hashtable,

    const Self = @This();

    pub const Operation = wire.Operation;

    pub fn init(gpa: Allocator, bucket_count: usize, node_count: u32) Allocator.Error!Self {
        return .{ .table = try .init(gpa, bucket_count, node_count) };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        self.table.deinit(gpa);
        self.* = undefined;
    }

    pub fn input_valid(operation: Operation, input: []const u8) bool {
        return input.len == operation.event_size();
    }

    pub fn apply(self: *Self, operation: Operation, input: []const u8, output: []u8) usize {
        assert(input_valid(operation, input));

        return switch (operation) {
            inline else => |operation_comptime| self.apply_event(
                operation_comptime,
                input,
                output,
            ),
        };
    }

    fn apply_event(
        self: *Self,
        comptime operation: Operation,
        input: []const u8,
        output: []u8,
    ) usize {
        const Event = operation.EventType();
        const Result = operation.ResultType();
        assert(input.len == @sizeOf(Event));
        assert(output.len >= @sizeOf(Result));

        const event = std.mem.bytesToValue(Event, input);
        const result: Result = switch (operation) {
            .put => self.apply_put(event),
            .get => self.apply_get(event),
            .remove => self.apply_remove(event),
        };
        assert(result.valid());

        @memcpy(output[0..@sizeOf(Result)], std.mem.asBytes(&result));
        return @sizeOf(Result);
    }

    fn apply_put(self: *Self, put: wire.Put) wire.PutResult {
        if (self.table.put(put.key, put.value)) {
            return .{ .status = .ok };
        } else |err| switch (err) {
            error.OutOfNodes => return .{ .status = .full },
        }
    }

    fn apply_get(self: *const Self, get: wire.Get) wire.GetResult {
        if (self.table.get(get.key)) |value| {
            return .{ .status = .ok, .value = value };
        } else {
            return .{ .status = .not_found };
        }
    }

    fn apply_remove(self: *Self, remove: wire.Remove) wire.RemoveResult {
        if (self.table.remove(remove.key)) {
            return .{ .status = .ok };
        } else {
            return .{ .status = .not_found };
        }
    }
};
