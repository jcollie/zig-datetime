// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reading fixed-width numeric fields out of a date string.
//!
//! Date syntaxes are made almost entirely of short runs of digits at a
//! known position, so the parsers here split that job in two: `int` finds
//! how far the run goes without converting anything, letting the caller
//! decide whether the length it found is the one the grammar wanted, and
//! `digits` converts a run that has already been checked. Keeping the two
//! apart is what lets `digits` skip the sign, base prefix and overflow
//! handling that make `std.fmt.parseInt` general.

const std = @import("std");
const log = std.log.scoped(.read);
const Nanosecond = @import("nanosecond.zig").Nanosecond;

/// Returns the run of ASCII digits at the beginning of `text`, at most
/// `maxlen` bytes long; the result is empty if `text` does not start with a
/// digit.
pub fn int(text: []const u8, maxlen: usize) []const u8 {
    if (text.len == 0) return text[0..0];

    const len = @min(text.len, maxlen);
    for (0..len) |i| {
        if (!std.ascii.isDigit(text[i])) return text[0..i];
    }

    return text[0..len];
}

/// Parses a run of ASCII digits as a decimal number.
///
/// Everything parsed here is a fixed-width field that `int` has already
/// checked the shape of, so there is no sign, no base prefix and no
/// separator to consider, which is what makes this worth having over
/// `std.fmt.parseInt`: it is about three times quicker for the two digit
/// fields that make up most of a date.
///
/// `text` must be all digits and no longer than nine of them, which is
/// the most that can fit in the return type.
pub fn digits(text: []const u8) u32 {
    std.debug.assert(text.len <= 9);

    var value: u32 = 0;
    for (text) |char| {
        std.debug.assert(std.ascii.isDigit(char));
        value = value * 10 + (char - '0');
    }
    return value;
}

test digits {
    try std.testing.expectEqual(@as(u32, 0), digits(""));
    try std.testing.expectEqual(@as(u32, 7), digits("7"));
    try std.testing.expectEqual(@as(u32, 7), digits("07"));
    try std.testing.expectEqual(@as(u32, 2024), digits("2024"));
    try std.testing.expectEqual(@as(u32, 999999999), digits("999999999"));
}

/// Parses exactly `length` digits (1-9) at the start of `text` as a decimal
/// fraction of a second and returns it scaled to nanoseconds, so "12" with
/// length 2 yields 120000000.
pub fn nanosecond(text: []const u8, length: usize) !Nanosecond {
    if (length == 0) return error.TooShort;
    if (length > 9) return error.TooLong;
    const v = int(text, length);
    if (v.len != length) return error.TooShort;
    return @as(Nanosecond, @intCast(digits(v))) *
        try std.math.powi(Nanosecond, 10, 9 - @as(Nanosecond, @intCast(length)));
}

test nanosecond {
    // The length is the number of digits the field was written with, so
    // the same digits mean different amounts at different lengths.
    try std.testing.expectEqual(@as(Nanosecond, 500000000), try nanosecond("5", 1));
    try std.testing.expectEqual(@as(Nanosecond, 120000000), try nanosecond("12", 2));
    try std.testing.expectEqual(@as(Nanosecond, 123456789), try nanosecond("123456789", 9));
    try std.testing.expectError(error.TooShort, nanosecond("1", 2));
}

test int {
    // A digit run that reaches the end of the input is returned in full
    // even when it is shorter than maxlen.
    try std.testing.expectEqualStrings("5", int("5", 2));
    try std.testing.expectEqualStrings("", int("", 2));
    try std.testing.expectEqualStrings("", int("x5", 2));
    try std.testing.expectEqualStrings("12", int("123", 2));
    try std.testing.expectEqualStrings("12", int("12:34", 4));
}
