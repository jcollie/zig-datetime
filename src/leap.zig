// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Leap years of the proleptic Gregorian calendar.

const Year = @import("year.zig").Year;

/// Returns true if `year` is a leap year in the proleptic Gregorian calendar.
pub fn is(year: Year) bool {
    // taken from https://github.com/ziglang/zig/pull/18451
    //
    // In the western Gregorian Calendar leap a year is a multiple of 4,
    // excluding multiples of 100, and adding multiples of 400. In code:
    //
    // if (@mod(year, 4) != 0)
    //     return false;
    // if (@mod(year, 100) != 0)
    //     return true;
    // return (0 == @mod(year, 400));
    //
    // The following is equivalent to the above but uses bitwise operations
    // when testing for divisibility, masking with 3 as test for multiples of 4
    // and with 15 as a test for multiples of 16. Multiples of 16 and 100 are,
    // conveniently, multiples of 400.

    const mask: Year = switch (@mod(year, 100)) {
        0 => 0b1111,
        else => 0b11,
    };
    return 0 == year & mask;
    // return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

test is {
    const testing = @import("std").testing;
    try testing.expectEqual(false, is(2005));
    try testing.expectEqual(true, is(2096));
    try testing.expectEqual(false, is(2100));
    try testing.expectEqual(true, is(2400));
}
