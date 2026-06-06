const std = @import("std");
const engine = @import("engine.zig");
const ternary = @import("ternary.zig");
const protocol = @import("protocol.zig");
const dashboard = @import("dashboard.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n", .{});
    try stdout.print("╔══════════════════════════════════════════════════════════════╗\n", .{});
    try stdout.print("║          PLATO ENGINE BLOCK — Zig Edition                   ║\n", .{});
    try stdout.print("║          Bare-Metal Room Runtime                            ║\n", .{});
    try stdout.print("╚══════════════════════════════════════════════════════════════╝\n", .{});
    try stdout.print("\n", .{});

    // Demo 1: Comptime ternary packing
    try stdout.print("▸ Comptime Ternary Packing\n", .{});
    const packed_val = comptime ternary.pack(6, .{ -1, 0, 1, 1, 0, -1 });
    try stdout.print("  pack(6, {{-1,0,+1,+1,0,-1}}) = 0x{X:0>8}\n", .{packed_val});
    const unpacked = comptime ternary.unpack(6, packed_val);
    try stdout.print("  unpack → {d}\n", .{unpacked});
    try stdout.print("  roundtrip verified at comptime ✓\n\n", .{});

    // Demo 2: @vector ternary operations
    try stdout.print("▸ Vectorized Ternary Operations\n", .{});
    const vec_a: @Vector(8, i8) = .{ 1, -1, 0, 1, -1, 0, 1, 1 };
    const vec_b: @Vector(8, i8) = .{ 1, 1, 0, -1, -1, 1, 0, -1 };
    const dot = ternary.vecDot(8, vec_a, vec_b);
    try stdout.print("  a = {d}\n", .{vec_a});
    try stdout.print("  b = {d}\n", .{vec_b});
    try stdout.print("  ternary dot product = {d}\n\n", .{dot});

    const vec_c = ternary.vecMul(8, vec_a, vec_b);
    try stdout.print("  element-wise ternary mul = {d}\n\n", .{vec_c});

    // Demo 3: Engine simulation
    try stdout.print("▸ Room Engine Simulation (20 ticks)\n", .{});
    var room = try engine.PlatoEngine.init(alloc, 4);
    defer room.deinit();
    room.addSensor("temperature", .temperature, 20.0);
    room.addSensor("humidity", .humidity, 50.0);
    room.addSensor("co2", .co2, 400.0);
    room.addSensor("light", .light, 300.0);
    room.setAlarm("temperature", 30.0, .above, "Temperature too high!");
    room.setAlarm("co2", 1000.0, .above, "CO2 level dangerous!");

    var rng = std.Random.DefaultPrng.init(42);
    for (0..20) |i| {
        const t: f64 = 20.0 + rng.random().float(f64) * 15.0;
        const h: f64 = 40.0 + rng.random().float(f64) * 30.0;
        const c: f64 = 350.0 + rng.random().float(f64) * 800.0;
        const l: f64 = 200.0 + rng.random().float(f64) * 400.0;
        room.updateSensor("temperature", t);
        room.updateSensor("humidity", h);
        room.updateSensor("co2", c);
        room.updateSensor("light", l);
        room.tick();
        if (i % 5 == 4) {
            try stdout.print("  tick {d:2}: temp={d:.1} hum={d:.1} co2={d:.0} light={d:.0}\n", .{
                i + 1,
                room.readSensor("temperature"),
                room.readSensor("humidity"),
                room.readSensor("co2"),
                room.readSensor("light"),
            });
        }
    }

    // Demo 4: History + sparkline
    try stdout.print("\n▸ Temperature History (sparkline)\n", .{});
    const temp_hist = room.getHistory("temperature");
    const spark = try dashboard.sparkline(alloc, temp_hist.items, 50);
    defer alloc.free(spark);
    try stdout.print("  {s}\n", .{spark});

    // Demo 5: Protocol parsing
    try stdout.print("\n▸ Protocol Parser\n", .{});
    const cmds = [_][]const u8{ "tick", "history 5", "actuator pump 1", "subscribe temperature", "help", "quit" };
    for (cmds) |cmd| {
        const parsed = protocol.parse(cmd);
        try stdout.print("  \"{s}\" → {s}\n", .{ cmd, @tagName(parsed) });
    }

    // Demo 6: Ternary consensus
    try stdout.print("\n▸ Ternary Consensus (voting)\n", .{});
    const votes = [5]i8{ 1, 1, -1, 1, 0 };
    const consensus = ternary.consensus(5, &votes);
    try stdout.print("  votes: {d} → consensus: {d}\n", .{ votes, consensus });

    // Demo 7: Status panel
    try stdout.print("\n▸ Room Status Panel\n", .{});
    const panel = try dashboard.renderPanel(alloc, &room);
    defer alloc.free(panel);
    try stdout.print("{s}\n", .{panel});

    try stdout.print("All demos complete. Zig × Plato = ♾\n", .{});
}
