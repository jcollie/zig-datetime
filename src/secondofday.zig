// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The second of the day, and its split into hour, minute and second.

const std = @import("std");

const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;

/// The seconds elapsed since midnight, 0 through 86399. A leap second, the
/// 61st second of its minute, is not one of them: a caller that has one
/// holds it back and puts it back after the split, as `DateTime.toUtc`
/// does.
pub const SecondOfDay = std.math.IntFittingRange(0, std.time.s_per_day - 1);

/// The clock reading a second of the day makes.
pub const Clock = struct {
    hour: Hour,
    minute: Minute,
    second: Second,
};

/// Splits a second of the day into hour, minute and second.
///
/// The usual way is a chain: the hour is `s / 3600`, what is left of the
/// hour is `s % 3600`, the minute is that `/ 60`, the second that `% 60`.
/// Each step waits on the one before, and each division by a constant is
/// itself a multiplication followed by a shift, with a remainder that needs
/// a second multiplication to recover.
///
/// This takes the two divisions straight from `s` instead, the whole
/// minutes `s / 60` and the whole hours `s / 3600`, which depend on
/// nothing but `s` and so run at the same time. The rest is subtraction:
/// the second is `s` less the whole minutes in it, `s - 60 * minutes`, and
/// the minute is the whole minutes less those that made up whole hours,
/// `minutes - 60 * hours`. Those two do not depend on each other either,
/// so the chain is two multiplications deep where the usual one is four.
/// Ben Joffe found no date library writing it this way and calls it "V1"
/// in <https://www.benjoffe.com/fast-time-of-day>.
///
/// The arithmetic is unsigned and 32 bits wide on purpose. A signed
/// division has to correct its quotient for a negative dividend that can
/// never occur here, and a 32-bit one by a constant needs no more than a
/// single multiplication and a shift.
///
/// The same article's "V3" goes one step further, using
/// `x % 60 == (x + 4 * (x / 60)) % 64` to swap the two multiplications by
/// 60 for shifts and a mask. On 2026-10-16 it took `Instant.asDateTime`
/// from 11.9 ns to 11.6, about 3%, which is not enough to make every
/// reader work the identity out.
pub fn split(s: SecondOfDay) Clock {
    const seconds: u32 = s;
    const minutes = seconds / std.time.s_per_min;
    const hours = seconds / std.time.s_per_hour;
    return .{
        .hour = @intCast(hours),
        .minute = @intCast(minutes - hours * 60),
        .second = @intCast(seconds - minutes * 60),
    };
}

test split {
    try std.testing.expectEqual(Clock{ .hour = 0, .minute = 0, .second = 0 }, split(0));
    try std.testing.expectEqual(Clock{ .hour = 13, .minute = 4, .second = 5 }, split(13 * 3600 + 4 * 60 + 5));
    try std.testing.expectEqual(Clock{ .hour = 23, .minute = 59, .second = 59 }, split(std.time.s_per_day - 1));
}

test "split agrees with the chain of divisions on every second of the day" {
    var s: u32 = 0;
    while (s < std.time.s_per_day) : (s += 1) {
        const clock = split(@intCast(s));
        try std.testing.expectEqual(s / 3600, clock.hour);
        try std.testing.expectEqual(s % 3600 / 60, clock.minute);
        try std.testing.expectEqual(s % 60, clock.second);
    }
}
