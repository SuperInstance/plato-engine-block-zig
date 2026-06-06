const std = @import("std");
const plato = @import("plato");
const engine = plato.engine;
const ternary = plato.ternary;
const protocol = plato.protocol;
const dashboard = plato.dashboard;

// Re-export all tests from each module
test {
    _ = plato.ternary;
    _ = plato.protocol;
    _ = plato.dashboard;
}

// ─── Engine tests ───────────────────────────────────────────────

test "engine init" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    try std.testing.expect(eng.tick_count == 0);
}

test "engine add sensor" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temperature", .temperature, 20.0);
    try std.testing.expect(eng.sensors.items.len == 1);
}

test "engine update and read sensor" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temperature", .temperature, 20.0);
    eng.updateSensor("temperature", 25.5);
    try std.testing.expect(eng.readSensor("temperature") == 25.5);
}

test "engine tick increments counter" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.tick();
    eng.tick();
    eng.tick();
    try std.testing.expect(eng.tick_count == 3);
}

test "engine history recording" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temp", .temperature, 20.0);
    eng.updateSensor("temp", 21.0);
    eng.updateSensor("temp", 22.0);
    const hist = eng.getHistory("temp");
    try std.testing.expect(hist.items.len == 2);
    try std.testing.expect(hist.items[0] == 21.0);
    try std.testing.expect(hist.items[1] == 22.0);
}

test "engine alarm above triggers" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temp", .temperature, 20.0);
    eng.setAlarm("temp", 30.0, .above, "Too hot!");
    eng.updateSensor("temp", 35.0);
    eng.tick();
    try std.testing.expect(eng.isAlarmTriggered("temp"));
}

test "engine alarm does not trigger when below threshold" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temp", .temperature, 20.0);
    eng.setAlarm("temp", 30.0, .above, "Too hot!");
    eng.updateSensor("temp", 25.0);
    eng.tick();
    try std.testing.expect(!eng.isAlarmTriggered("temp"));
}

test "engine alarm below triggers" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addSensor("temp", .temperature, 20.0);
    eng.setAlarm("temp", 10.0, .below, "Too cold!");
    eng.updateSensor("temp", 5.0);
    eng.tick();
    try std.testing.expect(eng.isAlarmTriggered("temp"));
}

test "engine actuator set state" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.addActuator("pump", 0);
    eng.setActuator("pump", 1);
    try std.testing.expect(eng.actuators.items[0].state == 1);
}

test "engine subscribe" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 4);
    defer eng.deinit();
    eng.subscribe("temperature");
    try std.testing.expect(eng.subscribers.items.len == 1);
}

// ─── Integration test: full room simulation ─────────────────────

test "integration: 50 tick room simulation" {
    const alloc = std.testing.allocator;
    var eng = try engine.PlatoEngine.init(alloc, 256);
    defer eng.deinit();

    eng.addSensor("temperature", .temperature, 20.0);
    eng.addSensor("humidity", .humidity, 50.0);
    eng.addSensor("co2", .co2, 400.0);
    eng.addSensor("light", .light, 300.0);

    eng.setAlarm("temperature", 30.0, .above, "Too hot!");
    eng.setAlarm("co2", 1000.0, .above, "CO2 dangerous!");
    eng.addActuator("hvac", 0);
    eng.addActuator("ventilation", 0);
    eng.subscribe("temperature");
    eng.subscribe("co2");

    var rng = std.Random.DefaultPrng.init(42);
    var alarm_fires: u32 = 0;

    for (0..50) |_| {
        const t: f64 = 20.0 + rng.random().float(f64) * 15.0;
        const h: f64 = 40.0 + rng.random().float(f64) * 30.0;
        const c: f64 = 350.0 + rng.random().float(f64) * 800.0;
        const l: f64 = 200.0 + rng.random().float(f64) * 400.0;
        eng.updateSensor("temperature", t);
        eng.updateSensor("humidity", h);
        eng.updateSensor("co2", c);
        eng.updateSensor("light", l);
        eng.tick();

        if (eng.isAlarmTriggered("temperature")) alarm_fires += 1;

        // Actuator logic: ternary control based on sensor reading
        const temp_vote: i8 = if (t > 28.0) -1 else if (t < 18.0) 1 else 0;
        eng.setActuator("hvac", temp_vote);
        const co2_vote: i8 = if (c > 800.0) 1 else 0;
        eng.setActuator("ventilation", co2_vote);
    }

    try std.testing.expect(eng.tick_count == 50);
    try std.testing.expect(eng.sensors.items.len == 4);

    const temp_hist = eng.getHistory("temperature");
    try std.testing.expect(temp_hist.items.len == 50);

    // With this seed, we should have some alarm fires
    try std.testing.expect(alarm_fires > 0);
}

test "integration: ternary packing in engine context" {
    // Simulate packing ternary actuator states for transmission
    const states = [4]i8{ 1, -1, 0, 1 };
    const packed_val = comptime ternary.pack(4, states);
    const unpacked = comptime ternary.unpack(4, packed_val);
    try std.testing.expectEqualSlices(i8, &states, &unpacked);
}
