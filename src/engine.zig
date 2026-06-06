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

pub const AlarmCondition = enum { above, below, equal };
pub const AlarmState = enum { normal, triggered };

pub const Alarm = struct {
    sensor_name: []const u8,
    threshold: f64,
    condition: AlarmCondition,
    message: []const u8,
    state: AlarmState = .normal,
};

pub const Actuator = struct {
    name: []const u8,
    state: i8, // ternary: -1, 0, +1
};

pub const PlatoEngine = struct {
    alloc: std.mem.Allocator,
    sensors: ArrayList(Sensor),
    alarms: ArrayList(Alarm),
    actuators: ArrayList(Actuator),
    tick_count: u64,
    subscribers: ArrayList([]const u8),

    pub fn init(alloc: std.mem.Allocator, max_history: usize) !PlatoEngine {
        _ = max_history;
        return PlatoEngine{
            .alloc = alloc,
            .sensors = ArrayList(Sensor).init(alloc),
            .alarms = ArrayList(Alarm).init(alloc),
            .actuators = ArrayList(Actuator).init(alloc),
            .tick_count = 0,
            .subscribers = ArrayList([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *PlatoEngine) void {
        for (self.sensors.items) |*s| s.deinit();
        self.sensors.deinit();
        self.alarms.deinit();
        self.actuators.deinit();
        for (self.subscribers.items) |s| self.alloc.free(s);
        self.subscribers.deinit();
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

    pub fn setAlarm(self: *PlatoEngine, sensor_name: []const u8, threshold: f64, condition: AlarmCondition, message: []const u8) void {
        self.alarms.append(.{
            .sensor_name = sensor_name,
            .threshold = threshold,
            .condition = condition,
            .message = message,
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
        // Evaluate alarms — no hidden control flow, pure comparison
        for (self.alarms.items) |*alarm| {
            const val = self.readSensor(alarm.sensor_name);
            const triggered = switch (alarm.condition) {
                .above => val > alarm.threshold,
                .below => val < alarm.threshold,
                .equal => val == alarm.threshold,
            };
            alarm.state = if (triggered) .triggered else .normal;
        }
    }

    pub fn subscribe(self: *PlatoEngine, sensor_name: []const u8) void {
        self.subscribers.append(self.alloc.dupe(u8, sensor_name) catch return) catch {};
    }

    pub fn isAlarmTriggered(self: *PlatoEngine, sensor_name: []const u8) bool {
        for (self.alarms.items) |alarm| {
            if (std.mem.eql(u8, alarm.sensor_name, sensor_name)) {
                return alarm.state == .triggered;
            }
        }
        return false;
    }
};
