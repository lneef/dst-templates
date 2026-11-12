const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const Hashtable = struct {
    const Self = @This();
    const Entry = struct {
        key: u64,
        val: u64,
    };

    slots: []?Entry,

    pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!Self {
        assert(std.math.isPowerOfTwo(capacity));
        const slots = try gpa.alloc(?Entry, capacity);
        @memset(slots, null);
        return .{ .slots = slots };
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }
};

test "init" {
    const gpa = testing.allocator;
    var ht: Hashtable = try .init(gpa, 8);
    defer ht.deinit(gpa);

    try testing.expectEqual(8, ht.slots.len);
    for (ht.slots) |slot| try testing.expectEqual(null, slot);
}
