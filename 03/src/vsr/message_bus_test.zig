const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const testing = std.testing;

const message_pool = @import("../message_pool.zig");
const IO = @import("../io/epoll.zig").IO;

const MessageBuffer = message_pool.MessageBuffer;
const MessagePool = message_pool.MessagePool;
const Header = @import("header.zig").Header;
const Process = @import("header.zig").Process;
const Bus = @import("message_bus.zig").MessageBus(IO);

const replica_count = 3;
const client_count = 2;
const requests_max = 10;
const burst_max = 3;
const ticks_max = 10_000;
const port_first = 17_300;
const launch_interval_ns = 50 * std.time.ns_per_ms;

var addresses: [replica_count]IO.Address = undefined;
var clients_done: std.atomic.Value(u32) = .init(0);

const Node = struct {
    bus: Bus,
    pool: *MessagePool,
    from_replicas: u32 = 0,
    from_clients: u32 = 0,
    reply: ?u64 = null,
    from_replica: [replica_count]u8 = @splat(0),

    fn on_message(bus: *Bus, message: *MessageBuffer) void {
        const node: *Node = @fieldParentPtr("bus", bus);
        const header = message.mtod(Header);

        switch (header.sender()) {
            .client => |client| {
                assert(header.size == @sizeOf(Header) + @sizeOf(u64));
                node.from_clients += 1;

                header.client = 0;
                header.replica = bus.process.replica;
                bus.send_to_client(client, message);
            },
            .replica => switch (bus.process) {
                .replica => {
                    assert(header.size == @sizeOf(Header));
                    assert(header.replica < replica_count);
                    node.from_replica[header.replica] += 1;
                    node.from_replicas += 1;
                },
                .client => {
                    assert(header.size == @sizeOf(Header) + @sizeOf(u64));
                    node.reply = message.mtod_offset(u64, @sizeOf(Header)).*;
                },
            },
        }
    }

    fn send_request(node: *Node, replica: u8, payload: u64) void {
        const message = node.pool.alloc() catch unreachable;
        defer node.pool.release(message);

        message.mtod(Header).* = .{
            .client = node.bus.process.client,
            .size = @sizeOf(Header) + @sizeOf(u64),
            .replica = 0,
        };
        message.mtod_offset(u64, @sizeOf(Header)).* = payload;
        message.data_len = @sizeOf(Header) + @sizeOf(u64);
        node.bus.send_to_replica(replica, message);
    }
};

fn run(process: Process) !void {
    const gpa = testing.allocator;

    var io: IO = try .init();
    defer io.deinit();

    const pool = try MessagePool.init(gpa, 32, 256);
    var node: Node = .{
        .bus = try .init(gpa, pool, process, Node.on_message, .{
            .io = &io,
            .addresses = &addresses,
            .clients = client_count,
        }),
        .pool = pool,
    };
    defer node.bus.deinit(gpa);

    try node.bus.start();
    switch (process) {
        .replica => |replica| try run_replica(&node, replica),
        .client => try run_client(&node),
    }
}

fn run_replica(node: *Node, replica: u8) !void {
    for (0..replica_count) |other| {
        if (other != replica) {
            for (0..burst_max) |_| {
                try node.bus.ping_replica(@intCast(other));
            }
        }
    }

    var ticks: u32 = 0;
    while (clients_done.load(.acquire) < client_count or
        node.from_replicas < (replica_count - 1) * burst_max)
    {
        try node.bus.tick();
        ticks += 1;
        if (ticks == ticks_max) return error.Timeout;
    }

    try testing.expectEqual((replica_count - 1) * burst_max, node.from_replicas);
    try testing.expectEqual(client_count * requests_max, node.from_clients);

    for (0..replica_count) |other| {
        try testing.expectEqual(node.from_replica[other], if (other == replica) @as(u8, 0) else burst_max);
    }
}

fn run_client(node: *Node) !void {
    for (0..requests_max) |request| {
        for (0..replica_count) |replica| {
            const payload: u64 = request * replica_count + replica;
            node.reply = null;
            node.send_request(@intCast(replica), payload);

            var ticks: u32 = 0;
            while (node.reply == null) {
                try node.bus.tick();
                ticks += 1;
                if (ticks == ticks_max) return error.Timeout;
            }
            try testing.expectEqual(payload, node.reply.?);
        }
    }
    _ = clients_done.fetchAdd(1, .release);
}

fn run_thread(process: Process) void {
    run(process) catch |err| std.debug.panic("{any}: {}", .{ process, err });
}

test "two clients and three replicas exchange messages" {
    for (&addresses, 0..) |*address, replica| {
        address.* = try .parse("127.0.0.1", @intCast(port_first + replica));
    }

    const processes = [replica_count + client_count]Process{
        .{ .replica = 0 },
        .{ .replica = 1 },
        .{ .replica = 2 },
        .{ .client = 100 },
        .{ .client = 200 },
    };
    var threads: [processes.len]std.Thread = undefined;
    for (processes, &threads) |process, *thread| {
        thread.* = try std.Thread.spawn(.{}, run_thread, .{process});
        _ = linux.nanosleep(&.{ .sec = 0, .nsec = launch_interval_ns }, null);
    }
    for (threads) |thread| {
        thread.join();
    }
}
