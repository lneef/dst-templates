/// The maximum number of sockets one IO instance can have open
pub const sockets_max = 64;

/// The Backlog for a socket marked as listen.
pub const listen_backlog = 64;

/// The longest time one IO tick waits for an event, in milliseconds.
pub const tick_ms = 1;

/// The maximum number of messages queued for sending on one connection.
pub const connection_send_queue_max = 4;

/// The number of ticks between two attempts to connect to the replicas during start.
pub const connect_interval_ticks = 10;
