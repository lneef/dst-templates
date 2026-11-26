const std = @import("std");
const assert = std.debug.assert;

pub const Process = union(enum) { replica: u8, client: u64 };

pub const Header = extern struct {
    client: u64,
    size: u32,
    replica: u8,
    reserved: [3]u8 = @splat(0),

    comptime {
        assert(@sizeOf(Header) == 16);
    }

    pub fn sender(self: Header) Process {
        if (self.client == 0) {
            return .{ .replica = self.replica };
        } else {
            return .{ .client = self.client };
        }
    }
};
