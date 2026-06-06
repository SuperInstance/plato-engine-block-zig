/// Terminal dashboard rendering — sparklines and status panels.
const std = @import("std");
const engine = @import("engine.zig");

const spark_chars = "▁▂▃▄▅▆▇█";

/// Render a sparkline string from f64 values.
pub fn sparkline(alloc: std.mem.Allocator, values: []const f64, width: usize) ![]u8 {
    if (values.len == 0) return alloc.dupe(u8, "(no data)");

    // Find min/max
    var min: f64 = values[0];
    var max: f64 = values[0];
    for (values[1..]) |v| {
        if (v < min) min = v;
        if (v > max) max = v;
    }
    const range = max - min;
    if (range == 0) {
        const buf = try alloc.alloc(u8, values.len);
        @memset(buf, '@');
        return buf;
    }

    // Sample or use values directly
    const n = @min(values.len, width);
    const result = try alloc.alloc(u8, n);
    const step: f64 = @floatFromInt(values.len);
    for (0..n) |i| {
        const idx: usize = @intFromFloat(@as(f64, @floatFromInt(i)) * step / @as(f64, @floatFromInt(n)));
        const clamped = @min(idx, values.len - 1);
        const normalized = (values[clamped] - min) / range;
        const char_idx: usize = @intFromFloat(normalized * 7.0);
        const ci = @min(char_idx, 7);
        // spark_chars is ASCII — but sparkline chars are multi-byte UTF-8 (3 bytes each)
        // Let's use simple block characters instead
        result[i] = " .:-=+*#@"[@min(ci, 8)];
    }
    return result;
}

/// Render a status panel for the engine.
pub fn renderPanel(alloc: std.mem.Allocator, eng: *engine.PlatoEngine) ![]u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.print("┌─────────────────────────────────────┐\n", .{});
    try w.print("│ PLATO ENGINE — Tick #{d:<8}          │\n", .{eng.tick_count});
    try w.print("├─────────────────────────────────────┤\n", .{});

    for (eng.sensors.items) |s| {
        const alarm_str: []const u8 = blk: {
            for (eng.alarms.items) |a| {
                if (std.mem.eql(u8, a.sensor_name, s.name) and a.state == .triggered)
                    break :blk " ⚠";
            }
            break :blk "";
        };
        try w.print("│ {s:<12} {d:>8.1}  {s:<4}│\n", .{ s.name, s.value, alarm_str });
    }

    try w.print("├─────────────────────────────────────┤\n", .{});

    for (eng.actuators.items) |a| {
        const state_str = switch (a.state) {
            1 => "ON ",
            -1 => "REV",
            else => "OFF",
        };
        try w.print("│ {s:<12} [{s}]              │\n", .{ a.name, state_str });
    }

    if (eng.actuators.items.len == 0) {
        try w.print("│ (no actuators)                      │\n", .{});
    }

    try w.print("└─────────────────────────────────────┘\n", .{});
    return buf.toOwnedSlice();
}

// ─── Tests ──────────────────────────────────────────────────────

test "sparkline empty values" {
    const alloc = std.testing.allocator;
    const vals = &[_]f64{};
    const s = try sparkline(alloc, vals, 10);
    defer alloc.free(s);
    try std.testing.expectEqualStrings("(no data)", s);
}

test "sparkline constant values" {
    const alloc = std.testing.allocator;
    const vals = &[_]f64{ 5.0, 5.0, 5.0 };
    const s = try sparkline(alloc, vals, 10);
    defer alloc.free(s);
    try std.testing.expect(s[0] == '@');
}

test "sparkline varying values" {
    const alloc = std.testing.allocator;
    const vals = &[_]f64{ 0.0, 5.0, 10.0, 15.0, 20.0 };
    const s = try sparkline(alloc, vals, 5);
    defer alloc.free(s);
    try std.testing.expect(s.len == 5);
    // First should be lowest char, last should be highest
    try std.testing.expect(s[0] == '.');
    try std.testing.expect(s[4] == '@');
}

test "renderPanel basic" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temp", .temperature, 22.5);
    const panel = try renderPanel(alloc, &eng);
    defer alloc.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "PLATO ENGINE") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "temp") != null);
}
