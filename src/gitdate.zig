// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The dates git reads: the strict form `GIT_COMMITTER_DATE` and
//! `git commit --date` take, and the approximate one, which git calls
//! *approxidate*, that `git log --since`, `--until` and `ref@{date}` take.
//!
//! git documents the strict form in git-commit(1) under DATE FORMATS: its
//! own `<unix-timestamp> <offset>`, RFC 2822, and ISO 8601 with a space or
//! a `T`. It documents the approximate form only by example, in
//! gitrevisions(7) and git-log(1): `yesterday`, `1 month 2 weeks 3 days 1
//! hour 1 second ago`, `noon`, `last friday`. What either does with
//! anything else is defined by what git does with it, so everything here
//! was worked out by asking git: `git var GIT_COMMITTER_IDENT` with
//! `GIT_COMMITTER_DATE` set is the strict parser's answer, `git rev-parse
//! --since=` the approximate one's, and `GIT_TEST_DATE_NOW` pins the
//! current time for both. `zig build oracle-git` in `upstream/` holds this
//! module to those answers across a corpus, eleven zones and six points
//! in time either side of daylight saving changes. git is licensed
//! GPL-2.0-only and this library MIT, so none of it is taken from git's
//! source.
//!
//! Both read the text a token at a time, skipping anything that is not a
//! letter or a digit, and ignoring words they do not know. So `junk
//! 2026-01-15 12:00 yesterday` is a strict date, and `the day before
//! yesterday` an approximate one meaning yesterday.
//!
//! **Strict.** A date is complete when it has a year, a month, an hour
//! and a minute. Without a day, it is two days before the first of the
//! month, which is what git makes of an unset day. Numbers are read as:
//!
//!   * `H:M[:S]`, a time of day. The hour may be 24 and the second 60,
//!     each rolling over into the next.
//!   * `A-B-C`, `A/B/C`, `A.B.C`, or the same with two parts: a date. A
//!     first number above 31 is a year, followed by the month and then
//!     the day (or the day and then the month, if that is the only
//!     reading with a real month). Otherwise the year comes last and
//!     the order of the other two is a guess; see `matchDate`.
//!   * `YYYYMMDD`, `HHMMSS`, and `HHMM` straight after a capital `T`
//!     while there is no hour yet: the ISO 8601 basic format.
//!   * four digits that are not a year: an offset east of UTC, `HHMM`,
//!     up to `1400` and with the minutes rolling over, so `0500` is five
//!     hours east and `0099` an hour and thirty-nine minutes.
//!   * a number of nine digits or more, as the first thing in the text:
//!     a Unix timestamp, whose UTC date and time the rest of the text may
//!     go on to change.
//!   * anything else, on its own: a year if it is 1901 through 2099,
//!     and otherwise the day, the month or a two digit year, whichever is
//!     still unknown and fits; see `strictLoneNumber`. Any other number
//!     of three digits or more with a leading zero is not read at all. A
//!     number that looked like a date and was not one is read as its
//!     first number on its own, and a `-` after it as the sign of an
//!     offset.
//!
//! and words as month names, `am` and `pm`, weekday names (ignored, as
//! the date already says which day it is), and the zone abbreviations in
//! `zone_names`. `+HHMM`, `-HH`, `+HH:MM` and the like are an offset from
//! UTC, and take precedence over a zone name or a bare `HHMM`, of which
//! the first counts.
//! git's own `<timestamp> <offset>`, optionally with an `@` in
//! front, is read as exactly that. Years run from 1970 through 2099.
//!
//! A date with no offset is local time in the zone given, resolved by
//! `mktime` as glibc's `mktime` resolves one, which matters for a local
//! time the zone skips or repeats.
//!
//! **Approximate.** The text is first tried as a strict date, and if it
//! is one that is the answer. Otherwise the numbers and words build up a
//! date field by field, from the current time: see `approximate`. Offsets
//! and zone names are ignored, and a numeric date that could be read two
//! ways is not read as one more than ten days from now if the other
//! reading is not.
//!
//! The approximate parser always produces a time. When nothing in the
//! text meant anything to it, that time is the current one, and
//! `Approximate.failed` says so: git uses this to treat `ref@{nonsense}`
//! as an unknown revision while `--since=nonsense` quietly means now.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const TimeZone = @import("TimeZone.zig");
const Year = @import("year.zig").Year;

/// What an approximate date is read against.
pub const Options = struct {
    /// The current time, as seconds since the Unix epoch. Relative dates
    /// count from it, fields a date leaves out are taken from it, and a
    /// guess between two readings of a date avoids one too far past it.
    now: i64,
    /// The zone local times are in.
    zone: *const TimeZone,
};

/// The result of `approximate`.
pub const Approximate = struct {
    /// Seconds since the Unix epoch.
    timestamp: i64,
    /// Nothing in the text was understood, so `timestamp` is just `now`.
    failed: bool,
};

/// The result of `strict`.
pub const Exact = struct {
    /// Seconds since the Unix epoch.
    timestamp: i64,
    /// Seconds east of UTC: the offset the text gave, or the one the zone
    /// had at that time when it gave none.
    offset: i32,
};

pub const ParseError = error{
    /// The text is not a complete strict date.
    InvalidDate,
};

/// Reads a date the way `GIT_COMMITTER_DATE` and `git commit --date` do.
///
/// The text is scanned token by token as the module documentation
/// describes, and succeeds once it has named a whole date and time of
/// day; anything it does not recognize is skipped. With no offset in the
/// text, the time is local to `zone`, and `Exact.offset` reports the
/// offset that was used. A date before 1970 in UTC is refused, as git
/// cannot store one.
pub fn strict(text: []const u8, zone: *const TimeZone) ParseError!Exact {
    if (internalFormat(text)) |exact| return exact;

    const s = scanStrict(text) orelse return error.InvalidDate;
    const f = s.fields;
    // git stores an unset day as -1, which rolls back two days from the
    // first of the month; the date is no less complete for it.
    const local = civil(f.year.?, f.month.?, f.day orelse -1, f.hour.?, f.minute.?, f.second orelse 0);

    const exact: Exact = if (s.utc)
        .{ .timestamp = local, .offset = s.offset orelse zone.offsetAt(local) }
    else if (s.offset) |given|
        .{ .timestamp = local -| given, .offset = given }
    else
        mktime(zone, local);

    if (exact.timestamp < 0) return error.InvalidDate;
    return exact;
}

test strict {
    // git's own format, the one it writes into a commit.
    try std.testing.expectEqual(Exact{ .timestamp = 1790000000, .offset = 90 * 60 }, try strict("1790000000 +0130", &TimeZone.utc));

    // RFC 2822, as an email would carry it.
    try std.testing.expectEqual(
        Exact{ .timestamp = 1788289200, .offset = -7 * 3600 },
        try strict("Tue, 1 Sep 2026 12:00:00 -0700", &TimeZone.utc),
    );

    // ISO 8601, with a space or a T, in the zone given when it has no
    // offset of its own.
    const new_york = try TimeZone.fromRule("EST5EDT,M3.2.0/2,M11.1.0/2");
    try std.testing.expectEqual(Exact{ .timestamp = 1768496400, .offset = -5 * 3600 }, try strict("2026-01-15T12:00", &new_york));

    // Without a time of day it is not a date git will put in a commit.
    try std.testing.expectError(error.InvalidDate, strict("2026-01-15", &TimeZone.utc));
}

/// Reads a date the way `git log --since` and `ref@{date}` do.
///
/// A strict date, if the text is one, is the answer. Otherwise the text
/// is read token by token into the fields of a local date and time, each
/// unset until something names it and taken from the current local time
/// when it is needed and still unset. Some words *settle* the date: they
/// work out the instant the fields name, move it, and set every field
/// from the local time at the result, as `localtime` would.
///
///   * A number is held, rather than used straight away, because the word
///     after it may say what it counts: `3 days`, `10 pm`, `2 fridays`.
///     If nothing takes it before the next number or the end of the text,
///     it is a day, month or year by `loneNumber`.
///   * A date or time of day is read as `strict` reads one, but sets
///     only what it names. A timestamp settles on that instant, if nothing
///     has been set yet.
///   * A unit (`seconds` through `years`, singular or plural, in any
///     case) moves the date so far back by the held count. Seconds
///     through weeks settle on the instant that many seconds earlier.
///     Months and years settle on the date so far and then move the
///     fields on the calendar, a day past the end of the month rolling
///     into the next, keeping what was settled on otherwise: the
///     daylight saving flag, and the weekday a weekday name counts from. With no count held a unit does nothing; `ago` never does
///     anything.
///   * A weekday name (or one with an `s`) with a count `n` held settles
///     on the `n`th of that weekday before the date so far, counting from
///     the weekday of the last instant settled on (to begin with,
///     today's). Without a count it does nothing.
///   * `last`, and `one` through `ten`, hold a count of one, or of the
///     number they name, if none is held. A number of three digits or
///     more with a leading zero, such as the `0100` of an offset, is not
///     held, but uses up a held number like any other.
///   * `yesterday` and `today` drop a held number and settle on the date
///     so far with the day set to yesterday's or today's. `today` first
///     sets the time to midnight, if it is still the current time.
///     `never` settles on the Unix epoch.
///   * `noon`, `midnight` and `tea` use up a held number and set the
///     time to 12:00, 0:00 and 17:00. If the time so far was earlier,
///     the fields still unset at the end are taken from yesterday rather
///     than today.
///   * `now` drops a held number and settles on the fields so far, those
///     still unset taken as the end would take them. `never` drops a held
///     number too.
///   * `am` and `pm` make the hour, or the held count as the hour, morning
///     or afternoon.
///   * A month name sets the month.
///
/// Whenever an unset year is needed, a month later in the year than the
/// current one is taken to be last year's, and otherwise it is this
/// year.
///
/// The local time the fields name is turned into an instant by
/// `mktimeDst`, told whether daylight saving time was in effect at the
/// last instant settled on (to begin with, now). So a winter date named
/// in summer is read at the summer offset, `1 month ago` keeps the time
/// of day on the clock across a change, and `1 week ago` keeps the
/// number of seconds.
pub fn approximate(text: []const u8, options: Options) Approximate {
    if (strict(text, options.zone)) |exact| return .{ .timestamp = exact.timestamp, .failed = false } else |_| {}

    var state: Approx = .init(options);
    state.scan(text);
    return .{
        .timestamp = state.finish(),
        .failed = !state.touched,
    };
}

test approximate {
    // Monday 2026-09-21 14:13:20 UTC.
    const options: Options = .{ .now = 1790000000, .zone = &TimeZone.utc };

    try std.testing.expectEqual(@as(i64, 1789913600), approximate("yesterday", options).timestamp);
    try std.testing.expectEqual(@as(i64, 1788790400), approximate("2 weeks ago", options).timestamp);
    try std.testing.expectEqual(@as(i64, 1789941600), approximate("10 pm yesterday", options).timestamp);

    // The Friday before, at the time it is now.
    try std.testing.expectEqual(@as(i64, 1789740800), approximate("last friday", options).timestamp);

    // A strict date is read strictly.
    try std.testing.expectEqual(@as(i64, 1768478400), approximate("2026-01-15 12:00", options).timestamp);

    // Nothing to go on: the current time, flagged as a guess.
    const nonsense = approximate("nonsense", options);
    try std.testing.expectEqual(@as(i64, 1790000000), nonsense.timestamp);
    try std.testing.expect(nonsense.failed);
}

// -- Local time ----------------------------------------------------------------

/// Turns a local time, as seconds since the epoch in the local frame,
/// into an instant in `zone` the way glibc's `mktime` does when it is
/// not told whether daylight saving time is in effect, which is how the
/// strict parser's dates are resolved.
///
/// A time the zone has once is that instant.
///
/// A time the zone skips, springing forward, could be read at either the
/// offset before the switch or the one after. glibc takes the reading
/// that lands in daylight saving time, if exactly one does, and
/// otherwise the offset before the switch. Either way 02:30 on a night
/// that jumps from 02:00 to 03:00 is 03:30.
///
/// A time the zone has twice is the instant `mktime` converges on from
/// its first guess, the local time read as UTC: the earlier of the two
/// in a zone west of UTC, and the later in one east of it. That guess is
/// glibc's for a process's first call; later calls in the same process
/// start from the offset the last one found, so git can answer the same
/// question differently depending on what it was asked before. This
/// answers as a fresh process does.
fn mktime(zone: *const TimeZone, local: i64) Exact {
    const c = Clock.at(local);
    const reading: DateTime = .{
        .year = @intCast(c.year),
        .month = @fromBackingInt(@as(u4, @intCast(c.month + 1))),
        .day = @intCast(c.day),
        .hour = @intCast(c.hour),
        .minute = @intCast(c.minute),
        .second = @intCast(c.second),
    };
    switch (zone.resolve(reading)) {
        .unique => |timestamp| return exactAt(zone, timestamp),
        .gap => |gap| {
            const after: Exact = .{ .timestamp = local -| gap.before, .offset = gap.before };
            const before: Exact = .{ .timestamp = local -| gap.after, .offset = gap.after };
            const after_dst = zone.typeAt(after.timestamp).is_dst;
            const before_dst = zone.typeAt(before.timestamp).is_dst;
            return if (before_dst and !after_dst) before else after;
        },
        .ambiguous => |both| {
            const guess = local -| zone.offsetAt(local);
            return exactAt(zone, if (guess == both.later) both.later else both.earlier);
        },
    }
}

test mktime {
    const berlin = try TimeZone.fromRule("CET-1CEST,M3.5.0,M10.5.0/3");
    const new_york = try TimeZone.fromRule("EST5EDT,M3.2.0/2,M11.1.0/2");

    // 2026-03-29 02:30 never happens in Berlin; it is read at +01:00, so
    // it lands in summer time at 03:30.
    const skipped = civil(2026, 2, 29, 2, 30, 0);
    try std.testing.expectEqual(Exact{ .timestamp = 1774747800, .offset = 3600 }, mktime(&berlin, skipped));

    // 2026-10-25 02:30 happens twice in Berlin, and the second is taken.
    const repeated = civil(2026, 9, 25, 2, 30, 0);
    try std.testing.expectEqual(Exact{ .timestamp = 1792891800, .offset = 3600 }, mktime(&berlin, repeated));

    // 2026-11-01 01:30 happens twice in New York, and the first is taken.
    const twice = civil(2026, 10, 1, 1, 30, 0);
    try std.testing.expectEqual(Exact{ .timestamp = 1793511000, .offset = -4 * 3600 }, mktime(&new_york, twice));
}

/// An instant and the offset `zone` has at it.
fn exactAt(zone: *const TimeZone, timestamp: i64) Exact {
    return .{ .timestamp = timestamp, .offset = zone.offsetAt(timestamp) };
}

test exactAt {
    try std.testing.expectEqual(Exact{ .timestamp = 5, .offset = 0 }, exactAt(&TimeZone.utc, 5));
}

/// Turns a local time into an instant in `zone`, told whether daylight
/// saving time is meant to be in effect, as `mktime` is when
/// `tm_isdst` is set. This is how the approximate parser's dates are
/// resolved.
///
/// The local time is read at the offset of a local time type with the
/// daylight saving flag asked for, where there is one: the time's own
/// type if its flag agrees, or for a time the zone skips or repeats,
/// whichever side of the switch agrees. Otherwise it is read at its own
/// type's offset moved by the zone's daylight saving amount, forward if
/// daylight saving time was asked for and back if it was not. So noon on
/// a January day in New York, asked for in daylight saving time, is noon
/// EDT; and in a year the zone kept no daylight saving time at all, the
/// answer is still an hour off standard time, as git's is.
fn mktimeDst(zone: *const TimeZone, local: i64, dst: bool) i64 {
    const c = Clock.at(local);
    const reading: DateTime = .{
        .year = @intCast(c.year),
        .month = @fromBackingInt(@as(u4, @intCast(c.month + 1))),
        .day = @intCast(c.day),
        .hour = @intCast(c.hour),
        .minute = @intCast(c.minute),
        .second = @intCast(c.second),
    };
    const own: TimeZone.Type = switch (zone.resolve(reading)) {
        .unique => |timestamp| zone.typeAt(timestamp),
        .gap => |gap| side: {
            const before = zone.typeAt(local -| gap.after);
            const after = zone.typeAt(local -| gap.before);
            break :side if (after.is_dst == dst) after else before;
        },
        .ambiguous => |both| side: {
            const earlier = zone.typeAt(both.earlier);
            const later = zone.typeAt(both.later);
            break :side if (later.is_dst == dst) later else earlier;
        },
    };
    if (own.is_dst == dst) return local -| own.offset;
    const shift = daylightAmount(zone);
    return local -| (if (dst) own.offset + shift else own.offset - shift);
}

test mktimeDst {
    const new_york = try TimeZone.fromRule("EST5EDT,M3.2.0/2,M11.1.0/2");

    // Noon in January, asked for in daylight saving time, is noon EDT.
    const winter = civil(2026, 0, 15, 12, 0, 0);
    try std.testing.expectEqual(@as(i64, 1768492800), mktimeDst(&new_york, winter, true));
    try std.testing.expectEqual(@as(i64, 1768496400), mktimeDst(&new_york, winter, false));

    // 02:30 on the night the clocks spring forward is read at the
    // offset asked for.
    const skipped = civil(2026, 2, 8, 2, 30, 0);
    try std.testing.expectEqual(@as(i64, 1772951400), mktimeDst(&new_york, skipped, true));
    try std.testing.expectEqual(@as(i64, 1772955000), mktimeDst(&new_york, skipped, false));
}

/// How far `zone` moves its clocks for daylight saving time: what its
/// rule says, or an hour if it has none.
fn daylightAmount(zone: *const TimeZone) i32 {
    if (zone.rule) |rule| if (rule.dst) |dst| return dst.offset - rule.std_offset;
    return std.time.s_per_hour;
}

test daylightAmount {
    const lord_howe = try TimeZone.fromRule("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0");
    try std.testing.expectEqual(@as(i32, 30 * 60), daylightAmount(&lord_howe));
    try std.testing.expectEqual(@as(i32, 3600), daylightAmount(&TimeZone.utc));
}

/// The fields of a local date and time, each unset until the text names
/// it. The month counts from zero, and nothing is range checked: a day of
/// 32, or of -10, rolls into the next or previous month by `civil`.
const Fields = struct {
    year: ?i64 = null,
    month: ?i64 = null,
    day: ?i64 = null,
    hour: ?i64 = null,
    minute: ?i64 = null,
    second: ?i64 = null,

    fn empty(self: Fields) bool {
        return std.meta.eql(self, Fields{});
    }

    test empty {
        try std.testing.expect((Fields{}).empty());
        try std.testing.expect(!(Fields{ .hour = 0 }).empty());
    }
};

/// A local date and time broken into fields, with the month counting
/// from zero and the weekday from Sunday.
const Clock = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    weekday: i64,

    /// Breaks down `local`, seconds since the epoch in the local frame.
    /// Times outside the calendar are clamped to its ends.
    fn at(local: i64) Clock {
        const days = Date.dayNumberFromSecondsSaturating(local);
        const date = Date.fromDayNumber(days);
        const second_of_day = @mod(local, std.time.s_per_day);
        return .{
            .year = date.year,
            .month = @as(i64, date.month.monthNumber()) - 1,
            .day = date.day,
            .hour = @divFloor(second_of_day, std.time.s_per_hour),
            .minute = @divFloor(@mod(second_of_day, std.time.s_per_hour), std.time.s_per_min),
            .second = @mod(second_of_day, std.time.s_per_min),
            .weekday = @mod(@as(i64, days) + 4, 7),
        };
    }

    test at {
        try std.testing.expectEqual(Clock{
            .year = 2026,
            .month = 8,
            .day = 21,
            .hour = 14,
            .minute = 13,
            .second = 20,
            .weekday = 1,
        }, Clock.at(1790000000));
    }
};

/// Returns the local seconds since the epoch of a date and time, rolling
/// any field that is out of range into the next one up, as `mktime`
/// does: month 12 is January of the next year, day 0 the last day of the
/// month before, hour 24 midnight of the next day.
///
/// The year is clamped to what a `Date` can hold and the rest is
/// saturating, so no input can trap; a result that far out is wrong in
/// the same way the input was.
fn civil(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) i64 {
    const whole_year = std.math.clamp(
        year +| @divFloor(month, 12),
        std.math.minInt(Year) + 1,
        std.math.maxInt(Year) - 1,
    );
    const first: Date = .{
        .year = @intCast(whole_year),
        .month = @fromBackingInt(@as(u4, @intCast(@mod(month, 12) + 1))),
        .day = 1,
    };
    const days = @as(i64, first.toDayNumber()) +| (day -| 1);
    return days *| std.time.s_per_day +|
        hour *| std.time.s_per_hour +|
        minute *| std.time.s_per_min +|
        second;
}

test civil {
    try std.testing.expectEqual(@as(i64, 1790000000), civil(2026, 8, 21, 14, 13, 20));

    // February 30th is March 2nd, and day 0 the last of the month before.
    try std.testing.expectEqual(civil(2026, 2, 2, 0, 0, 0), civil(2026, 1, 30, 0, 0, 0));
    try std.testing.expectEqual(civil(2026, 7, 31, 0, 0, 0), civil(2026, 8, 0, 0, 0, 0));

    // A month count past December carries into the year.
    try std.testing.expectEqual(civil(2027, 0, 1, 0, 0, 0), civil(2026, 12, 1, 0, 0, 0));
    try std.testing.expectEqual(civil(2025, 11, 1, 0, 0, 0), civil(2026, -1, 1, 0, 0, 0));
}

// -- Reading numbers -----------------------------------------------------------

/// A run of digits and its value, saturating rather than overflowing.
const Number = struct {
    value: u64,
    start: usize,
    end: usize,

    fn read(text: []const u8, start: usize) Number {
        var value: u64 = 0;
        var end = start;
        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {
            value = value *| 10 +| (text[end] - '0');
        }
        return .{ .value = value, .start = start, .end = end };
    }

    fn len(self: Number) usize {
        return self.end - self.start;
    }

    test read {
        const n = Number.read("x2026-01", 1);
        try std.testing.expectEqual(@as(u64, 2026), n.value);
        try std.testing.expectEqual(@as(usize, 4), n.len());
        try std.testing.expectEqual(std.math.maxInt(u64), Number.read("99999999999999999999999", 0).value);
    }
};

/// Whether a digit follows `text[index]`.
fn digitAfter(text: []const u8, index: usize) bool {
    return index + 1 < text.len and std.ascii.isDigit(text[index + 1]);
}

test digitAfter {
    try std.testing.expect(digitAfter("1-2", 1));
    try std.testing.expect(!digitAfter("1-", 1));
    try std.testing.expect(!digitAfter("1-x", 1));
}

/// Whether `n` is three digits or more with a leading zero, which git
/// does not take as a number standing on its own: `0500`, `005`. So an
/// offset like `+0100` read approximately is no number at all, while
/// `+1200` is twelve hundred.
fn paddedOut(n: Number, text: []const u8) bool {
    return n.len() > 2 and text[n.start] == '0';
}

test paddedOut {
    try std.testing.expect(paddedOut(Number.read("0500", 0), "0500"));
    try std.testing.expect(!paddedOut(Number.read("05", 0), "05"));
    try std.testing.expect(!paddedOut(Number.read("1200", 0), "1200"));
}

/// The year a number standing on its own names to the approximate
/// parser: 1970 through 2099 as itself, 70 through 99 as the 1900s and 1
/// through 37 as the 2000s. Anything else is no year.
fn loneYear(n: u64) ?i64 {
    if (n >= 1970 and n <= 2099) return @intCast(n);
    if (n >= 70 and n <= 99) return @as(i64, @intCast(n)) + 1900;
    if (n >= 1 and n <= 37) return @as(i64, @intCast(n)) + 2000;
    return null;
}

test loneYear {
    try std.testing.expectEqual(@as(?i64, 2026), loneYear(2026));
    try std.testing.expectEqual(@as(?i64, 1999), loneYear(99));
    try std.testing.expectEqual(@as(?i64, 2037), loneYear(37));
    try std.testing.expectEqual(@as(?i64, null), loneYear(38));
    try std.testing.expectEqual(@as(?i64, null), loneYear(2100));
}

/// The year that ends a numeric date such as `01/02/26`: 1901 through
/// 2099 as itself, and two digits as 1971 through 2037, 70 up being the
/// 1900s. Read approximately, a year before 1970, or a two digit year
/// after the current one, is refused.
fn trailingYear(n: u64, check: ?Check) ?i64 {
    if (n >= 1901 and n <= 2099) {
        if (check != null and n < 1970) return null;
        return @intCast(n);
    }
    if (n >= 100) return null;
    const year = @as(i64, @intCast(n)) + @as(i64, if (n < 70) 2000 else 1900);
    if (year <= 1970 or year > 2037) return null;
    if (check) |c| if (year > c.now.year) return null;
    return year;
}

test trailingYear {
    const check: Check = .{ .now = Clock.at(1790000000), .timestamp = 1790000000 };
    try std.testing.expectEqual(@as(?i64, 2026), trailingYear(26, check));
    try std.testing.expectEqual(@as(?i64, 2000), trailingYear(0, check));
    try std.testing.expectEqual(@as(?i64, null), trailingYear(27, check));
    try std.testing.expectEqual(@as(?i64, 2027), trailingYear(27, null));
    try std.testing.expectEqual(@as(?i64, null), trailingYear(70, null));
    try std.testing.expectEqual(@as(?i64, 2027), trailingYear(2027, check));
}

/// The year that starts a numeric date such as `2026-01-15` or
/// `99-01-02`, whose first number is too large to be a day: 1901 through
/// 2099 as itself, and two digits as the 1900s from 70 up and otherwise
/// the 2000s. Read approximately, a year before 1970 is refused.
fn leadingYear(n: u64, check: ?Check) ?i64 {
    const year: i64 = if (n >= 1901 and n <= 2099)
        @intCast(n)
    else if (n >= 70 and n <= 99)
        @as(i64, @intCast(n)) + 1900
    else if (n < 70)
        @as(i64, @intCast(n)) + 2000
    else
        return null;
    if (check != null and year < 1970) return null;
    return year;
}

test leadingYear {
    const check: Check = .{ .now = Clock.at(1790000000), .timestamp = 1790000000 };
    try std.testing.expectEqual(@as(?i64, 2032), leadingYear(32, null));
    try std.testing.expectEqual(@as(?i64, 1970), leadingYear(70, null));
    try std.testing.expectEqual(@as(?i64, 1969), leadingYear(1969, null));
    try std.testing.expectEqual(@as(?i64, null), leadingYear(1969, check));
    try std.testing.expectEqual(@as(?i64, null), leadingYear(1900, null));
}

/// Stores a number standing on its own, for the approximate parser, in
/// the first field that is unset and can take it: the day if the number
/// is 1 through 31, else the month if it is 1 through 12, else the year
/// if `loneYear` makes one of it. Otherwise, and always for zero, it is
/// dropped.
fn loneNumber(f: *Fields, n: u64) void {
    if (n == 0) return;
    if (f.day == null and n <= 31) {
        f.day = @intCast(n);
    } else if (f.month == null and n <= 12) {
        f.month = @as(i64, @intCast(n)) - 1;
    } else if (f.year == null) {
        if (loneYear(n)) |year| f.year = year;
    }
}

test loneNumber {
    var f: Fields = .{};
    loneNumber(&f, 25);
    loneNumber(&f, 5);
    loneNumber(&f, 2025);
    try std.testing.expectEqual(Fields{ .year = 2025, .month = 4, .day = 25 }, f);

    // A number that fits nowhere is dropped.
    loneNumber(&f, 40);
    try std.testing.expectEqual(Fields{ .year = 2025, .month = 4, .day = 25 }, f);
}

/// Stores a number standing on its own, for the strict parser, in the
/// first of these that applies: a year from 1901 through 2099 is the
/// year, whatever was there (and one before 1970 makes the date
/// invalid); otherwise it is the day if that is unset and it can be;
/// two digits from `00` through `09` are the 2000s if the year is
/// unset; 1 through 12 is the month if that is unset; and 70 through 99
/// is the 1900s if the year is unset.
fn strictLoneNumber(f: *Fields, n: Number) void {
    const v = n.value;
    if (v >= 1901 and v <= 2099) {
        f.year = @intCast(v);
    } else if (f.day == null and v >= 1 and v <= 31) {
        f.day = @intCast(v);
    } else if (f.year == null and v <= 9 and n.len() == 2) {
        f.year = @as(i64, @intCast(v)) + 2000;
    } else if (f.month == null and v >= 1 and v <= 12) {
        f.month = @as(i64, @intCast(v)) - 1;
    } else if (f.year == null and v >= 70 and v <= 99) {
        f.year = @as(i64, @intCast(v)) + 1900;
    }
}

test strictLoneNumber {
    var f: Fields = .{ .year = 2026, .month = 0, .day = 15 };
    strictLoneNumber(&f, Number.read("1999", 0));
    try std.testing.expectEqual(@as(?i64, 1999), f.year);

    // A two digit year is taken only when there is none.
    strictLoneNumber(&f, Number.read("99", 0));
    try std.testing.expectEqual(@as(?i64, 1999), f.year);

    // With the day known, a two digit `05` is a year and a `5` a month.
    var g: Fields = .{ .day = 1 };
    strictLoneNumber(&g, Number.read("05", 0));
    try std.testing.expectEqual(Fields{ .year = 2005, .day = 1 }, g);
    var h: Fields = .{ .day = 1 };
    strictLoneNumber(&h, Number.read("5", 0));
    try std.testing.expectEqual(Fields{ .month = 4, .day = 1 }, h);
}

/// What the approximate parser checks a numeric date against: the
/// current local time, and the current instant.
const Check = struct {
    now: Clock,
    timestamp: i64,
};

/// Reads a numeric date starting with `first`, which is followed by
/// `-`, `/` or `.` and another number, and possibly the same separator
/// and a third, into `f`. Returns where the text after it starts, or
/// null if it is not a date.
///
/// A first number above 31 is a year by `leadingYear`, and the other two
/// are the month and the day, or the day and the month if only that
/// order has a real month. The third number is required.
///
/// Otherwise the year, if there is one, is last, by `trailingYear`, and
/// the first two are a month and a day in some order: the month first
/// for `/` and `-`, the day first for `.`, then the other. Read strictly
/// (`check` null) the first order with a real month and day is taken.
/// Read approximately, each order is also refused if it names a date
/// more than ten days after now, so that `10/05` read on 2026-09-21 is
/// the 10th of May rather than the 5th of October. A refused date is not
/// a date at all, and the caller reads its numbers one at a time, which
/// usually comes to the same thing. Read approximately, too, a year
/// before 1970 is no year.
///
/// "More than ten days after now" compares the date, in the year given
/// or else the current one, at the current local time of day, read as
/// though it were UTC, against the current instant: so a zone east of
/// UTC refuses a little sooner and one west of it a little later.
///
/// What git does with a date that fails is kept, because it shows: a
/// year at the start is checked only after the month and the day are
/// stored, so they can be left behind in `f` when null is returned.
fn matchDate(text: []const u8, first: Number, f: *Fields, check: ?Check) ?usize {
    const separator = text[first.end];
    const second = Number.read(text, first.end + 1);
    const third: ?Number = if (second.end < text.len and text[second.end] == separator and digitAfter(text, second.end))
        Number.read(text, second.end + 1)
    else
        null;

    if (first.value > 31) {
        const last = third orelse return null;
        const year = leadingYear(first.value, check);
        for ([_]Order{
            .{ .month = second.value, .day = last.value },
            .{ .month = last.value, .day = second.value },
        }) |order| {
            const month = realMonth(order.month) orelse continue;
            const day = realDay(order.day) orelse continue;
            f.month = month;
            f.day = day;
            f.year = year orelse continue;
            return last.end;
        }
        return null;
    }

    const year: ?i64 = if (third) |last| trailingYear(last.value, check) orelse return null else null;
    const end = if (third) |last| last.end else second.end;

    const day_first: Order = .{ .month = second.value, .day = first.value };
    const month_first: Order = .{ .month = first.value, .day = second.value };
    const orders: [2]Order = if (separator == '.') .{ day_first, month_first } else .{ month_first, day_first };

    for (orders) |order| {
        const month = realMonth(order.month) orelse continue;
        const day = realDay(order.day) orelse continue;
        if (check) |c| {
            const now = c.now;
            const when = civil(year orelse now.year, month, day, now.hour, now.minute, now.second);
            if (when > c.timestamp +| 10 * std.time.s_per_day) continue;
        }
        if (year) |y| f.year = y;
        f.month = month;
        f.day = day;
        return end;
    }
    return null;
}

const Order = struct { month: u64, day: u64 };

test matchDate {
    const check: Check = .{ .now = Clock.at(1790000000), .timestamp = 1790000000 };

    // A year first is followed by the month and the day.
    var iso: Fields = .{};
    try std.testing.expectEqual(@as(?usize, 10), matchDate("2026-01-15", Number.read("2026-01-15", 0), &iso, check));
    try std.testing.expectEqual(Fields{ .year = 2026, .month = 0, .day = 15 }, iso);

    // A slash is month first, unless that is too far ahead of now.
    var may: Fields = .{};
    _ = matchDate("10/05", Number.read("10/05", 0), &may, check).?;
    try std.testing.expectEqual(Fields{ .month = 4, .day = 10 }, may);
    var october: Fields = .{};
    _ = matchDate("10/05", Number.read("10/05", 0), &october, null).?;
    try std.testing.expectEqual(Fields{ .month = 9, .day = 5 }, october);

    // A dot is day first.
    var february: Fields = .{};
    _ = matchDate("01.02.2026", Number.read("01.02.2026", 0), &february, check).?;
    try std.testing.expectEqual(Fields{ .year = 2026, .month = 1, .day = 1 }, february);

    // No month at all.
    var nothing: Fields = .{};
    try std.testing.expectEqual(@as(?usize, null), matchDate("10/30", Number.read("10/30", 0), &nothing, check));

    // A year at the start that is no year still leaves the month and the
    // day behind.
    var left: Fields = .{};
    try std.testing.expectEqual(@as(?usize, null), matchDate("2100-01-02", Number.read("2100-01-02", 0), &left, null));
    try std.testing.expectEqual(Fields{ .month = 1, .day = 1 }, left);
}

fn realMonth(n: u64) ?i64 {
    return if (n >= 1 and n <= 12) @as(i64, @intCast(n)) - 1 else null;
}

test realMonth {
    try std.testing.expectEqual(@as(?i64, 0), realMonth(1));
    try std.testing.expectEqual(@as(?i64, null), realMonth(13));
}

fn realDay(n: u64) ?i64 {
    return if (n >= 1 and n <= 31) @intCast(n) else null;
}

test realDay {
    try std.testing.expectEqual(@as(?i64, 31), realDay(31));
    try std.testing.expectEqual(@as(?i64, null), realDay(0));
}

/// A time of day read out of numbers, and where the text after it
/// starts.
const Time = struct {
    hour: i64,
    minute: i64,
    second: i64,
    end: usize,
};

/// Reads `H:M` or `H:M:S` starting with `first`, which is followed by a
/// colon and a digit. The hour may be up to 24 and the second up to 60,
/// rolling into the next day or minute, which is how git reads both.
/// Anything out of range is not a time.
fn matchTime(text: []const u8, first: Number) ?Time {
    const minute = Number.read(text, first.end + 1);
    const second: ?Number = if (minute.end < text.len and text[minute.end] == ':' and digitAfter(text, minute.end))
        Number.read(text, minute.end + 1)
    else
        null;

    if (first.value > 24 or minute.value > 59) return null;
    if (second) |s| if (s.value > 60) return null;
    return .{
        .hour = @intCast(first.value),
        .minute = @intCast(minute.value),
        .second = if (second) |s| @intCast(s.value) else 0,
        .end = if (second) |s| s.end else minute.end,
    };
}

test matchTime {
    try std.testing.expectEqual(Time{ .hour = 12, .minute = 30, .second = 0, .end = 5 }, matchTime("12:30", Number.read("12:30", 0)).?);
    try std.testing.expectEqual(Time{ .hour = 24, .minute = 0, .second = 60, .end = 8 }, matchTime("24:00:60", Number.read("24:00:60", 0)).?);
    try std.testing.expectEqual(@as(?Time, null), matchTime("12:60", Number.read("12:60", 0)));
}

/// `am` and `pm`: the hour, reduced to twelve hours and put in the
/// morning or the afternoon. So `13 am` is 1:00, `0 pm` noon and `24 am`
/// midnight. An hour not yet given (null) stays unset under `am` but is
/// set by `pm`, to a value nothing can see, since it comes without a
/// minute; it only matters as being set.
fn meridiem(hour: ?i64, afternoon: bool) ?i64 {
    const h = hour orelse return if (afternoon) 11 else null;
    return @mod(h, 12) + @as(i64, if (afternoon) 12 else 0);
}

test meridiem {
    try std.testing.expectEqual(@as(?i64, 0), meridiem(12, false));
    try std.testing.expectEqual(@as(?i64, 12), meridiem(12, true));
    try std.testing.expectEqual(@as(?i64, 13), meridiem(1, true));
    try std.testing.expectEqual(@as(?i64, 13), meridiem(13, true));
    try std.testing.expectEqual(@as(?i64, 1), meridiem(13, false));
    try std.testing.expectEqual(@as(?i64, 12), meridiem(24, true));
    try std.testing.expectEqual(@as(?i64, null), meridiem(null, false));
}

// -- Words -----------------------------------------------------------------------

const month_names = [_][]const u8{ "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
const weekday_names = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };

/// Whether `word` is `name` or, at three letters or more, the start of
/// it, in any case.
fn abbreviates(word: []const u8, name: []const u8) bool {
    return word.len >= 3 and word.len <= name.len and std.ascii.eqlIgnoreCase(word, name[0..word.len]);
}

test abbreviates {
    try std.testing.expect(abbreviates("Sept", "september"));
    try std.testing.expect(!abbreviates("Se", "september"));
    try std.testing.expect(!abbreviates("Septemberx", "september"));
}

/// The month a word names, counting from zero, by `abbreviates`.
fn monthWord(word: []const u8) ?i64 {
    for (month_names, 0..) |name, index| {
        if (abbreviates(word, name)) return @intCast(index);
    }
    return null;
}

test monthWord {
    try std.testing.expectEqual(@as(?i64, 8), monthWord("Sept"));
    try std.testing.expectEqual(@as(?i64, 11), monthWord("DECEMBER"));
    try std.testing.expectEqual(@as(?i64, null), monthWord("Se"));
}

/// The weekday a word names, counting from Sunday, by `abbreviates` or
/// as the name with an `s`.
fn weekdayWord(word: []const u8) ?i64 {
    for (weekday_names, 0..) |name, index| {
        if (abbreviates(word, name)) return @intCast(index);
        if (word.len == name.len + 1 and std.ascii.eqlIgnoreCase(word[0..name.len], name) and
            std.ascii.toLower(word[name.len]) == 's') return @intCast(index);
    }
    return null;
}

test weekdayWord {
    try std.testing.expectEqual(@as(?i64, 5), weekdayWord("friday"));
    try std.testing.expectEqual(@as(?i64, 1), weekdayWord("Mon"));
    try std.testing.expectEqual(@as(?i64, 5), weekdayWord("Fridays"));
    try std.testing.expectEqual(@as(?i64, null), weekdayWord("fridayx"));
    try std.testing.expectEqual(@as(?i64, null), weekdayWord("fr"));
}

/// The zone abbreviations git knows, and their offsets in minutes east
/// of UTC.
///
/// Found by asking git about every word of one to three letters and a
/// list of longer abbreviations, with `TZ` set to a zone whose offset none
/// of them has, so that an unknown word showed as that zone's offset.
/// The order matters only where one prefix starts two names: `IDL` is the
/// International Date Line *West*.
const zone_names = [_]struct { name: []const u8, minutes: i32 }{
    .{ .name = "IDLW", .minutes = -12 * 60 },
    .{ .name = "NT", .minutes = -11 * 60 },
    .{ .name = "CAT", .minutes = -10 * 60 },
    .{ .name = "HST", .minutes = -10 * 60 },
    .{ .name = "HDT", .minutes = -9 * 60 },
    .{ .name = "YST", .minutes = -9 * 60 },
    .{ .name = "YDT", .minutes = -8 * 60 },
    .{ .name = "PST", .minutes = -8 * 60 },
    .{ .name = "PDT", .minutes = -7 * 60 },
    .{ .name = "MST", .minutes = -7 * 60 },
    .{ .name = "MDT", .minutes = -6 * 60 },
    .{ .name = "CST", .minutes = -6 * 60 },
    .{ .name = "CDT", .minutes = -5 * 60 },
    .{ .name = "EST", .minutes = -5 * 60 },
    .{ .name = "EDT", .minutes = -4 * 60 },
    .{ .name = "AST", .minutes = -3 * 60 },
    .{ .name = "ADT", .minutes = -2 * 60 },
    .{ .name = "WAT", .minutes = -1 * 60 },
    .{ .name = "GMT", .minutes = 0 },
    .{ .name = "UTC", .minutes = 0 },
    .{ .name = "Z", .minutes = 0 },
    .{ .name = "WET", .minutes = 0 },
    .{ .name = "BST", .minutes = 1 * 60 },
    .{ .name = "CET", .minutes = 1 * 60 },
    .{ .name = "MET", .minutes = 1 * 60 },
    .{ .name = "MEWT", .minutes = 1 * 60 },
    .{ .name = "FWT", .minutes = 1 * 60 },
    .{ .name = "CEST", .minutes = 2 * 60 },
    .{ .name = "MEST", .minutes = 2 * 60 },
    .{ .name = "MESZ", .minutes = 2 * 60 },
    .{ .name = "FST", .minutes = 2 * 60 },
    .{ .name = "EET", .minutes = 2 * 60 },
    .{ .name = "EEST", .minutes = 3 * 60 },
    .{ .name = "WAST", .minutes = 7 * 60 },
    .{ .name = "WADT", .minutes = 8 * 60 },
    .{ .name = "CCT", .minutes = 8 * 60 },
    .{ .name = "JST", .minutes = 9 * 60 },
    .{ .name = "EAST", .minutes = 10 * 60 },
    .{ .name = "GST", .minutes = 10 * 60 },
    .{ .name = "EADT", .minutes = 11 * 60 },
    .{ .name = "NZT", .minutes = 12 * 60 },
    .{ .name = "NZST", .minutes = 12 * 60 },
    .{ .name = "IDLE", .minutes = 12 * 60 },
    .{ .name = "NZDT", .minutes = 13 * 60 },
};

/// The offset a zone abbreviation names, in seconds east of UTC: a word
/// that is one of `zone_names`, or abbreviates one by `abbreviates`. So
/// `CES` is `CEST`, but `ESTONIA` is not `EST`.
fn zoneWord(word: []const u8) ?i32 {
    for (zone_names) |zone| {
        if (std.ascii.eqlIgnoreCase(word, zone.name) or abbreviates(word, zone.name)) {
            return zone.minutes * std.time.s_per_min;
        }
    }
    return null;
}

test zoneWord {
    try std.testing.expectEqual(@as(?i32, 0), zoneWord("utc"));
    try std.testing.expectEqual(@as(?i32, 2 * 3600), zoneWord("CES"));
    try std.testing.expectEqual(@as(?i32, -12 * 3600), zoneWord("IDL"));
    try std.testing.expectEqual(@as(?i32, -11 * 3600), zoneWord("NT"));
    try std.testing.expectEqual(@as(?i32, null), zoneWord("ESTONIA"));
    try std.testing.expectEqual(@as(?i32, null), zoneWord("UT"));
}

/// What a unit word moves back by.
const Unit = union(enum) {
    seconds: i64,
    months: i64,
};

const unit_names = [_]struct { name: []const u8, unit: Unit }{
    .{ .name = "second", .unit = .{ .seconds = 1 } },
    .{ .name = "minute", .unit = .{ .seconds = std.time.s_per_min } },
    .{ .name = "hour", .unit = .{ .seconds = std.time.s_per_hour } },
    .{ .name = "day", .unit = .{ .seconds = std.time.s_per_day } },
    .{ .name = "week", .unit = .{ .seconds = std.time.s_per_week } },
    .{ .name = "month", .unit = .{ .months = 1 } },
    .{ .name = "year", .unit = .{ .months = 12 } },
};

/// The unit a word names: the unit's name, alone or with an `s`, in any
/// case. `sec`, `mins` and `hrs` are not units.
fn unitWord(word: []const u8) ?Unit {
    for (unit_names) |entry| {
        const name = entry.name;
        if (std.ascii.eqlIgnoreCase(word, name)) return entry.unit;
        if (word.len == name.len + 1 and std.ascii.eqlIgnoreCase(word[0..name.len], name) and
            std.ascii.toLower(word[name.len]) == 's') return entry.unit;
    }
    return null;
}

test unitWord {
    try std.testing.expectEqual(Unit{ .seconds = std.time.s_per_day }, unitWord("Days").?);
    try std.testing.expectEqual(Unit{ .months = 12 }, unitWord("year").?);
    try std.testing.expectEqual(@as(?Unit, null), unitWord("mins"));
    try std.testing.expectEqual(@as(?Unit, null), unitWord("dayss"));
}

const number_names = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" };

/// The count `one` through `ten` names.
fn numberWord(word: []const u8) ?u64 {
    for (number_names, 1..) |name, value| {
        if (std.ascii.eqlIgnoreCase(word, name)) return value;
    }
    return null;
}

test numberWord {
    try std.testing.expectEqual(@as(?u64, 3), numberWord("Three"));
    try std.testing.expectEqual(@as(?u64, null), numberWord("eleven"));
}

fn wordEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and std.ascii.isAlphabetic(text[end])) end += 1;
    return end;
}

test wordEnd {
    try std.testing.expectEqual(@as(usize, 3), wordEnd("Jan5", 0));
}

// -- The strict parser -----------------------------------------------------------

/// The smallest number read as a Unix timestamp.
const timestamp_min = 100_000_000;

/// 2100-01-01, the first second git will not hold.
const timestamp_end = 4102444800;

/// git's own `<timestamp> <offset>`, at the start of `text`: digits, a
/// space, a sign and four digits. An `@` may come first, and then the
/// timestamp may be any number; without it the number has to be large
/// enough to be a timestamp at all. The offset is only a note of the
/// zone the time was recorded in, and does not move the instant.
fn internalFormat(text: []const u8) ?Exact {
    const at_sign = text.len > 0 and text[0] == '@';
    const start: usize = @intFromBool(at_sign);
    if (start >= text.len or !std.ascii.isDigit(text[start])) return null;

    const n = Number.read(text, start);
    if (!at_sign and n.value < timestamp_min) return null;
    if (n.value >= timestamp_end) return null;
    if (n.end + 6 > text.len or text[n.end] != ' ') return null;

    const sign = text[n.end + 1];
    if (sign != '+' and sign != '-') return null;
    const digits = text[n.end + 2 ..][0..4];
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;

    const hours: i32 = (digits[0] - '0') * 10 + (digits[1] - '0');
    const minutes: i32 = (digits[2] - '0') * 10 + (digits[3] - '0');
    const magnitude = (hours * 60 + minutes) * std.time.s_per_min;
    return .{
        .timestamp = @intCast(n.value),
        .offset = if (sign == '-') -magnitude else magnitude,
    };
}

test internalFormat {
    try std.testing.expectEqual(Exact{ .timestamp = 1790000000, .offset = 90 * 60 }, internalFormat("1790000000 +0130").?);
    try std.testing.expectEqual(Exact{ .timestamp = 0, .offset = 0 }, internalFormat("@0 +0000").?);
    try std.testing.expectEqual(@as(?Exact, null), internalFormat("12345678 +0000"));
    try std.testing.expectEqual(@as(?Exact, null), internalFormat("1790000000"));
}

/// What `scanStrict` found.
const Scanned = struct {
    fields: Fields = .{},
    /// Seconds east of UTC.
    offset: ?i32 = null,
    /// The fields came from a timestamp, and are in UTC rather than
    /// local time whatever offset the text goes on to give.
    utc: bool = false,
};

/// Scans `text` as a strict date and returns what it found, or null if
/// it is not a complete one. See the module documentation for what each
/// token means.
fn scanStrict(text: []const u8) ?Scanned {
    var s: Scanned = .{};
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (std.ascii.isAlphabetic(c)) {
            const end = wordEnd(text, i);
            const word = text[i..end];
            if (monthWord(word)) |month| {
                s.fields.month = month;
            } else if (std.ascii.eqlIgnoreCase(word, "am") or std.ascii.eqlIgnoreCase(word, "pm")) {
                // With no hour yet, `pm` makes one of it (see `meridiem`),
                // which keeps a `T1200` after it from being a time.
                s.fields.hour = meridiem(s.fields.hour, word[0] == 'p' or word[0] == 'P');
            } else if (zoneWord(word)) |offset| {
                // A zone name gives way to a numeric offset, and to the
                // first zone name.
                if (s.offset == null) s.offset = offset;
            }
            i = end;
            continue;
        }

        if ((c == '+' or c == '-') and digitAfter(text, i)) {
            if (matchOffset(text, i + 1)) |matched| {
                s.offset = if (c == '-') -matched.offset else matched.offset;
                i = matched.end;
            } else {
                // Not an offset, and not anything else either.
                i = Number.read(text, i + 1).end;
            }
            continue;
        }

        if (!std.ascii.isDigit(c)) {
            i += 1;
            continue;
        }

        const n = Number.read(text, i);
        const next: u8 = if (n.end < text.len) text[n.end] else 0;
        const after_t = i > 0 and text[i - 1] == 'T';

        if (next == ':' and digitAfter(text, n.end)) {
            if (matchTime(text, n)) |time| {
                s.fields.hour = time.hour;
                s.fields.minute = time.minute;
                s.fields.second = time.second;
                i = time.end;
                continue;
            }
        } else if ((next == '-' or next == '/' or next == '.') and digitAfter(text, n.end)) {
            if (matchDate(text, n, &s.fields, null)) |end| {
                i = end;
                continue;
            }
        } else if (n.len() == 8) {
            if (compactDate(n.value)) |date| {
                s.fields.year = date.year;
                s.fields.month = date.month;
                s.fields.day = date.day;
                i = n.end;
                continue;
            }
        } else if (n.len() == 6 or (n.len() == 4 and after_t and s.fields.hour == null)) {
            if (compactTime(n)) |time| {
                s.fields.hour = time.hour;
                s.fields.minute = time.minute;
                s.fields.second = time.second;
                i = n.end;
                continue;
            }
        }

        if (n.value >= timestamp_min) {
            if (s.fields.empty() and n.value <= std.math.maxInt(i64) / 2) {
                const clock = Clock.at(@intCast(n.value));
                s.fields = .{
                    .year = clock.year,
                    .month = clock.month,
                    .day = clock.day,
                    .hour = clock.hour,
                    .minute = clock.minute,
                    .second = clock.second,
                };
                s.utc = true;
            }
        } else if (n.len() == 4 and !(n.value >= 1901 and n.value <= 2099)) {
            // Four digits that are not a year are an offset east of UTC,
            // the minutes rolling over into the hours, as long as nothing
            // has given one already.
            if (n.value <= 1400 and s.offset == null) {
                s.offset = @intCast((n.value / 100) * std.time.s_per_hour + (n.value % 100) * std.time.s_per_min);
            }
        } else if (!paddedOut(n, text)) {
            strictLoneNumber(&s.fields, n);
        }
        i = n.end;
    }

    const f = s.fields;
    if (f.year == null or f.month == null or f.hour == null or f.minute == null) return null;
    const year = f.year.?;
    if (year < 1970 or year > 2099) return null;
    return s;
}

test scanStrict {
    const s = scanStrict("Thu Jan 15 12:00:00 2026 -0500").?;
    try std.testing.expectEqual(Fields{ .year = 2026, .month = 0, .day = 15, .hour = 12, .minute = 0, .second = 0 }, s.fields);
    try std.testing.expectEqual(@as(?i32, -5 * 3600), s.offset);

    // Words it does not know are skipped.
    try std.testing.expect(scanStrict("junk 2026-01-15 12:00 yesterday") != null);

    // Without a minute there is no time of day.
    try std.testing.expectEqual(@as(?Scanned, null), scanStrict("Jan 15 2026 12"));
}

/// An offset from UTC after a sign: `HH`, `HHMM` or `HH:MM`, with the
/// hour below 24 and the minute below 60. Returns it in seconds and
/// where the text after it starts.
fn matchOffset(text: []const u8, start: usize) ?struct { offset: i32, end: usize } {
    const n = Number.read(text, start);
    var hours: u64 = undefined;
    var minutes: u64 = 0;
    var end = n.end;
    switch (n.len()) {
        2 => {
            hours = n.value;
            if (end < text.len and text[end] == ':' and digitAfter(text, end)) {
                const m = Number.read(text, end + 1);
                if (m.len() != 2) return null;
                minutes = m.value;
                end = m.end;
            }
        },
        4 => {
            hours = n.value / 100;
            minutes = n.value % 100;
        },
        else => return null,
    }
    if (hours >= 24 or minutes >= 60) return null;
    return .{ .offset = @intCast(hours * std.time.s_per_hour + minutes * std.time.s_per_min), .end = end };
}

test matchOffset {
    try std.testing.expectEqual(@as(i32, 5 * 3600), matchOffset("0500", 0).?.offset);
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 30 * 60), matchOffset("05:30", 0).?.offset);
    try std.testing.expectEqual(@as(i32, 3600), matchOffset("01", 0).?.offset);
    try std.testing.expect(matchOffset("5", 0) == null);
    try std.testing.expect(matchOffset("2400", 0) == null);
}

/// `YYYYMMDD`, with a year from 1970 through 2099 and a real month and
/// day.
fn compactDate(n: u64) ?struct { year: i64, month: i64, day: i64 } {
    const year = n / 10000;
    if (year < 1970 or year > 2099) return null;
    const month = realMonth(n / 100 % 100) orelse return null;
    const day = realDay(n % 100) orelse return null;
    return .{ .year = @intCast(year), .month = month, .day = day };
}

test compactDate {
    try std.testing.expectEqual(@as(i64, 2026), compactDate(20260308).?.year);
    try std.testing.expectEqual(@as(i64, 2), compactDate(20260308).?.month);
    try std.testing.expect(compactDate(20261308) == null);
}

/// `HHMM` or `HHMMSS`, in the ranges `matchTime` allows.
fn compactTime(n: Number) ?Time {
    const v = if (n.len() == 4) n.value * 100 else n.value;
    const hour = v / 10000;
    const minute = v / 100 % 100;
    const second = v % 100;
    if (hour > 24 or minute > 59 or second > 60) return null;
    return .{ .hour = @intCast(hour), .minute = @intCast(minute), .second = @intCast(second), .end = n.end };
}

test compactTime {
    try std.testing.expectEqual(@as(i64, 2), compactTime(Number.read("023000", 0)).?.hour);
    try std.testing.expectEqual(@as(i64, 30), compactTime(Number.read("0230", 0)).?.minute);
    try std.testing.expect(compactTime(Number.read("026100", 0)) == null);
}

// -- The approximate parser ------------------------------------------------------

/// The state `approximate` builds up as it reads.
const Approx = struct {
    zone: *const TimeZone,
    /// The current instant, and the local time then.
    timestamp: i64,
    now: Clock,
    fields: Fields = .{},
    /// Whether daylight saving time was in effect at the last instant
    /// settled on, which is what the fields are read as having.
    dst: bool,
    /// The weekday of the last instant settled on.
    weekday: i64,
    /// What the fields still unset at the end, or at `now`, are taken
    /// from: the current local time, or the day before it once a `noon`,
    /// `midnight` or `tea` has found that time of day still to come.
    base: Clock,
    /// A number read and not yet used, or zero for none.
    pending: u64 = 0,
    /// Whether anything in the text meant something.
    touched: bool = false,

    /// The largest count a unit or weekday is taken to mean. Anything
    /// larger is far outside the calendar either way.
    const count_max = 1 << 40;

    fn init(options: Options) Approx {
        const local_type = options.zone.typeAt(options.now);
        const now = Clock.at(options.now +| local_type.offset);
        return .{
            .zone = options.zone,
            .timestamp = options.now,
            .now = now,
            .dst = local_type.is_dst,
            .weekday = now.weekday,
            .base = now,
        };
    }

    fn scan(self: *Approx, text: []const u8) void {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (std.ascii.isAlphabetic(c)) {
                const end = wordEnd(text, i);
                self.word(text[i..end]);
                i = end;
            } else if (std.ascii.isDigit(c)) {
                i = self.number(text, i);
            } else {
                i += 1;
            }
        }
    }

    /// The fields so far, those still unset taken from the current
    /// local time; but a month later in the year than the current one,
    /// with no year, is last year's.
    fn filled(self: Approx) Clock {
        return self.filledFrom(self.now);
    }

    /// The fields so far, those still unset taken from `now`, by the same
    /// rule as `filled`.
    fn filledFrom(self: Approx, now: Clock) Clock {
        const f = self.fields;
        const later = if (f.month) |month| month > self.now.month else false;
        return .{
            .year = f.year orelse if (later) now.year - 1 else now.year,
            .month = f.month orelse now.month,
            .day = f.day orelse now.day,
            .hour = f.hour orelse now.hour,
            .minute = f.minute orelse now.minute,
            .second = f.second orelse now.second,
            .weekday = self.weekday,
        };
    }

    /// The instant the fields so far name.
    fn instant(self: Approx) i64 {
        const c = self.filled();
        return mktimeDst(self.zone, civil(c.year, c.month, c.day, c.hour, c.minute, c.second), self.dst);
    }

    /// Sets every field from the local time at `timestamp`, and reads
    /// them from now on as having its daylight saving time or not.
    fn settle(self: *Approx, timestamp: i64) void {
        const local_type = self.zone.typeAt(timestamp);
        self.setFields(Clock.at(timestamp +| local_type.offset));
        self.dst = local_type.is_dst;
    }

    /// Sets every field from `c`.
    fn setFields(self: *Approx, c: Clock) void {
        self.fields = .{
            // git keeps a year before 1900 as a negative count from 1900,
            // which is how it marks a field it has not been given.
            .year = if (c.year < 1900) null else c.year,
            .month = c.month,
            .day = c.day,
            .hour = c.hour,
            .minute = c.minute,
            .second = c.second,
        };
        self.weekday = c.weekday;
    }

    /// Uses up a held number as `loneNumber` would.
    fn release(self: *Approx) void {
        if (self.pending != 0) loneNumber(&self.fields, self.pending);
        self.pending = 0;
    }

    /// Takes the held number as a count, leaving none held.
    fn take(self: *Approx) i64 {
        const n = @min(self.pending, count_max);
        self.pending = 0;
        return @intCast(n);
    }

    fn number(self: *Approx, text: []const u8, start: usize) usize {
        self.touched = true;
        self.release();

        const n = Number.read(text, start);
        const next: u8 = if (n.end < text.len) text[n.end] else 0;

        if (next == ':' and digitAfter(text, n.end)) {
            if (matchTime(text, n)) |time| {
                self.fields.hour = time.hour;
                self.fields.minute = time.minute;
                self.fields.second = time.second;
                return time.end;
            }
        } else if ((next == '-' or next == '/' or next == '.') and digitAfter(text, n.end)) {
            const check: Check = .{ .now = self.now, .timestamp = self.timestamp };
            if (matchDate(text, n, &self.fields, check)) |end| return end;
        }

        if (paddedOut(n, text)) {
            // Uses up the number before it and is not one itself, which
            // is what makes an offset like `+0100` mean nothing here.
        } else if (n.value >= timestamp_min and self.fields.empty()) {
            self.settle(@intCast(@min(n.value, std.math.maxInt(i64) / 2)));
        } else {
            self.pending = n.value;
        }
        return n.end;
    }

    fn word(self: *Approx, w: []const u8) void {
        if (std.ascii.eqlIgnoreCase(w, "yesterday")) {
            self.touched = true;
            self.pending = 0;
            self.fields.day = self.now.day - 1;
            self.settle(self.instant());
        } else if (std.ascii.eqlIgnoreCase(w, "today")) {
            self.touched = true;
            self.pending = 0;
            self.fields.day = self.now.day;
            const c = self.filled();
            if (c.hour == self.now.hour and c.minute == self.now.minute and c.second == self.now.second) {
                self.fields.hour = 0;
                self.fields.minute = 0;
                self.fields.second = 0;
            }
            self.settle(self.instant());
        } else if (std.ascii.eqlIgnoreCase(w, "noon")) {
            self.clock(12);
        } else if (std.ascii.eqlIgnoreCase(w, "midnight")) {
            self.clock(0);
        } else if (std.ascii.eqlIgnoreCase(w, "tea")) {
            self.clock(17);
        } else if (std.ascii.eqlIgnoreCase(w, "now")) {
            self.touched = true;
            self.pending = 0;
            const c = self.filledFrom(self.base);
            self.settle(mktimeDst(self.zone, civil(c.year, c.month, c.day, c.hour, c.minute, c.second), self.dst));
        } else if (std.ascii.eqlIgnoreCase(w, "never")) {
            self.touched = true;
            self.pending = 0;
            self.settle(0);
        } else if (std.ascii.eqlIgnoreCase(w, "last")) {
            self.touched = true;
            if (self.pending == 0) self.pending = 1;
        } else if (std.ascii.eqlIgnoreCase(w, "am") or std.ascii.eqlIgnoreCase(w, "pm")) {
            self.touched = true;
            const f = &self.fields;
            if (self.pending != 0) {
                f.hour = self.take();
                f.minute = 0;
                f.second = 0;
            }
            f.hour = meridiem(f.hour orelse self.now.hour, w[0] == 'p' or w[0] == 'P');
        } else if (numberWord(w)) |n| {
            self.touched = true;
            if (self.pending == 0) self.pending = n;
        } else if (unitWord(w)) |unit| {
            if (self.pending == 0) return;
            self.touched = true;
            const n = self.take();
            switch (unit) {
                .seconds => |each| self.settle(self.instant() -| n *| each),
                .months => |each| {
                    // Settled where it is, then moved on the calendar
                    // alone: the daylight saving flag and the weekday a
                    // weekday name counts from are those from before.
                    self.settle(self.instant());
                    const c = self.filled();
                    const weekday = self.weekday;
                    self.setFields(Clock.at(civil(c.year, c.month -| n *| each, c.day, c.hour, c.minute, c.second)));
                    self.weekday = weekday;
                },
            }
        } else if (monthWord(w)) |month| {
            self.touched = true;
            self.fields.month = month;
        } else if (weekdayWord(w)) |weekday| {
            if (self.pending == 0) return;
            self.touched = true;
            const n = self.take();
            const back = @mod(self.weekday - weekday - 1, 7) + 1;
            self.fields.day = self.filled().day -| back -| 7 *| (n - 1);
            self.settle(self.instant());
        }
    }

    /// `noon`, `midnight` and `tea`: the time `hour`:00. If the time so
    /// far is earlier, an unset date is to be the day before today's.
    fn clock(self: *Approx, hour: i64) void {
        self.touched = true;
        self.release();
        if (hour > self.filled().hour) {
            const b = self.base;
            self.base = Clock.at(civil(b.year, b.month, b.day - 1, b.hour, b.minute, b.second));
        }
        self.fields.hour = hour;
        self.fields.minute = 0;
        self.fields.second = 0;
    }

    /// Uses up what is still held and returns the instant the text
    /// named.
    fn finish(self: *Approx) i64 {
        self.release();
        const c = self.filledFrom(self.base);
        return mktimeDst(self.zone, civil(c.year, c.month, c.day, c.hour, c.minute, c.second), self.dst);
    }
};

test Approx {
    // Monday 2026-09-21 14:13:20 UTC.
    const options: Options = .{ .now = 1790000000, .zone = &TimeZone.utc };
    const read = struct {
        fn read(text: []const u8, o: Options) i64 {
            return approximate(text, o).timestamp;
        }
    }.read;

    // A held number is a day, then a month, then a year.
    try std.testing.expectEqual(civil(2025, 8, 5, 14, 13, 20), read("5 25", options));
    try std.testing.expectEqual(civil(2026, 4, 25, 14, 13, 20), read("25 5", options));

    // A month later in the year than this one, with no year, was last
    // year's.
    try std.testing.expectEqual(civil(2025, 9, 5, 14, 13, 20), read("Oct 5", options));

    // Units count back from the date so far.
    try std.testing.expectEqual(civil(2026, 0, 2, 14, 13, 20), read("Jan 5 3 days ago", options));

    // Named times go back a day if they are later than now.
    try std.testing.expectEqual(civil(2026, 8, 21, 12, 0, 0), read("noon", options));
    try std.testing.expectEqual(civil(2026, 8, 20, 17, 0, 0), read("tea", options));

    try std.testing.expectEqual(@as(i64, 0), read("never", options));
}
