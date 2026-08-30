// https://www.nist.gov/pml/owm/metric-si-prefixes

const std = @import("std");

pub const Prefix = enum(i8) {
    quetta = 30,
    ronna = 27,
    yotta = 24,
    zetta = 21,
    exa = 18,
    peta = 15,
    tera = 12,
    giga = 9,
    mega = 6,
    kilo = 3,
    hecto = 2,
    deka = 1,
    deci = -1,
    centi = -2,
    milli = -3,
    micro = -6,
    nano = -9,
    pico = -12,
    femto = -15,
    atto = -18,
    zepto = -21,
    yocto = -24,
    ronto = -27,
    quecto = -30,
    _,

    /// Returns the power of ten this prefix represents.
    pub fn exponent(self: Prefix) i8 {
        return @intFromEnum(self);
    }

    /// Returns the SI symbol for this prefix (e.g. "k" for kilo, "µ" for
    /// micro). Asserts that this is one of the named SI prefixes.
    pub fn symbol(self: Prefix) []const u8 {
        return switch (self) {
            .quetta => "Q",
            .ronna => "R",
            .yotta => "Y",
            .zetta => "Z",
            .exa => "E",
            .peta => "P",
            .tera => "T",
            .giga => "G",
            .mega => "M",
            .kilo => "k",
            .hecto => "h",
            .deka => "da",
            .deci => "d",
            .centi => "c",
            .milli => "m",
            .micro => "µ",
            .nano => "n",
            .pico => "p",
            .femto => "f",
            .atto => "a",
            .zepto => "z",
            .yocto => "y",
            .ronto => "r",
            .quecto => "q",
            _ => unreachable,
        };
    }
};

/// Converts `value` from units of prefix `from` to units of prefix `to`.
/// When converting to a larger unit the result is truncated and the leftover
/// amount, in `from` units, is returned as `remainder`.
pub fn convert(from: Prefix, to: Prefix, value: i128) struct { result: i128, remainder: i128 } {
    const exponent = from.exponent() - to.exponent();
    if (exponent < 0) {
        const factor = std.math.pow(i128, 10, @abs(exponent));
        const remainder = @rem(value, factor);
        const result = @divTrunc(value, factor);
        return .{ .result = result, .remainder = remainder };
    }
    if (exponent > 0) {
        const factor = std.math.pow(i128, 10, exponent);
        return .{ .result = factor * value, .remainder = 0 };
    }
    return .{ .result = value, .remainder = 0 };
}

test "symbol" {
    try std.testing.expectEqualStrings("k", Prefix.kilo.symbol());
    try std.testing.expectEqualStrings("µ", Prefix.micro.symbol());
}

test "convert-1" {
    const result = convert(.milli, .micro, 1);
    try std.testing.expectEqual(@as(i128, 1000), result.result);
    try std.testing.expectEqual(@as(i128, 0), result.remainder);
}

// pub fn conversionFactor(from: i8, to: i8) !i30 {
//     if (from < to) return error.InvalidConversion;
//     if (from == to) return 1;
// }
