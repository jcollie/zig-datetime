// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parses a fixed corpus of inputs against a fixed corpus of format
//! strings and writes the results out for `tools/oracle_parse.js` to check
//! against moment.js.
//!
//! The corpus lives here for the same reason the formatting one does: a
//! format string has to be comptime known, so only this side can
//! enumerate them. Only the sequences that can be parsed appear; the ones
//! that name no date, such as the quarter and the week, are a compile
//! error to parse and so cannot be in the list.
//!
//! There are two halves. The round trip half formats an instant and feeds
//! the result straight back in, which is the case that has to work and
//! covers a lot of ground cheaply. The awkward half is written by hand and
//! is where the two implementations are expected to part company: input
//! that is too short for its sequence, text left over at the end, a
//! separator that does not match, and values outside their range.
//!
//! Output is one record per line, tab separated: the format string, the
//! input, which of the two parsing modes it was read in, `ok` or `err`,
//! and then either how many bytes were consumed and the result rendered
//! canonically, or the name of the error.
//!
//! Every case is written twice, once per mode, and the checker holds each
//! to the matching mode of moment.
//!
//! Fields that the format string does not mention are taken from
//! `relative_to`, so the reference instant is fixed here and pinned to the
//! same value on the moment side. It is deliberately not the first of
//! January, because the two fill in a missing month and day differently
//! and a January reference would hide it.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;

/// What unmentioned fields are taken from, as milliseconds since the Unix
/// epoch: 2001-09-09T01:46:40Z. `tools/oracle_parse.js` pins moment's
/// `now` to the same instant, which is what it defaults from.
const reference = 1000000000000;

/// How every result is written for comparison. The two agree on
/// formatting, so rendering both sides the same way turns "did these
/// parse to the same value" into a string comparison.
const canonical = "YYYY-MM-DDTHH:mm:ss.SSSZ";

/// The instants the round trip half starts from, as milliseconds.
const instants = [_]i64{
    0, // the epoch, a Thursday
    1710513005123, // an ordinary afternoon
    1704240429000, // single digit month, day, hour, minute and second
    1704240000000, // midnight
    1710460800000, // noon
    1709164800000, // the leap day
    1735689599000, // the last second of a year
    -2208988800000, // 1900, well before the epoch
};

/// The offsets the round trip half reads those instants at, in minutes.
const offsets = [_]i32{ 0, -300, 345 };

/// The format strings for the round trip. Every one of these has to read
/// back what it wrote, whatever the two implementations do with the
/// awkward cases below.
const round_trip = [_][]const u8{
    "YYYY-MM-DD",
    "YYYY-MM-DDTHH:mm:ss",
    "YYYY-MM-DDTHH:mm:ssZ",
    "YYYY-MM-DDTHH:mm:ssZZ",
    "DD/MM/YYYY",
    "MM-DD",
    "YYYY",
    "YY-MM-DD",
    "HH:mm",
    "HH:mm:ss",
    "h:mm a",
    "h:mm A",
    "MMM D YYYY",
    "MMMM D, YYYY",
    "ddd, DD MMM YYYY HH:mm:ss ZZ",
    "dddd, D MMMM YYYY",
    "Do MMMM YYYY",
    "YYYY-DDDD",
    "E",
    "d",
};

/// Inputs that are not simply what this library wrote, which is where the
/// two are expected to differ. moment has a lenient mode and a strict one
/// and they disagree about most of these, so the checker reports each
/// against both rather than picking one.
const awkward = [_]struct { fmt: []const u8, inputs: []const []const u8 }{
    .{
        .fmt = "YYYY-MM-DD",
        .inputs = &.{
            "2024-03-15", // exact, as a control
            "2024-3-15", // unpadded where the sequence is padded
            "2024-03-15 and then some", // text left over
            "2024/03/15", // the separator does not match
            "2024-13-15", // month out of range
            "2024-02-31", // day out of range for the month
            "2024-00-15", // month below range
            "24-03-15", // year too short
            "", // nothing at all
            "hello", // not a date
            "2024-03", // stops early
        },
    },
    .{
        .fmt = "HH:mm",
        .inputs = &.{ "14:30", "4:30", "24:00", "14:60", "14:30:00", "14" },
    },
    .{
        .fmt = "YYYY",
        .inputs = &.{ "2024", "24", "202", "20244" },
    },
    .{
        .fmt = "MM-DD",
        .inputs = &.{ "03-15", "3-15", "12-31" },
    },
    .{
        .fmt = "MMM D YYYY",
        .inputs = &.{ "Mar 15 2024", "MAR 15 2024", "mar 15 2024", "Xxx 15 2024", "March 15 2024" },
    },
    .{
        .fmt = "h:mm a",
        .inputs = &.{ "2:30 pm", "2:30 PM", "12:30 am", "0:30 pm", "13:30 pm" },
    },
    .{
        .fmt = "YYYY-MM-DDTHH:mm:ssZ",
        .inputs = &.{
            "2024-03-15T14:30:00+00:00",
            "2024-03-15T14:30:00-05:00",
            "2024-03-15T14:30:00+0500",
            "2024-03-15T14:30:00Z",
        },
    },
    .{
        .fmt = "dddd, D MMMM YYYY",
        .inputs = &.{
            "Friday, 15 March 2024", // the weekday agrees with the date
            "Monday, 15 March 2024", // and here it does not
        },
    },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    const base = Instant.fromMilliTimestamp(reference).asDateTime();

    var line: [256]u8 = undefined;

    // The round trip: what this wrote, read straight back.
    inline for (round_trip) |fmt| {
        for (instants) |at| {
            for (offsets) |minutes| {
                const seconds = minutes * 60;
                const shifted: Instant = .{
                    .timestamp = Instant.fromMilliTimestamp(at).timestamp +
                        @as(i128, seconds) * std.time.ns_per_s,
                };
                var value = shifted.asDateTime();
                value.offset = seconds;

                var writer = std.Io.Writer.fixed(&line);
                try value.format(fmt, &writer);

                try report(out, fmt, writer.buffered(), base);
            }
        }
    }

    // And the inputs chosen to be difficult.
    inline for (awkward) |case| {
        for (case.inputs) |input| {
            try report(out, case.fmt, input, base);
        }
    }

    try out.flush();
}

/// Parses `input` against `fmt` in both modes and writes a record for
/// each.
fn report(
    out: *std.Io.Writer,
    comptime fmt: []const u8,
    input: []const u8,
    base: DateTime,
) !void {
    inline for (.{ DateTime.Mode.lenient, DateTime.Mode.strict }) |mode| {
        try reportOne(out, fmt, input, base, mode);
    }
}

/// Parses `input` against `fmt` in one mode and writes the record.
fn reportOne(
    out: *std.Io.Writer,
    comptime fmt: []const u8,
    input: []const u8,
    base: DateTime,
    mode: DateTime.Mode,
) !void {
    // A tab or a newline would make the record ambiguous. Nothing in the
    // corpus holds either, so this guards against one growing them.
    std.debug.assert(std.mem.indexOfAny(u8, fmt, "\t\n") == null);
    std.debug.assert(std.mem.indexOfAny(u8, input, "\t\n") == null);

    const result = DateTime.parseWith(fmt, input, .{
        .relative_to = base,
        .mode = mode,
    }) catch |err| {
        try out.print("{s}\t{s}\t{t}\terr\t{t}\n", .{ fmt, input, mode, err });
        return;
    };

    var rendered: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&rendered);
    try result.value.format(canonical, &writer);

    try out.print("{s}\t{s}\t{t}\tok\t{d} {s}\n", .{ fmt, input, mode, result.str.len, writer.buffered() });
}
