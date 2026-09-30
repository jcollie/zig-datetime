// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formatting and parsing with .NET's date and time format strings, the
//! vocabulary of `DateTime.ToString`, `DateTimeOffset.ParseExact` and
//! PowerShell's `Get-Date -Format`.
//!
//! There are two kinds of format string, told apart by their length. One
//! character is a *standard* format, which names a pattern the culture
//! supplies: `d` is the short date, `T` the long time, `o` the round trip
//! form. Anything longer is a *custom* format, where letters repeat to ask
//! for a width or a name: `yyyy-MM-dd`, `dddd, MMMM d`, `HH:mm:ss.fff`.
//! A custom specifier on its own is written with a `%` in front of it,
//! `%d`, because `d` alone would be the standard short date.
//!
//! ```zig
//! try dotnet.format(value, "yyyy-MM-ddTHH:mm:ss.fffzzz", writer);
//! try dotnet.format(value, "O", writer);    // 2024-03-15T14:30:05.1230000-05:00
//! const back = try dotnet.parse("dd MMM yyyy", "15 Mar 2024");
//! ```
//!
//! This is the sixth vocabulary in the library, beside the moment.js
//! sequences, Go's layouts, the CLDR patterns, the C library's `strftime`
//! and PowerShell's `-UFormat` in `powershell`. It is here because a C#
//! program, a PowerShell script or an Excel-adjacent export has usually
//! written its dates this way, and translating one by hand is how a `MM`
//! for the month becomes an `mm` for the minute.
//!
//! The format string is comptime, so it is taken apart while this is
//! compiled and what is left at runtime is a straight line of writes or
//! reads. Everything .NET answers with a `FormatException` -- an
//! unterminated quote, a `%` at the end, eight `f`s, a single character
//! that names no standard format -- is a compile error here.
//!
//! A culture supplies what a standard format expands to and the names and
//! separators a custom one writes; see `Culture`. `Culture.invariant` is
//! the default, and `Culture.en_us` is what most PowerShell sessions run
//! in.
//!
//! The .NET runtime is the specification, and `zig build
//! oracle-powershell` checks it: .NET formats the same corpus, reads back
//! what this wrote, and the results are diffed. .NET has two types a
//! format string is applied to, and this follows `DateTimeOffset`, the
//! one that carries an offset the way a `DateTime` here does. Where this
//! deliberately differs it is written down on the piece that differs, and
//! the oracle carries the same list so that anything else is a failure.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Month = @import("month.zig").Month;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const Year = @import("year.zig").Year;
const locale = @import("locale.zig");

/// What a culture contributes to a format string: the patterns the
/// standard formats expand to, the separators `/` and `:` stand for, the
/// meridiem, the era, and the month and day names.
///
/// This is the part of .NET's `DateTimeFormatInfo` that formatting and
/// parsing a Gregorian date read. It is a comptime value, because a
/// standard format is a pattern that has to be taken apart while this is
/// compiled; a culture of your own is a struct literal.
pub const Culture = struct {
    /// What .NET calls it: "" for the invariant culture, "en-US".
    name: []const u8,
    /// Where the month and day names come from.
    names: locale.Locale,

    /// `d`.
    short_date_pattern: []const u8,
    /// `D`, and the date half of `f` and `F`.
    long_date_pattern: []const u8,
    /// `t`, and the time half of `f` and `g`.
    short_time_pattern: []const u8,
    /// `T`, and the time half of `G`.
    long_time_pattern: []const u8,
    /// `F` and `U`.
    full_date_time_pattern: []const u8,
    /// `m` and `M`.
    month_day_pattern: []const u8,
    /// `y` and `Y`.
    year_month_pattern: []const u8,

    /// What `/` writes.
    date_separator: []const u8,
    /// What `:` writes.
    time_separator: []const u8,
    /// What `tt` writes before noon; `t` writes its first character.
    am_designator: []const u8,
    /// What `tt` writes from noon on.
    pm_designator: []const u8,
    /// What `g` writes: the era every year from 1 onwards is in.
    era_name: []const u8,
    /// The other spelling of the era, which parsing also accepts.
    abbreviated_era_name: []const u8,

    /// The last year a two digit year can stand for, so that with the
    /// default 2049 `49` is 2049 and `50` is 1950. This is .NET's
    /// `Calendar.TwoDigitYearMax`, which moved from 2029 to 2049 in .NET 8.
    two_digit_year_max: Year = 2049,

    /// `CultureInfo.InvariantCulture`: the culture meant for text that
    /// machines read back, and the one PowerShell itself uses when it
    /// turns a date into a string inside an expression.
    pub const invariant: Culture = .{
        .name = "",
        .names = locale.en,
        .short_date_pattern = "MM/dd/yyyy",
        .long_date_pattern = "dddd, dd MMMM yyyy",
        .short_time_pattern = "HH:mm",
        .long_time_pattern = "HH:mm:ss",
        .full_date_time_pattern = "dddd, dd MMMM yyyy HH:mm:ss",
        .month_day_pattern = "MMMM dd",
        .year_month_pattern = "yyyy MMMM",
        .date_separator = "/",
        .time_separator = ":",
        .am_designator = "AM",
        .pm_designator = "PM",
        .era_name = "A.D.",
        .abbreviated_era_name = "AD",
    };

    /// `en-US`, which is what `Get-Date` formats with on most machines.
    ///
    /// .NET on Linux and macOS takes a culture's patterns from ICU, and
    /// these are what .NET 10 reads from ICU 76. The space before `tt` is
    /// U+202F NARROW NO-BREAK SPACE rather than an ordinary one, because
    /// CLDR 42 changed it; an older ICU, or Windows' own data, still has
    /// U+0020 there.
    pub const en_us: Culture = .{
        .name = "en-US",
        .names = locale.en,
        .short_date_pattern = "M/d/yyyy",
        .long_date_pattern = "dddd, MMMM d, yyyy",
        .short_time_pattern = "h:mm\u{202F}tt",
        .long_time_pattern = "h:mm:ss\u{202F}tt",
        .full_date_time_pattern = "dddd, MMMM d, yyyy h:mm:ss\u{202F}tt",
        .month_day_pattern = "MMMM d",
        .year_month_pattern = "MMMM yyyy",
        .date_separator = "/",
        .time_separator = ":",
        .am_designator = "AM",
        .pm_designator = "PM",
        .era_name = "AD",
        .abbreviated_era_name = "A",
    };
};

test Culture {
    // The two built in cultures differ in their patterns and agree in
    // their names.
    try std.testing.expectEqualStrings("MM/dd/yyyy", Culture.invariant.short_date_pattern);
    try std.testing.expectEqualStrings("M/d/yyyy", Culture.en_us.short_date_pattern);
    try std.testing.expectEqualStrings(Culture.invariant.am_designator, Culture.en_us.am_designator);
}

/// The patterns behind the standard formats that are the same in every
/// culture, spelled the way .NET's `DateTimeFormatInfo` spells them.
pub const pattern = struct {
    /// `o` and `O`: every digit a `DateTimeOffset` holds, and its offset.
    pub const round_trip = "yyyy'-'MM'-'dd'T'HH':'mm':'ss'.'fffffffK";
    /// `r` and `R`: RFC 1123, in UTC.
    pub const rfc1123 = "ddd, dd MMM yyyy HH':'mm':'ss 'GMT'";
    /// `s`: ISO 8601 without an offset, as the reading stands.
    pub const sortable = "yyyy'-'MM'-'dd'T'HH':'mm':'ss";
    /// `u`: the same with a space for the `T`, in UTC.
    pub const universal_sortable = "yyyy'-'MM'-'dd HH':'mm':'ss'Z'";
};

/// What a custom specifier stands for, named for its meaning rather than
/// its letter, with the letter beside it.
pub const Specifier = enum {
    /// `d`, `dd`: the day of the month; `ddd`, `dddd`: the weekday's name.
    day,
    /// `M`, `MM`: the month's number; `MMM`, `MMMM`: its name.
    month,
    /// `y` onwards: the year, or its last two digits for `y` and `yy`.
    year,
    /// `h`, `hh`: the hour on a twelve hour clock.
    hour12,
    /// `H`, `HH`: the hour on a twenty-four hour clock.
    hour24,
    /// `m`, `mm`.
    minute,
    /// `s`, `ss`.
    second,
    /// `f` through `fffffff`: that many digits of the second's fraction.
    fraction,
    /// `F` through `FFFFFFF`: the same with the trailing zeros dropped.
    fraction_trimmed,
    /// `t`: the meridiem's first character; `tt`: the whole of it.
    meridiem,
    /// `g`, `gg`: the era.
    era,
    /// `z`, `zz`, `zzz`: the offset in hours, or hours and minutes.
    offset,
    /// `K`: the offset as `+hh:mm`.
    offset_round_trip,
    /// `:`: the culture's time separator.
    time_separator,
    /// `/`: the culture's date separator.
    date_separator,
    /// `Z` when reading: `Z` or `GMT`, meaning UTC. Writing, it is text.
    zulu,
    /// `GMT` when reading, in any case, unquoted: the text `GMT`, meaning
    /// UTC. Writing, its `M` is a month, so this is never produced then.
    gmt,
    /// A `.` directly followed by two `F`s or more when reading. .NET
    /// treats the two as one optional piece: the dot may be missing, and
    /// the fraction with it.
    dot_fraction,
};

/// One specifier and how many times its letter was repeated.
pub const Field = struct {
    which: Specifier,
    /// How many times the letter was written, which is what decides the
    /// width or the form: `M` is 3, `MM` is 03, `MMM` is Mar.
    count: u8 = 1,
    /// Whether a month name here takes the form a language uses after a
    /// day number. .NET decides it from whether a `d` or `dd` stands near
    /// the `MMM`; see `usesGenitive`.
    genitive: bool = false,
};

/// A format string is a run of these: text to copy through, or a field
/// to fill in.
pub const Chunk = union(enum) {
    literal: []const u8,
    field: Field,
};

/// Whether a format string is being compiled to be written or to be read.
///
/// The two are not the same. .NET's formatter and its parser each have
/// their own tokenizer, and they disagree about `%dd`, about `Z` and
/// about an unquoted `GMT`; the difference is recorded on `compile`.
pub const Purpose = enum { format, parse };

/// A compiled format string: its chunks, and what the standard format it
/// came from, if any, asked for on top of them.
pub const Compiled = struct {
    chunks: []const Chunk,
    /// Whether the value is moved into UTC before it is written, and
    /// whether the text read is UTC whatever it says: `r`, `u` and `U`.
    universal: bool = false,
    /// Whether the culture's own names are set aside for the invariant
    /// ones: `o`, `r`, `s` and `u`, which are meant to be read by
    /// machines.
    invariant: bool = false,
    /// The two standard formats .NET reads with code of its own rather
    /// than through their pattern, which is stricter than the pattern
    /// would be.
    shape: enum { pattern, rfc1123, round_trip } = .pattern,
};

/// Takes a format string apart, expanding a standard format into the
/// culture's pattern first.
///
/// A string of one character is a standard format and must be one of
/// `dDfFgGmMoOrRstTuUyY`. Anything longer is a custom format, which is
/// read left to right:
///
/// - The letters `d M y h H m s f F t g z` take every repeat of themselves
///   that follows as one field; `K` is always one character long.
/// - `:` and `/` are the culture's separators.
/// - `'...'` and `"..."` are literal text, inside which `\` escapes the
///   next character.
/// - `\` makes the next character literal.
/// - `%` makes the next character a specifier of its own, which is how a
///   custom format of one specifier is told from a standard one.
/// - Anything else is literal text.
///
/// Reading, three things differ, because .NET's parser tokenizes for
/// itself: `%` is skipped and the specifier after it keeps its repeats, so
/// `%dd` is one `dd` rather than two `d`; `Z` means UTC rather than the
/// letter Z; and an unquoted `GMT`, in any case, is the text GMT and
/// means UTC. A `.` directly before `FF` or more becomes `.dot_fraction`.
///
/// What .NET refuses with a `FormatException` is a compile error: a `%`
/// at the end or doubled, a `\` at the end, an unterminated quote, more
/// than seven `f` or `F`, and a single character that is no standard
/// format.
pub fn compile(
    comptime format_string: []const u8,
    comptime culture: Culture,
    comptime purpose: Purpose,
) Compiled {
    comptime {
        if (format_string.len == 0) @compileError(
            "dotnet: an empty format string asks for .NET's default format; name one, such as \"G\"",
        );
        if (format_string.len > 1) return .{ .chunks = tokenize(format_string, purpose) };

        return switch (format_string[0]) {
            'd' => .{ .chunks = tokenize(culture.short_date_pattern, purpose) },
            'D' => .{ .chunks = tokenize(culture.long_date_pattern, purpose) },
            'f' => .{ .chunks = tokenize(culture.long_date_pattern ++ " " ++ culture.short_time_pattern, purpose) },
            'F' => .{ .chunks = tokenize(culture.full_date_time_pattern, purpose) },
            'g' => .{ .chunks = tokenize(culture.short_date_pattern ++ " " ++ culture.short_time_pattern, purpose) },
            'G' => .{ .chunks = tokenize(culture.short_date_pattern ++ " " ++ culture.long_time_pattern, purpose) },
            'm', 'M' => .{ .chunks = tokenize(culture.month_day_pattern, purpose) },
            'o', 'O' => .{ .chunks = tokenize(pattern.round_trip, purpose), .invariant = true, .shape = .round_trip },
            'r', 'R' => .{ .chunks = tokenize(pattern.rfc1123, purpose), .invariant = true, .universal = true, .shape = .rfc1123 },
            's' => .{ .chunks = tokenize(pattern.sortable, purpose), .invariant = true },
            't' => .{ .chunks = tokenize(culture.short_time_pattern, purpose) },
            'T' => .{ .chunks = tokenize(culture.long_time_pattern, purpose) },
            'u' => .{ .chunks = tokenize(pattern.universal_sortable, purpose), .invariant = true, .universal = true },
            'U' => .{ .chunks = tokenize(culture.full_date_time_pattern, purpose), .universal = true },
            'y', 'Y' => .{ .chunks = tokenize(culture.year_month_pattern, purpose) },
            else => @compileError(
                "dotnet: '" ++ format_string ++ "' is not a standard format; a custom specifier on its own is written with a % in front of it, as '%" ++ format_string ++ "'",
            ),
        };
    }
}

test compile {
    // A standard format expands to the culture's pattern.
    const short = comptime compile("d", Culture.invariant, .format);
    try std.testing.expectEqual(@as(usize, 5), short.chunks.len);
    try std.testing.expectEqual(Specifier.month, short.chunks[0].field.which);
    try std.testing.expectEqual(Specifier.date_separator, short.chunks[1].field.which);

    // And says what it asks for beyond the pattern.
    try std.testing.expect((comptime compile("u", Culture.invariant, .format)).universal);
    try std.testing.expect(!(comptime compile("s", Culture.invariant, .format)).universal);

    // Two characters or more is a custom format.
    const custom = comptime compile("dd", Culture.invariant, .format);
    try std.testing.expectEqual(@as(u8, 2), custom.chunks[0].field.count);
}

/// The length of the UTF-8 sequence starting with `byte`, or 1 for a byte
/// that starts none, so that an escape or a `%` takes a whole character
/// rather than splitting one.
fn sequenceLength(comptime byte: u8) usize {
    return std.unicode.utf8ByteSequenceLength(byte) catch 1;
}

/// How many times `format_string[at]` repeats, starting there.
fn repeatCount(comptime format_string: []const u8, comptime at: usize) usize {
    var end = at + 1;
    while (end < format_string.len and format_string[end] == format_string[at]) end += 1;
    return end - at;
}

/// Splits a custom format string into chunks; see `compile` for the
/// rules.
pub fn tokenize(comptime format_string: []const u8, comptime purpose: Purpose) []const Chunk {
    comptime {
        @setEvalBranchQuota(200000);

        var chunks: []const Chunk = &.{};
        var text: []const u8 = "";
        var i: usize = 0;

        while (i < format_string.len) {
            const char = format_string[i];

            if (specifierOf(char)) |which| {
                const count = if (which == .offset_round_trip or which == .time_separator or which == .date_separator)
                    1
                else
                    repeatCount(format_string, i);

                if ((which == .fraction or which == .fraction_trimmed) and count > 7) @compileError(
                    "dotnet: '" ++ format_string ++ "' asks for more than seven digits of a fraction, which is all .NET holds",
                );
                if (which == .year and purpose == .parse and count > 9) @compileError(
                    "dotnet: '" ++ format_string ++ "' reads more than nine digits of a year",
                );

                chunks = flush(chunks, &text);
                chunks = chunks ++ &[_]Chunk{.{ .field = .{
                    .which = which,
                    .count = count,
                    .genitive = which == .month and count >= 3 and usesGenitive(format_string, i, count),
                } }};
                i += count;
                continue;
            }

            switch (char) {
                '\'', '"' => {
                    var j = i + 1;
                    var closed = false;
                    while (j < format_string.len) {
                        if (format_string[j] == char) {
                            closed = true;
                            j += 1;
                            break;
                        }
                        if (format_string[j] == '\\') {
                            if (j + 1 >= format_string.len) @compileError(
                                "dotnet: '" ++ format_string ++ "' ends in a \\ with nothing to escape",
                            );
                            const length = sequenceLength(format_string[j + 1]);
                            text = text ++ format_string[j + 1 .. j + 1 + length];
                            j += 1 + length;
                            continue;
                        }
                        text = text ++ format_string[j .. j + 1];
                        j += 1;
                    }
                    if (!closed) @compileError(
                        "dotnet: '" ++ format_string ++ "' has a quote that is never closed",
                    );
                    i = j;
                },

                '%' => {
                    if (i + 1 >= format_string.len or format_string[i + 1] == '%') @compileError(
                        "dotnet: a % in '" ++ format_string ++ "' is at the end or doubled",
                    );

                    switch (purpose) {
                        // The parser only steps over it, and the specifier
                        // that follows is read with its repeats.
                        .parse => i += 1,

                        // The formatter formats the one character after it
                        // as a custom format of its own, which is where a
                        // single specifier ends up.
                        .format => {
                            const next = format_string[i + 1];
                            const length = sequenceLength(next);
                            if (specifierOf(next)) |which| {
                                chunks = flush(chunks, &text);
                                chunks = chunks ++ &[_]Chunk{.{ .field = .{ .which = which } }};
                            } else if (next == '\'' or next == '"' or next == '\\') {
                                @compileError(
                                    "dotnet: '" ++ format_string ++ "' puts a quote or a \\ alone after a %",
                                );
                            } else {
                                text = text ++ format_string[i + 1 .. i + 1 + length];
                            }
                            i += 1 + length;
                        },
                    }
                },

                '\\' => {
                    if (i + 1 >= format_string.len) @compileError(
                        "dotnet: '" ++ format_string ++ "' ends in a \\ with nothing to escape",
                    );
                    const length = sequenceLength(format_string[i + 1]);
                    text = text ++ format_string[i + 1 .. i + 1 + length];
                    i += 1 + length;
                },

                'Z' => {
                    if (purpose == .parse) {
                        chunks = flush(chunks, &text);
                        chunks = chunks ++ &[_]Chunk{.{ .field = .{ .which = .zulu } }};
                    } else {
                        text = text ++ "Z";
                    }
                    i += 1;
                },

                'G' => {
                    if (purpose == .parse and i + 3 <= format_string.len and
                        std.ascii.eqlIgnoreCase(format_string[i .. i + 3], "GMT"))
                    {
                        chunks = flush(chunks, &text);
                        chunks = chunks ++ &[_]Chunk{.{ .field = .{ .which = .gmt } }};
                        i += 3;
                    } else {
                        text = text ++ "G";
                        i += 1;
                    }
                },

                '.' => {
                    // Only a run of two `F`s or more, because of how .NET
                    // looks for it: having failed to match the dot, it
                    // steps onto the first `F` and then asks whether the
                    // character *after* that one is an `F` too. So `.F`
                    // with the dot missing is a failure and `.FF` is not.
                    if (purpose == .parse and i + 2 < format_string.len and
                        format_string[i + 1] == 'F' and format_string[i + 2] == 'F')
                    {
                        const count = repeatCount(format_string, i + 1);
                        if (count > 7) @compileError(
                            "dotnet: '" ++ format_string ++ "' asks for more than seven digits of a fraction, which is all .NET holds",
                        );
                        chunks = flush(chunks, &text);
                        chunks = chunks ++ &[_]Chunk{.{ .field = .{ .which = .dot_fraction, .count = count } }};
                        i += 1 + count;
                    } else {
                        text = text ++ ".";
                        i += 1;
                    }
                },

                else => {
                    text = text ++ format_string[i .. i + 1];
                    i += 1;
                },
            }
        }

        return flush(chunks, &text);
    }
}

test tokenize {
    const date = comptime tokenize("yyyy-MM-dd", .format);
    try std.testing.expectEqual(@as(usize, 5), date.len);
    try std.testing.expectEqual(Specifier.year, date[0].field.which);
    try std.testing.expectEqual(@as(u8, 4), date[0].field.count);
    try std.testing.expectEqualStrings("-", date[1].literal);

    // Quoted text and an escaped letter are both literal.
    const quoted = comptime tokenize("'day' d\\d", .format);
    try std.testing.expectEqualStrings("day ", quoted[0].literal);
    try std.testing.expectEqualStrings("d", quoted[2].literal);

    // The two tokenizers disagree about `%dd`: writing, it is two days;
    // reading, one two-digit day.
    try std.testing.expectEqual(@as(usize, 2), (comptime tokenize("%dd", .format)).len);
    try std.testing.expectEqual(@as(u8, 2), (comptime tokenize("%dd", .parse))[0].field.count);

    // And about `Z`, which is only a zone when reading.
    try std.testing.expectEqualStrings("Z", (comptime tokenize("HHZ", .format))[1].literal);
    try std.testing.expectEqual(Specifier.zulu, (comptime tokenize("HHZ", .parse))[1].field.which);
}

/// Moves the literal text gathered so far into `chunks`, if there is any.
fn flush(comptime chunks: []const Chunk, comptime text: *[]const u8) []const Chunk {
    comptime {
        if (text.len == 0) return chunks;
        const result = chunks ++ &[_]Chunk{.{ .literal = text.* }};
        text.* = "";
        return result;
    }
}

/// The specifier a character of a custom format stands for, or null when
/// it is not one.
fn specifierOf(comptime char: u8) ?Specifier {
    return switch (char) {
        'd' => .day,
        'M' => .month,
        'y' => .year,
        'h' => .hour12,
        'H' => .hour24,
        'm' => .minute,
        's' => .second,
        'f' => .fraction,
        'F' => .fraction_trimmed,
        't' => .meridiem,
        'g' => .era,
        'z' => .offset,
        'K' => .offset_round_trip,
        ':' => .time_separator,
        '/' => .date_separator,
        else => null,
    };
}

test specifierOf {
    try std.testing.expectEqual(@as(?Specifier, .month), specifierOf('M'));
    try std.testing.expectEqual(@as(?Specifier, .minute), specifierOf('m'));
    try std.testing.expectEqual(@as(?Specifier, null), specifierOf('T'));
}

/// Whether the month name at `at` takes the form a language uses after a
/// day number, which is .NET's `IsUseGenitiveForm`.
///
/// It looks backwards from the month for the nearest `d` and counts the
/// run of `d`s it belongs to; one or two is a day of the month, and says
/// yes. Failing that it looks forwards past the month the same way. A run
/// of three or more is a weekday name and says nothing. Quotes are not
/// taken into account, which is .NET's behaviour rather than an oversight
/// here: a `d` inside quoted text counts.
fn usesGenitive(comptime format_string: []const u8, comptime at: usize, comptime count: usize) bool {
    comptime {
        // Counted as the number of characters before a position, so that
        // zero means the start of the string rather than an index below it.
        var i: usize = at;
        while (i > 0 and format_string[i - 1] != 'd') i -= 1;
        if (i > 0) {
            var repeat: usize = 0;
            i -= 1;
            while (i > 0 and format_string[i - 1] == 'd') : (i -= 1) repeat += 1;
            if (repeat <= 1) return true;
        }

        var j = at + count;
        while (j < format_string.len and format_string[j] != 'd') j += 1;
        if (j < format_string.len) {
            var repeat: usize = 0;
            j += 1;
            while (j < format_string.len and format_string[j] == 'd') : (j += 1) repeat += 1;
            if (repeat <= 1) return true;
        }

        return false;
    }
}

test usesGenitive {
    try std.testing.expect(comptime usesGenitive("d MMMM", 2, 4));
    try std.testing.expect(comptime usesGenitive("MMMM dd", 0, 4));
    // A weekday name is not a day number.
    try std.testing.expect(!(comptime usesGenitive("dddd MMMM", 5, 4)));
    try std.testing.expect(!(comptime usesGenitive("MMMM yyyy", 0, 4)));
}

/// What can go wrong writing a value, beyond the writer itself failing.
pub const FormatError = error{
    /// `g` was asked for a year before 1. A .NET calendar has one era,
    /// which begins in year 1, and a `DateTime` here reaches further back
    /// than that; writing "A.D." beside year 0 would be false, and .NET
    /// has no other era to write.
    YearOutsideEra,
} || std.Io.Writer.Error;

/// Writes `value` under `format_string` in the invariant culture.
///
/// Flushes `writer` before returning, as `DateTime.format` does.
///
/// ```zig
/// try dotnet.format(value, "yyyy-MM-ddTHH:mm:sszzz", writer);
/// ```
pub fn format(
    value: DateTime,
    comptime format_string: []const u8,
    writer: *std.Io.Writer,
) FormatError!void {
    return formatIn(value, format_string, Culture.invariant, writer);
}

test format {
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 15,
        .hour = 14,
        .minute = 30,
        .second = 5,
        .nanosecond = 123456789,
        .offset = -5 * std.time.s_per_hour,
    };
    value.updateDayOfWeek();

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("2024-03-15", try bufFormat(&buffer, value, "yyyy-MM-dd"));
    try std.testing.expectEqualStrings("2:30 PM", try bufFormat(&buffer, value, "h:mm tt"));
    try std.testing.expectEqualStrings("Friday, 15 March 2024", try bufFormat(&buffer, value, "D"));
    try std.testing.expectEqualStrings("2024-03-15T14:30:05.1234567-05:00", try bufFormat(&buffer, value, "o"));
    try std.testing.expectEqualStrings("Fri, 15 Mar 2024 19:30:05 GMT", try bufFormat(&buffer, value, "R"));
}

/// Writes `value` under `format_string` in `culture`.
///
/// The value is treated the way .NET treats a `DateTimeOffset`: `z`,
/// `zzz` and `K` write its own offset, and `r` and `u` move it into UTC
/// before writing it. `U`, which .NET refuses for a `DateTimeOffset`,
/// does what it does for a `DateTime`: moves it into UTC and writes the
/// culture's full pattern.
///
/// Four things reach beyond what .NET can hold, and are written as the
/// arithmetic .NET's own code does would write them in a wider integer:
///
/// - **A year outside 1 through 9999.** `yyyy` of year 12345 is `12345`,
///   and a year before 1 is written with a minus sign ahead of the
///   padding, `-0005`, the way .NET writes a negative number. `yy` of it
///   is the remainder C# takes, so year -5 is `-05`.
/// - **A nanosecond.** .NET holds a hundred of them at a time, and `f`
///   stops at seven digits, so the two agree digit for digit.
/// - **An offset that is not whole minutes**, which Chicago's local mean
///   time is. `zzz` and `K` write the hours and minutes and drop the
///   seconds, as `TimeSpan.Minutes` would.
/// - **`g` before year 1**, which is `error.YearOutsideEra`.
///
/// Flushes `writer` before returning.
pub fn formatIn(
    value: DateTime,
    comptime format_string: []const u8,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) FormatError!void {
    try writeCompiled(value, comptime compile(format_string, culture, .format), culture, writer);
    try writer.flush();
}

test formatIn {
    var value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .hour = 9, .minute = 7 };
    value.updateDayOfWeek();

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try formatIn(value, "g", Culture.en_us, &writer);
    try std.testing.expectEqualStrings("3/5/2024 9:07\u{202F}AM", writer.buffered());
}

/// Writes a compiled format string without flushing, which is what the
/// public entry points and `powershell` are built out of.
pub fn writeCompiled(
    value: DateTime,
    comptime compiled: Compiled,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) FormatError!void {
    const in: Culture = comptime if (compiled.invariant) Culture.invariant else culture;
    const reading = if (compiled.universal) value.toUtc() else value;

    inline for (compiled.chunks, 0..) |chunk, index| {
        // A trimmed fraction that comes out empty takes the dot before it
        // away too, whatever wrote that dot. So the chunk ahead of one is
        // held back in a buffer until the fraction has been decided.
        const next_trims = comptime index + 1 < compiled.chunks.len and
            compiled.chunks[index + 1] == .field and
            compiled.chunks[index + 1].field.which == .fraction_trimmed;

        if (next_trims) {
            var buffer: [max_field]u8 = undefined;
            var held = std.Io.Writer.fixed(&buffer);
            try writeChunk(reading, chunk, in, &held);
            var bytes = held.buffered();
            const digits = trimmedDigits(reading.nanosecond, compiled.chunks[index + 1].field.count);
            if (digits == 0 and bytes.len > 0 and bytes[bytes.len - 1] == '.') bytes = bytes[0 .. bytes.len - 1];
            try writer.writeAll(bytes);
        } else {
            try writeChunk(reading, chunk, in, writer);
        }
    }
}

/// The longest a single chunk writes when it has to be held back: a month
/// or weekday name in a long language, or a culture's literal text.
const max_field = 256;

/// Writes one chunk.
fn writeChunk(
    value: DateTime,
    comptime chunk: Chunk,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) FormatError!void {
    switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .field => |field| try writeField(value, field, culture, writer),
    }
}

/// Writes one field, which is .NET's `FormatCustomized` for one
/// specifier.
fn writeField(
    value: DateTime,
    comptime field: Field,
    comptime culture: Culture,
    writer: *std.Io.Writer,
) FormatError!void {
    const count = field.count;

    switch (field.which) {
        .day => switch (count) {
            1, 2 => try writeNumber(writer, value.day, count),
            3 => try writer.writeAll(culture.names.weekdayName(value.weekday, .ddd)),
            else => try writer.writeAll(culture.names.weekdayName(value.weekday, .dddd)),
        },

        .month => switch (count) {
            1, 2 => try writeNumber(writer, value.month.monthNumber(), count),
            3 => try writer.writeAll(culture.names.monthName(value.month, .MMM, field.genitive)),
            else => try writer.writeAll(culture.names.monthName(value.month, .MMMM, field.genitive)),
        },

        // Two or fewer is the year's last two digits, three or more is the
        // whole year padded to at least that width. The remainder is C#'s,
        // which keeps the sign of the year.
        .year => if (count <= 2)
            try writeNumber(writer, @rem(value.year, 100), count)
        else
            try writeNumber(writer, value.year, count),

        .hour12 => try writeNumber(writer, twelve(value.hour), @min(count, 2)),
        .hour24 => try writeNumber(writer, value.hour, @min(count, 2)),
        .minute => try writeNumber(writer, value.minute, @min(count, 2)),
        .second => try writeNumber(writer, value.second, @min(count, 2)),

        .fraction => try writeFraction(writer, value.nanosecond, count),
        .fraction_trimmed => {
            const digits = trimmedDigits(value.nanosecond, count);
            if (digits > 0) try writeFraction(writer, value.nanosecond, digits);
        },

        .meridiem => {
            const designator = if (value.hour < 12) culture.am_designator else culture.pm_designator;
            if (count == 1) {
                // The first character, which in UTF-8 may be several bytes.
                if (designator.len > 0) {
                    const length = std.unicode.utf8ByteSequenceLength(designator[0]) catch 1;
                    try writer.writeAll(designator[0..@min(length, designator.len)]);
                }
            } else {
                try writer.writeAll(designator);
            }
        },

        .era => {
            if (value.year < 1) return error.YearOutsideEra;
            try writer.writeAll(culture.era_name);
        },

        .offset => try writeOffset(writer, value.offset, count),
        .offset_round_trip => try writeOffset(writer, value.offset, 3),

        .time_separator => try writer.writeAll(culture.time_separator),
        .date_separator => try writer.writeAll(culture.date_separator),

        // Only the parser makes these.
        .zulu, .gmt, .dot_fraction => unreachable,
    }
}

/// Writes `number` with at least `digits` digits, and a minus sign ahead
/// of the padding when it is negative, which is how .NET writes a
/// negative number under a format like `"0000"`.
fn writeNumber(writer: *std.Io.Writer, number: anytype, digits: usize) std.Io.Writer.Error!void {
    const wide: i64 = number;
    if (wide < 0) try writer.writeByte('-');
    try writer.printInt(@abs(wide), 10, .lower, .{ .width = digits, .fill = '0' });
}

test writeNumber {
    var buffer: [16]u8 = undefined;

    var padded = std.Io.Writer.fixed(&buffer);
    try writeNumber(&padded, @as(u8, 5), 2);
    try std.testing.expectEqualStrings("05", padded.buffered());

    // A width is a minimum.
    var wide = std.Io.Writer.fixed(&buffer);
    try writeNumber(&wide, @as(i32, 12345), 4);
    try std.testing.expectEqualStrings("12345", wide.buffered());

    var negative = std.Io.Writer.fixed(&buffer);
    try writeNumber(&negative, @as(i32, -5), 4);
    try std.testing.expectEqualStrings("-0005", negative.buffered());
}

/// The hour on a twelve hour clock, where midnight and noon are both 12.
fn twelve(hour: u5) u5 {
    const wrapped = hour % 12;
    return if (wrapped == 0) 12 else wrapped;
}

test twelve {
    try std.testing.expectEqual(@as(u5, 12), twelve(0));
    try std.testing.expectEqual(@as(u5, 1), twelve(13));
}

/// Writes the first `digits` digits of a fraction of a second, truncated
/// rather than rounded, which is `f`.
fn writeFraction(writer: *std.Io.Writer, nanosecond: Nanosecond, digits: usize) std.Io.Writer.Error!void {
    var buffer: [9]u8 = undefined;
    _ = std.fmt.printInt(&buffer, nanosecond, 10, .lower, .{ .width = 9, .fill = '0' });
    try writer.writeAll(buffer[0..digits]);
}

test writeFraction {
    var buffer: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeFraction(&writer, 123456789, 3);
    try std.testing.expectEqualStrings("123", writer.buffered());
}

/// How many of the first `digits` digits of a fraction are left once its
/// trailing zeros are dropped, which is what `F` writes. Zero means none
/// at all.
fn trimmedDigits(nanosecond: Nanosecond, digits: usize) usize {
    var buffer: [9]u8 = undefined;
    _ = std.fmt.printInt(&buffer, nanosecond, 10, .lower, .{ .width = 9, .fill = '0' });
    var kept = digits;
    while (kept > 0 and buffer[kept - 1] == '0') kept -= 1;
    return kept;
}

test trimmedDigits {
    try std.testing.expectEqual(@as(usize, 1), trimmedDigits(100_000_000, 3));
    try std.testing.expectEqual(@as(usize, 3), trimmedDigits(123_456_789, 3));
    try std.testing.expectEqual(@as(usize, 0), trimmedDigits(0, 7));
    // Digits past the ones asked for do not count.
    try std.testing.expectEqual(@as(usize, 0), trimmedDigits(456, 3));
}

/// Writes an offset the way `z`, `zz` and `zzz` do: always signed, then
/// the hours unpadded, padded to two, or padded to two with the minutes
/// after a colon.
///
/// Zero is `+`, as .NET writes it. Seconds are dropped, because a .NET
/// offset has none.
fn writeOffset(writer: *std.Io.Writer, offset: i32, count: usize) std.Io.Writer.Error!void {
    try writer.writeByte(if (offset < 0) '-' else '+');
    const magnitude = @abs(offset);
    const hours = magnitude / std.time.s_per_hour;
    const minutes = magnitude % std.time.s_per_hour / std.time.s_per_min;

    switch (count) {
        1 => try writer.print("{d}", .{hours}),
        2 => try writer.print("{d:0>2}", .{hours}),
        else => try writer.print("{d:0>2}:{d:0>2}", .{ hours, minutes }),
    }
}

test writeOffset {
    var buffer: [16]u8 = undefined;

    var short = std.Io.Writer.fixed(&buffer);
    try writeOffset(&short, -7 * std.time.s_per_hour, 1);
    try std.testing.expectEqualStrings("-7", short.buffered());

    var full = std.Io.Writer.fixed(&buffer);
    try writeOffset(&full, 5 * std.time.s_per_hour + 45 * std.time.s_per_min, 3);
    try std.testing.expectEqualStrings("+05:45", full.buffered());

    var zero = std.Io.Writer.fixed(&buffer);
    try writeOffset(&zero, 0, 2);
    try std.testing.expectEqualStrings("+00", zero.buffered());
}

/// Formats into `buffer` and returns what was written, for the tests.
fn bufFormat(buffer: []u8, value: DateTime, comptime format_string: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try format(value, format_string, &writer);
    return writer.buffered();
}

/// What a format string can fail to read.
///
/// One error, because there is one question -- did this text match this
/// format -- and .NET's own answer to every way it can fail is the same
/// `FormatException`.
pub const ParseError = error{ParseError};

/// What `parse` read.
pub const Result = struct {
    value: DateTime,
    /// Whether the text said where it was: an offset, a `Z`, `GMT`, or a
    /// standard format that is UTC by definition. When it did not, the
    /// value's offset is `Options.relative_to`'s, which is zero by
    /// default, and a caller that needs to know where the reading was made
    /// has to find out some other way. This is what .NET records as
    /// `DateTimeKind.Unspecified`.
    has_offset: bool,
};

/// What `parseIn` can be told.
pub const Options = struct {
    /// Where the date comes from when the text does not give one, standing
    /// in for the clock .NET would read.
    ///
    /// .NET fills a missing date from today, except that a text with a
    /// month or a day in it and no year gets January or the 1st for what
    /// is missing and only the year from today. This is used in exactly
    /// those places, and its offset is the value's when the text names
    /// none. The default is .NET's own `DateTime.MinValue`, 0001-01-01,
    /// which is what `DateTimeStyles.NoCurrentDateDefault` asks for.
    relative_to: DateTime = .{ .year = 1, .month = .Jan, .day = 1, .weekday = .Mon },
};

/// Reads `text` under `format_string` in the invariant culture. The whole
/// of `text` has to be read.
///
/// ```zig
/// const result = try dotnet.parse("yyyy-MM-ddTHH:mm:sszzz", "2024-03-15T14:30:05-05:00");
/// // result.value is 14:30:05 on the 15th of March, five hours west;
/// // result.has_offset is true.
/// ```
pub fn parse(comptime format_string: []const u8, text: []const u8) ParseError!Result {
    return parseIn(format_string, text, Culture.invariant, .{});
}

test parse {
    const result = try parse("yyyy-MM-ddTHH:mm:sszzz", "2024-03-15T14:30:05-05:00");
    try std.testing.expectEqual(@as(Year, 2024), result.value.year);
    try std.testing.expectEqual(@as(u5, 14), result.value.hour);
    try std.testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), result.value.offset);
    try std.testing.expect(result.has_offset);

    // No offset in the text is reported rather than hidden.
    try std.testing.expect(!(try parse("yyyy-MM-dd", "2024-03-15")).has_offset);

    // The whole input has to be read.
    try std.testing.expectError(error.ParseError, parse("yyyy-MM-dd", "2024-03-15 and more"));
}

/// Reads `text` under `format_string` in `culture`, the way .NET's
/// `ParseExact` does with no `DateTimeStyles`.
///
/// It is strict, and exactly as strict as .NET:
///
/// - Every character of the format has to be matched by the same
///   character of the text, spaces included, and all of the text has to
///   be used. Only names and the meridiem ignore case.
/// - A one letter numeric field reads one or two digits, and a longer one
///   exactly as many as it has letters, so `d` reads `5` and `15` while
///   `dd` reads only `05` and `15`. `yyyy` wants four digits.
/// - `F` reads as many digits as it has letters, or fewer, or none, and a
///   `.` in front of it may be missing along with it.
/// - `z` and `zz` read a signed hour; `zzz` and `K` a signed hour and
///   minutes with or without a colon, and `K` accepts `Z` or nothing too.
/// - A field that turns up twice must say the same thing both times, the
///   weekday must be the date's own, `tt` cannot contradict a twenty-four
///   hour clock, and the offset must be within fourteen hours.
///
/// Two digit years are placed in the hundred years ending with
/// `Culture.two_digit_year_max`. A date the text does not give comes from
/// `options.relative_to`; see `Options`.
///
/// `o` and `r` are read the way .NET reads them, with code of their own
/// that is stricter than their patterns, and `r`, `u` and `U` are UTC
/// whatever else the text says -- which is `DateTimeOffset`'s reading.
/// `DateTime.ParseExact` ignores the `Z` and `GMT` that `u` and `r` quote,
/// a compatibility bug .NET keeps on purpose.
///
/// Where this reads more than .NET does, it is because the value can hold
/// it: a year before 1 or after 9999 when a field has the digits for one.
/// Where it reads less, it is refusing something .NET should have: an
/// offset from `o` with more than 59 minutes in it. Neither ever changes
/// what text .NET accepts means.
pub fn parseIn(
    comptime format_string: []const u8,
    text: []const u8,
    comptime culture: Culture,
    options: Options,
) ParseError!Result {
    const compiled = comptime compile(format_string, culture, .parse);
    const in: Culture = comptime if (compiled.invariant) Culture.invariant else culture;

    // .NET refuses an empty text before it looks at the format, so even a
    // format that could match nothing, `FF`, does not match it.
    if (text.len == 0) return error.ParseError;

    var state: State = .{};
    switch (compiled.shape) {
        .rfc1123 => try readRfc1123(text, &state),
        .round_trip => try readRoundTrip(text, &state),
        .pattern => {
            var rest = text;
            try readCompiled(compiled, &rest, &state, in);
            if (rest.len != 0) return error.ParseError;
        },
    }

    if (compiled.universal) try settle(i32, &state.offset, 0);
    return state.finish(in, options);
}

test parseIn {
    const result = try parseIn("d", "3/5/2024", Culture.en_us, .{});
    try std.testing.expectEqual(Month.Mar, result.value.month);
    try std.testing.expectEqual(@as(u6, 5), result.value.day);

    // A time on its own takes its date from the reference.
    var base: DateTime = .{ .year = 2019, .month = .Jul, .day = 4 };
    base.updateDayOfWeek();
    const time = try parseIn("HH:mm", "14:30", Culture.invariant, .{ .relative_to = base });
    try std.testing.expectEqual(@as(Year, 2019), time.value.year);
    try std.testing.expectEqual(@as(u5, 14), time.value.hour);
}

/// Reads the chunks of a compiled format string into `state`.
pub fn readCompiled(
    comptime compiled: Compiled,
    rest: *[]const u8,
    state: *State,
    comptime culture: Culture,
) ParseError!void {
    inline for (compiled.chunks) |chunk| switch (chunk) {
        .literal => |literal| try readLiteral(rest, literal),
        .field => |field| try readField(field, rest, state, culture),
    };
}

/// Matches literal text from the format string against the input.
///
/// Every character has to be there as it is written, with one exception
/// .NET makes: a space in the format also matches a no-break space,
/// U+00A0, or a narrow one, U+202F. That is what lets text written with
/// ICU's en-US time pattern, which puts U+202F before the meridiem, be
/// read by a format string somebody typed with an ordinary space.
fn readLiteral(rest: *[]const u8, literal: []const u8) ParseError!void {
    var input = rest.*;
    for (literal) |char| {
        if (input.len > 0 and input[0] == char) {
            input = input[1..];
        } else if (char == ' ' and std.mem.startsWith(u8, input, "\u{00A0}")) {
            input = input["\u{00A0}".len..];
        } else if (char == ' ' and std.mem.startsWith(u8, input, "\u{202F}")) {
            input = input["\u{202F}".len..];
        } else {
            return error.ParseError;
        }
    }
    rest.* = input;
}

test readLiteral {
    var exact: []const u8 = ", 5";
    try readLiteral(&exact, ", ");
    try std.testing.expectEqualStrings("5", exact);

    var narrow: []const u8 = "\u{202F}PM";
    try readLiteral(&narrow, " ");
    try std.testing.expectEqualStrings("PM", narrow);

    // Not the other way round: a narrow space in the format is only
    // itself.
    var plain: []const u8 = " PM";
    try std.testing.expectError(error.ParseError, readLiteral(&plain, "\u{202F}"));
}

/// What has been read so far, and what could not be settled until the
/// whole format string had been.
///
/// Every slot starts empty, and one that is filled twice has to be filled
/// with the same thing, which is .NET's `CheckNewValue`: `d/M` and `dd`
/// in one format both name the day and must agree.
pub const State = struct {
    year: ?i32 = null,
    /// Whether some `y` field had two letters or fewer, which makes the
    /// year a two digit one to be windowed.
    two_digit_year: bool = false,
    month: ?u8 = null,
    day: ?u8 = null,
    weekday: ?DayOfWeek = null,
    /// The hour as it was written, before a twelve hour clock is settled.
    hour: ?u8 = null,
    /// Whether any hour was read from `h`.
    twelve_hour: bool = false,
    minute: ?u8 = null,
    second: ?u8 = null,
    nanosecond: ?Nanosecond = null,
    half: ?locale.Half = null,
    offset: ?i32 = null,

    /// Turns what was read into the value it names, and refuses one that
    /// is not a time. The order is .NET's `DoStrictParse`.
    pub fn finish(self: State, comptime culture: Culture, options: Options) ParseError!Result {
        var year = self.year;
        if (self.two_digit_year) {
            const short = year.?;
            if (short >= 100) return error.ParseError;
            year = windowYear(short, culture.two_digit_year_max);
        }

        var hour: u8 = self.hour orelse 0;
        if (self.twelve_hour) {
            // No meridiem is the morning: .NET chose not to throw here.
            if (hour > 12) return error.ParseError;
            const half = self.half orelse .am;
            hour = switch (half) {
                .am => if (hour == 12) 0 else hour,
                .pm => if (hour == 12) 12 else hour + 12,
            };
        } else if (self.half) |half| {
            // A meridiem beside a twenty-four hour clock has to agree
            // with it.
            if ((half == .am and hour >= 12) or (half == .pm and hour < 12)) return error.ParseError;
        }

        // .NET's table of what a missing year, month or day becomes.
        var value: DateTime = .{};
        if (self.month == null and self.day == null) {
            if (year) |given| {
                value.year = given;
                value.month = .Jan;
                value.day = 1;
            } else {
                value.year = options.relative_to.year;
                value.month = options.relative_to.month;
                value.day = options.relative_to.day;
            }
        } else {
            value.year = year orelse options.relative_to.year;
            const month = self.month orelse 1;
            if (month < 1 or month > 12) return error.ParseError;
            value.month = @enumFromInt(month);
            const day = self.day orelse 1;
            if (day < 1 or day > value.month.lastDay(value.year)) return error.ParseError;
            value.day = @intCast(day);
        }

        if (hour > 23) return error.ParseError;
        const minute = self.minute orelse 0;
        const second = self.second orelse 0;
        if (minute > 59 or second > 59) return error.ParseError;

        value.hour = @intCast(hour);
        value.minute = @intCast(minute);
        value.second = @intCast(second);
        value.nanosecond = self.nanosecond orelse 0;
        value.updateDayOfWeek();

        if (self.weekday) |weekday| {
            if (weekday != value.weekday) return error.ParseError;
        }

        if (self.offset) |offset| {
            if (@abs(offset) > 14 * std.time.s_per_hour) return error.ParseError;
            value.offset = offset;
        } else {
            value.offset = options.relative_to.offset;
        }

        return .{ .value = value, .has_offset = self.offset != null };
    }
};

/// Places a two digit year in the hundred years that end with `max`,
/// which is .NET's `Calendar.ToFourDigitYear`.
fn windowYear(short: i32, max: Year) Year {
    const century = @divFloor(max, 100) * 100;
    const candidate = century + short;
    return if (candidate > max) candidate - 100 else candidate;
}

test windowYear {
    try std.testing.expectEqual(@as(Year, 2049), windowYear(49, 2049));
    try std.testing.expectEqual(@as(Year, 1950), windowYear(50, 2049));
    try std.testing.expectEqual(@as(Year, 2000), windowYear(0, 2049));
}

/// Fills `slot`, or checks that what it already holds is `value`.
pub fn settle(comptime T: type, slot: *?T, value: T) ParseError!void {
    if (slot.*) |held| {
        if (held != value) return error.ParseError;
    }
    slot.* = value;
}

test settle {
    var slot: ?u8 = null;
    try settle(u8, &slot, 5);
    try settle(u8, &slot, 5);
    try std.testing.expectError(error.ParseError, settle(u8, &slot, 6));
}

/// Reads one field out of the input, which is .NET's `ParseByFormat` for
/// one specifier.
fn readField(
    comptime field: Field,
    rest: *[]const u8,
    state: *State,
    comptime culture: Culture,
) ParseError!void {
    const count = field.count;

    switch (field.which) {
        .year => {
            if (count <= 2) state.two_digit_year = true;
            const year = if (count == 1) try readDigits(rest, 1, 2) else try readDigits(rest, count, count);
            try settle(i32, &state.year, @intCast(year));
        },

        .month => {
            const month: u8 = switch (count) {
                1, 2 => @intCast(try readNumber(rest, count)),
                3 => try readMonthName(rest, culture, .MMM),
                else => try readMonthName(rest, culture, .MMMM),
            };
            try settle(u8, &state.month, month);
        },

        .day => switch (count) {
            1, 2 => try settle(u8, &state.day, @intCast(try readNumber(rest, count))),
            else => {
                const match = culture.names.matchWeekday(rest.*, if (count == 3) .ddd else .dddd) orelse
                    return error.ParseError;
                rest.* = rest.*[match.len..];
                try settle(DayOfWeek, &state.weekday, match.weekday);
            },
        },

        .hour12, .hour24 => {
            if (field.which == .hour12) state.twelve_hour = true;
            try settle(u8, &state.hour, @intCast(try readNumber(rest, @min(count, 2))));
        },
        .minute => try settle(u8, &state.minute, @intCast(try readNumber(rest, @min(count, 2)))),
        .second => try settle(u8, &state.second, @intCast(try readNumber(rest, @min(count, 2)))),

        .fraction => try settle(Nanosecond, &state.nanosecond, try readFraction(rest, count, true)),
        .fraction_trimmed => try settle(Nanosecond, &state.nanosecond, try readFraction(rest, count, false)),
        .dot_fraction => if (rest.len > 0 and rest.*[0] == '.') {
            rest.* = rest.*[1..];
            try settle(Nanosecond, &state.nanosecond, try readFraction(rest, count, false));
        },

        .meridiem => {
            const half: locale.Half = if (count == 1) first: {
                // The first character only, and compared exactly: .NET's
                // `MatchAbbreviatedTimeMark` does not fold case.
                if (firstCharacter(culture.am_designator)) |am| {
                    if (std.mem.startsWith(u8, rest.*, am)) {
                        rest.* = rest.*[am.len..];
                        break :first .am;
                    }
                }
                if (firstCharacter(culture.pm_designator)) |pm| {
                    if (std.mem.startsWith(u8, rest.*, pm)) {
                        rest.* = rest.*[pm.len..];
                        break :first .pm;
                    }
                }
                return error.ParseError;
            } else if (matchWord(rest, culture.am_designator))
                .am
            else if (matchWord(rest, culture.pm_designator))
                .pm
            else
                return error.ParseError;
            try settle(locale.Half, &state.half, half);
        },

        // The era is read and checked but changes nothing, because the
        // calendar has only the one.
        .era => if (!matchWord(rest, culture.era_name) and !matchWord(rest, culture.abbreviated_era_name))
            return error.ParseError,

        .offset => try settle(i32, &state.offset, try readOffset(rest, count)),

        .offset_round_trip => if (rest.len > 0 and rest.*[0] == 'Z') {
            rest.* = rest.*[1..];
            try settle(i32, &state.offset, 0);
        } else if (rest.len > 0 and (rest.*[0] == '+' or rest.*[0] == '-')) {
            try settle(i32, &state.offset, try readOffset(rest, 3));
        },

        .zulu => {
            // `Z` or `GMT` in any case, and not the start of a longer
            // word, which is .NET's `GetTimeZoneName`.
            if (!matchZoneWord(rest, "GMT") and !matchZoneWord(rest, "Z")) return error.ParseError;
            try settle(i32, &state.offset, 0);
        },

        .gmt => {
            if (!std.mem.startsWith(u8, rest.*, "GMT")) return error.ParseError;
            rest.* = rest.*[3..];
            try settle(i32, &state.offset, 0);
        },

        .time_separator => try readSeparator(rest, ":", culture.time_separator),
        .date_separator => try readSeparator(rest, "/", culture.date_separator),
    }
}

/// The first character of `text`, as the bytes that encode it, or null
/// when it is empty.
fn firstCharacter(text: []const u8) ?[]const u8 {
    if (text.len == 0) return null;
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch 1;
    return text[0..@min(length, text.len)];
}

test firstCharacter {
    try std.testing.expectEqualStrings("A", firstCharacter("AM").?);
    try std.testing.expectEqual(@as(?[]const u8, null), firstCharacter(""));
}

/// Steps over `word` at the start of the input if it is there in any
/// case, and says whether it was.
fn matchWord(rest: *[]const u8, word: []const u8) bool {
    if (word.len == 0 or rest.len < word.len) return false;
    if (!std.ascii.eqlIgnoreCase(rest.*[0..word.len], word)) return false;
    rest.* = rest.*[word.len..];
    return true;
}

test matchWord {
    var text: []const u8 = "pm!";
    try std.testing.expect(matchWord(&text, "PM"));
    try std.testing.expectEqualStrings("!", text);
    try std.testing.expect(!matchWord(&text, "PM"));
}

/// `matchWord`, refusing a match that runs straight into a letter.
///
/// .NET asks `char.IsLetter` of what follows. This treats an ASCII letter
/// or any byte of a multi-byte character as a letter, which is right for
/// every letter and wrong only for a non-ASCII character that is not one,
/// directly after a zone name.
fn matchZoneWord(rest: *[]const u8, word: []const u8) bool {
    var input = rest.*;
    if (!matchWord(&input, word)) return false;
    if (input.len > 0 and (std.ascii.isAlphabetic(input[0]) or input[0] >= 0x80)) return false;
    rest.* = input;
    return true;
}

test matchZoneWord {
    var zulu: []const u8 = "z";
    try std.testing.expect(matchZoneWord(&zulu, "Z"));

    var word: []const u8 = "Zulu";
    try std.testing.expect(!matchZoneWord(&word, "Z"));
}

/// Reads a separator: the character the format string wrote, or the
/// culture's own separator in its place.
///
/// .NET accepts the plain character unless the culture's separator is
/// longer and begins with it, in which case only the whole separator
/// will do.
fn readSeparator(rest: *[]const u8, comptime plain: []const u8, comptime separator: []const u8) ParseError!void {
    const plain_allowed = comptime !(separator.len > 1 and separator[0] == plain[0]);
    if (plain_allowed and std.mem.startsWith(u8, rest.*, plain)) {
        rest.* = rest.*[1..];
        return;
    }
    if (!std.mem.startsWith(u8, rest.*, separator)) return error.ParseError;
    rest.* = rest.*[separator.len..];
}

test readSeparator {
    var text: []const u8 = "/05";
    try readSeparator(&text, "/", ".");
    try std.testing.expectEqualStrings("05", text);

    var culture: []const u8 = ".05";
    try readSeparator(&culture, "/", ".");
    try std.testing.expectEqualStrings("05", culture);
}

/// Reads between `min` and `max` ASCII digits, which is .NET's
/// `ParseDigits`: as many as there are up to `max`, and a failure when
/// that is fewer than `min`.
fn readDigits(rest: *[]const u8, min: usize, max: usize) ParseError!u32 {
    var value: u32 = 0;
    var read: usize = 0;
    while (read < max and read < rest.len and std.ascii.isDigit(rest.*[read])) : (read += 1) {
        value = value * 10 + (rest.*[read] - '0');
    }
    if (read < min) return error.ParseError;
    rest.* = rest.*[read..];
    return value;
}

test readDigits {
    var text: []const u8 = "123x";
    try std.testing.expectEqual(@as(u32, 12), try readDigits(&text, 1, 2));
    try std.testing.expectEqualStrings("3x", text);

    var short: []const u8 = "5x";
    try std.testing.expectError(error.ParseError, readDigits(&short, 2, 2));
}

/// Reads a one or two letter numeric field: one or two digits for one
/// letter, exactly two for two.
fn readNumber(rest: *[]const u8, count: usize) ParseError!u32 {
    return if (count == 1) readDigits(rest, 1, 2) else readDigits(rest, 2, 2);
}

test readNumber {
    var one: []const u8 = "5";
    try std.testing.expectEqual(@as(u32, 5), try readNumber(&one, 1));

    var two: []const u8 = "5";
    try std.testing.expectError(error.ParseError, readNumber(&two, 2));
}

/// Reads a month name in the form `tag` asks for, in any case, and
/// returns the month's number.
fn readMonthName(rest: *[]const u8, comptime culture: Culture, comptime tag: anytype) ParseError!u8 {
    const match = culture.names.matchMonth(rest.*, tag) orelse return error.ParseError;
    rest.* = rest.*[match.len..];
    return match.month.monthNumber();
}

test readMonthName {
    var text: []const u8 = "MARCH 5";
    try std.testing.expectEqual(@as(u8, 3), try readMonthName(&text, Culture.invariant, .MMMM));
    try std.testing.expectEqualStrings(" 5", text);
}

/// Reads up to `digits` digits of a fraction of a second and scales them
/// to nanoseconds. With `exact`, fewer than `digits` is a failure, which
/// is `f`; without it, any number including none is accepted, which is
/// `F`.
fn readFraction(rest: *[]const u8, digits: usize, exact: bool) ParseError!Nanosecond {
    var value: Nanosecond = 0;
    var read: usize = 0;
    while (read < digits and read < rest.len and std.ascii.isDigit(rest.*[read])) : (read += 1) {
        value = value * 10 + (rest.*[read] - '0');
    }
    if (exact and read < digits) return error.ParseError;
    rest.* = rest.*[read..];

    var scale: Nanosecond = 1;
    for (read..9) |_| scale *= 10;
    return value * scale;
}

test readFraction {
    var three: []const u8 = "123";
    try std.testing.expectEqual(@as(Nanosecond, 123_000_000), try readFraction(&three, 3, true));

    var short: []const u8 = "5";
    try std.testing.expectError(error.ParseError, readFraction(&short, 3, true));

    var trimmed: []const u8 = "5";
    try std.testing.expectEqual(@as(Nanosecond, 500_000_000), try readFraction(&trimmed, 3, false));
}

/// Reads an offset the way `z`, `zz` and `zzz` do, which is .NET's
/// `ParseTimeZoneOffset`, and returns it in seconds east.
///
/// A sign is required. `z` then reads one or two digits of hours and `zz`
/// exactly two, and neither reads minutes. `zzz` reads one or two digits
/// of hours, an optional colon, and exactly two of minutes.
fn readOffset(rest: *[]const u8, count: usize) ParseError!i32 {
    if (rest.len == 0) return error.ParseError;
    const sign: i32 = switch (rest.*[0]) {
        '+' => 1,
        '-' => -1,
        else => return error.ParseError,
    };
    var input = rest.*[1..];

    var minutes: u32 = 0;
    const hours = if (count <= 2) try readNumber(&input, count) else hours: {
        const hours = try readDigits(&input, 1, 2);
        if (input.len > 0 and input[0] == ':') input = input[1..];
        minutes = try readDigits(&input, 2, 2);
        break :hours hours;
    };
    if (minutes >= 60) return error.ParseError;

    rest.* = input;
    return sign * @as(i32, @intCast(hours * std.time.s_per_hour + minutes * std.time.s_per_min));
}

test readOffset {
    var hours: []const u8 = "-7";
    try std.testing.expectEqual(@as(i32, -7 * std.time.s_per_hour), try readOffset(&hours, 1));

    var full: []const u8 = "+05:45";
    try std.testing.expectEqual(@as(i32, 5 * std.time.s_per_hour + 45 * std.time.s_per_min), try readOffset(&full, 3));

    var basic: []const u8 = "+0545";
    try std.testing.expectEqual(@as(i32, 5 * std.time.s_per_hour + 45 * std.time.s_per_min), try readOffset(&basic, 3));

    var unsigned: []const u8 = "05:45";
    try std.testing.expectError(error.ParseError, readOffset(&unsigned, 3));
}

/// Reads exactly two digits at a fixed position, for the two standard
/// formats .NET reads by position.
fn fixedDigits(text: []const u8, at: usize, count: usize) ParseError!u32 {
    var value: u32 = 0;
    for (text[at .. at + count]) |char| {
        if (!std.ascii.isDigit(char)) return error.ParseError;
        value = value * 10 + (char - '0');
    }
    return value;
}

test fixedDigits {
    try std.testing.expectEqual(@as(u32, 2024), try fixedDigits("x2024", 1, 4));
    try std.testing.expectError(error.ParseError, fixedDigits("20x4", 0, 4));
}

/// Reads `r`, which is .NET's `TryParseFormatR`: exactly 29 characters,
/// `Fri, 15 Mar 2024 19:30:05 GMT`, the names in any case and `GMT` in
/// upper case, and the weekday checked against the date.
fn readRfc1123(text: []const u8, state: *State) ParseError!void {
    if (text.len != 29) return error.ParseError;

    const weekday = locale.en.matchWeekday(text[0..3], .ddd) orelse return error.ParseError;
    if (text[3] != ',' or text[4] != ' ' or text[7] != ' ' or text[11] != ' ' or
        text[16] != ' ' or text[19] != ':' or text[22] != ':')
    {
        return error.ParseError;
    }
    const month = locale.en.matchMonth(text[8..11], .MMM) orelse return error.ParseError;
    if (!std.mem.eql(u8, text[25..29], " GMT")) return error.ParseError;

    state.weekday = weekday.weekday;
    state.day = @intCast(try fixedDigits(text, 5, 2));
    state.month = month.month.monthNumber();
    state.year = @intCast(try fixedDigits(text, 12, 4));
    state.hour = @intCast(try fixedDigits(text, 17, 2));
    state.minute = @intCast(try fixedDigits(text, 20, 2));
    state.second = @intCast(try fixedDigits(text, 23, 2));
    state.offset = 0;
}

test readRfc1123 {
    var state: State = .{};
    try readRfc1123("fri, 15 MAR 2024 19:30:05 GMT", &state);
    try std.testing.expectEqual(@as(?u8, 3), state.month);

    var lower: State = .{};
    try std.testing.expectError(error.ParseError, readRfc1123("Fri, 15 Mar 2024 19:30:05 gmt", &lower));
}

/// Reads `o`, which is .NET's `TryParseFormatO`: exactly
/// `2024-03-15T14:30:05.1230000`, seven digits of fraction and no fewer,
/// then nothing, `Z`, or an offset of `+hh:mm` or `+h:mm`.
///
/// .NET does not check the offset's minutes, so it reads `+05:99` as
/// 6:39. That is refused here.
fn readRoundTrip(text: []const u8, state: *State) ParseError!void {
    if (text.len < 27 or text[4] != '-' or text[7] != '-' or text[10] != 'T' or
        text[13] != ':' or text[16] != ':' or text[19] != '.')
    {
        return error.ParseError;
    }

    state.year = @intCast(try fixedDigits(text, 0, 4));
    state.month = @intCast(try fixedDigits(text, 5, 2));
    state.day = @intCast(try fixedDigits(text, 8, 2));
    state.hour = @intCast(try fixedDigits(text, 11, 2));
    state.minute = @intCast(try fixedDigits(text, 14, 2));
    state.second = @intCast(try fixedDigits(text, 17, 2));
    state.nanosecond = @intCast(try fixedDigits(text, 20, 7) * 100);

    if (text.len == 27) return;

    switch (text[27]) {
        'Z' => {
            if (text.len != 28) return error.ParseError;
            state.offset = 0;
        },
        '+', '-' => {
            // Two digits of hours, or one: .NET allows the shorter form
            // for compatibility.
            const hour_digits: usize = switch (text.len) {
                33 => 2,
                32 => 1,
                else => return error.ParseError,
            };
            const hours = try fixedDigits(text, 28, hour_digits);
            const colon = 28 + hour_digits;
            if (text[colon] != ':') return error.ParseError;
            const minutes = try fixedDigits(text, colon + 1, 2);
            if (minutes >= 60) return error.ParseError;

            const sign: i32 = if (text[27] == '-') -1 else 1;
            state.offset = sign * @as(i32, @intCast(hours * std.time.s_per_hour + minutes * std.time.s_per_min));
        },
        else => return error.ParseError,
    }
}

test readRoundTrip {
    var state: State = .{};
    try readRoundTrip("2024-03-15T14:30:05.1230000-5:00", &state);
    try std.testing.expectEqual(@as(?i32, -5 * std.time.s_per_hour), state.offset);
    try std.testing.expectEqual(@as(?Nanosecond, 123_000_000), state.nanosecond);

    var short: State = .{};
    try std.testing.expectError(error.ParseError, readRoundTrip("2024-03-15T14:30:05.123-05:00", &short));
}

test "a formatted value reads back as itself" {
    var value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .hour = 14,
        .minute = 7,
        .second = 9,
        .nanosecond = 120_000_000,
        .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
    };
    value.updateDayOfWeek();

    var buffer: [128]u8 = undefined;
    inline for (.{
        "yyyy-MM-ddTHH:mm:ss.fffffffzzz",
        "dddd, MMMM d, yyyy h:mm:ss.FFF tt K",
        "o",
        "ddd dd MMM yyyy HH:mm:ss.ff zzz",
        "yyyyMMddTHHmmssfff zzz",
    }) |format_string| {
        const written = try bufFormat(&buffer, value, format_string);
        const back = try parse(format_string, written);
        try std.testing.expect(back.has_offset);
        try std.testing.expectEqual(value.toInstant().timestamp, back.value.toInstant().timestamp);
        try std.testing.expectEqual(value.offset, back.value.offset);
    }

    // `r` and `u` are UTC, so what comes back is the same instant written
    // in UTC, without the fraction neither of them writes.
    inline for (.{ "r", "u" }) |format_string| {
        const written = try bufFormat(&buffer, value, format_string);
        const back = try parse(format_string, written);
        try std.testing.expectEqual(@as(i32, 0), back.value.offset);
        try std.testing.expectEqual(
            @divFloor(value.toInstant().timestamp, std.time.ns_per_s),
            @divFloor(back.value.toInstant().timestamp, std.time.ns_per_s),
        );
    }
}
