// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a corpus of instants against a corpus of Go layouts and writes
//! the results out for `tools/oracle_go.go` to check against Go's own
//! `time` package.
//!
//! The corpus lives here for the same reason the other two do: a layout
//! has to be comptime known for `golayout.format` to take it apart while
//! this is compiled, so only this side can enumerate them.
//!
//! Output is one record per line, tab separated, of two kinds. An `F`
//! record is a formatting result: the instant as milliseconds since the
//! Unix epoch, the offset it is read at in minutes east of UTC, the zone
//! name the reading carries, the layout, and what this library wrote. A
//! `P` record is what came back when that text was read again under the
//! same layout, rendered canonically, or `err` when it would not read.
//!
//! The zone name is carried because a layout may contain `MST`, and Go
//! writes the numeric offset there when a zone has no name. Passing the
//! name across rather than inventing one on the Go side keeps the two
//! answering the same question.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Designation = datetime.Designation;
const Instant = datetime.Instant;
const golayout = datetime.golayout;

/// How a parsed result is written for comparison. The two agree on
/// formatting, so rendering both sides the same way turns "did these read
/// the same thing" into a string comparison.
const canonical = "2006-01-02T15:04:05.000000000-07:00:00";

/// The instants to format, as milliseconds since the Unix epoch.
const instants = [_]i64{
    0, // the epoch, a Thursday
    1710513005123, // an ordinary afternoon
    1704240429000, // single digit month, day, hour, minute and second
    1704240000000, // midnight, where the twelve hour clock reads 12
    1710460800000, // noon, the other end of the meridiem
    1709164800000, // the leap day
    1735689599000, // the last second of a year
    -2208988800000, // 1900, well before the epoch
    1710513005000, // a whole second, so a trimmed fraction disappears
    1710513005100, // a tenth, so a trimmed fraction keeps one digit
    -62135596800000, // year 1, where a four digit year needs its padding
    -63500000000000, // a year before the common era, which needs a sign
};

/// The offsets those instants are read at, in minutes east of UTC, paired
/// with the name the zone goes by. The empty name is the case a `DateTime`
/// that never went through a `TimeZone` is in, and is what makes `MST`
/// fall back to a numeric offset on both sides.
const zones = [_]struct { minutes: i32, name: []const u8 }{
    .{ .minutes = 0, .name = "UTC" },
    .{ .minutes = -300, .name = "CDT" },
    .{ .minutes = 345, .name = "+0545" },
    .{ .minutes = 840, .name = "" },
    .{ .minutes = -720, .name = "" },
    .{ .minutes = 0, .name = "" },
};

/// Every piece of the reference time on its own, so that a disagreement
/// names the piece responsible rather than a combination.
const piece_layouts = [_][]const u8{
    "January",   "Jan",     "1",      "01",
    "Monday",    "Mon",     "2",      "_2",
    "02",        "__2",     "002",    "15",
    "3",         "03",      "4",      "04",
    "5",         "05",      "2006",   "06",
    "PM",        "pm",      "MST",    "-0700",
    "-070000",   "-07",     "-07:00", "-07:00:00",
    "Z0700",     "Z070000", "Z07",    "Z07:00",
    "Z07:00:00",
};

/// Both kinds of fractional second at several widths, and with both of
/// the characters that can introduce one.
const fraction_layouts = [_][]const u8{
    ".0",         ".00",        ".000",  ".000000",
    ".000000000", ".9",         ".99",   ".999",
    ".999999",    ".999999999", ",000",  ",999",
    ",9",         ".0000",      ".9999",
};

/// The layouts Go's own package names.
const named_layouts = [_][]const u8{
    "01/02 03:04:05PM '06 -0700",
    "Mon Jan _2 15:04:05 2006",
    "Mon Jan _2 15:04:05 MST 2006",
    "Mon Jan 02 15:04:05 -0700 2006",
    "02 Jan 06 15:04 MST",
    "02 Jan 06 15:04 -0700",
    "Monday, 02-Jan-06 15:04:05 MST",
    "Mon, 02 Jan 2006 15:04:05 MST",
    "Mon, 02 Jan 2006 15:04:05 -0700",
    "2006-01-02T15:04:05Z07:00",
    "2006-01-02T15:04:05.999999999Z07:00",
    "3:04PM",
    "Jan _2 15:04:05",
    "Jan _2 15:04:05.000",
    "Jan _2 15:04:05.000000",
    "Jan _2 15:04:05.000000000",
    "2006-01-02 15:04:05",
    "2006-01-02",
    "15:04:05",
};

/// The corners of the tokenizer, where something that nearly names a
/// piece of the reference time is a literal instead.
const corner_layouts = [_][]const u8{
    "Jane",                          "Month",      "January2",  "Mon2",
    "_2006",                         "__2006",     "20060102",  "150405",
    "hello",                         "",           "2006.0002", "MSTMST",
    "2006-01-02T15:04:05.000Z07:00", "[2006] Jan", "0",         "00",
    "07",                            "-07:0",      "Z",         "Z07:0",
    ".",                             ",",          ".0.0",      "2006 2006",
};

const layouts = piece_layouts ++ fraction_layouts ++ named_layouts ++ corner_layouts;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    var line: [256]u8 = undefined;

    for (instants) |at| {
        for (zones) |zone| {
            const seconds = zone.minutes * 60;
            const shifted: Instant = .{
                .timestamp = Instant.fromMilliTimestamp(at).timestamp +
                    @as(i128, seconds) * std.time.ns_per_s,
            };
            var value = shifted.asDateTime();
            value.offset = seconds;
            value.designation = .from(zone.name);

            inline for (layouts) |current| {
                var writer = std.Io.Writer.fixed(&line);
                try golayout.format(value, current, &writer);
                const formatted = writer.buffered();

                // The record separator would otherwise be ambiguous.
                std.debug.assert(std.mem.indexOfAny(u8, current, "\t\n") == null);
                std.debug.assert(std.mem.indexOfAny(u8, formatted, "\t\n") == null);

                try out.print("F\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{
                    at,
                    zone.minutes,
                    zone.name,
                    current,
                    formatted,
                });

                // And read it straight back, which is the case that has
                // to work and which puts every piece through the parser
                // without a second corpus to keep in step.
                var parse_result: [64]u8 = undefined;
                var parsed_writer = std.Io.Writer.fixed(&parse_result);
                if (golayout.parse(current, formatted)) |back| {
                    try golayout.format(back, canonical, &parsed_writer);
                    try out.print("P\t{s}\t{s}\tok\t{s}\n", .{
                        current,
                        formatted,
                        parsed_writer.buffered(),
                    });
                } else |_| {
                    try out.print("P\t{s}\t{s}\terr\t\n", .{ current, formatted });
                }
            }
        }
    }

    try out.flush();
}
