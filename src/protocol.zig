/// Text protocol parser for Plato Engine Block.
/// Commands: tick, history N, actuator NAME STATE, subscribe SENSOR, help, quit
const std = @import("std");

pub const Command = union(enum) {
    tick,
    history: usize,
    actuator: struct { name: []const u8, state: i8 },
    subscribe: []const u8,
    help,
    quit,
    unknown: []const u8,
};

/// Parse a text command string into a typed Command.
/// No allocations — works entirely on the input slice.
pub fn parse(input: []const u8) Command {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return .{ .unknown = "" };

    // Simple command matching — no hidden control flow
    if (std.mem.eql(u8, trimmed, "tick")) return .tick;
    if (std.mem.eql(u8, trimmed, "help")) return .help;
    if (std.mem.eql(u8, trimmed, "quit")) return .quit;
    if (std.mem.eql(u8, trimmed, "exit")) return .quit;

    if (std.mem.startsWith(u8, trimmed, "history")) {
        const arg = std.mem.trimLeft(u8, trimmed["history".len..], " ");
        const n = std.fmt.parseInt(usize, arg, 10) catch 10;
        return .{ .history = n };
    }

    if (std.mem.startsWith(u8, trimmed, "actuator")) {
        const rest = std.mem.trimLeft(u8, trimmed["actuator".len..], " ");
        // Split "pump 1" → name="pump", state=1
        if (std.mem.indexOfScalar(u8, rest, ' ')) |space_idx| {
            const name = rest[0..space_idx];
            const state_str = std.mem.trimLeft(u8, rest[space_idx..], " ");
            const state = std.fmt.parseInt(i8, state_str, 10) catch 0;
            return .{ .actuator = .{ .name = name, .state = state } };
        }
        return .{ .actuator = .{ .name = rest, .state = 0 } };
    }

    if (std.mem.startsWith(u8, trimmed, "subscribe")) {
        const sensor = std.mem.trimLeft(u8, trimmed["subscribe".len..], " ");
        if (sensor.len > 0) return .{ .subscribe = sensor };
        return .{ .unknown = trimmed };
    }

    return .{ .unknown = trimmed };
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

test "parse subscribe temperature" {
    const cmd = parse("subscribe temperature");
    try std.testing.expect(cmd == .subscribe);
    try std.testing.expectEqualSlices(u8, "temperature", cmd.subscribe);
}

test "parse help" {
    const cmd = parse("help");
    try std.testing.expect(cmd == .help);
}

test "parse quit" {
    const cmd = parse("quit");
    try std.testing.expect(cmd == .quit);
}

test "parse exit as quit" {
    const cmd = parse("exit");
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

test "parse actuator without state defaults to 0" {
    const cmd = parse("actuator pump");
    try std.testing.expect(cmd == .actuator);
    try std.testing.expectEqual(@as(i8, 0), cmd.actuator.state);
}
