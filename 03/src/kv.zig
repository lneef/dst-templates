const hashtable = @import("kv/hashtable.zig");
const wire = @import("kv/wire.zig");

pub const StateMachine = @import("kv/state_machine.zig").StateMachine;

pub const Hashtable = hashtable.Hashtable;
pub const Key = hashtable.Key;
pub const Value = hashtable.Value;

pub const Operation = wire.Operation;

pub const Put = wire.Put;
pub const Get = wire.Get;
pub const Remove = wire.Remove;

pub const PutResult = wire.PutResult;
pub const PutStatus = wire.PutStatus;
pub const GetResult = wire.GetResult;
pub const GetStatus = wire.GetStatus;
pub const RemoveResult = wire.RemoveResult;
pub const RemoveStatus = wire.RemoveStatus;

test {
    _ = @import("kv/hashtable.zig");
    _ = @import("kv/state_machine.zig");
    _ = @import("kv/wire.zig");
}
