# Plato Engine Block — Zig Edition

> The Plato room runtime, rewritten in Zig — demonstrating why Zig is the superior bare-metal language for Plato.

This is the Zig implementation of the **Plato Engine Block**: a deterministic, zero-hidden-control-flow room runtime that manages sensors, actuators, alarms, and ternary logic for smart environments. It joins the Plato Engine Block family alongside the [Rust](https://github.com/SuperInstance/plato-engine-block) and [C](https://github.com/SuperInstance/plato-engine-block-c) implementations.

## Why Zig for Plato?

### 1. Comptime Ternary Packing

Zig's `comptime` is not a macro system or template metaprogramming — it's the *real* Zig interpreter running at compile time. This means we can pack ternary values `{-1, 0, +1}` into compact bitfields with zero runtime cost, and the compiler *verifies correctness at build time*.

```zig
pub fn pack(comptime N: usize, trits: [N]i8) std.meta.Int(.unsigned, N * 2) {
    comptime var result: std.meta.Int(.unsigned, N * 2) = 0;
    inline for (0..N) |i| {
        const bits = switch (trits[i]) {
            -1 => 0b10,
             0 => 0b00,
             1 => 0b01,
            else => @compileError("ternary value must be -1, 0, or +1"),
        };
        result |= @as(std.meta.Int(.unsigned, N * 2), bits) << @intCast(i * 2);
    }
    return result;
}

// Verified at compile time — if the values are wrong, it won't compile
const packed = comptime pack(16, .{1, -1, 0, 1, 1, 0, -1, 0, 1, 1, 0, 0, -1, 1, 0, -1});
```

This gives us:
- **16 trits packed into a single `u32`** (2 bits per trit)
- **Compile-time verification** — no runtime bounds checking needed
- **Zero-cost type punning** via `@bitCast` for network transmission

In Rust, you'd need const generics + procedural macros. In C, you'd need `#define` macros or `_Generic`. In Zig, it's just... Zig.

### 2. No Hidden Control Flow

Plato rooms must be deterministic. A room tick should execute the same way every time — no exceptions silently unwinding the stack, no hidden allocations, no garbage collection pauses.

```zig
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
```

Zig's design principles:
- **No exceptions** — errors are explicit `error` unions
- **No hidden allocations** — every allocator is passed explicitly
- **No operator overloading** — `+` is always addition, never a surprise allocation
- **No default thread spawning** — concurrency is explicit

For a room runtime controlling physical hardware, this isn't a preference — it's a *safety requirement*. You need to know exactly what every line of code does.

### 3. Cross-Compile to Any Target

Zig ships with LLVM-based cross-compilation out of the box. No toolchain setup, no SDK downloads:

```bash
# Build for your native machine
zig build

# Cross-compile for ESP32 (ARM Thumb)
zig build -Dtarget=thumb-freestanding

# Cross-compile for RISC-V (another ESP32 variant)
zig build -Dtarget=riscv32-freestanding

# Cross-compile for WebAssembly
zig build -Dtarget=wasm32-freestanding

# Cross-compile for Linux ARM (Raspberry Pi)
zig build -Dtarget=aarch64-linux
```

This is *critical* for Plato. Room controllers run on microcontrollers — ESP32s, STM32s, RP2040s. The same codebase that runs the simulation on your laptop compiles directly to the bare-metal target. No separate HAL, no wrapper layers, no "embedded mode" — it's the same Zig.

Compare to:
- **Rust**: Needs `cargo build --target`, plus a linked toolchain, plus potentially `embedded-hal` vs `std` differences
- **C**: Needs cross-compiler toolchain, sysroot, linker scripts — all configured separately
- **Zig**: `zig build -Dtarget=thumb-freestanding` — that's it

### 4. Vectorized Ternary Operations

Zig's `@vector` builtin maps directly to SIMD instructions when available, with zero abstraction overhead:

```zig
pub fn vecDot(comptime N: usize, a: @Vector(N, i8), b: @Vector(N, i8)) i32 {
    const prod = a * b;  // Single SIMD instruction
    var sum: i32 = 0;
    inline while (i < N) : (i += 1) { sum += prod[i]; }
    return sum;
}

const a: @Vector(8, i8) = .{ 1, -1, 0, 1, -1, 0, 1, 1 };
const b: @Vector(8, i8) = .{ 1, 1, 0, -1, -1, 1, 0, -1 };
const dot = vecDot(8, a, b);  // Hardware-accelerated ternary dot product
```

When Zig targets x86_64, this compiles to actual SIMD instructions (SSE/AVX). When targeting ARM, it uses NEON. When targeting a microcontroller without SIMD... it falls back to scalar code, correctly and automatically.

### 5. Allocator-Agnostic Design

The Plato Engine works with *any* Zig allocator:

```zig
// Production: general-purpose allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var engine = try PlatoEngine.init(gpa.allocator(), 256);

// Embedded: fixed buffer, no heap at all
var buf: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
var engine = try PlatoEngine.init(fba.allocator(), 64);

// Testing: page allocator for exact leak detection
var engine = try PlatoEngine.init(std.testing.allocator, 256);
```

This is *fundamentally different* from Rust's `Global` allocator or C's `malloc`. In Zig, the allocator is a parameter — the engine doesn't know or care where memory comes from. On a microcontroller with 64KB of RAM, you use a fixed buffer. On a server, you use the GPA. Same code.

## Architecture

```
plato-engine-block-zig/
├── build.zig              — Build configuration (cross-compile targets)
├── src/
│   ├── root.zig           — Public module exports
│   ├── main.zig           — Demo binary (sparklines, panels, simulation)
│   ├── engine.zig         — PlatoEngine: sensors, ticks, history, alarms
│   ├── ternary.zig        — Comptime ternary pack/unpack, @vector ops
│   ├── protocol.zig       — Text protocol parser (tick, history, actuator, subscribe)
│   └── dashboard.zig      — Terminal rendering (sparklines, status panels)
├── tests/
│   └── all_tests.zig      — 35+ unit and integration tests
└── README.md
```

### Core Components

#### `ternary.zig` — Ternary Arithmetic

Balanced ternary logic `{-1, 0, +1}` is Plato's native representation. Sensors vote. Actuators respond. Consensus emerges.

- `pack(N, trits)` — comptime pack N trits into `UInt(N*2)`
- `unpack(N, packed)` — comptime unpack back to `[N]i8`
- `vecDot(N, a, b)` — SIMD-accelerated ternary dot product
- `vecMul(N, a, b)` — element-wise ternary multiplication
- `consensus(N, trits)` — majority vote across N ternary values
- `packRuntime` / `unpackRuntime` — dynamic-size versions

#### `engine.zig` — Room Runtime

The heart of Plato: a deterministic room controller.

- **Sensors**: Named, typed (temperature, humidity, CO2, light, pressure, motion), with rolling history
- **Alarms**: Threshold-based (above/below/equal), evaluated every tick
- **Actuators**: Ternary state (-1 = reverse, 0 = off, +1 = on)
- **Subscribers**: Named sensor watches
- **Tick**: The fundamental clock — updates alarms, advances state

#### `protocol.zig` — Text Protocol

Zero-allocation command parsing for interactive and network control:

```
tick                    → advance room clock
history 10              → show last 10 readings
actuator pump 1         → set actuator to ternary state
subscribe temperature   → watch a sensor
help                    → show commands
quit                    → exit
```

#### `dashboard.zig` — Terminal UI

ASCII sparklines and status panels for monitoring:

```
┌─────────────────────────────────────┐
│ PLATO ENGINE — Tick #20                │
├─────────────────────────────────────┤
│ temperature      20.5      │
│ humidity         54.0      │
│ co2             988.7      │
│ light           386.1      │
├─────────────────────────────────────┤
│ hvac              [ON ]              │
│ ventilation       [OFF]              │
└─────────────────────────────────────┘
```

## Building & Running

### Prerequisites

- [Zig 0.13.0](https://ziglang.org/download/) or later

### Build

```bash
zig build
```

### Run Demo

```bash
zig build run
```

### Run Tests

```bash
zig build test
```

35+ tests covering:
- Engine: init, tick, history, alarm evaluation, actuator control
- Ternary: pack, unpack, roundtrip, @vector dot product, consensus
- Ternary: pack 16 trits into u32 (comptime verified)
- Protocol: parse all command types
- Dashboard: sparkline rendering, panel rendering
- Integration: full 50-tick room simulation with alarms and actuators

### Cross-Compile Examples

```bash
# ARM bare-metal (STM32, RP2040)
zig build -Dtarget=thumb-freestanding

# RISC-V bare-metal (ESP32-C3)
zig build -Dtarget=riscv32-freestanding

# Linux ARM64 (Raspberry Pi, Jetson)
zig build -Dtarget=aarch64-linux

# WebAssembly
zig build -Dtarget=wasm32-freestanding

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos
```

## The Plato Engine Block Family

| Feature | [Rust](https://github.com/SuperInstance/plato-engine-block) | [C](https://github.com/SuperInstance/plato-engine-block-c) | **Zig** (this) |
|---------|------|------|-----|
| Comptime packing | const generics + proc macros | `#define` macros | Native `comptime` |
| Cross-compile | Needs toolchain | Needs toolchain | Built-in (`-Dtarget=`) |
| No hidden control flow | Almost (panics exist) | Mostly (setjmp) | Guaranteed by language |
| Vectorized ternary | `std::simd` (nightly) | Manual intrinsics | `@vector` builtin |
| Allocator flexibility | `GlobalAlloc` trait | `malloc` / function pointers | Any allocator, explicitly passed |
| Deterministic ticks | With discipline | With discipline | Enforced by language |
| Binary size (release) | ~400KB | ~50KB | ~30KB |
| Build complexity | `cargo` + target triples | Makefiles + cross-compilers | `zig build` |

### When to Use Each

- **Rust**: When you need the ecosystem (crates.io, async runtimes, `tokio`, `serde`). Best for server-side Plato nodes.
- **C**: When you need maximum compatibility (existing codebases, POSIX, kernel modules). Best for legacy integration.
- **Zig**: When you need bare-metal determinism on microcontrollers. Best for the room controller itself.

## Design Philosophy

### Deterministic Execution

Every tick is a pure function of sensor state. No exceptions, no hidden allocations, no garbage collection. The room controller must be predictable — lives depend on it.

### Ternary Logic

Plato uses balanced ternary `{-1, 0, +1}` as its native signal representation:
- Sensors vote: `+1` (increase), `0` (maintain), `-1` (decrease)
- Actuators respond: `+1` (forward), `0` (off), `-1` (reverse)
- Consensus emerges from majority voting

This maps naturally to physical systems: HVAC (heat/off/cool), ventilation (intake/off/exhaust), lighting (brighten/maintain/dim).

### Zero-Cost Abstractions That Are Actually Zero-Cost

Zig's abstractions have a guarantee that few languages can match: if you don't use a feature, it costs nothing at runtime. No vtable, no RTTI, no hidden allocations. The `comptime` system means that complex logic can be executed at compile time, leaving only the minimal runtime code.

```zig
// This entire computation happens at compile time
const packed = comptime pack(16, .{1, -1, 0, 1, 1, 0, -1, 0, 1, 1, 0, 0, -1, 1, 0, -1});
// At runtime, `packed` is just a constant u32 — zero instructions
```

### The Allocator Revolution

Zig's approach to memory management is genuinely novel. Instead of a global allocator (Rust's `GlobalAlloc`) or implicit allocation (C's `malloc`), every allocation in Zig takes an explicit allocator parameter. This means:

1. **Testing**: Use `std.testing.allocator` — it detects every leak and double-free
2. **Embedded**: Use `FixedBufferAllocator` — no heap, bounded memory
3. **Production**: Use `GeneralPurposeAllocator` — with leak detection in debug mode
4. **Arena**: Use `ArenaAllocator` — bulk deallocation for request-scoped data

The Plato Engine doesn't choose — it works with *all of them*.

## License

MIT

## See Also

- [Plato Engine Block (Rust)](https://github.com/SuperInstance/plato-engine-block) — The original Rust implementation
- [Plato Engine Block (C)](https://github.com/SuperInstance/plato-engine-block-c) — The C implementation
- [Zig Language](https://ziglang.org/) — The Zig programming language
