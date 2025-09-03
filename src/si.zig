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

    pub fn exponent(self: Prefix) i5 {
        return @intFromEnum(self);
    }

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
        };
    }
};

pub fn convert(from: Prefix, to: Prefix, value: i128) struct { result: i128, remainder: i128 } {
    const exponent = from - to;
    if (exponent == 0) return .{ .result = value, .remainder = 0 };
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
}

test "convert-1" {
    const result = convert(.milli, .micro, 1);
    try std.testing.expectEqual(i128, result.result, 1000);
    try std.testing.expectEqual(i128, result.remainder, 0);
}

// pub fn conversionFactor(from: i8, to: i8) !i30 {
//     if (from < to) return error.InvalidConversion;
//     if (from == to) return 1;
// }
