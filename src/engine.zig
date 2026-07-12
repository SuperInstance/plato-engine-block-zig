const std = @import("std");
const ArrayList = std.ArrayList;

pub const SensorKind = enum {
    temperature,
    humidity,
    co2,
    light,
    pressure,
    motion,
    custom,
};

pub const Sensor = struct {
    name: []const u8,
    kind: SensorKind,
    value: f64,
    history: ArrayList(f64),
    max_history: usize,

    pub fn init(alloc: std.mem.Allocator, name: []const u8, kind: SensorKind, initial: f64, max_history: usize) Sensor {
        return .{
            .name = name,
            .kind = kind,
            .value = initial,
            .history = ArrayList(f64).initCapacity(alloc, max_history) catch unreachable,
            .max_history = max_history,
        };
    }

    pub fn update(self: *Sensor, value: f64) void {
        self.value = value;
        if (self.history.items.len >= self.max_history) {
            _ = self.history.orderedRemove(0);
        }
        self.history.append(value) catch {};
    }

    pub fn deinit(self: *Sensor) void {
        self.history.deinit();
    }
};

// Full set of alarm conditions per PLATO Wire Protocol v0.1 BNF:
// condition ::= name ("<" | ">" | "==" | "!=" | "<=" | ">=") number
pub const AlarmCondition = enum {
    less_than, // <
    greater_than, // >
    equal, // ==
    not_equal, // !=
    less_equal, // <=
    greater_equal, // >=

    pub fn fromString(s: []const u8) ?AlarmCondition {
        if (std.mem.eql(u8, s, "<")) return .less_than;
        if (std.mem.eql(u8, s, ">")) return .greater_than;
        if (std.mem.eql(u8, s, "==")) return .equal;
        if (std.mem.eql(u8, s, "!=")) return .not_equal;
        if (std.mem.eql(u8, s, "<=")) return .less_equal;
        if (std.mem.eql(u8, s, ">=")) return .greater_equal;
        return null;
    }

    pub fn toString(self: AlarmCondition) []const u8 {
        return switch (self) {
            .less_than => "<",
            .greater_than => ">",
            .equal => "==",
            .not_equal => "!=",
            .less_equal => "<=",
            .greater_equal => ">=",
        };
    }

    pub fn evaluate(self: AlarmCondition, value: f64, threshold: f64) bool {
        return switch (self) {
            .less_than => value < threshold,
            .greater_than => value > threshold,
            .equal => value == threshold,
            .not_equal => value != threshold,
            .less_equal => value <= threshold,
            .greater_equal => value >= threshold,
        };
    }
};

pub const AlarmState = enum { idle, active };

pub const Alarm = struct {
    id: []const u8,
    sensor_name: []const u8,
    threshold: f64,
    condition: AlarmCondition,
    message: []const u8,
    state: AlarmState = .idle,
    cooldown_sec: u32 = 30,
    last_triggered: ?i64 = null, // Unix timestamp or null
    cooldown_ticks_remaining: u32 = 0,

    pub fn evaluate(self: *Alarm, value: f64) bool {
        return self.condition.evaluate(value, self.threshold);
    }
};

pub const Actuator = struct {
    name: []const u8,
    state: i8, // ternary: -1, 0, +1
};

/// Per-tick snapshot for spec-compliant history buffer.
pub const TickSnapshot = struct {
    t: i64, // Unix timestamp (seconds)
    seq: u64,
    sensor_values: ArrayList(f64),

    pub fn deinit(self: *TickSnapshot) void {
        self.sensor_values.deinit();
    }
};

pub const PlatoEngine = struct {
    alloc: std.mem.Allocator,
    sensors: ArrayList(Sensor),
    alarms: ArrayList(Alarm),
    actuators: ArrayList(Actuator),
    tick_count: u64,
    subscribers: ArrayList([]const u8),
    tick_snapshots: ArrayList(TickSnapshot),
    max_history: usize,
    tick_hz: f64,
    room_id: []const u8,

    pub fn init(alloc: std.mem.Allocator, max_history: usize) !PlatoEngine {
        return PlatoEngine{
            .alloc = alloc,
            .sensors = ArrayList(Sensor).init(alloc),
            .alarms = ArrayList(Alarm).init(alloc),
            .actuators = ArrayList(Actuator).init(alloc),
            .tick_count = 0,
            .subscribers = ArrayList([]const u8).init(alloc),
            .tick_snapshots = ArrayList(TickSnapshot).init(alloc),
            .max_history = max_history,
            .tick_hz = 0.2,
            .room_id = "engine_room",
        };
    }

    pub fn deinit(self: *PlatoEngine) void {
        for (self.sensors.items) |*s| s.deinit();
        self.sensors.deinit();
        self.alarms.deinit();
        self.actuators.deinit();
        for (self.subscribers.items) |s| self.alloc.free(s);
        self.subscribers.deinit();
        for (self.tick_snapshots.items) |*ts| ts.deinit();
        self.tick_snapshots.deinit();
    }

    pub fn addSensor(self: *PlatoEngine, name: []const u8, kind: SensorKind, initial: f64) void {
        const s = Sensor.init(self.alloc, name, kind, initial, 256);
        self.sensors.append(s) catch {};
    }

    pub fn updateSensor(self: *PlatoEngine, name: []const u8, value: f64) void {
        for (self.sensors.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) {
                s.update(value);
                return;
            }
        }
    }

    pub fn readSensor(self: *PlatoEngine, name: []const u8) f64 {
        for (self.sensors.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s.value;
        }
        return 0.0;
    }

    pub fn getHistory(self: *PlatoEngine, name: []const u8) ArrayList(f64) {
        for (self.sensors.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s.history;
        }
        return ArrayList(f64).init(self.alloc);
    }

    /// Set an alarm with full parameters.
    pub fn setAlarm(self: *PlatoEngine, sensor_name: []const u8, threshold: f64, condition: AlarmCondition, message: []const u8) void {
        self.alarms.append(.{
            .id = sensor_name,
            .sensor_name = sensor_name,
            .threshold = threshold,
            .condition = condition,
            .message = message,
        }) catch {};
    }

    /// Set an alarm with full id and cooldown (for runtime `alarm set` command).
    pub fn setAlarmFull(self: *PlatoEngine, id: []const u8, sensor_name: []const u8, threshold: f64, condition: AlarmCondition, cooldown_sec: u32) void {
        // Check if alarm with same id exists — replace it
        for (self.alarms.items) |*a| {
            if (std.mem.eql(u8, a.id, id)) {
                a.sensor_name = sensor_name;
                a.threshold = threshold;
                a.condition = condition;
                a.cooldown_sec = cooldown_sec;
                return;
            }
        }
        self.alarms.append(.{
            .id = id,
            .sensor_name = sensor_name,
            .threshold = threshold,
            .condition = condition,
            .message = "",
            .cooldown_sec = cooldown_sec,
        }) catch {};
    }

    pub fn addActuator(self: *PlatoEngine, name: []const u8, state: i8) void {
        self.actuators.append(.{ .name = name, .state = state }) catch {};
    }

    pub fn setActuator(self: *PlatoEngine, name: []const u8, state: i8) void {
        for (self.actuators.items) |*a| {
            if (std.mem.eql(u8, a.name, name)) {
                a.state = state;
                return;
            }
        }
    }

    pub fn tick(self: *PlatoEngine) void {
        self.tick_count += 1;
        const now: i64 = std.time.timestamp();

        // Record per-tick snapshot for history
        var snapshot_values = ArrayList(f64).initCapacity(self.alloc, self.sensors.items.len) catch {
            // Still evaluate alarms even if snapshot fails
            self.evaluateAlarms(now);
            return;
        };
        for (self.sensors.items) |s| {
            snapshot_values.append(s.value) catch {};
        }
        // Ring buffer: remove oldest if at capacity
        if (self.tick_snapshots.items.len >= self.max_history) {
            var old = self.tick_snapshots.orderedRemove(0);
            old.deinit();
        }
        self.tick_snapshots.append(.{
            .t = now,
            .seq = self.tick_count,
            .sensor_values = snapshot_values,
        }) catch {};

        // Evaluate alarms
        self.evaluateAlarms(now);
    }

    fn evaluateAlarms(self: *PlatoEngine, now: i64) void {
        for (self.alarms.items) |*alarm| {
            // Decrement cooldown
            if (alarm.cooldown_ticks_remaining > 0) {
                alarm.cooldown_ticks_remaining -= 1;
            }

            const val = self.readSensor(alarm.sensor_name);
            const triggered = alarm.evaluate(val);

            if (triggered and alarm.cooldown_ticks_remaining == 0) {
                alarm.state = .active;
                alarm.last_triggered = now;
                // Convert cooldown_sec to ticks (approximate: 1 tick = 1/tick_hz seconds)
                const ticks_per_sec = if (self.tick_hz > 0) self.tick_hz else 0.2;
                alarm.cooldown_ticks_remaining = @as(u32, @intFromFloat(@as(f64, @floatFromInt(alarm.cooldown_sec)) * ticks_per_sec));
            } else if (!triggered) {
                alarm.state = .idle;
            }
        }
    }

    pub fn subscribe(self: *PlatoEngine, sensor_name: []const u8) void {
        self.subscribers.append(self.alloc.dupe(u8, sensor_name) catch return) catch {};
    }

    pub fn isAlarmTriggered(self: *PlatoEngine, sensor_name: []const u8) bool {
        for (self.alarms.items) |alarm| {
            if (std.mem.eql(u8, alarm.sensor_name, sensor_name)) {
                return alarm.state == .active;
            }
        }
        return false;
    }

    /// Get the last Unix timestamp from the most recent tick.
    pub fn lastTimestamp(self: *const PlatoEngine) i64 {
        if (self.tick_snapshots.items.len == 0) return 0;
        return self.tick_snapshots.items[self.tick_snapshots.items.len - 1].t;
    }
};
