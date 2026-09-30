// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formats a corpus of instants against a corpus of .NET and PowerShell
//! format strings, reads text back, and writes the results out for
//! `src/oracle_powershell.ps1` to check against .NET and `Get-Date`
//! themselves.
//!
//! The corpus lives here for the same reason the other oracles' do: a
//! format string has to be comptime known for `dotnet.format` to take it
//! apart while this is compiled, so only this side can enumerate them.
//!
//! Output is one record per line, tab separated, with tabs, newlines and
//! backslashes in the text escaped as `\t`, `\n` and `\\`. There are three
//! kinds.
//!
//! An `F` record is a .NET formatting result: the culture, the instant as
//! milliseconds since the Unix epoch, the offset it is read at in minutes
//! east of UTC, the format string, and what `dotnet.formatIn` wrote.
//!
//! A `P` record is a .NET parse: the culture, the format string, the
//! text, and what `dotnet.parseIn` made of it -- `err`, or whether it had
//! an offset, the reading (in UTC when it had one, as written when not),
//! and the offset in minutes. The text is either what an `F` record wrote,
//! read straight back, or one of a list of inputs chosen for the corners
//! of the parser.
//!
//! A `G` record is `Get-Date`: the IANA zone the reading is local to, the
//! offset that zone has at that instant, the instant, which parameter,
//! the format string, and what `powershell.format` or `powershell.uformat`
//! wrote. `Get-Date` formats a local `DateTime`, so the oracle has to run
//! it in a process whose zone is the one named.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;
const dotnet = datetime.dotnet;
const powershell = datetime.powershell;

/// The instants to format, as milliseconds since the Unix epoch.
const instants = [_]i64{
    0, // the epoch, a Thursday
    1710513005123, // an ordinary afternoon
    1704240429000, // single digit month, day, hour, minute and second
    1704240000000, // midnight, where the twelve hour clock reads 12
    1710460800000, // noon, the other end of the meridiem
    1709164800000, // the leap day
    1735689599000, // the last second of a year
    1704067200000, // New Year's Day, where the week counts start over
    -2208988800000, // 1900, well before the epoch
    1136073600000, // a Sunday, where %u and %w disagree most
    1483228800000, // 2017-01-01, a Sunday: ISO week 52 of the year before
    1710513005500, // half a second, which %s rounds up
    1710513005100, // a tenth, so a trimmed fraction keeps one digit
    -400, // just before the epoch, which %s writes as -0
    -1500, // a second and a half before it, which rounds away from zero
    -62135424000000, // 0001-01-03, where a four digit year needs its padding
    253402218000000, // 9999-12-31T01:00Z, the last day .NET holds
};

/// The offsets the instants are read at for .NET's own formatting, in
/// minutes east of UTC. .NET's `DateTimeOffset` holds whole minutes
/// within fourteen hours, and so does this list.
const offsets = [_]i32{ 0, -300, 345, 840, -720, 330 };

/// The zones `Get-Date` is run in, and the offset each has. Kathmandu has
/// had +05:45 only since 1986, so it is asked only about instants after
/// that; the other three have never changed.
const zones = [_]struct { name: []const u8, minutes: i32, since: i64 }{
    .{ .name = "UTC", .minutes = 0, .since = std.math.minInt(i64) },
    .{ .name = "Etc/GMT+5", .minutes = -300, .since = std.math.minInt(i64) },
    .{ .name = "Asia/Kathmandu", .minutes = 345, .since = 504901800000 },
    .{ .name = "Etc/GMT-14", .minutes = 840, .since = std.math.minInt(i64) },
};

/// Every standard format.
const standard = [_][]const u8{
    "d", "D", "f", "F", "g", "G", "m", "M", "o", "O",
    "r", "R", "s", "t", "T", "u", "U", "y", "Y",
};

/// Every custom specifier on its own, at every width that means something
/// different and one past it.
const specifiers = [_][]const u8{
    "%d",     "dd",      "ddd", "dddd", "ddddd", "%M",   "MM",     "MMM",
    "MMMM",   "MMMMM",   "%y",  "yy",   "yyy",   "yyyy", "yyyyy",  "%h",
    "hh",     "hhh",     "%H",  "HH",   "HHH",   "%m",   "mm",     "mmm",
    "%s",     "ss",      "sss", "%f",   "ff",    "fff",  "ffff",   "fffff",
    "ffffff", "fffffff", "%F",  "FF",   "FFF",   "FFFF", "FFFFFF", "FFFFFFF",
    "%t",     "tt",      "ttt", "%g",   "gg",    "%z",   "zz",     "zzz",
    "zzzz",   "%K",      "KK",  "%:",   "%/",    "d/M",  "H:m",
};

/// The shapes callers actually write, and the corners of the tokenizer.
const shapes = [_][]const u8{
    "yyyy-MM-ddTHH:mm:ss.fffK",
    "yyyy-MM-ddTHH:mm:ss.fffffffzzz",
    "dddd MM/dd/yyyy HH:mm K",
    "dddd, MMMM d, yyyy h:mm:ss tt",
    "ddd, dd MMM yyyy HH:mm:ss 'GMT'",
    "d MMMM yyyy",
    "MMMM d",
    "MMM d, yyyy",
    "h:mm tt",
    "hh:mm:ss.FF t",
    "HH:mm:ss zzz",
    "HH:mm:ss.FFFFFFF",
    "yyyyMMdd",
    "yyyyMMddZ",
    "yyyyMMddTHHmmssffff",
    "yyyyMMddTHHmmssffffZ",
    "yyyy/MM/dd",
    "yy-M-d",
    "ss.FFF",
    "ss'.'FFF",
    "ss\\.FFF",
    "tt.FFF",
    "s.F",
    ".FF",
    "'day' d",
    "\\d\\a\\y d",
    "\"quoted\" d",
    "'it''s' d",
    "'a\\'b' d",
    "%dd",
    "%yy",
    "GMT",
    "Gmt HH",
    "HHZ",
    "hello",
    "yyyy-MM-dd HH:mm:ss.fff gg",
    "\u{65e5}d\\\u{65e5}",
    "%\u{65e5}",
};

const formats = standard ++ specifiers ++ shapes;

/// Texts handed to the parser that no formatter here wrote, each with the
/// format string and culture to read it under, chosen for the corners of
/// .NET's `ParseExact`: widths, case, separators, the meridiem, offsets,
/// an optional fraction, fields that repeat, and dates that are not dates.
const parse_cases = [_]struct { format: []const u8, text: []const u8, en_us: bool = false }{
    .{ .format = "d", .text = "3/5/2024" },
    .{ .format = "M/d/yyyy", .text = "3/5/2024" },
    .{ .format = "M/d/yyyy", .text = "03/05/2024" },
    .{ .format = "M/d/yyyy", .text = "003/05/2024" },
    .{ .format = "dd MMM yyyy", .text = "5 Mar 2024" },
    .{ .format = "d MMM yyyy", .text = "05 mar 2024" },
    .{ .format = "d MMMM yyyy", .text = "5 MARCH 2024" },
    .{ .format = "d MMM yyyy", .text = "5 March 2024" },
    .{ .format = "d MMMM yyyy", .text = "5 Mar 2024" },
    .{ .format = "MMM", .text = "SEPT" },
    .{ .format = "dddd", .text = "Tues" },
    .{ .format = "HH:mm", .text = "7:05" },
    .{ .format = "H:mm", .text = "7:05" },
    .{ .format = "H:mm", .text = "07:05" },
    .{ .format = "h:mm tt", .text = "7:05 pm" },
    .{ .format = "h:mm tt", .text = "13:05 PM" },
    .{ .format = "h:mm tt", .text = "0:05 PM" },
    .{ .format = "HH:mm tt", .text = "13:05 AM" },
    .{ .format = "HH:mm tt", .text = "13:05 PM" },
    .{ .format = "hh", .text = "12" },
    .{ .format = "hh tt", .text = "12 AM" },
    .{ .format = "H tt", .text = "0 AM" },
    .{ .format = "%t HH", .text = "A 10" },
    .{ .format = "%t HH", .text = "a 10" },
    .{ .format = "%t HH", .text = "P 10" },
    .{ .format = "yy", .text = "49" },
    .{ .format = "yy", .text = "50" },
    .{ .format = "%y", .text = "5" },
    .{ .format = "yyy", .text = "019" },
    .{ .format = "yyyy", .text = "0000" },
    .{ .format = "yyyy", .text = "24" },
    .{ .format = "yyyyy", .text = "12345" },
    .{ .format = "yyyyy", .text = "02024" },
    .{ .format = "HH zzz", .text = "10 +5:30" },
    .{ .format = "HH zzz", .text = "10 +0530" },
    .{ .format = "HH zzz", .text = "10 +05:3" },
    .{ .format = "HH zzz", .text = "10 +15:00" },
    .{ .format = "HH zzz", .text = "10 +14:00" },
    .{ .format = "HH zzz", .text = "10 05:30" },
    .{ .format = "HH z", .text = "10 +5" },
    .{ .format = "HH z", .text = "10 +05" },
    .{ .format = "HH zz", .text = "10 +5" },
    .{ .format = "HH zz", .text = "10 -05" },
    .{ .format = "HH K", .text = "10 Z" },
    .{ .format = "HH K", .text = "10 " },
    .{ .format = "HH K", .text = "10 -07:00" },
    .{ .format = "HHK", .text = "10" },
    .{ .format = "HH zzz K", .text = "10 +05:00 +05:00" },
    .{ .format = "HH zzz K", .text = "10 +05:00 Z" },
    .{ .format = "ss.FFF", .text = "05" },
    .{ .format = "ss.FFF", .text = "05.1" },
    .{ .format = "ss.FFF", .text = "05." },
    .{ .format = "ss.FFF", .text = "05.1234" },
    .{ .format = "ss.fff", .text = "05.12" },
    .{ .format = "ss.fff", .text = "05.123" },
    .{ .format = "ss.f fff", .text = "05.1 100" },
    .{ .format = "ss.f fff", .text = "05.1 123" },
    .{ .format = "HHZ", .text = "10Z" },
    .{ .format = "HHZ", .text = "10gmt" },
    .{ .format = "HHZ", .text = "10Zulu" },
    .{ .format = "HH GMT", .text = "10 GMT" },
    .{ .format = "HH GMT", .text = "10 gmt" },
    .{ .format = "HH 'GMT'", .text = "10 GMT" },
    .{ .format = "ddd dd MMM yyyy", .text = "Thu 15 Mar 2024" },
    .{ .format = "ddd dd MMM yyyy", .text = "fri 15 Mar 2024" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000Z" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000+5:45" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000+05:45" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.123-05:00" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000+05:99" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000z" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000+0545" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000-14:00" },
    .{ .format = "o", .text = "2024-03-15T14:30:05.1230000-15:00" },
    .{ .format = "O", .text = "2024-02-30T14:30:05.1230000Z" },
    .{ .format = "o", .text = "2024-03-15 14:30:05.1230000Z" },
    .{ .format = "R", .text = "fri, 15 mar 2024 19:30:05 GMT" },
    .{ .format = "R", .text = "Fri, 15 Mar 2024 19:30:05 gmt" },
    .{ .format = "R", .text = "Thu, 15 Mar 2024 19:30:05 GMT" },
    .{ .format = "r", .text = "Fri, 5 Mar 2024 19:30:05 GMT" },
    .{ .format = "r", .text = "Fri, 15 Mar 2024 19:30:05 GMT " },
    .{ .format = "r", .text = "Fri,15 Mar 2024 19:30:05 GMT" },
    .{ .format = "u", .text = "2024-03-15 19:30:05Z" },
    .{ .format = "u", .text = "2024-03-15 19:30:05z" },
    .{ .format = "s", .text = "2024-03-15T19:30:05" },
    .{ .format = "dd/MM/yyyy", .text = "15-03-2024" },
    .{ .format = "%d", .text = "15" },
    .{ .format = "%dd", .text = "15" },
    .{ .format = "%dd", .text = "5" },
    .{ .format = "d d", .text = "5 6" },
    .{ .format = "d dd", .text = "5 05" },
    .{ .format = "MMMM", .text = "March" },
    .{ .format = "MM/dd", .text = "03/15" },
    .{ .format = "HH:mm", .text = "14:30" },
    .{ .format = "g", .text = "03/15/2024 14:30" },
    .{ .format = "gg yyyy", .text = "A.D. 2024" },
    .{ .format = "gg yyyy", .text = "ad 2024" },
    .{ .format = "gg yyyy", .text = "B.C. 2024" },
    .{ .format = "yyyy-MM-dd", .text = "2024-02-30" },
    .{ .format = "yyyy-MM-dd", .text = "2023-02-29" },
    .{ .format = "yyyy-MM-dd", .text = "2024-13-01" },
    .{ .format = "HH:mm:ss", .text = "23:59:60" },
    .{ .format = "HH:mm:ss", .text = "24:00:00" },
    .{ .format = "yyyy-MM-dd HH:mm", .text = "2024-03-15  14:30" },
    .{ .format = "yyyy-MM-dd", .text = "2024-03-15 " },
    .{ .format = "yyyy-MM-dd", .text = " 2024-03-15" },
    .{ .format = "yyyyMMddTHHmmssffffZ", .text = "20240315T1930051234Z" },
    .{ .format = "yyyyMMddZ", .text = "20240315" },
    .{ .format = "t", .text = "7:05\u{202F}PM", .en_us = true },
    .{ .format = "t", .text = "7:05 PM", .en_us = true },
    .{ .format = "g", .text = "3/15/2024 2:30\u{202F}PM", .en_us = true },
    .{ .format = "gg yyyy", .text = "AD 2024", .en_us = true },
    .{ .format = "gg yyyy", .text = "A 2024", .en_us = true },
    .{ .format = "gg yyyy", .text = "A.D. 2024", .en_us = true },
};

/// Every `-UFormat` conversion on its own, the composites, and the
/// corners of PowerShell's translation.
const uformats = [_][]const u8{
    "%A",     "%a",           "%B",    "%b",                "%C",                "%c",                "%D",        "%d",
    "%e",     "%F",           "%G",    "%g",                "%H",                "%h",                "%I",        "%j",
    "%k",     "%l",           "%M",    "%m",                "%n",                "%p",                "%R",        "%r",
    "%S",     "%s",           "%t",    "%T",                "%U",                "%u",                "%V",        "%W",
    "%w",     "%X",           "%x",    "%Y",                "%y",                "%Z",                "%%",        "+%Y",
    "{{%Y}}", "100%% %Y",     "hello", "%A %m/%d/%Y %R %Z", "%A %B/%d/%Y %T %Z", "%Y-%m-%dT%H:%M:%S", "%G-W%V-%u", "%j of %Y",
    "%s.%S",  "%Y%m%d%H%M%S",
};

/// The `-Format` strings to hand `Get-Date`: PowerShell's four names, in
/// more than one case, and the .NET formats whose answer depends on the
/// value being a local `DateTime`.
const psformats = [_][]const u8{
    "FileDate",                "FileDateUniversal",     "FileDateTime", "FileDateTimeUniversal",
    "filedate",                "FILEDATETIMEUNIVERSAL", "o",            "O",
    "u",                       "R",                     "U",            "%K",
    "zzz",                     "%z",                    "s",            "F",
    "dddd MM/dd/yyyy HH:mm K",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    // Where the date comes from when a text does not give one. .NET reads
    // the clock there, and the oracle runs .NET in UTC, so today in UTC is
    // what makes the two agree.
    var relative_to = DateTime.utc(io);
    relative_to.hour = 0;
    relative_to.minute = 0;
    relative_to.second = 0;
    relative_to.nanosecond = 0;
    const options: dotnet.Options = .{ .relative_to = relative_to };

    var line: [512]u8 = undefined;

    inline for (.{ "invariant", "en-US" }) |culture_name| {
        const culture = comptime if (std.mem.eql(u8, culture_name, "en-US")) dotnet.Culture.en_us else dotnet.Culture.invariant;

        for (instants) |at| {
            for (offsets) |minutes| {
                const value = reading(at, minutes);

                inline for (formats) |current| {
                    var writer = std.Io.Writer.fixed(&line);
                    try dotnet.formatIn(value, current, culture, &writer);
                    const formatted = writer.buffered();

                    try out.print("F\t{s}\t{d}\t{d}\t", .{ culture_name, at, minutes });
                    try escaped(out, current);
                    try out.writeByte('\t');
                    try escaped(out, formatted);
                    try out.writeByte('\n');

                    // And read it straight back, which puts every
                    // specifier through the parser without a second corpus
                    // to keep in step.
                    try parseRecord(out, culture_name, current, formatted, dotnet.parseIn(current, formatted, culture, options));
                }
            }
        }

        inline for (parse_cases) |case| {
            if (case.en_us == std.mem.eql(u8, culture_name, "en-US")) {
                try parseRecord(out, culture_name, case.format, case.text, dotnet.parseIn(case.format, case.text, culture, options));
            }
        }
    }

    for (zones) |zone| {
        for (instants) |at| {
            if (at < zone.since) continue;
            const value = reading(at, zone.minutes);

            inline for (psformats) |current| {
                var writer = std.Io.Writer.fixed(&line);
                try powershell.format(value, current, &writer);
                try gRecord(out, zone.name, zone.minutes, at, "Format", current, writer.buffered());
            }
            inline for (uformats) |current| {
                var writer = std.Io.Writer.fixed(&line);
                try powershell.uformat(value, current, &writer);
                try gRecord(out, zone.name, zone.minutes, at, "UFormat", current, writer.buffered());
            }
        }
    }

    try out.flush();
}

/// The reading of the instant `at` milliseconds after the epoch at an
/// offset of `minutes` east of UTC.
fn reading(at: i64, minutes: i32) DateTime {
    const seconds = minutes * 60;
    const shifted: Instant = .{
        .timestamp = Instant.fromMilliTimestamp(at).timestamp +
            @as(i128, seconds) * std.time.ns_per_s,
    };
    var value = shifted.asDateTime();
    value.offset = seconds;
    return value;
}

/// Writes a `P` record for what `dotnet.parseIn` made of `text`.
fn parseRecord(
    out: *std.Io.Writer,
    culture_name: []const u8,
    format_string: []const u8,
    text: []const u8,
    result: dotnet.ParseError!dotnet.Result,
) !void {
    try out.print("P\t{s}\t", .{culture_name});
    try escaped(out, format_string);
    try out.writeByte('\t');
    try escaped(out, text);

    const parsed = result catch {
        try out.writeAll("\terr\n");
        return;
    };
    // In UTC when it had an offset, which is how .NET reports one it was
    // told to adjust to UTC; as written when it did not.
    const shown = if (parsed.has_offset) parsed.value.toUtc() else parsed.value;
    try out.print("\t{d}\t{d}-{d}-{d}T{d}:{d}:{d}.{d:0>7}\t{d}\n", .{
        @intFromBool(parsed.has_offset),
        shown.year,
        shown.month.monthNumber(),
        shown.day,
        shown.hour,
        shown.minute,
        shown.second,
        shown.nanosecond / 100,
        @divFloor(parsed.value.offset, 60),
    });
}

/// Writes a `G` record.
fn gRecord(
    out: *std.Io.Writer,
    zone: []const u8,
    minutes: i32,
    at: i64,
    parameter: []const u8,
    format_string: []const u8,
    formatted: []const u8,
) !void {
    try out.print("G\t{s}\t{d}\t{d}\t{s}\t", .{ zone, minutes, at, parameter });
    try escaped(out, format_string);
    try out.writeByte('\t');
    try escaped(out, formatted);
    try out.writeByte('\n');
}

/// Writes `text` with the three characters that would break a record
/// escaped.
fn escaped(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |char| switch (char) {
        '\t' => try out.writeAll("\\t"),
        '\n' => try out.writeAll("\\n"),
        '\\' => try out.writeAll("\\\\"),
        else => try out.writeByte(char),
    };
}
