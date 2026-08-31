// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Writing the pieces of a formatted date that are more than a padded
//! number: English ordinal suffixes and UTC offsets.

const std = @import("std");

// pub fn Ordinal(style: enum {.normal, .superscript}) type {
//     return struct {
//         pub fn print(writer: anytype, num: )

// };
// }
const normal = [_][]const u8{
    "th",
    "st",
    "nd",
    "rd",
    "th",
    "th",
    "th",
    "th",
    "th",
    "th",
};

test "normal" {
    try std.testing.expectEqual(10, normal.len);
}

const superscripts = [_][]const u8{
    "ᵗʰ",
    "ˢᵗ",
    "ⁿᵈ",
    "ʳᵈ",
    "ᵗʰ",
    "ᵗʰ",
    "ᵗʰ",
    "ᵗʰ",
    "ᵗʰ",
    "ᵗʰ",
};

test "superscript" {
    try std.testing.expectEqual(10, superscripts.len);
}

/// Writes `num` followed by its English ordinal suffix ("1st", "2nd", "3rd",
/// "4th", ...), using Unicode superscript suffixes when `superscript` is
/// true. `num` must be an unsigned integer.
pub fn ordinal(writer: anytype, num: anytype, superscript: bool) !void {
    const info = @typeInfo(@TypeOf(num));
    if (info != .int) @compileError("ordinal can only print integers");
    if (info.int.signedness != .unsigned) @compileError("ordinal can only print unsigned integers");

    const table = if (superscript) superscripts else normal;

    try writer.print("{}", .{num});
    try writer.writeAll(
        switch (num / 10 % 10) {
            1 => table[0],
            else => table[num % 10],
        },
    );
}

test "print ordinal normal" {
    const cases = [_]struct { number: u16, result: []const u8 }{
        .{
            .number = 0,
            .result = "0th",
        },
        .{
            .number = 1,
            .result = "1st",
        },
        .{
            .number = 2,
            .result = "2nd",
        },
        .{
            .number = 3,
            .result = "3rd",
        },
        .{
            .number = 4,
            .result = "4th",
        },
        .{
            .number = 11,
            .result = "11th",
        },
        .{
            .number = 12,
            .result = "12th",
        },
        .{
            .number = 13,
            .result = "13th",
        },
        .{
            .number = 14,
            .result = "14th",
        },
        .{
            .number = 31,
            .result = "31st",
        },
        .{
            .number = 112,
            .result = "112th",
        },
        .{
            .number = 9311,
            .result = "9311th",
        },
    };

    inline for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();

        try ordinal(&buf.writer, case.number, false);
        try std.testing.expectEqualStrings(case.result, buf.written());
    }
}

test "print ordinal superscript" {
    const cases = [_]struct { number: u16, result: []const u8 }{
        .{
            .number = 0,
            .result = "0ᵗʰ",
        },
        .{
            .number = 1,
            .result = "1ˢᵗ",
        },
        .{
            .number = 2,
            .result = "2ⁿᵈ",
        },
        .{
            .number = 3,
            .result = "3ʳᵈ",
        },
        .{
            .number = 4,
            .result = "4ᵗʰ",
        },
        .{
            .number = 11,
            .result = "11ᵗʰ",
        },
        .{
            .number = 12,
            .result = "12ᵗʰ",
        },
        .{
            .number = 13,
            .result = "13ᵗʰ",
        },
        .{
            .number = 14,
            .result = "14ᵗʰ",
        },
        .{
            .number = 31,
            .result = "31ˢᵗ",
        },
        .{
            .number = 112,
            .result = "112ᵗʰ",
        },
        .{
            .number = 9311,
            .result = "9311ᵗʰ",
        },
    };

    inline for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();

        try ordinal(&buf.writer, case.number, true);
        try std.testing.expectEqualStrings(case.result, buf.written());
    }
}

/// Writes a UTC offset given in `seconds` east of UTC in the form `+HH:MM`
/// or `+HHMM`, depending on `separator`. The sign is always written, and
/// zero is written as `+00:00` rather than as `Z`.
///
/// Neither RFC 822 nor ISO 8601 can express an offset finer than a minute,
/// so an offset that is not a whole number of minutes is truncated towards
/// zero. That only arises for the local mean time offsets that timezones
/// used before standard time, such as America/Chicago's -5:50:36.
pub fn offset(writer: anytype, seconds: i32, separator: enum { none, colon }) !void {
    try writer.writeAll(if (seconds < 0) "-" else "+");

    const magnitude = @abs(seconds);
    try writer.print("{d:0>2}", .{magnitude / std.time.s_per_hour});
    switch (separator) {
        .none => {},
        .colon => try writer.writeAll(":"),
    }
    try writer.print("{d:0>2}", .{magnitude % std.time.s_per_hour / std.time.s_per_min});
}

test "offset" {
    const cases = [_]struct { seconds: i32, colon: []const u8, none: []const u8 }{
        .{ .seconds = 0, .colon = "+00:00", .none = "+0000" },
        .{ .seconds = -5 * std.time.s_per_hour, .colon = "-05:00", .none = "-0500" },
        .{ .seconds = 5 * std.time.s_per_hour + 45 * std.time.s_per_min, .colon = "+05:45", .none = "+0545" },
        .{ .seconds = -(3 * std.time.s_per_hour + 30 * std.time.s_per_min), .colon = "-03:30", .none = "-0330" },
        .{ .seconds = 14 * std.time.s_per_hour, .colon = "+14:00", .none = "+1400" },
        // America/Chicago's local mean time, truncated towards zero.
        .{ .seconds = -21036, .colon = "-05:50", .none = "-0550" },
    };

    for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();

        try offset(&buf.writer, case.seconds, .colon);
        try std.testing.expectEqualStrings(case.colon, buf.written());

        buf.clearRetainingCapacity();
        try offset(&buf.writer, case.seconds, .none);
        try std.testing.expectEqualStrings(case.none, buf.written());
    }
}
