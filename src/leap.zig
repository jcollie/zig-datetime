// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Leap years of the proleptic Gregorian calendar.

const Year = @import("year.zig").Year;

/// Returns true if `year` is a leap year in the proleptic Gregorian calendar,
/// the calendar of ISO 8601-1:2019, 4.2.1: a common year of 365 days or a
/// leap year of 366.
///
/// The rule is that a year is a leap year if it is a multiple of 4, unless
/// it is a multiple of 100, unless it is also a multiple of 400. Written
/// that way it costs two divisions by constants that are not powers of two,
/// each of which a compiler turns into a multiplication, a shift and a
/// correction. This is the form Cassio Neri put into libstdc++ in 2023
/// (<https://github.com/gcc-mirror/gcc/commit/86a0df1a6c7fe4a835620b868e76ea78d42d6620>),
/// which needs only one, and that one by 25:
///
///     leap = year & (if (year % 25 == 0) 15 else 3) == 0
///
/// It is built in three steps, each equivalent to the one before:
///
/// - Test for a century first. For a multiple of 100, "a multiple of 400"
///   is the same as "a multiple of 16", because 400 = 16 · 25 and a
///   multiple of 100 is already a multiple of 25. For anything else the
///   rule is just "a multiple of 4". So a century is tested against 16 and
///   every other year against 4.
/// - Testing a multiple of 4 or of 16 is masking the low two or four bits,
///   `& 3` or `& 15`, which is exact for negative years too, because a
///   two's complement number is a multiple of 2^k exactly when its low k
///   bits are zero.
/// - Test for a multiple of 25 in place of 100. That wrongly calls 25, 50
///   and 75 (and every year like them) a century, but none of those is a
///   multiple of 4, so they fail `& 3` and fail `& 15` alike and the answer
///   comes out the same. Among multiples of 4, a multiple of 25 is exactly a
///   multiple of 100. A division by 25 compiles shorter than one by 100.
///
/// Only whether the remainder is zero matters, and that does not depend on
/// its sign, so this uses `@rem`. `@mod` would give the same answer and
/// spend instructions correcting a sign that is never looked at. On
/// x86-64 this compiles to one multiplication, an add, a compare and a
/// conditional move; the previous form of this function, `@mod(year, 100)`
/// with the same masks, took a second multiplication and the sign
/// correction, and `zig build bench` measured it at 1.27 ns a call to this
/// one's 0.64.
///
/// Ben Joffe's survey of leap-year tests
/// (<https://www.benjoffe.com/fast-leap-year>) offers two others. His own
/// "fuzzy century" test is this one with the division by 25 written out
/// by hand as a multiplication, and was no faster here. Falk Hüffner's
/// three-instruction test measured about 10% faster in Joffe's
/// benchmarks, but works only for years from 0 up, and `Year` is signed.
///
/// On 2026-10-16 this agreed with the textbook rule above for every one of
/// the 2^32 values of `Year`.
pub fn is(year: Year) bool {
    const mask: Year = if (@rem(year, 25) == 0) 0b1111 else 0b11;
    return year & mask == 0;
}

test is {
    const testing = @import("std").testing;
    try testing.expectEqual(false, is(2005));
    try testing.expectEqual(true, is(2096));
    try testing.expectEqual(false, is(2100));
    try testing.expectEqual(true, is(2400));
    try testing.expectEqual(true, is(0));
    try testing.expectEqual(false, is(-100));
    try testing.expectEqual(true, is(-400));
}

/// The rule as it is usually written, for the test below to check `is`
/// against.
fn textbook(year: i64) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

test "is agrees with the textbook rule" {
    const std = @import("std");
    // Every year within a million of year 0, which takes in every residue
    // modulo 400 many times over on both sides of zero.
    var year: Year = -1_000_000;
    while (year <= 1_000_000) : (year += 1) {
        try std.testing.expectEqual(textbook(year), is(year));
    }
    // And the 1000 years at each end of `Year`, where an intermediate
    // result that overflowed would show.
    for (0..1000) |i| {
        const offset: Year = @intCast(i);
        const low = std.math.minInt(Year) + offset;
        const high = std.math.maxInt(Year) - offset;
        try std.testing.expectEqual(textbook(low), is(low));
        try std.testing.expectEqual(textbook(high), is(high));
    }
}
