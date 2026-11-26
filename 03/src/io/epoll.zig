const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const constants = @import("../constants.zig");

pub const IO = struct {
    epoll_fd: linux.fd_t,

    slots: [constants.sockets_max]Slot,

    pub const socket_t = u32;
    pub const Address = std.Io.net.IpAddress;

    pub const Error = error{
        AddressInUse,
        BrokenPipe,
        ConnectionRefused,
        ConnectionResetByPeer,
        SocketLimitExceeded,
        Unexpected,
    };
    pub const AcceptError = Error;
    pub const ConnectError = Error;
    pub const RecvError = Error;
    pub const SendError = Error;

    pub const Completion = struct {
        context: ?*anyopaque = null,
        callback: ?Callback = null,
        operation: Operation = .none,

        const Callback = *const fn (
            context: *anyopaque,
            completion: *Completion,
            result: Error!usize,
        ) void;

        const Operation = union(enum) {
            none,
            accept,
            connect: linux.sockaddr.in,
            recv: []u8,
            send: []const u8,
        };

        fn complete(completion: *Completion, result: Error!usize) void {
            assert(completion.operation != .none);

            completion.callback.?(completion.context.?, completion, result);
        }
    };

    const Slot = struct {
        fd: ?linux.fd_t = null,
        interest: u32 = 0,
        accept: ?*Completion = null,
        recv: ?*Completion = null,
        send: ?*Completion = null,
    };

    comptime {
        assert(constants.sockets_max > 0);
        assert(constants.sockets_max <= std.math.maxInt(socket_t));
        assert(constants.listen_backlog > 0);
        // A negative timeout makes epoll_wait block until an event arrives
        assert(constants.tick_ms >= 0);
    }

    pub fn init() !IO {
        const epoll_fd = try check(linux.epoll_create1(0));
        return .{ .epoll_fd = @intCast(epoll_fd), .slots = @splat(.{}) };
    }

    pub fn deinit(self: *IO) void {
        for (&self.slots) |*slot| {
            assert(slot.fd == null);
        }
        fd_close(self.epoll_fd);
    }

    pub fn listen(self: *IO, address: Address) !socket_t {
        const fd = try socket_tcp();
        errdefer fd_close(fd);

        try option_enable(fd, .{ .level = linux.SOL.SOCKET, .option = linux.SO.REUSEADDR });
        const sockaddr = try sockaddr_in(address);
        _ = try check(linux.bind(fd, @ptrCast(&sockaddr), @sizeOf(linux.sockaddr.in)));
        _ = try check(linux.listen(fd, constants.listen_backlog));
        return self.socket_add(fd);
    }

    pub fn connect(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, ConnectError!void) void,
        completion: *Completion,
        address: Address,
    ) !socket_t {
        const fd = try socket_tcp();
        errdefer fd_close(fd);

        const sockaddr = try sockaddr_in(address);
        const socket = try self.stream_add(fd);
        assert(self.slots[socket].recv == null);

        completion.* = .{
            .context = context,
            .callback = erase_types(Context, void, callback),
            .operation = .{ .connect = sockaddr },
        };
        self.slots[socket].recv = completion;
        return socket;
    }

    pub fn accept(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, AcceptError!socket_t) void,
        completion: *Completion,
        listen_socket: socket_t,
    ) void {
        assert(self.slots[listen_socket].fd != null);
        assert(self.slots[listen_socket].accept == null);

        completion.* = .{
            .context = context,
            .callback = erase_types(Context, socket_t, callback),
            .operation = .accept,
        };
        self.slots[listen_socket].accept = completion;
    }

    pub fn close_socket(self: *IO, socket: socket_t) void {
        fd_close(self.slots[socket].fd.?);
        self.slots[socket] = .{};
    }

    pub fn recv(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, RecvError!usize) void,
        completion: *Completion,
        socket: socket_t,
        buffer: []u8,
    ) void {
        assert(self.slots[socket].fd != null);
        assert(self.slots[socket].recv == null);
        assert(buffer.len > 0);

        completion.* = .{
            .context = context,
            .callback = erase_types(Context, usize, callback),
            .operation = .{ .recv = buffer },
        };
        self.slots[socket].recv = completion;
    }

    pub fn send(
        self: *IO,
        comptime Context: type,
        context: Context,
        comptime callback: fn (Context, *Completion, SendError!usize) void,
        completion: *Completion,
        socket: socket_t,
        bytes: []const u8,
    ) void {
        assert(self.slots[socket].fd != null);
        assert(self.slots[socket].send == null);
        assert(bytes.len > 0);

        completion.* = .{
            .context = context,
            .callback = erase_types(Context, usize, callback),
            .operation = .{ .send = bytes },
        };
        self.slots[socket].send = completion;
    }

    pub fn tick(self: *IO) !void {
        for (0..constants.sockets_max) |socket| {
            try self.interest_update(@intCast(socket));
        }

        var events: [constants.sockets_max]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(self.epoll_fd, &events, events.len, constants.tick_ms);
        const events_count = switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .INTR => 0,
            else => return error.Unexpected,
        };
        assert(events_count <= events.len);

        for (events[0..events_count]) |event| {
            const socket: socket_t = @intCast(event.data.u64);
            const slot = &self.slots[socket];

            const failed = (event.events & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0;
            const readable = failed or (event.events & linux.EPOLL.IN) != 0;
            const writable = failed or (event.events & linux.EPOLL.OUT) != 0;

            if (readable) {
                self.accept_ready(slot);
                recv_ready(slot);
            }
            if (writable) {
                connect_ready(slot);
                send_ready(slot);
            }
        }
    }

    fn interest_update(self: *IO, socket: socket_t) !void {
        const slot = &self.slots[socket];

        var interest: u32 = 0;
        if (slot.accept != null) interest |= linux.EPOLL.IN;
        if (slot.recv) |completion| {
            interest |= switch (completion.operation) {
                .connect => linux.EPOLL.OUT,
                .recv => linux.EPOLL.IN,
                .none, .accept, .send => unreachable,
            };
        }
        if (slot.send != null) interest |= linux.EPOLL.OUT;

        if (interest != slot.interest) {
            var event: linux.epoll_event = .{ .events = interest, .data = .{ .u64 = socket } };
            _ = try check(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, slot.fd.?, &event));
            slot.interest = interest;
        }
    }

    fn accept_ready(self: *IO, slot: *Slot) void {
        if (slot.accept) |completion| {
            assert(completion.operation == .accept);

            const rc = linux.accept4(slot.fd.?, null, null, linux.SOCK.NONBLOCK);
            switch (linux.errno(rc)) {
                .AGAIN => {},
                else => {
                    slot.accept = null;
                    completion.complete(self.accepted(rc));
                },
            }
        }
    }

    fn connect_ready(slot: *Slot) void {
        if (slot.recv) |completion| {
            if (completion.operation == .connect) {
                const sockaddr = &completion.operation.connect;
                const rc = linux.connect(slot.fd.?, sockaddr, @sizeOf(linux.sockaddr.in));
                switch (linux.errno(rc)) {
                    .INPROGRESS, .ALREADY => {},
                    else => {
                        slot.recv = null;
                        completion.complete(check(rc));
                    },
                }
            }
        }
    }

    fn recv_ready(slot: *Slot) void {
        if (slot.recv) |completion| {
            if (completion.operation == .recv) {
                const buffer = completion.operation.recv;
                const rc = linux.recvfrom(slot.fd.?, buffer.ptr, buffer.len, 0, null, null);
                switch (linux.errno(rc)) {
                    .AGAIN => {},
                    else => {
                        slot.recv = null;
                        completion.complete(transferred(rc));
                    },
                }
            }
        }
    }

    fn send_ready(slot: *Slot) void {
        if (slot.send) |completion| {
            const bytes = completion.operation.send;
            // NOSIGNAL makes send on a connection that the peer has closed fail with PIPE.
            const flags = linux.MSG.NOSIGNAL;
            const rc = linux.sendto(slot.fd.?, bytes.ptr, bytes.len, flags, null, 0);
            switch (linux.errno(rc)) {
                .AGAIN => {},
                else => {
                    slot.send = null;
                    completion.complete(transferred(rc));
                },
            }
        }
    }

    fn accepted(self: *IO, rc: usize) AcceptError!usize {
        const fd: linux.fd_t = @intCast(try check(rc));
        errdefer fd_close(fd);

        return try self.stream_add(fd);
    }

    fn stream_add(self: *IO, fd: linux.fd_t) Error!socket_t {
        try option_enable(fd, .{ .level = linux.IPPROTO.TCP, .option = linux.TCP.NODELAY });
        return self.socket_add(fd);
    }

    fn socket_add(self: *IO, fd: linux.fd_t) Error!socket_t {
        assert(fd >= 0);

        const socket = self.slot_find_free() orelse return error.SocketLimitExceeded;
        var event: linux.epoll_event = .{ .events = 0, .data = .{ .u64 = socket } };
        _ = try check(linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event));
        assert(self.slots[socket].fd == null);
        self.slots[socket] = .{ .fd = fd };
        return socket;
    }

    fn slot_find_free(self: *const IO) ?socket_t {
        for (&self.slots, 0..) |*slot, index| {
            if (slot.fd == null) return @intCast(index);
        }
        return null;
    }

    fn erase_types(
        comptime Context: type,
        comptime Result: type,
        comptime callback: fn (Context, *Completion, Error!Result) void,
    ) Completion.Callback {
        return &struct {
            fn erased(context: *anyopaque, completion: *Completion, result: Error!usize) void {
                if (result) |value| {
                    const typed: Result = if (Result == void) {} else @intCast(value);
                    callback(@ptrCast(@alignCast(context)), completion, typed);
                } else |err| {
                    callback(@ptrCast(@alignCast(context)), completion, err);
                }
            }
        }.erased;
    }

    fn fd_close(fd: linux.fd_t) void {
        const rc = linux.close(fd);
        assert(linux.errno(rc) != .BADF);
    }

    fn socket_tcp() Error!linux.fd_t {
        const flags = linux.SOCK.STREAM | linux.SOCK.NONBLOCK;
        return @intCast(try check(linux.socket(linux.AF.INET, flags, linux.IPPROTO.TCP)));
    }

    fn option_enable(fd: linux.fd_t, options: struct { level: i32, option: u32 }) Error!void {
        try option_set(fd, .{ .level = options.level, .option = options.option, .value = 1 });
    }

    fn option_set(
        fd: linux.fd_t,
        options: struct { level: i32, option: u32, value: u32 },
    ) Error!void {
        _ = try check(linux.setsockopt(
            fd,
            options.level,
            options.option,
            std.mem.asBytes(&options.value),
            @sizeOf(u32),
        ));
    }

    fn sockaddr_in(address: Address) !linux.sockaddr.in {
        return switch (address) {
            .ip4 => |ip4| .{
                .port = std.mem.nativeToBig(u16, ip4.port),
                .addr = @bitCast(ip4.bytes),
            },
            .ip6 => error.AddressFamilyUnsupported,
        };
    }

    fn transferred(rc: usize) Error!usize {
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .CONNRESET => error.ConnectionResetByPeer,
            .PIPE => error.BrokenPipe,
            else => error.Unexpected,
        };
    }

    fn check(rc: usize) Error!usize {
        return switch (linux.errno(rc)) {
            .SUCCESS => rc,
            .ADDRINUSE => error.AddressInUse,
            .CONNREFUSED => error.ConnectionRefused,
            else => error.Unexpected,
        };
    }
};
