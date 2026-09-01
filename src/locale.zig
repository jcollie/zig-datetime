// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The language a date is written in and read back from.
//!
//! A `Locale` is everything about formatting that is not the format
//! string: the names of the months and the days, what stands for AM and
//! PM, how an ordinal is written, which day the week starts on, and what
//! the `L` family of sequences stands for. `en` is built in and is what
//! every entry point without a locale uses, so nothing changes for a
//! caller that never asks for one.
//!
//! This is runtime data rather than a comptime parameter. The format
//! string stays comptime, because it decides which code runs; the locale
//! only decides which bytes come out, so a program can pick one from a
//! request header or a configuration file without a switch over
//! everything it might have compiled in. The one thing that does not fit
//! that split is `L`: it stands for another format string rather than for
//! a value, so a locale that changes it changes what has to be tokenized,
//! and `DateTime.format` walks those expansions at run time. See
//! `DateTime.formatWith`.
//!
//! The vocabulary is moment.js's, as it is everywhere else in this
//! library, and so is the data: `tools/gen_locales.js` reads moment's own
//! locale files and writes the rest of them out. See `build.zig`.

const std = @import("std");

const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Month = @import("month.zig").Month;
const formatsequence = @import("formatsequence.zig");
const FormatTag = formatsequence.FormatTag;
const generated = @import("locales");
const print = @import("print.zig");

/// Which of the two halves of the day a meridiem names.
pub const Half = enum { am, pm };

/// Upper or lower case, which is the only difference between the `A` and
/// `a` sequences.
pub const Case = enum { lower, upper };

/// What a month name match consumed and which month it named.
pub const MonthMatch = struct {
    month: Month,
    /// How many bytes of the input the name took.
    len: usize,
};

/// What a day name match consumed and which day it named.
pub const WeekdayMatch = struct {
    weekday: DayOfWeek,
    /// How many bytes of the input the name took.
    len: usize,
};

/// What a meridiem match consumed and what it meant.
pub const MeridiemMatch = struct {
    /// How many bytes of the input the meridiem took.
    len: usize,
    half: Half,
};

/// The `L` family: sequences that stand for a whole format string rather
/// than for a value, so that "the usual way to write a date here" can be
/// asked for without knowing what that is.
///
/// A locale may name the lower case spellings or leave them to be
/// derived. moment derives one by taking the upper case string and
/// dropping a letter from each of `MMMM`, `MM`, `DD` and `dddd`, so that
/// `MM/DD/YYYY` becomes `M/D/YYYY`; eighteen of its locales name their
/// own instead, because the rule gets them wrong -- Chinese `llll` keeps
/// the full weekday name that the rule would shorten. Null here means
/// derive, which is what `Expansion.abbreviate` asks the caller to do.
pub const LongDateFormat = struct {
    /// The time of day, as `LT`.
    LT: []const u8,
    /// The time of day with seconds, as `LTS`.
    LTS: []const u8,
    /// The date in figures, as `L`.
    L: []const u8,
    /// The date with the month named, as `LL`.
    LL: []const u8,
    /// `LL` with the time, as `LLL`.
    LLL: []const u8,
    /// `LLL` with the weekday, as `LLLL`.
    LLLL: []const u8,

    /// `L` shortened, when the locale names it rather than leaving it to
    /// be derived.
    l: ?[]const u8 = null,
    /// `LL` shortened.
    ll: ?[]const u8 = null,
    /// `LLL` shortened.
    lll: ?[]const u8 = null,
    /// `LLLL` shortened.
    llll: ?[]const u8 = null,

    /// Whether each of the ten writes the declined month name, in the
    /// order `index` gives them.
    ///
    /// Which form a language reaches for is decided by a regular
    /// expression over the format string, and every locale that has two
    /// forms writes its own: some look for the day before the month, some
    /// for the month before the day, some allow a full stop between and
    /// some do not. There is no one rule to carry, so for the strings
    /// that are the locale's own the answer is recorded rather than
    /// worked out. Null, which is what a hand-written locale leaves it,
    /// falls back to the rule most of moment's locales use; see
    /// `DateTime.DayState`.
    months_declined: ?[10]bool = null,

    /// Where `tag` sits in `months_declined`.
    fn index(tag: FormatTag) usize {
        return switch (tag) {
            .LT => 0,
            .LTS => 1,
            .L => 2,
            .LL => 3,
            .LLL => 4,
            .LLLL => 5,
            .l => 6,
            .ll => 7,
            .lll => 8,
            .llll => 9,
            else => unreachable,
        };
    }

    /// What a localized sequence stands for, and what still has to be
    /// decided about the sequences inside it.
    pub const Expansion = struct {
        fmt: []const u8,
        /// True only when a lower case spelling fell back to the upper
        /// case string, which is then shortened a sequence at a time.
        abbreviate: bool,
        /// Whether a month name inside is the declined one. Null when the
        /// locale has nothing to say, which is every locale with one form
        /// of each name.
        months_declined: ?bool,
    };

    /// Returns what `tag` stands for, which must be one of the ten.
    pub fn get(self: LongDateFormat, tag: FormatTag) Expansion {
        const declined: ?bool = if (self.months_declined) |flags| flags[index(tag)] else null;
        const spelled: struct { fmt: []const u8, abbreviate: bool } = switch (tag) {
            .LT => .{ .fmt = self.LT, .abbreviate = false },
            .LTS => .{ .fmt = self.LTS, .abbreviate = false },
            .L => .{ .fmt = self.L, .abbreviate = false },
            .LL => .{ .fmt = self.LL, .abbreviate = false },
            .LLL => .{ .fmt = self.LLL, .abbreviate = false },
            .LLLL => .{ .fmt = self.LLLL, .abbreviate = false },
            .l => if (self.l) |own| .{ .fmt = own, .abbreviate = false } else .{ .fmt = self.L, .abbreviate = true },
            .ll => if (self.ll) |own| .{ .fmt = own, .abbreviate = false } else .{ .fmt = self.LL, .abbreviate = true },
            .lll => if (self.lll) |own| .{ .fmt = own, .abbreviate = false } else .{ .fmt = self.LLL, .abbreviate = true },
            .llll => if (self.llll) |own| .{ .fmt = own, .abbreviate = false } else .{ .fmt = self.LLLL, .abbreviate = true },
            else => unreachable,
        };
        return .{
            .fmt = spelled.fmt,
            .abbreviate = spelled.abbreviate,
            .months_declined = declined,
        };
    }

    test get {
        const held: LongDateFormat = .{
            .LT = "h:mm A",
            .LTS = "h:mm:ss A",
            .L = "MM/DD/YYYY",
            .LL = "MMMM D, YYYY",
            .LLL = "MMMM D, YYYY h:mm A",
            .LLLL = "dddd, MMMM D, YYYY h:mm A",
            // As Chinese does, where the rule would shorten a weekday
            // name that the language keeps whole.
            .llll = "YYYY/M/D dddd HH:mm",
        };

        try std.testing.expectEqualStrings("MM/DD/YYYY", held.get(.L).fmt);
        try std.testing.expect(!held.get(.L).abbreviate);

        // Not named, so the upper case one shortened.
        try std.testing.expectEqualStrings("MM/DD/YYYY", held.get(.l).fmt);
        try std.testing.expect(held.get(.l).abbreviate);

        // Named, so taken as it stands.
        try std.testing.expectEqualStrings("YYYY/M/D dddd HH:mm", held.get(.llll).fmt);
        try std.testing.expect(!held.get(.llll).abbreviate);
    }
};

/// Which day the week starts on and which January day is always in the
/// first week, which is what the `w`, `gg` and `e` sequences count by.
///
/// moment says the same thing as `dow` and `doy`, where `doy` is
/// `7 + dow - january_day_in_first_week`. This is the way round that
/// `Date.weekOfYear` already takes.
pub const Week = struct {
    starts_on: DayOfWeek,
    /// May be zero or negative, naming a day of the December before. See
    /// `Date.weekOfYear`.
    january_day_in_first_week: i8,

    /// The ISO 8601 rule, which the `W` and `GG` sequences always use
    /// whatever the locale says.
    pub const iso: Week = .{ .starts_on = .Mon, .january_day_in_first_week = 4 };

    /// Returns moment's `doy` for this rule, which is what a locale file
    /// writes down and so what a comparison against one has to match.
    pub fn dayOfYear(self: Week) u8 {
        return @intCast(7 + @as(i16, self.starts_on.weekdayNumber()) -
            @as(i16, self.january_day_in_first_week));
    }

    test dayOfYear {
        // moment's `en` is dow 0, doy 6; its `fr` and every ISO locale
        // are dow 1, doy 4.
        try std.testing.expectEqual(@as(u8, 6), (Week{ .starts_on = .Sun, .january_day_in_first_week = 1 }).dayOfYear());
        try std.testing.expectEqual(@as(u8, 4), Week.iso.dayOfYear());

        // Eight of moment's locales use a `doy` of 12, which puts the
        // anchoring day in the December before.
        try std.testing.expectEqual(
            @as(u8, 12),
            (Week{ .starts_on = .Sun, .january_day_in_first_week = -5 }).dayOfYear(),
        );
    }
};

/// The arrangements of day and month name that make a language use its
/// declined month form.
///
/// Every locale that has two forms decides between them with a regular
/// expression over the whole format string, and they do not agree on
/// what to look for: most want the day before the name, two want it
/// after, Czech allows a full stop between, and Polish counts a plain
/// day but not an ordinal one. Rather than carry the patterns, this
/// carries which arrangements each of them accepts, which is what the
/// patterns amount to and what `tools/gen_locales.js` can find out by
/// asking.
///
/// All false is a language with one form, which is most of them.
pub const DeclineShapes = struct {
    /// `D MMMM`
    day_then_month: bool = false,
    /// `D. MMMM`
    day_stop_month: bool = false,
    /// `Do MMMM`
    ordinal_then_month: bool = false,
    /// `MMMM D`
    month_then_day: bool = false,
    /// `MMMM Do`
    month_then_ordinal: bool = false,

    /// Whether any arrangement at all makes this language decline.
    pub fn any(self: DeclineShapes) bool {
        return self.day_then_month or self.day_stop_month or self.ordinal_then_month or
            self.month_then_day or self.month_then_ordinal;
    }

    /// Whether a format string holding `found` asks for the declined
    /// form here: it does when the string has an arrangement this
    /// language accepts.
    pub fn declines(self: DeclineShapes, found: DeclineShapes) bool {
        return (self.day_then_month and found.day_then_month) or
            (self.day_stop_month and found.day_stop_month) or
            (self.ordinal_then_month and found.ordinal_then_month) or
            (self.month_then_day and found.month_then_day) or
            (self.month_then_ordinal and found.month_then_ordinal);
    }

    test declines {
        // Polish counts a plain day before the name and not an ordinal
        // one, which is the whole of the difference between its pattern
        // and everyone else's.
        const polish: DeclineShapes = .{ .day_then_month = true };

        try std.testing.expect(polish.declines(.{ .day_then_month = true }));
        try std.testing.expect(!polish.declines(.{ .ordinal_then_month = true }));

        // A language with one form declines for nothing.
        const plain: DeclineShapes = .{};
        try std.testing.expect(!plain.any());
        try std.testing.expect(!plain.declines(.{ .day_then_month = true }));
    }
};

/// Everything about writing a date that is not the format string.
pub const Locale = struct {
    /// What the locale goes by, in moment's spelling: "en", "fr",
    /// "pt-br". Lower case, since that is how moment names them and how
    /// `byName` looks them up.
    tag: []const u8,

    /// The month names, January first, as they are written on their own.
    months: *const [12][]const u8,
    /// The short month names, January first.
    months_short: *const [12][]const u8,
    /// The forms used when the name follows a day number, for the
    /// languages that decline it there: Russian writes "март" alone and
    /// "5 марта" in a date. Null where the language has one form, which
    /// is most of them.
    months_in_format: ?*const [12][]const u8 = null,
    /// The same for the short names.
    months_short_in_format: ?*const [12][]const u8 = null,

    /// The day names, Sunday first, whatever day the week starts on.
    /// Sunday first because that is how the `d` sequence numbers them,
    /// and `week.starts_on` is what moves the start of the week.
    weekdays: *const [7][]const u8,
    /// The short day names, Sunday first, which `ddd` writes.
    weekdays_short: *const [7][]const u8,
    /// The shortest day names, Sunday first, which `dd` writes.
    weekdays_min: *const [7][]const u8,

    /// What the `L` family stands for here.
    long_date_format: LongDateFormat,

    /// Which day the week starts on and how the first one is found.
    week: Week,

    /// Which arrangements of day and month name make this language use
    /// its declined month form. All false for a language with one, which
    /// is most of them.
    months_decline: DeclineShapes = .{},

    /// Writes what `A` or `a` stands for at this time of day.
    ///
    /// A function rather than two strings because it is one in moment:
    /// Chinese picks between four words by the hour and the half hour,
    /// and Russian between four more. English is the degenerate case.
    writeMeridiem: *const fn (writer: *std.Io.Writer, hour: Hour, minute: Minute, case: Case) std.Io.Writer.Error!void = writeEnglishMeridiem,

    /// Returns what a meridiem at the start of `text` consumed and meant,
    /// or null when there is not one there.
    matchMeridiem: *const fn (text: []const u8) ?MeridiemMatch = matchEnglishMeridiem,

    /// Writes `n` the way `tag` asks for it: `Do` writes the day of the
    /// month as an ordinal, and every other `o` sequence its own number.
    ///
    /// `tag` is passed because the answer depends on it. French writes
    /// the first of the month "1er" and the first week "1re".
    writeOrdinal: *const fn (writer: *std.Io.Writer, n: u32, tag: FormatTag) std.Io.Writer.Error!void = writeEnglishOrdinal,

    /// Returns how many bytes at the start of `text` are the decoration
    /// around `n` that `writeOrdinal` would have written after it, or
    /// null when the text does not carry one.
    ///
    /// The number itself has already been read, which is why this is
    /// given it: a suffix can depend on the number in front of it.
    matchOrdinal: *const fn (text: []const u8, n: u32, tag: FormatTag) ?usize = matchEnglishOrdinal,

    /// How a name in the input is compared with a name from the tables
    /// above.
    ///
    /// The default folds ASCII case, which is what moment's case
    /// insensitive matching amounts to for a language written in ASCII.
    /// It is not case folding for anything else: it leaves "MÄRZ" and
    /// "März" different, and a locale whose names need better than that
    /// carries its own. Folding Unicode properly would mean a case
    /// mapping table, which is a larger thing than this library is.
    eql: *const fn (a: []const u8, b: []const u8) bool = std.ascii.eqlIgnoreCase,

    /// Returns the month name `tag` asks for.
    ///
    /// `in_format` picks the declined form where the language has one,
    /// and is what `DateTime.format` passes when a day number came
    /// before the month in the format string.
    pub fn monthName(self: Locale, month: Month, tag: FormatTag, in_format: bool) []const u8 {
        const index = @intFromEnum(month) - 1;
        return switch (tag) {
            .MMMM => if (in_format) (self.months_in_format orelse self.months)[index] else self.months[index],
            .MMM => if (in_format) (self.months_short_in_format orelse self.months_short)[index] else self.months_short[index],
            else => unreachable,
        };
    }

    test monthName {
        // English has one form, so asking for the declined one gives the
        // same answer rather than nothing.
        try std.testing.expectEqualStrings("March", en.monthName(.Mar, .MMMM, false));
        try std.testing.expectEqualStrings("March", en.monthName(.Mar, .MMMM, true));
        try std.testing.expectEqualStrings("Mar", en.monthName(.Mar, .MMM, false));
    }

    /// Returns the day name `tag` asks for.
    pub fn weekdayName(self: Locale, weekday: DayOfWeek, tag: FormatTag) []const u8 {
        const index = weekday.weekdayNumber();
        return switch (tag) {
            .dddd => self.weekdays[index],
            .ddd => self.weekdays_short[index],
            .dd => self.weekdays_min[index],
            else => unreachable,
        };
    }

    test weekdayName {
        try std.testing.expectEqualStrings("Tuesday", en.weekdayName(.Tue, .dddd));
        try std.testing.expectEqualStrings("Tue", en.weekdayName(.Tue, .ddd));
        try std.testing.expectEqualStrings("Tu", en.weekdayName(.Tue, .dd));
    }

    /// Returns the month whose name `tag` spells at the start of `text`,
    /// and how many bytes it took, or null when none of them do.
    ///
    /// Longest first, so that "March" is not read as "Mar" with "ch"
    /// left over, and every form the language has is tried, so that a
    /// declined name is understood wherever it turns up.
    pub fn matchMonth(self: Locale, text: []const u8, tag: FormatTag) ?MonthMatch {
        const tables: []const *const [12][]const u8 = switch (tag) {
            .MMMM => &.{ self.months, self.months_in_format orelse self.months },
            .MMM => &.{ self.months_short, self.months_short_in_format orelse self.months_short },
            else => unreachable,
        };

        var best: ?MonthMatch = null;
        for (tables) |table| {
            for (table, 1..) |name, number| {
                if (name.len > text.len) continue;
                if (!self.eql(text[0..name.len], name)) continue;
                if (best == null or name.len > best.?.len) {
                    best = .{ .month = @enumFromInt(number), .len = name.len };
                }
            }
        }
        return best;
    }

    test matchMonth {
        const found = en.matchMonth("March 5", .MMMM).?;
        try std.testing.expectEqual(Month.Mar, found.month);
        try std.testing.expectEqual(@as(usize, 5), found.len);

        // Case is folded, and a name that is a prefix of another does not
        // win over it.
        try std.testing.expectEqual(Month.Mar, en.matchMonth("MARCH", .MMMM).?.month);
        try std.testing.expectEqual(@as(usize, 5), en.matchMonth("March", .MMMM).?.len);

        try std.testing.expectEqual(@as(?MonthMatch, null), en.matchMonth("Smarch", .MMMM));
    }

    /// Returns the day whose name `tag` spells at the start of `text`,
    /// and how many bytes it took, or null when none of them do.
    pub fn matchWeekday(self: Locale, text: []const u8, tag: FormatTag) ?WeekdayMatch {
        const table = switch (tag) {
            .dddd => self.weekdays,
            .ddd => self.weekdays_short,
            .dd => self.weekdays_min,
            else => unreachable,
        };

        var best: ?WeekdayMatch = null;
        for (table, 0..) |name, number| {
            if (name.len > text.len) continue;
            if (!self.eql(text[0..name.len], name)) continue;
            if (best == null or name.len > best.?.len) {
                best = .{ .weekday = @enumFromInt(number), .len = name.len };
            }
        }
        return best;
    }

    test matchWeekday {
        const found = en.matchWeekday("Tuesday!", .dddd).?;
        try std.testing.expectEqual(DayOfWeek.Tue, found.weekday);
        try std.testing.expectEqual(@as(usize, 7), found.len);

        try std.testing.expectEqual(DayOfWeek.Tue, en.matchWeekday("tu", .dd).?.weekday);
        // The short table holds "Tue", which is a prefix of "Tuesday",
        // so asking for `ddd` takes the three letters and leaves the
        // rest. Which is what strict parsing wants: `ddd` means three.
        const short = en.matchWeekday("Tuesday", .ddd).?;
        try std.testing.expectEqual(DayOfWeek.Tue, short.weekday);
        try std.testing.expectEqual(@as(usize, 3), short.len);

        try std.testing.expectEqual(@as(?WeekdayMatch, null), en.matchWeekday("Toosday", .dddd));
    }

    /// The number this locale gives the `e` sequence, which counts from
    /// the day the week starts on rather than from Sunday.
    ///
    /// `d` is always Sunday-based and `E` always ISO, so this is the only
    /// one of the three that moves.
    pub fn weekdayNumber(self: Locale, weekday: DayOfWeek) u3 {
        const from_sunday: u8 = weekday.weekdayNumber();
        const start: u8 = self.week.starts_on.weekdayNumber();
        return @intCast((from_sunday + 7 - start) % 7);
    }

    test weekdayNumber {
        // English starts its week on Sunday, so `e` and `d` agree.
        try std.testing.expectEqual(@as(u3, 2), en.weekdayNumber(.Tue));

        // A locale that starts on Monday does not: moment's `fr` writes
        // 1 where `d` writes 2.
        const monday_first: Locale = .{
            .tag = "test",
            .months = en.months,
            .months_short = en.months_short,
            .weekdays = en.weekdays,
            .weekdays_short = en.weekdays_short,
            .weekdays_min = en.weekdays_min,
            .long_date_format = en.long_date_format,
            .week = .iso,
        };
        try std.testing.expectEqual(@as(u3, 1), monday_first.weekdayNumber(.Tue));
        try std.testing.expectEqual(@as(u3, 6), monday_first.weekdayNumber(.Sun));
    }
};

/// Writes "AM" or "PM", which is what English does and what every locale
/// without a meridiem of its own falls back to.
fn writeEnglishMeridiem(writer: *std.Io.Writer, hour: Hour, minute: Minute, case: Case) std.Io.Writer.Error!void {
    _ = minute;
    try writer.writeAll(switch (case) {
        .lower => if (hour < 12) "am" else "pm",
        .upper => if (hour < 12) "AM" else "PM",
    });
}

test writeEnglishMeridiem {
    var buffer: [2]u8 = undefined;

    var lower = std.Io.Writer.fixed(&buffer);
    try writeEnglishMeridiem(&lower, 9, 0, .lower);
    try std.testing.expectEqualStrings("am", lower.buffered());

    var upper = std.Io.Writer.fixed(&buffer);
    try writeEnglishMeridiem(&upper, 13, 30, .upper);
    try std.testing.expectEqualStrings("PM", upper.buffered());
}

/// Reads "am" or "pm" in any case, which is what moment's `en` accepts.
fn matchEnglishMeridiem(text: []const u8) ?MeridiemMatch {
    if (text.len < 2) return null;
    if (std.ascii.eqlIgnoreCase(text[0..2], "am")) return .{ .len = 2, .half = .am };
    if (std.ascii.eqlIgnoreCase(text[0..2], "pm")) return .{ .len = 2, .half = .pm };
    return null;
}

test matchEnglishMeridiem {
    try std.testing.expectEqual(Half.am, matchEnglishMeridiem("AM").?.half);
    try std.testing.expectEqual(Half.pm, matchEnglishMeridiem("pm and more").?.half);
    try std.testing.expectEqual(@as(usize, 2), matchEnglishMeridiem("Am").?.len);
    try std.testing.expectEqual(@as(?MeridiemMatch, null), matchEnglishMeridiem("xm"));
}

/// Writes `n` with the English ordinal suffix: "1st", "2nd", "11th".
///
/// The same answer for every sequence, which is why the tag is unused
/// here and taken anyway: French needs it, and the signature is shared.
fn writeEnglishOrdinal(writer: *std.Io.Writer, n: u32, tag: FormatTag) std.Io.Writer.Error!void {
    _ = tag;
    try print.ordinal(writer, n);
}

test writeEnglishOrdinal {
    var buffer: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeEnglishOrdinal(&writer, 21, .Do);
    try std.testing.expectEqualStrings("21st", writer.buffered());
}

/// Returns 2 when `text` starts with an English ordinal suffix.
///
/// Which one it is does not matter: the number in front of it has already
/// been read, so this only has to say how much to step over. That is
/// moment's behaviour too -- its `dayOfMonthOrdinalParse` accepts any of
/// the four after any number.
fn matchEnglishOrdinal(text: []const u8, n: u32, tag: FormatTag) ?usize {
    _ = n;
    _ = tag;
    if (text.len < 2) return null;
    return if (@import("ordinal.zig").map.get(text[0..2]) != null) 2 else null;
}

test matchEnglishOrdinal {
    try std.testing.expectEqual(@as(?usize, 2), matchEnglishOrdinal("st", 1, .Do));
    try std.testing.expectEqual(@as(?usize, 2), matchEnglishOrdinal("th of May", 5, .Do));
    try std.testing.expectEqual(@as(?usize, null), matchEnglishOrdinal(" of May", 5, .Do));
}

/// The month names, as their own array so that `en` can point at them and
/// so that `Month.longName` and this cannot drift apart.
const english_months = [12][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

const english_months_short = [12][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

const english_weekdays = [7][]const u8{
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
};

const english_weekdays_short = [7][]const u8{
    "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat",
};

const english_weekdays_min = [7][]const u8{
    "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa",
};

/// English, as moment's `en` locale defines it.
///
/// Built in rather than generated, because it is what every entry point
/// without a locale uses and the library has to work with no options set.
pub const en: Locale = .{
    .tag = "en",
    .months = &english_months,
    .months_short = &english_months_short,
    .weekdays = &english_weekdays,
    .weekdays_short = &english_weekdays_short,
    .weekdays_min = &english_weekdays_min,
    .long_date_format = .{
        .LT = "h:mm A",
        .LTS = "h:mm:ss A",
        .L = "MM/DD/YYYY",
        .LL = "MMMM D, YYYY",
        .LLL = "MMMM D, YYYY h:mm A",
        .LLLL = "dddd, MMMM D, YYYY h:mm A",
    },
    // moment's `en` puts January 1st in week one and starts the week on
    // Sunday, which is dow 0 and doy 6.
    .week = .{ .starts_on = .Sun, .january_day_in_first_week = 1 },
};

test en {
    // The names agree with the ones `Month` and `DayOfWeek` carry, which
    // is what keeps the built-in locale from drifting away from them.
    var month: ?Month = .Jan;
    while (month) |each| : (month = each.next()) {
        try std.testing.expectEqualStrings(each.longName(), en.monthName(each, .MMMM, false));
        try std.testing.expectEqualStrings(each.shortName(), en.monthName(each, .MMM, false));
        if (each == .Dec) break;
    }

    for (0..7) |number| {
        const day: DayOfWeek = @enumFromInt(number);
        try std.testing.expectEqualStrings(day.longName(), en.weekdayName(day, .dddd));
        try std.testing.expectEqualStrings(day.shortName(), en.weekdayName(day, .ddd));
        try std.testing.expectEqualStrings(day.veryShortName(), en.weekdayName(day, .dd));
    }
}

/// One locale as the generated data holds it: plain values, with none of
/// the function pointers a `Locale` carries.
///
/// The generated file names no type of its own, because it is a module of
/// its own and could not reach one here. It writes tuples of anonymous
/// struct literals instead, and they are read back as this. `fromEntry`
/// is what turns one into a `Locale`, and it is where the tables below
/// become the functions a `Locale` answers with.
pub const Entry = struct {
    tag: []const u8,

    months: [12][]const u8,
    months_short: [12][]const u8,
    months_in_format: ?[12][]const u8 = null,
    months_short_in_format: ?[12][]const u8 = null,

    weekdays: [7][]const u8,
    weekdays_short: [7][]const u8,
    weekdays_min: [7][]const u8,

    LT: []const u8,
    LTS: []const u8,
    L: []const u8,
    LL: []const u8,
    LLL: []const u8,
    LLLL: []const u8,
    l: ?[]const u8 = null,
    ll: ?[]const u8 = null,
    lll: ?[]const u8 = null,
    llll: ?[]const u8 = null,
    months_declined: ?[10]bool = null,

    /// The day the week starts on, Sunday = 0, which is moment's `dow`.
    week_starts_on: u3,
    /// Which arrangements of day and month name make this language use
    /// its declined month form.
    months_decline: DeclineShapes = .{},

    /// Which January day is always in week one, which is
    /// `7 + dow - doy` in moment's terms. May be zero or negative; see
    /// `Date.weekOfYear`.
    january_day_in_first_week: i8,

    /// What `A` and `a` write, indexed by hour, then by which part of the
    /// hour it is, then by case.
    ///
    /// The middle index is there because five of moment's locales change
    /// the word inside the hour and none of them changes it anywhere but
    /// on the minute and the half hour: 0 is exactly on the hour, 1 is
    /// the first half, 2 is the second. Every other locale repeats itself
    /// across the three, which costs nothing but a pointer.
    meridiem: [24][3][2][]const u8,

    /// The distinct decorations this locale puts around an ordinal, as
    /// what goes before the number and what goes after it.
    ordinal_forms: []const [2][]const u8,
    /// Which of those forms each number takes, indexed by
    /// `ordinalSlot(n)` within a sequence's table.
    ///
    /// One table per sequence, in `ordinal_tags` order, because a locale
    /// can disagree with itself between them: French writes the first of
    /// the month "1er" and the first week "1re".
    ordinal_index: []const [ordinal_slots]u8,
};

/// The sequences that write an ordinal, in the order `Entry.ordinal_index`
/// holds their tables.
pub const ordinal_tags = [_]FormatTag{ .Mo, .Do, .DDDo, .do, .wo, .Wo };

/// How many numbers an ordinal table distinguishes.
pub const ordinal_slots = 200;

/// Which slot of an ordinal table `n` reads.
///
/// Under a hundred every number has its own, because a language may treat
/// any of them specially: French writes "1er" and then plain numbers.
/// At a hundred and above the last two digits decide, which is what
/// English needs for "101st" and "111th" -- and French agrees, since it
/// writes 101 plain.
///
/// Nothing above 366 can reach here: the day of the year is the largest
/// number any of these sequences writes.
pub fn ordinalSlot(n: u32) usize {
    return if (n < 100) n else 100 + n % 100;
}

test ordinalSlot {
    // Below a hundred, a number is its own slot.
    try std.testing.expectEqual(@as(usize, 1), ordinalSlot(1));
    try std.testing.expectEqual(@as(usize, 99), ordinalSlot(99));

    // Above it, the last two digits, so that "101st" and "1st" can differ
    // while "101st" and "201st" cannot.
    try std.testing.expectEqual(@as(usize, 101), ordinalSlot(101));
    try std.testing.expectEqual(ordinalSlot(101), ordinalSlot(201));
    try std.testing.expectEqual(@as(usize, 111), ordinalSlot(111));
}

/// Which part of the hour `minute` falls in, as `Entry.meridiem` indexes
/// it.
fn meridiemSlot(minute: Minute) usize {
    if (minute == 0) return 0;
    return if (minute < 30) 1 else 2;
}

test meridiemSlot {
    try std.testing.expectEqual(@as(usize, 0), meridiemSlot(0));
    try std.testing.expectEqual(@as(usize, 1), meridiemSlot(29));
    try std.testing.expectEqual(@as(usize, 2), meridiemSlot(30));
    try std.testing.expectEqual(@as(usize, 2), meridiemSlot(59));
}

/// Reads one of the generated file's anonymous struct literals as an
/// `Entry`.
///
/// Field by field, because the generated file is a module of its own and
/// so cannot name `Entry`: what it writes is a struct with the same
/// fields and a different type, and Zig does not coerce one to the other.
/// Naming each field here is also what makes a generated file that has
/// drifted a compile error rather than a surprise.
fn toEntry(comptime raw: anytype) Entry {
    return .{
        .tag = raw.tag,
        .months = raw.months,
        .months_short = raw.months_short,
        .months_in_format = raw.months_in_format,
        .months_short_in_format = raw.months_short_in_format,
        .weekdays = raw.weekdays,
        .weekdays_short = raw.weekdays_short,
        .weekdays_min = raw.weekdays_min,
        .LT = raw.LT,
        .LTS = raw.LTS,
        .L = raw.L,
        .LL = raw.LL,
        .LLL = raw.LLL,
        .LLLL = raw.LLLL,
        .l = raw.l,
        .ll = raw.ll,
        .lll = raw.lll,
        .llll = raw.llll,
        .months_declined = raw.months_declined,
        // Field by field, for the same reason `toEntry` copies the
        // rest: the generated file writes a struct with these fields and
        // a type of its own.
        .months_decline = .{
            .day_then_month = raw.months_decline.day_then_month,
            .day_stop_month = raw.months_decline.day_stop_month,
            .ordinal_then_month = raw.months_decline.ordinal_then_month,
            .month_then_day = raw.months_decline.month_then_day,
            .month_then_ordinal = raw.months_decline.month_then_ordinal,
        },
        .week_starts_on = raw.week_starts_on,
        .january_day_in_first_week = raw.january_day_in_first_week,
        .meridiem = raw.meridiem,
        .ordinal_forms = raw.ordinal_forms,
        .ordinal_index = raw.ordinal_index,
    };
}

/// Turns one generated entry into a `Locale`, building the functions it
/// answers with out of the entry's tables.
///
/// `entry` is comptime because the functions close over it: each locale
/// gets its own, holding its own tables, which is how a struct of plain
/// data becomes one that can be asked questions.
fn fromEntry(comptime entry: Entry) Locale {
    const tables = struct {
        const months = entry.months;
        const months_short = entry.months_short;
        const months_in_format = entry.months_in_format;
        const months_short_in_format = entry.months_short_in_format;
        const weekdays = entry.weekdays;
        const weekdays_short = entry.weekdays_short;
        const weekdays_min = entry.weekdays_min;

        fn writeMeridiem(writer: *std.Io.Writer, hour: Hour, minute: Minute, case: Case) std.Io.Writer.Error!void {
            try writer.writeAll(entry.meridiem[hour][meridiemSlot(minute)][@intFromEnum(case)]);
        }

        fn matchMeridiem(text: []const u8) ?MeridiemMatch {
            // Every word this locale can write, longest first so that one
            // that starts with another does not cut it short. Which half
            // it names is which half of the day it is written in.
            var best: ?MeridiemMatch = null;
            for (entry.meridiem, 0..) |hour, number| {
                for (hour) |part| for (part) |word| {
                    if (word.len == 0 or word.len > text.len) continue;
                    if (!std.ascii.eqlIgnoreCase(text[0..word.len], word)) continue;
                    if (best == null or word.len > best.?.len) {
                        best = .{ .len = word.len, .half = if (number < 12) .am else .pm };
                    }
                };
            }
            return best;
        }

        fn form(n: u32, tag: FormatTag) [2][]const u8 {
            const which = for (ordinal_tags, 0..) |each, index| {
                if (each == tag) break index;
                // A sequence with no table of its own is written the way
                // the day of the month is, which is the one every locale
                // defines.
            } else 1;
            const table = entry.ordinal_index[which];
            return entry.ordinal_forms[table[ordinalSlot(n)]];
        }

        fn writeOrdinal(writer: *std.Io.Writer, n: u32, tag: FormatTag) std.Io.Writer.Error!void {
            const around = form(n, tag);
            try writer.writeAll(around[0]);
            try writer.print("{d}", .{n});
            try writer.writeAll(around[1]);
        }

        fn matchOrdinal(text: []const u8, n: u32, tag: FormatTag) ?usize {
            const suffix = form(n, tag)[1];
            if (suffix.len == 0) return 0;
            if (suffix.len > text.len) return null;
            return if (std.ascii.eqlIgnoreCase(text[0..suffix.len], suffix)) suffix.len else null;
        }
    };

    return .{
        .tag = entry.tag,
        .months = &tables.months,
        .months_short = &tables.months_short,
        .months_in_format = if (tables.months_in_format) |*names| names else null,
        .months_short_in_format = if (tables.months_short_in_format) |*names| names else null,
        .weekdays = &tables.weekdays,
        .weekdays_short = &tables.weekdays_short,
        .weekdays_min = &tables.weekdays_min,
        .long_date_format = .{
            .LT = entry.LT,
            .LTS = entry.LTS,
            .L = entry.L,
            .LL = entry.LL,
            .LLL = entry.LLL,
            .LLLL = entry.LLLL,
            .l = entry.l,
            .ll = entry.ll,
            .lll = entry.lll,
            .llll = entry.llll,
            .months_declined = entry.months_declined,
        },
        .week = .{
            .starts_on = @enumFromInt(entry.week_starts_on),
            .january_day_in_first_week = entry.january_day_in_first_week,
        },
        .months_decline = entry.months_decline,
        .writeMeridiem = tables.writeMeridiem,
        .matchMeridiem = tables.matchMeridiem,
        .writeOrdinal = tables.writeOrdinal,
        .matchOrdinal = tables.matchOrdinal,
    };
}

/// Whether this build has the generated locales, which `-Dembed-locales`
/// asks for. `en` is here either way.
pub const embedded = all.len > 0;

/// The moment.js release the generated locales came from, empty when
/// there are none.
pub const moment_version = generated.moment_version;

/// The generated locales, sorted by tag. Empty unless the build asked for
/// them.
pub const all: []const Locale = built: {
    // Every locale builds its own tables and its own four functions, and
    // there are a hundred and thirty-seven of them.
    @setEvalBranchQuota(2000000);
    var out: [generated.entries.len]Locale = undefined;
    for (&out, 0..) |*slot, index| {
        slot.* = fromEntry(toEntry(generated.entries[index]));
    }
    const final = out;
    break :built &final;
};

/// Returns the locale `tag` names, or null when this build does not carry
/// it. Matching is exact and lower case, as moment's tags are.
///
/// Naming a locale like this is what pulls every one of them into the
/// binary; a program that knows which it wants should name it directly.
pub fn byName(tag: []const u8) ?Locale {
    if (std.mem.eql(u8, tag, en.tag)) return en;

    // With no generated locales the list is comptime empty, and the
    // search below will not compile against it: indexing a slice whose
    // length is known to be zero is an error however unreachable the
    // index is.
    if (comptime !embedded) return null;

    var low: usize = 0;
    var high: usize = all.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, all[mid].tag, tag)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return all[mid],
        }
    }
    return null;
}

test byName {
    // English is always here, whatever the build asked for.
    try std.testing.expectEqualStrings("en", byName("en").?.tag);
    try std.testing.expectEqual(@as(?Locale, null), byName("nonesuch"));

    if (!embedded) return error.SkipZigTest;
    try std.testing.expectEqualStrings("fr", byName("fr").?.tag);
}

test all {
    if (!embedded) {
        try std.testing.expectEqual(@as(usize, 0), all.len);
        return error.SkipZigTest;
    }

    // Sorted by tag, which is what makes `byName` a binary search, and
    // every one of them findable by the name it carries.
    for (all[1..], all[0 .. all.len - 1]) |locale, previous| {
        try std.testing.expect(std.mem.lessThan(u8, previous.tag, locale.tag));
    }
    for (all) |locale| {
        try std.testing.expectEqualStrings(locale.tag, byName(locale.tag).?.tag);
    }
}
