const std = @import("std");

const constants = @import("../constants.zig");
const message_pool = @import("../message_pool.zig");

const MessageBuffer = message_pool.MessageBuffer;
const MessagePool = message_pool.MessagePool;
const Header = @import("header.zig").Header;
const Process = @import("header.zig").Process;

pub fn MessageBus(comptime IO: type) type {
    _ = IO;
    return struct {};
}
