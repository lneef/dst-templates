const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const Key = @import("hashtable.zig").Key;
const Value = @import("hashtable.zig").Value;

comptime {
    assert(builtin.cpu.arch.endian() == .little);
}

pub const Operation = enum(u8) {
    put = 1,
    get = 2,
    remove = 3,

    pub fn EventType(comptime operation: Operation) type {
        return switch (operation) {
            .put => Put,
            .get => Get,
            .remove => Remove,
        };
    }

    pub fn ResultType(comptime operation: Operation) type {
        return switch (operation) {
            .put => PutResult,
            .get => GetResult,
            .remove => RemoveResult,
        };
    }

    pub inline fn event_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.EventType()),
        };
    }

    pub inline fn result_size(operation: Operation) u32 {
        return switch (operation) {
            inline else => |operation_comptime| @sizeOf(operation_comptime.ResultType()),
        };
    }
};

pub const Put = extern struct {
    key: Key,
    value: Value,

    comptime {
        assert(@sizeOf(Put) == 16);
    }
};

pub const Get = extern struct {
    key: Key,

    comptime {
        assert(@sizeOf(Get) == 8);
    }
};

pub const Remove = extern struct {
    key: Key,

    comptime {
        assert(@sizeOf(Remove) == 8);
    }
};

pub const PutStatus = enum(u8) { ok = 1, full = 2, _ };

pub const PutResult = extern struct {
    status: PutStatus,
    reserved: [7]u8 = @splat(0),

    comptime {
        assert(@sizeOf(PutResult) == 8);
    }

    pub fn valid(self: PutResult) bool {
        if (!std.mem.allEqual(u8, &self.reserved, 0)) return false;
        return switch (self.status) {
            .ok, .full => true,
            _ => false,
        };
    }
};

pub const GetStatus = enum(u8) { ok = 1, not_found = 2, _ };

pub const GetResult = extern struct {
    value: Value = 0,
    status: GetStatus,
    reserved: [7]u8 = @splat(0),

    comptime {
        assert(@sizeOf(GetResult) == 16);
    }

    pub fn valid(self: GetResult) bool {
        if (!std.mem.allEqual(u8, &self.reserved, 0)) return false;
        return switch (self.status) {
            .ok => true,
            .not_found => self.value == 0,
            _ => false,
        };
    }
};

pub const RemoveStatus = enum(u8) { ok = 1, not_found = 2, _ };

pub const RemoveResult = extern struct {
    status: RemoveStatus,
    reserved: [7]u8 = @splat(0),

    comptime {
        assert(@sizeOf(RemoveResult) == 8);
    }

    pub fn valid(self: RemoveResult) bool {
        if (!std.mem.allEqual(u8, &self.reserved, 0)) return false;
        return switch (self.status) {
            .ok, .not_found => true,
            _ => false,
        };
    }
};
