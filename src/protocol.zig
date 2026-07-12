/// Text protocol parser and JSON response formatter for Plato Engine Block.
/// Commands: tick, history N, actuator NAME STATE, subscribe, help, quit
/// All responses are JSON per PLATO Wire Protocol v0.1.
const std = @import("std");
const engine = @import("engine.zig");

pub const Command = union(enum) {
    tick,
    history: usize,
    actuator: struct { name: []const u8, state: i8 },
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

/// Format a tick response as JSON.
pub fn formatTick(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.print("{{\"type\":\"tick\",\"t\":0.0,\"seq\":{d},\"data\":{{", .{eng.tick_count});
    for (eng.sensors.items, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":{d:.4}", .{ s.name, s.value });
    }
    try w.writeAll("}}");

    return buf.toOwnedSlice();
}

/// Format a history response as JSON.
pub fn formatHistory(alloc: std.mem.Allocator, eng: *const engine.PlatoEngine, n: usize) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.print("{{\"type\":\"history\",\"count\":{d},\"ticks\":[", .{n});

    // Zig history is per-sensor; we emit per-tick by iterating
    // For each tick index (most recent N), build a tick object
    var written: usize = 0;
    var tick_idx: usize = eng.tick_count;
    while (tick_idx > 0 and written < n) : (written += 1) {
        tick_idx -= 1;
        if (written > 0) try w.writeAll(",");
        try w.print("{{\"t\":0.0,\"seq\":{d},\"data\":{{", .{tick_idx});
        for (eng.sensors.items, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            if (tick_idx < s.history.items.len) {
                try w.print("\"{s}\":{d:.4}", .{ s.name, s.history.items[tick_idx] });
            } else {
                try w.print("\"{s}\":0.0", .{s.name});
            }
        }
        try w.writeAll("}}");
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

/// Format an error response.
pub fn formatError(alloc: std.mem.Allocator, message: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc,
        "{{\"type\":\"error\",\"message\":\"{s}\"}}",
        .{message});
}

/// Format subscribed response.
pub fn formatSubscribed(alloc: std.mem.Allocator) ![]u8 {
    return alloc.dupe(u8, "{\"type\":\"subscribed\",\"tick_hz\":0.2}");
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

test "format error" {
    const alloc = std.testing.allocator;
    const result = try formatError(alloc, "test error");
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "test error") != null);
}

test "format subscribed" {
    const alloc = std.testing.allocator;
    const result = try formatSubscribed(alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"subscribed\"") != null);
}

test "format bye" {
    const alloc = std.testing.allocator;
    const result = try formatBye(alloc);
    defer alloc.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"type\":\"bye\"") != null);
}
