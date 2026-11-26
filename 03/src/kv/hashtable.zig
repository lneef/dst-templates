const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const List = std.SinglyLinkedList;

pub const Key = u64;
pub const Value = u64;

pub const Hashtable = struct {
    buckets: []List,
    nodes: []Node,
    free: List,
    count: u32,

    const Self = @This();

    const Node = struct {
        key: Key,
        value: Value,
        link: List.Node,

        fn from(link: *List.Node) *Node {
            return @fieldParentPtr("link", link);
        }
    };

    pub fn init(gpa: Allocator, bucket_count: usize, node_count: u32) Allocator.Error!Self {
        assert(std.math.isPowerOfTwo(bucket_count));
        assert(node_count > 0);

        const buckets = try gpa.alloc(List, bucket_count);
        errdefer gpa.free(buckets);
        @memset(buckets, .{ .first = null });

        const nodes = try gpa.alloc(Node, node_count);
        errdefer gpa.free(nodes);

        var free: List = .{ .first = null };
        for (nodes) |*node| {
            node.* = .{ .key = undefined, .value = undefined, .link = .{ .next = null } };
            free.prepend(&node.link);
        }

        const self: Self = .{ .buckets = buckets, .nodes = nodes, .free = free, .count = 0 };
        return self;
    }

    pub fn deinit(self: *Self, gpa: Allocator) void {
        gpa.free(self.buckets);
        gpa.free(self.nodes);
        self.* = undefined;
    }

    pub fn put(self: *Self, key: Key, value: Value) error{OutOfNodes}!void {
        const slot = self.find(key);
        if (slot.*) |link| {
            const node = Node.from(link);
            assert(node.key == key);
            assert(self.count > 0);

            node.value = value;
        } else {
            const link = self.free.popFirst() orelse {
                assert(self.count == self.nodes.len);
                return error.OutOfNodes;
            };
            assert(self.count < self.nodes.len);

            Node.from(link).* = .{ .key = key, .value = value, .link = .{ .next = null } };
            slot.* = link;
            self.count += 1;
        }

        assert(self.count > 0);
        assert(self.count <= self.nodes.len);
        assert(self.get(key).? == value);
    }

    pub fn get(self: *const Self, key: Key) ?Value {
        if (self.find(key).*) |link| {
            const node = Node.from(link);
            assert(node.key == key);
            assert(self.count > 0);

            return node.value;
        } else {
            return null;
        }
    }

    pub fn remove(self: *Self, key: Key) bool {
        const slot = self.find(key);
        if (slot.*) |link| {
            assert(Node.from(link).key == key);
            assert(self.count > 0);

            slot.* = link.next;
            self.free.prepend(link);
            self.count -= 1;

            assert(self.free.first == link);
            assert(self.count < self.nodes.len);
            assert(self.get(key) == null);
            return true;
        } else {
            return false;
        }
    }

    fn find(self: *const Self, key: Key) *?*List.Node {
        assert(self.count <= self.nodes.len);

        const home = self.bucket_index(key);
        var slot = &self.buckets[home].first;
        var chain_length: u32 = 0;
        while (slot.*) |link| : (slot = &link.next) {
            assert(chain_length < self.count);
            chain_length += 1;

            const node = Node.from(link);
            assert(self.bucket_index(node.key) == home);
            if (node.key == key) return slot;
        }

        assert(slot.* == null);
        assert(chain_length <= self.count);
        return slot;
    }

    fn bucket_index(self: *const Self, key: Key) usize {
        assert(std.math.isPowerOfTwo(self.buckets.len));

        const mask = self.buckets.len - 1;
        const index: usize = @intCast(std.hash.int(key) & mask);
        assert(index < self.buckets.len);
        return index;
    }
};
