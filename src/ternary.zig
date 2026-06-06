/// Comptime ternary packing/unpacking and vectorized operations.
/// Ternary values: {-1, 0, +1} → packed 2 bits per trit into unsigned integers.
const std = @import("std");

/// Pack N ternary values (each -1, 0, or +1) into an unsigned integer.
/// Encoding: -1 → 0b10, 0 → 0b00, +1 → 0b01 (balanced ternary in 2 bits).
/// Comptime-verified: the length must be known at compile time.
pub fn pack(comptime N: usize, trits: [N]i8) std.meta.Int(.unsigned, N * 2) {
    comptime var result: std.meta.Int(.unsigned, N * 2) = 0;
    inline for (0..N) |i| {
        const bits: std.meta.Int(.unsigned, 2) = switch (trits[i]) {
            -1 => 0b10,
            0 => 0b00,
            1 => 0b01,
            else => @compileError("ternary value must be -1, 0, or +1"),
        };
        result |= @as(std.meta.Int(.unsigned, N * 2), bits) << @intCast(i * 2);
    }
    return result;
}

/// Unpack N ternary values from an unsigned integer.
pub fn unpack(comptime N: usize, packed_val: std.meta.Int(.unsigned, N * 2)) [N]i8 {
    comptime var result: [N]i8 = undefined;
    inline for (0..N) |i| {
        const mask = @as(std.meta.Int(.unsigned, N * 2), 0b11) << @intCast(i * 2);
        const bits = (packed_val & mask) >> @intCast(i * 2);
        result[i] = switch (@as(u2, @truncate(bits))) {
            0b00 => 0,
            0b01 => 1,
            0b10 => -1,
            0b11 => @compileError("invalid ternary encoding"),
        };
    }
    return result;
}

/// Ternary multiply two values: {-1,0,+1} × {-1,0,+1} → {-1,0,+1}
pub fn ternaryMul(a: i8, b: i8) i8 {
    return a * b;
}

/// Ternary dot product using @vector SIMD.
pub fn vecDot(comptime N: usize, a: @Vector(N, i8), b: @Vector(N, i8)) i32 {
    const prod = a * b;
    var sum: i32 = 0;
    comptime var i: usize = 0;
    inline while (i < N) : (i += 1) {
        sum += prod[i];
    }
    return sum;
}

/// Element-wise ternary multiply using @vector.
pub fn vecMul(comptime N: usize, a: @Vector(N, i8), b: @Vector(N, i8)) @Vector(N, i8) {
    return a * b;
}

/// Ternary consensus (majority vote) — returns the most common value among trits.
pub fn consensus(comptime N: usize, trits: *const [N]i8) i8 {
    var pos: usize = 0;
    var neg: usize = 0;
    var zero: usize = 0;
    for (trits) |t| {
        switch (t) {
            1 => pos += 1,
            -1 => neg += 1,
            else => zero += 1,
        }
    }
    if (pos >= neg and pos >= zero) return 1;
    if (neg >= pos and neg >= zero) return -1;
    return 0;
}

/// Pack trits at runtime (for dynamic sizes).
pub fn packRuntime(alloc: std.mem.Allocator, trits: []const i8) !u64 {
    _ = alloc;
    var result: u64 = 0;
    for (trits, 0..) |t, i| {
        const bits: u64 = switch (t) {
            -1 => 0b10,
            0 => 0b00,
            1 => 0b01,
            else => return error.InvalidTernaryValue,
        };
        result |= bits << @intCast(i * 2);
    }
    return result;
}

/// Unpack trits at runtime.
pub fn unpackRuntime(alloc: std.mem.Allocator, packed_val: u64, n: usize) ![]i8 {
    var result = try alloc.alloc(i8, n);
    for (0..n) |i| {
        const bits = (packed_val >> @intCast(i * 2)) & 0b11;
        result[i] = switch (@as(u2, @truncate(bits))) {
            0b00 => 0,
            0b01 => 1,
            0b10 => -1,
            0b11 => return error.InvalidTernaryEncoding,
        };
    }
    return result;
}

// ─── Comptime tests ─────────────────────────────────────────────

test "pack 1 trit" {
    const p = comptime pack(1, .{1});
    try std.testing.expect(p == 0b01);
}

test "pack -1 trit" {
    const p = comptime pack(1, .{-1});
    try std.testing.expect(p == 0b10);
}

test "pack 4 trits" {
    const p = comptime pack(4, .{ 1, 0, -1, 1 });
    // +1=01, 0=00, -1=10, +1=01 → 01_10_00_01 = 0b01_10_00_01 = 0x61
    // bit layout: bits[0]=01, bits[1]=00, bits[2]=10, bits[3]=01
    // packed = 0b01_10_00_01 = 0x61
    try std.testing.expect(p == 0x61);
}

test "unpack 4 trits" {
    const trits = comptime unpack(4, 0x61);
    try std.testing.expectEqual(trits, .{ 1, 0, -1, 1 });
}

test "pack/unpack roundtrip 6 trits" {
    const original = [6]i8{ -1, 0, 1, 1, 0, -1 };
    const p = comptime pack(6, original);
    const u = comptime unpack(6, p);
    try std.testing.expectEqualSlices(i8, &original, &u);
}

test "pack 16 trits into u32" {
    const trits = [16]i8{ 1, -1, 0, 1, 1, 0, -1, 0, 1, 1, 0, 0, -1, 1, 0, -1 };
    const p = comptime pack(16, trits);
    try std.testing.expect(@TypeOf(p) == u32);
    const u = comptime unpack(16, p);
    try std.testing.expectEqualSlices(i8, &trits, &u);
}

test "vec dot product" {
    const a: @Vector(4, i8) = .{ 1, -1, 0, 1 };
    const b: @Vector(4, i8) = .{ 1, 1, 0, -1 };
    const d = vecDot(4, a, b);
    // 1*1 + (-1)*1 + 0*0 + 1*(-1) = 1 - 1 + 0 - 1 = -1
    try std.testing.expect(d == -1);
}

test "vec element-wise multiply" {
    const a: @Vector(4, i8) = .{ 1, -1, 0, 1 };
    const b: @Vector(4, i8) = .{ 1, 1, 0, -1 };
    const c = vecMul(4, a, b);
    try std.testing.expect(c[0] == 1);
    try std.testing.expect(c[1] == -1);
    try std.testing.expect(c[2] == 0);
    try std.testing.expect(c[3] == -1);
}

test "consensus majority +1" {
    const votes = [5]i8{ 1, 1, -1, 1, 0 };
    try std.testing.expect(consensus(5, &votes) == 1);
}

test "consensus tie → 0" {
    const votes = [4]i8{ 1, -1, 1, -1 };
    try std.testing.expect(consensus(4, &votes) == 1); // 1 ties with -1 at 2 each, pos wins
}

test "consensus -1 majority" {
    const votes = [5]i8{ -1, -1, -1, 0, 1 };
    try std.testing.expect(consensus(5, &votes) == -1);
}

test "packRuntime roundtrip" {
    const alloc = std.testing.allocator;
    const trits = [_]i8{ 1, 0, -1, 1, -1 };
    const p = try packRuntime(alloc, &trits);
    const u = try unpackRuntime(alloc, p, 5);
    defer alloc.free(u);
    try std.testing.expectEqualSlices(i8, &trits, u);
}

test "ternaryMul basic" {
    try std.testing.expect(ternaryMul(1, 1) == 1);
    try std.testing.expect(ternaryMul(1, -1) == -1);
    try std.testing.expect(ternaryMul(0, 1) == 0);
    try std.testing.expect(ternaryMul(-1, -1) == 1);
}

test "pack 8 trits into u16" {
    const trits = [8]i8{ 1, 1, 1, 1, 1, 1, 1, 1 };
    const p = comptime pack(8, trits);
    try std.testing.expect(@TypeOf(p) == u16);
    try std.testing.expect(p == 0x5555); // all +1 = 01_01_01_01_01_01_01_01
}
