/// Text protocol parser and JSON response formatter for Plato Engine Block.
/// Commands: tick, history N, actuator NAME STATE, alarm list, alarm set,
///            subscribe, unsubscribe, help, quit
/// All responses are JSON per PLATO Wire Protocol v0.1.
const std = @import("std");
const engine = @import("engine.zig");

pub const Command = union(enum) {
    tick,
    history: usize,
    actuator: struct { name: []const u8, state: i8 },
    alarm_list,
    alarm_set: struct {
        id: []const u8,
        sensor_name: []const u8,
        condition: []const u8,
        threshold: f64,
        cooldown_sec: u32,
    },
    subscribe,
    unsubscribe,
    help,
    quit,
    unknown: []const u8,
};

/// Parse a text command string into a typed Command.
/// No allocations — works entirely on the input slice.
pub fn parse(input: []const u8) Command {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return .{ .unknown = "" };

    if (std.mem.eql(u8, trimmed, "tick")) return .tick;
    if (std.mem.eql(u8, trimmed, "help")) return .help;
    if (std.mem.eql(u8, trimmed, "quit")) return .quit;
    if (std.mem.eql(u8, trimmed, "subscribe")) return .subscribe;
    if (std.mem.eql(u8, trimmed, "unsubscribe")) return .unsubscribe;

    if (std.mem.startsWith(u8, trimmed, "history")) {
        const arg = std.mem.trimLeft(u8, trimmed["history".len..], " ");
        const n = std.fmt.parseInt(usize, arg, 10) catch 10;
        return .{ .history = n };
    }

    if (std.mem.startsWith(u8, trimmed, "actuator")) {
        const rest = std.mem.trimLeft(u8, trimmed["actuator".len..], " ");
        if (std.mem.indexOfScalar(u8, rest, ' ')) |space_idx| {
            const name = rest[0..space_idx];
            const state_str = std.mem.trimLeft(u8, rest[space_idx..], " ");
            const state = std.fmt.parseInt(i8, state_str, 10) catch 0;
            return .{ .actuator = .{ .name = name, .state = state } };
        }
        return .{ .actuator = .{ .name = rest, .state = 0 } };
    }

    // alarm list
    if (std.mem.eql(u8, trimmed, "alarm list")) return .alarm_list;

    // alarm set <id> <sensor> <op> <threshold> <cooldown>
    // e.g. "alarm set overheat coolant_temp_c > 95 30"
    if (std.mem.startsWith(u8, trimmed, "alarm set")) {
        const rest = std.mem.trimLeft(u8, trimmed["alarm set".len..], " ");
        // Parse: id sensor op threshold cooldown
        var parts = std.mem.tokenizeAny(u8, rest, " \t");
        const id = parts.next() orelse return .{ .unknown = "alarm set: missing id" };
        const sensor = parts.next() orelse return .{ .unknown = "alarm set: missing sensor" };
        const op = parts.next() orelse return .{ .unknown = "alarm set: missing condition" };
        const thresh_str = parts.next() orelse return .{ .unknown = "alarm set: missing threshold" };
        const cd_str = parts.next() orelse return .{ .unknown = "alarm set: missing cooldown" };

        // Validate operator
        if (engine.AlarmCondition.fromString(op) == null) {
            return .{ .unknown = "alarm set: invalid condition operator" };
        }

        const threshold = std.fmt.parseFloat(f64, thresh_str) catch
            return .{ .unknown = "alarm set: invalid threshold" };
        const cooldown = std.fmt.parseInt(u32, cd_str, 10) catch
            return .{ .unknown = "alarm set: invalid cooldown" };

        return .{ .alarm_set = .{
            .id = id,
            .sensor_name = sensor,
            .condition = op,
            .threshold = threshold,
            .cooldown_sec = cooldown,
        } };
    }

    // Legacy bare actuator command: "pump 1"
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space_idx| {
        const name = trimmed[0..space_idx];
        const state_str = std.mem.trimLeft(u8, trimmed[space_idx..], " ");
        if (std.fmt.parseInt(i8, state_str, 10)) |state| {
            return .{ .actuator = .{ .name = name, .state = state } };
        } else |_| {}
    }

    return .{ .unknown = trimmed };
}

// ─── JSON Response Formatters (PLATO Wire Protocol v0.1) ──────

/// Format a welcome message as JSON.
pub fn formatWelcome(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.print("{{\"type\":\"welcome\",\"room_id\":\"{s}\",\"tick_hz\":{d:.4},\"sensors\":[", .{ eng.room_id, eng.tick_hz });
    for (eng.sensors.items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{s.name});
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

/// Format a tick response as JSON with real Unix timestamp.
pub fn formatTick(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    const t = eng.lastTimestamp();
    try w.print("{{\"type\":\"tick\",\"t\":{d}.0,\"seq\":{d},\"data\":{{", .{ t, eng.tick_count });
    for (eng.sensors.items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":{d:.4}", .{ s.name, s.value });
    }
    try w.writeAll("}}");

    return buf.toOwnedSlice();
}

/// Format a history response as JSON using per-tick snapshots.
pub fn formatHistory(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine, n: usize) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    const available = eng.tick_snapshots.items.len;
    const count = @min(n, available);

    try w.print("{{\"type\":\"history\",\"count\":{d},\"ticks\":[", .{count});

    // Return in chronological order (oldest first). Snapshots are stored oldest→newest.
    const start: usize = if (available > count) available - count else 0;
    var written: usize = 0;
    var i: usize = start;
    while (i < available) : (i += 1) {
        const snap = eng.tick_snapshots.items[i];
        if (written > 0) try w.writeAll(",");
        try w.print("{{\"t\":{d}.0,\"seq\":{d},\"data\":{{", .{ snap.t, snap.seq });
        for (snap.sensor_values.items, 0..) |val, si| {
            if (si > 0) try w.writeAll(",");
            if (si < eng.sensors.items.len) {
                try w.print("\"{s}\":{d:.4}", .{ eng.sensors.items[si].name, val });
            }
        }
        try w.writeAll("}}");
        written += 1;
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

/// Format an ack response for actuator commands.
pub fn formatAck(alloc: std.mem.Allocator, name: []const u8, value: f64) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"type\":\"ack\",\"command\":\"actuator\",\"name\":\"{s}\",\"value\":{d:.4}}}",
        .{ name, value });
}

/// Format an alarm_set ack response.
pub fn formatAlarmSetAck(alloc: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"type\":\"ack\",\"command\":\"alarm_set\",\"id\":\"{s}\"}}",
        .{id});
}

/// Format an alarm_list response with full alarm details per spec.
pub fn formatAlarmList(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.writeAll("{\"type\":\"alarm_list\",\"alarms\":[");
    for (eng.alarms.items, 0..) |alarm, i| {
        if (i > 0) try w.writeAll(",");
        const state_str: []const u8 = if (alarm.state == .active) "active" else "idle";
        try w.print(
            "{{\"id\":\"{s}\",\"condition\":\"{s} {s} {d}\",\"cooldown_sec\":{d}",
            .{ alarm.id, alarm.sensor_name, alarm.condition.toString(), alarm.threshold, alarm.cooldown_sec },
        );
        if (alarm.last_triggered) |lt| {
            try w.print(",\"last_triggered\":{d}.0", .{lt});
        } else {
            try w.writeAll(",\"last_triggered\":null");
        }
        try w.print(",\"state\":\"{s}\"}}", .{state_str});
    }
    try w.writeAll("]}");

    return buf.toOwnedSlice();
}

/// Format an error response.
pub fn formatError(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"type\":\"error\",\"message\":\"{s}\"}}",
        .{message});
}

/// Format subscribed response.
pub fn formatSubscribed(alloc: std.mem.Allocator, tick_hz: f64) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"type\":\"subscribed\",\"tick_hz\":{d:.4}}}",
        .{tick_hz});
}

/// Format unsubscribed response.
pub fn formatUnsubscribed(alloc: std.mem.Allocator) ![]u8 {
    return alloc.dupe(u8, "{\"type\":\"unsubscribed\"}");
}

/// Format help response.
pub fn formatHelp(alloc: std.mem.Allocator) ![]u8 {
    return alloc.dupe(u8,
        "{\"type\":\"help\",\"commands\":[\"tick\",\"history [N]\",\"actuator <name> <value>\",\"alarm list\",\"alarm set <id> <condition> <cooldown>\",\"subscribe\",\"unsubscribe\",\"help\",\"quit\"]}");
}

/// Format bye response.
pub fn formatBye(alloc: std.mem.Allocator) ![]u8 {
    return alloc.dupe(u8, "{\"type\":\"bye\"}");
}

// ─── Tests ──────────────────────────────────────────────────────

test "parse tick" {
    const cmd = parse("tick");
    try std.testing.expect(cmd == .tick);
}

test "parse history 5" {
    const cmd = parse("history 5");
    try std.testing.expect(cmd == .history);
    try std.testing.expectEqual(@as(usize, 5), cmd.history);
}

test "parse history 20" {
    const cmd = parse("history 20");
    try std.testing.expectEqual(@as(usize, 20), cmd.history);
}

test "parse actuator pump 1" {
    const cmd = parse("actuator pump 1");
    try std.testing.expect(cmd == .actuator);
    try std.testing.expectEqualSlices(u8, "pump", cmd.actuator.name);
    try std.testing.expectEqual(@as(i8, 1), cmd.actuator.state);
}

test "parse actuator valve -1" {
    const cmd = parse("actuator valve -1");
    try std.testing.expectEqualSlices(u8, "valve", cmd.actuator.name);
    try std.testing.expectEqual(@as(i8, -1), cmd.actuator.state);
}

test "parse subscribe" {
    const cmd = parse("subscribe");
    try std.testing.expect(cmd == .subscribe);
}

test "parse unsubscribe" {
    const cmd = parse("unsubscribe");
    try std.testing.expect(cmd == .unsubscribe);
}

test "parse help" {
    const cmd = parse("help");
    try std.testing.expect(cmd == .help);
}

test "parse quit" {
    const cmd = parse("quit");
    try std.testing.expect(cmd == .quit);
}

test "parse unknown command" {
    const cmd = parse("foobar");
    try std.testing.expect(cmd == .unknown);
}

test "parse with whitespace" {
    const cmd = parse("  tick  ");
    try std.testing.expect(cmd == .tick);
}

test "parse alarm list" {
    const cmd = parse("alarm list");
    try std.testing.expect(cmd == .alarm_list);
}

test "parse alarm set" {
    const cmd = parse("alarm set overheat coolant_temp_c > 95 30");
    try std.testing.expect(cmd == .alarm_set);
    try std.testing.expectEqualSlices(u8, "overheat", cmd.alarm_set.id);
    try std.testing.expectEqualSlices(u8, "coolant_temp_c", cmd.alarm_set.sensor_name);
    try std.testing.expectEqualSlices(u8, ">", cmd.alarm_set.condition);
    try std.testing.expectEqual(@as(f64, 95.0), cmd.alarm_set.threshold);
    try std.testing.expectEqual(@as(u32, 30), cmd.alarm_set.cooldown_sec);
}

test "parse alarm set with <= operator" {
    const cmd = parse("alarm set low_pressure pressure <= 50 60");
    try std.testing.expect(cmd == .alarm_set);
    try std.testing.expectEqualSlices(u8, "<=", cmd.alarm_set.condition);
}

test "format error" {
    const alloc = std.testing.allocator;
    const result = try formatError(alloc, "test error");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test error") != null);
}

test "format subscribed" {
    const alloc = std.testing.allocator;
    const result = try formatSubscribed(alloc, 0.2);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"subscribed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "0.2") != null);
}

test "format bye" {
    const alloc = std.testing.allocator;
    const result = try formatBye(alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"bye\"") != null);
}

test "format alarm set ack" {
    const alloc = std.testing.allocator;
    const result = try formatAlarmSetAck(alloc, "overheat");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"ack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"command\":\"alarm_set\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "overheat") != null);
}

test "AlarmCondition fromString all operators" {
    try std.testing.expect(engine.AlarmCondition.fromString("<") != null);
    try std.testing.expect(engine.AlarmCondition.fromString(">") != null);
    try std.testing.expect(engine.AlarmCondition.fromString("==") != null);
    try std.testing.expect(engine.AlarmCondition.fromString("!=") != null);
    try std.testing.expect(engine.AlarmCondition.fromString("<=") != null);
    try std.testing.expect(engine.AlarmCondition.fromString(">=") != null);
    try std.testing.expect(engine.AlarmCondition.fromString("foo") == null);
}

test "AlarmCondition evaluate" {
    try std.testing.expect(engine.AlarmCondition.greater_than.evaluate(100.0, 95.0));
    try std.testing.expect(!engine.AlarmCondition.less_than.evaluate(100.0, 95.0));
    try std.testing.expect(engine.AlarmCondition.equal.evaluate(95.0, 95.0));
    try std.testing.expect(engine.AlarmCondition.not_equal.evaluate(96.0, 95.0));
    try std.testing.expect(engine.AlarmCondition.less_equal.evaluate(95.0, 95.0));
    try std.testing.expect(engine.AlarmCondition.greater_equal.evaluate(95.0, 95.0));
}
