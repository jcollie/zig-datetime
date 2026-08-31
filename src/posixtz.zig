// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parser and evaluator for the POSIX `TZ` string, the rule that appears in
//! the footer of a version 2 or later TZif file and that also shows up in
//! the `TZ` environment variable.
//!
//! The footer describes what a zone does after its last stored transition.
//! It is not an optional extra: a file compiled with `zic -b slim`, which
//! is the default since tzcode 2020b, deliberately stops emitting
//! transitions once they become a repeating annual rule and leaves this
//! string to describe every year from then on.
//!
//! A string looks like `CST6CDT,M3.2.0,M11.1.0` or `<-03>3` and reads as
//! `std offset [dst [offset] [,start[/time],end[/time]]]`.

const std = @import("std");

const Date = @import("Date.zig");
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;
const Type = @import("tzif.zig").Type;

/// What `parse` can fail with. `MissingRules` is the case worth naming:
/// the string gave a daylight saving designation but no rule saying when
/// it starts and ends, which POSIX allows and this cannot evaluate.
pub const ParseError = error{
    BadDesignation,
    BadOffset,
    BadRule,
    MissingRules,
    Truncated,
};

/// When in the year a switch happens. The three spellings come straight
/// from POSIX.
pub const Rule = union(enum) {
    /// `Jn`: the nth day of the year counting from 1, where February 29
    /// is never counted, so `J60` is always March 1.
    julian_no_leap: u16,
    /// `n`: the nth day of the year counting from 0, where February 29 is
    /// counted in leap years.
    julian: u16,
    /// `Mm.w.d`: weekday `d` of week `w` of month `m`, where week 5 means
    /// the last such weekday in the month.
    month_week_day: struct {
        month: Month,
        /// 1-5, where 5 means the last occurrence in the month.
        week: u8,
        weekday: DayOfWeek,
    },

    /// Returns the day this rule picks out in `year`, as a day number
    /// counted from the epoch.
    ///
    /// `january_first` is that year's first of January, already converted.
    /// Taking it rather than working it out is what keeps this off the
    /// calendar: everything here is arithmetic on a day number, and a
    /// caller asking about three years in a row converts once and steps
    /// between them by the length of a year. Converting inside would put
    /// two conversions behind every switch and twelve behind every
    /// `Posix.spanAt`.
    fn dayNumber(self: Rule, year: Year, january_first: Date.DaysType) Date.DaysType {
        switch (self) {
            .month_week_day => |spec| {
                const first_of_month = january_first + spec.month.daysBefore(year);
                const first_weekday = @intFromEnum(DayOfWeek.fromDaysSinceStartOfEra(first_of_month));
                const wanted = @intFromEnum(spec.weekday);

                // The first `wanted` weekday of the month, then forward by
                // whole weeks. Week 5 means "last", which is the same as
                // going too far and stepping back a week.
                var day: u16 = 1 + (7 + @as(u16, wanted) - first_weekday) % 7;
                day += (@as(u16, spec.week) - 1) * 7;
                const last = spec.month.lastDay(year);
                while (day > last) day -= 7;

                return first_of_month + day - 1;
            },
            .julian_no_leap, .julian => {
                const leap = Month.Feb.lastDay(year) == 29;
                const day_of_year: u16 = switch (self) {
                    // J1 is January 1. In a leap year every day from March
                    // onwards sits one further into the real year, because
                    // the numbering pretends February 29 does not exist.
                    .julian_no_leap => |n| if (leap and n >= 60) n + 1 else n,
                    // This form is zero based and does count February 29.
                    .julian => |n| n + 1,
                    else => unreachable,
                };

                return january_first + day_of_year - 1;
            },
        }
    }

    /// Returns the day of the month this rule picks out in `year`.
    ///
    /// The same answer as `dayNumber` said another way, and the way that
    /// reads: this is what the rule means, and `dayNumber` is how the hot
    /// path asks for it.
    fn dayOfMonth(self: Rule, year: Year) struct { month: Month, day: Day } {
        const january_first = (Date{ .year = year, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
        const date = Date.fromDaysSinceStartOfEra(self.dayNumber(year, january_first));
        return .{ .month = date.month, .day = date.day };
    }

    test dayOfMonth {
        // The United States rules: the second Sunday of March and the
        // first Sunday of November.
        const march: Rule = .{ .month_week_day = .{ .month = .Mar, .week = 2, .weekday = .Sun } };
        try std.testing.expectEqual(Month.Mar, march.dayOfMonth(2024).month);
        try std.testing.expectEqual(@as(Day, 10), march.dayOfMonth(2024).day);

        // Week 5 means the last such weekday, however many there are.
        const last: Rule = .{ .month_week_day = .{ .month = .Mar, .week = 5, .weekday = .Sun } };
        try std.testing.expectEqual(@as(Day, 31), last.dayOfMonth(2024).day);

        // `Jn` never counts February 29, so J60 is March 1 in any year.
        const julian: Rule = .{ .julian_no_leap = 60 };
        try std.testing.expectEqual(Month.Mar, julian.dayOfMonth(2024).month);
        try std.testing.expectEqual(@as(Day, 1), julian.dayOfMonth(2024).day);
        try std.testing.expectEqual(Month.Mar, julian.dayOfMonth(2025).month);

        // The zero-based form does count it, so the same ordinal lands a
        // day earlier in a leap year than it does in an ordinary one.
        const zero_based: Rule = .{ .julian = 59 };
        try std.testing.expectEqual(Month.Feb, zero_based.dayOfMonth(2024).month);
        try std.testing.expectEqual(@as(Day, 29), zero_based.dayOfMonth(2024).day);
        try std.testing.expectEqual(Month.Mar, zero_based.dayOfMonth(2025).month);
    }
};

/// A switch into or out of daylight saving time.
pub const Transition = struct {
    rule: Rule,
    /// Seconds after local midnight, defaulting to 02:00:00. POSIX allows
    /// this to be negative or past the end of the day.
    time: i32 = 2 * std.time.s_per_hour,

    /// Returns the Unix timestamp at which this transition happens in
    /// `year`, given the UTC offset in effect just before it.
    fn timestamp(self: Transition, year: Year, offset_before: i32, january_first: Date.DaysType) i64 {
        const midnight = @as(i64, self.rule.dayNumber(year, january_first)) * std.time.s_per_day;
        return midnight + self.time - offset_before;
    }

    test timestamp {
        // The second Sunday of March 2024 is the 10th, and the switch
        // defaults to 02:00 local time. The offset in effect just before
        // it is standard time, which is what turns that into UTC.
        const transition: Transition = .{
            .rule = .{ .month_week_day = .{ .month = .Mar, .week = 2, .weekday = .Sun } },
        };

        const january_first = (Date{ .year = 2024, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
        const at = transition.timestamp(2024, -6 * std.time.s_per_hour, january_first);
        try std.testing.expectEqual(@as(i64, 1710057600), at);
    }
};

/// The daylight saving half of a rule: what the clock reads then, what it
/// is called, and the two points in the year it is bounded by.
pub const Dst = struct {
    designation: []const u8,
    /// Seconds east of UTC.
    offset: i32,
    start: Transition,
    end: Transition,
};

/// A parsed POSIX `TZ` string.
///
/// This is a rule rather than a table: it describes every year the same
/// way, so it can answer for times arbitrarily far past the end of a TZif
/// file's stored transitions. `span` evaluates it for a given timestamp.
pub const Posix = struct {
    std_designation: []const u8,
    /// Seconds east of UTC.
    std_offset: i32,
    /// Null when the zone has no daylight saving time, as in `<-03>3`.
    dst: ?Dst,

    /// A stretch of time over which one local time type applies. The
    /// same shape as `tzif.Tzif.Span`, so that a caller can treat a
    /// stored transition and a rule-derived one alike.
    pub const Span = struct {
        local_type: Type,
        start: i64,
        end: i64,
    };

    /// Returns the span around `timestamp`.
    ///
    /// Any `i64` is accepted, but only an instant well inside the
    /// calendar answers meaningfully. Placing a span needs the switches
    /// of the years either side of it, so the first and last year a
    /// `Date` can hold have no year beyond them to look at and the bounds
    /// come back open; past `Date.min_seconds` and `Date.max_seconds`
    /// there is no year at all and everything saturates. The result stays
    /// total either way.
    ///
    /// The bounds are the nearest switch either side, and a switch either
    /// side may belong to a neighbouring year, since a switch time can be
    /// up to 167 hours off its day and so spill out of the year that
    /// names it. So the work is: convert `timestamp` to a local date once
    /// to name its year, evaluate that year's two switches, and take the
    /// neighbouring years' as well unless it can be shown they cannot
    /// help. `spanAtScanning` is the same thing with nothing shown and
    /// every year evaluated, and a test holds the two against each other.
    ///
    /// Naming the year is the expensive part, so the neighbours are
    /// reached by stepping the first of January by a year's length rather
    /// than converting again, and every switch is worked out as an offset
    /// from that one day number.
    pub fn spanAt(self: Posix, timestamp: i64) Span {
        const dst = self.dst orelse return .{
            .local_type = self.localType(false),
            .start = std.math.minInt(i64),
            .end = std.math.maxInt(i64),
        };

        // Which year's rules apply is decided in local standard time,
        // which is what POSIX means by the rules being "local".
        // Saturating, because a caller may hand in any `i64` and the sum
        // of an extreme one and an offset is not one.
        const local = timestamp +| self.std_offset;
        const days = Date.daysFromSecondsSaturating(local);

        // The year, and its first of January. Every switch below is an
        // offset from that one day number, which is what keeps the
        // calendar out of the rest of this.
        const placed = Date.yearAndFirstDay(days);
        const year = placed.year;
        const january_first = placed.january_first;

        const start_at = dst.start.timestamp(year, self.std_offset, january_first);
        const end_at = dst.end.timestamp(year, dst.offset, january_first);
        const lower = @min(start_at, end_at);
        const upper = @max(start_at, end_at);

        // When the instant sits between this year's own two switches, and
        // both of them are far enough inside the year, no switch of the
        // neighbouring years can be between them and there is nothing to
        // gain by working those out.
        //
        // Far enough is provable rather than assumed. A switch for year Y
        // is `dayNumber(Y) * 86400 + time - offset`, where the day is
        // inside Y, the time is under 168 hours either way, and the offset
        // is under 25 hours, so no switch of Y reaches more than about
        // nine days outside Y. Ten is the margin taken here.
        //
        // Everything real passes: a rule switching in March and November
        // is months clear of either end. What does not is the sort of rule
        // the fuzzer builds, `M1.1.0/167`, and that takes the long way
        // round. `spanAtScanning` is that long way, and a test compares
        // the two over every rule and instant it can think of, which is
        // what says this reasoning holds.
        const reach = 10 * std.time.s_per_day;
        const opens = @as(i64, january_first) *| std.time.s_per_day;
        const closes = (@as(i64, january_first) +| yearLength(year)) *| std.time.s_per_day;
        const clear_of_the_year = lower > opens +| reach and upper < closes -| reach;

        if (clear_of_the_year and lower <= timestamp and timestamp < upper) {
            return .{
                .local_type = self.localType(lower == start_at),
                .start = lower,
                .end = upper,
            };
        }

        const Switch = struct { at: i64, opens_dst: bool };
        var switches: [6]Switch = undefined;
        switches[0] = .{ .at = start_at, .opens_dst = true };
        switches[1] = .{ .at = end_at, .opens_dst = false };
        var count: usize = 2;

        // Saturating, because `year` may already be the first or last a
        // `Year` can hold, when the timestamp was outside the calendar.
        const previous = year -| 1;
        const next = year +| 1;

        // Which neighbouring years can hold the bound this year is
        // missing. When the switches are clear of both ends of the year,
        // every switch of the year before lies below this year's pair and
        // every switch of the year after lies above it, so only the side
        // the instant fell off of the pair can supply anything. When they
        // are not clear, nothing is known and both years are needed.
        const want_previous = !clear_of_the_year or timestamp < lower;
        const want_next = !clear_of_the_year or timestamp >= upper;

        // A year equal to its own neighbour is one the arithmetic above
        // saturated at, and would only repeat switches already in hand.
        if (want_previous and previous != year) {
            const first = january_first - yearLength(previous);
            switches[count] = .{
                .at = dst.start.timestamp(previous, self.std_offset, first),
                .opens_dst = true,
            };
            switches[count + 1] = .{
                .at = dst.end.timestamp(previous, dst.offset, first),
                .opens_dst = false,
            };
            count += 2;
        }

        if (want_next and next != year) {
            const first = january_first + yearLength(year);
            switches[count] = .{
                .at = dst.start.timestamp(next, self.std_offset, first),
                .opens_dst = true,
            };
            switches[count + 1] = .{
                .at = dst.end.timestamp(next, dst.offset, first),
                .opens_dst = false,
            };
            count += 2;
        }

        // The span is bounded by the nearest switch either side, which is
        // one pass rather than a sort: ordering them all only to walk to
        // the pair straddling the instant is work the answer does not use.
        var start: i64 = std.math.minInt(i64);
        var end: i64 = std.math.maxInt(i64);
        var in_dst = false;
        var have_start = false;

        for (switches[0..count]) |candidate| {
            if (candidate.at <= timestamp) {
                if (!have_start or candidate.at > start) {
                    start = candidate.at;
                    // Whether the span is the daylight one follows from
                    // which switch opened it.
                    in_dst = candidate.opens_dst;
                    have_start = true;
                }
            } else if (candidate.at < end) {
                end = candidate.at;
            }
        }

        return .{
            .local_type = self.localType(in_dst),
            .start = start,
            .end = end,
        };
    }

    /// What `spanAt` means, written the slow and obvious way: the switches
    /// of all three years that could hold one, and the nearest either side
    /// of `timestamp`.
    ///
    /// This exists for the test below to hold `spanAt` against. `spanAt`
    /// skips years it can show hold nothing, and the reasoning behind
    /// those skips is the part worth checking against something that does
    /// no reasoning at all; a shortcut checked only by its own argument is
    /// how the last two bugs in this file got in.
    fn spanAtScanning(self: Posix, timestamp: i64) Span {
        const dst = self.dst orelse return .{
            .local_type = self.localType(false),
            .start = std.math.minInt(i64),
            .end = std.math.maxInt(i64),
        };

        const local = timestamp +| self.std_offset;
        const days = Date.daysFromSecondsSaturating(local);
        const placed = Date.yearAndFirstDay(days);
        const year = placed.year;
        const january_first = placed.january_first;

        // Saturating, because `year` may already be the first or last a
        // `Year` can hold. A repeated year only puts a duplicate in the
        // list below, which the walk does not mind. The neighbouring
        // years' first of January is this one's stepped by the length of a
        // year, which saves converting them.
        const previous = year -| 1;
        const next = year +| 1;
        const years = [_]Year{ previous, year, next };
        const firsts = [_]Date.DaysType{
            if (previous == year) january_first else january_first - yearLength(previous),
            january_first,
            if (next == year) january_first else january_first + yearLength(year),
        };

        // The span is bounded by the nearest switch either side, which is
        // one pass rather than a sort: ordering all six only to walk to
        // the pair straddling the instant is work the answer does not use.
        var start: i64 = std.math.minInt(i64);
        var end: i64 = std.math.maxInt(i64);
        var in_dst = false;
        var have_start = false;

        for (years, firsts) |each, first| {
            const candidates = [_]struct { at: i64, opens_dst: bool }{
                .{ .at = dst.start.timestamp(each, self.std_offset, first), .opens_dst = true },
                .{ .at = dst.end.timestamp(each, dst.offset, first), .opens_dst = false },
            };

            for (candidates) |candidate| {
                if (candidate.at <= timestamp) {
                    if (!have_start or candidate.at > start) {
                        start = candidate.at;
                        // Whether this span is the daylight one follows
                        // from which switch opened it.
                        in_dst = candidate.opens_dst;
                        have_start = true;
                    }
                } else if (candidate.at < end) {
                    end = candidate.at;
                }
            }
        }

        return .{
            .local_type = self.localType(in_dst),
            .start = start,
            .end = end,
        };
    }

    test spanAtScanning {
        const rule = try parse("CST6CDT,M3.2.0,M11.1.0");

        // The second Sunday of March 2024, an hour before and after.
        const spring = 1710057600;
        const before = rule.spanAtScanning(spring - 3600);
        const after = rule.spanAtScanning(spring + 3600);

        try std.testing.expectEqual(@as(i64, -6 * 3600), before.local_type.offset);
        try std.testing.expectEqual(@as(i64, -5 * 3600), after.local_type.offset);
        try std.testing.expectEqual(spring, before.end);
        try std.testing.expectEqual(spring, after.start);

        // And it is the same answer `spanAt` shortcuts its way to.
        try std.testing.expectEqual(rule.spanAt(spring - 3600), before);
        try std.testing.expectEqual(rule.spanAt(spring + 3600), after);
    }

    /// This rule's daylight or standard type, whichever was asked for.
    ///
    /// `spanAt` and `spanAtScanning` return from several places between
    /// them and all of them need it, which is the only reason it is a
    /// function.
    fn localType(self: Posix, in_dst: bool) Type {
        if (in_dst) if (self.dst) |dst| return .{
            .offset = dst.offset,
            .is_dst = true,
            .designation = dst.designation,
        };

        return .{
            .offset = self.std_offset,
            .is_dst = false,
            .designation = self.std_designation,
        };
    }

    test spanAt {
        const rule = try parse("CST6CDT,M3.2.0,M11.1.0");

        // Midsummer 2024 falls inside daylight saving time, and the span runs
        // from the March switch to the November one.
        const summer = rule.spanAt(1720000000);
        try testing.expect(summer.local_type.is_dst);
        try testing.expectEqualStrings("CDT", summer.local_type.designation);
        try testing.expectEqual(@as(i64, 1710057600), summer.start);
        try testing.expectEqual(@as(i64, 1730617200), summer.end);

        // Midwinter is standard time, and its span is bounded by switches in
        // the years either side, which is why the neighbouring years matter.
        const winter = rule.spanAt(1704067200);
        try testing.expect(!winter.local_type.is_dst);
        try testing.expectEqualStrings("CST", winter.local_type.designation);

        // A zone that never switches has one span covering all of time.
        const fixed = try parse("<-03>3");
        const always = fixed.spanAt(0);
        try testing.expectEqual(@as(i64, std.math.minInt(i64)), always.start);
        try testing.expectEqual(@as(i64, std.math.maxInt(i64)), always.end);
    }

    /// Returns the local time type in effect at `timestamp`. The same
    /// caveat as `spanAt` about instants outside the calendar.
    ///
    /// This used to have a search of its own, over one year rather than
    /// three, and it was wrong for rules whose two switches do not sit
    /// tidily inside the year that names them: a switch time may be up to
    /// 167 hours either side of its day and so spill into a neighbouring
    /// year, and two switches landing in the same week can swap order
    /// from year to year. Fuzzing found both, which is two more than
    /// reading it found, so it defers to `spanAt` and there is one search
    /// to be right about. The speed that cost is back in `spanAt`, where
    /// skipping a year is conditional on being able to show it holds
    /// nothing rather than on the rule looking ordinary.
    pub fn typeAt(self: Posix, timestamp: i64) Type {
        return self.spanAt(timestamp).local_type;
    }

    test typeAt {
        const rule = try parse("CST6CDT,M3.2.0,M11.1.0");

        const summer = rule.typeAt(1720000000);
        try testing.expect(summer.is_dst);
        try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), summer.offset);

        const winter = rule.typeAt(1704067200);
        try testing.expect(!winter.is_dst);
        try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), winter.offset);
    }
};

/// Parses a POSIX TZ string. The returned value borrows the designations
/// out of `text`, which must outlive it.
pub fn parse(text: []const u8) ParseError!Posix {
    var cursor: Cursor = .{ .text = text };

    const std_designation = try cursor.designation();
    // POSIX writes offsets as the amount to add to local time to reach UTC,
    // which is the opposite sign to everything else here, so "EST5" is a
    // zone five hours west and its offset east of UTC is negative.
    const std_offset = -try cursor.offset();

    if (cursor.done()) return .{
        .std_designation = std_designation,
        .std_offset = std_offset,
        .dst = null,
    };

    const dst_designation = try cursor.designation();
    // An absent daylight offset means one hour ahead of standard time.
    const dst_offset = if (cursor.done() or cursor.peek() == ',')
        std_offset + std.time.s_per_hour
    else
        -try cursor.offset();

    // tzdata always writes the rules out, and without them the switch
    // dates would be a guess, so an absent rule set is refused rather
    // than filled in with somebody's local convention.
    if (cursor.done()) return error.MissingRules;

    try cursor.expect(',');
    const start = try cursor.transition();
    try cursor.expect(',');
    const end = try cursor.transition();
    if (!cursor.done()) return error.BadRule;

    return .{
        .std_designation = std_designation,
        .std_offset = std_offset,
        .dst = .{
            .designation = dst_designation,
            .offset = dst_offset,
            .start = start,
            .end = end,
        },
    };
}

/// How many days `year` has, which is how the rule evaluation steps from
/// one year's first of January to its neighbour's without converting one.
fn yearLength(year: Year) Date.DaysType {
    return if (Month.Feb.lastDay(year) == 29) 366 else 365;
}

test "the shortcut in spanAt agrees with a full scan" {
    // Every rule this file, its tests and the fuzzer's seeds have thought
    // of, including the ones whose switches land outside the year they
    // belong to and so cannot take the shortcut at all.
    const rules = [_][]const u8{
        "UTC0",
        "EST5",
        "<-03>3",
        "IST-5:30",
        "EST5EDT,M3.2.0,M11.1.0",
        "CST6CDT,M3.2.0/2,M11.1.0/2",
        "AEST-10AEDT,M10.1.0,M4.1.0", // southern, so the span crosses the new year
        "CST6CDT,J60,J300",
        "CST6CDT,59,300",
        "CST6CDT,M3.5.0,M11.1.0",
        "CST6CDT,M1.1.0,M12.5.6", // switches in the first and last weeks
        "CST6CDT,J1,J365",
        "CST6CDT,0,365",
        "AAA0BBB,M1.1.0/167,M1.1.0/-167", // a week either side of the year's edge
        "AAA0BBB,M12.5.6/167,M1.1.0/-167",
        "AAA24BBB24,M1.1.0,M2.1.0", // the largest offsets POSIX allows
        "AAA-24BBB-24,M12.1.0,M1.1.0",
        // The first Sunday of January less a day is January in most
        // years and the December before in the rest, so one year's switch
        // can land inside the year before's pair. 2022 into 2023 is such
        // a pair of years, and is inside the sweep below.
        "AAA0BBB,M1.1.0/-24,J365/12",
        "AAA0BBB,J1/12,M12.5.0/167", // and the same shape at the other end
        "AAA0BBB,J1,J1", // a rule whose two switches coincide
        "AAA0BBB,M6.1.0/24,M6.1.0/24",
    };

    for (rules) |text| {
        const rule = try parse(text);

        // A coarse sweep, at a step that is not a divisor of a day so
        // that it walks over every hour of the clock in turn.
        var at: i64 = 1704067200 - 2 * 365 * std.time.s_per_day;
        while (at < 1704067200 + 2 * 365 * std.time.s_per_day) : (at += 7 * 3600 + 13) {
            try std.testing.expectEqual(rule.spanAtScanning(at), rule.spanAt(at));
        }

        // And a fine one either side of the new year, second by second
        // through the hours the shortcut's margin is reasoning about.
        for ([_]i64{ 1703980800, 1704067200, 1735516800, 1735603200 }) |midnight| {
            var near = midnight - 8 * std.time.s_per_day;
            while (near < midnight + 8 * std.time.s_per_day) : (near += 997) {
                try std.testing.expectEqual(rule.spanAtScanning(near), rule.spanAt(near));
            }
        }

        // Every switch of a decade, and the seconds either side of it,
        // since those are the instants the two could most easily place on
        // opposite sides of.
        var year: Year = 2015;
        while (year <= 2025) : (year += 1) {
            const first = (Date{ .year = year, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
            if (rule.dst) |dst| {
                for ([_]i64{
                    dst.start.timestamp(year, rule.std_offset, first),
                    dst.end.timestamp(year, dst.offset, first),
                }) |edge| {
                    for ([_]i64{ -2, -1, 0, 1, 2 }) |delta| {
                        const probe = edge +| delta;
                        try std.testing.expectEqual(rule.spanAtScanning(probe), rule.spanAt(probe));
                    }
                }
            }
        }

        // The ends of the range, where the arithmetic saturates and the
        // two have to saturate the same way.
        for ([_]i64{
            std.math.minInt(i64),     std.math.maxInt(i64),
            std.math.minInt(i64) + 1, std.math.maxInt(i64) - 1,
            Date.min_seconds,         Date.max_seconds,
            Date.min_seconds - 1,     Date.max_seconds + 1,
            Date.min_seconds + 1,     Date.max_seconds - 1,
            std.math.minInt(i64) / 4, std.math.maxInt(i64) / 4,
            std.math.minInt(i32),     std.math.maxInt(i32),
            0,                        -1,
        }) |probe| {
            try std.testing.expectEqual(rule.spanAtScanning(probe), rule.spanAt(probe));
        }
    }
}

test yearLength {
    try std.testing.expectEqual(@as(Date.DaysType, 366), yearLength(2024));
    try std.testing.expectEqual(@as(Date.DaysType, 365), yearLength(2025));
    try std.testing.expectEqual(@as(Date.DaysType, 365), yearLength(2100));
    try std.testing.expectEqual(@as(Date.DaysType, 366), yearLength(2000));

    // And it is the distance between two consecutive first of Januaries,
    // which is the only reason it is here.
    const first = (Date{ .year = 2024, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    const second = (Date{ .year = 2025, .month = .Jan, .day = 1 }).toDaysSinceStartOfEra();
    try std.testing.expectEqual(yearLength(2024), second - first);
}

/// A position in the string, with the small operations the grammar is
/// written in terms of.
const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    /// Whether the string is exhausted.
    fn done(self: Cursor) bool {
        return self.index >= self.text.len;
    }

    test done {
        var cursor: Cursor = .{ .text = "5" };
        try std.testing.expect(!cursor.done());

        cursor.index = 1;
        try std.testing.expect(cursor.done());
    }

    /// The character at the cursor. The caller must have checked `done`.
    fn peek(self: Cursor) u8 {
        return self.text[self.index];
    }

    test peek {
        const cursor: Cursor = .{ .text = "<-03>3" };
        try std.testing.expectEqual(@as(u8, '<'), cursor.peek());
    }

    /// Consumes `char`, which the grammar requires to be next.
    fn expect(self: *Cursor, char: u8) ParseError!void {
        if (self.done() or self.peek() != char) return error.BadRule;
        self.index += 1;
    }

    test expect {
        // The dots of an `Mm.w.d` rule are required, so a missing one is
        // a malformed rule rather than the end of the field.
        var cursor: Cursor = .{ .text = ".2.0" };
        try cursor.expect('.');
        try std.testing.expectEqual(@as(usize, 1), cursor.index);

        try std.testing.expectError(error.BadRule, cursor.expect('.'));
    }

    /// Reads a zone abbreviation, either three or more letters or any run
    /// of letters, digits and signs inside angle brackets.
    fn designation(self: *Cursor) ParseError![]const u8 {
        if (self.done()) return error.Truncated;

        if (self.peek() == '<') {
            self.index += 1;
            const start = self.index;
            while (!self.done() and self.peek() != '>') : (self.index += 1) {
                switch (self.peek()) {
                    'a'...'z', 'A'...'Z', '0'...'9', '+', '-' => {},
                    else => return error.BadDesignation,
                }
            }
            if (self.done()) return error.BadDesignation;
            defer self.index += 1;
            const name = self.text[start..self.index];
            if (name.len < 3) return error.BadDesignation;
            return name;
        }

        const start = self.index;
        while (!self.done() and std.ascii.isAlphabetic(self.peek())) self.index += 1;
        const name = self.text[start..self.index];
        if (name.len < 3) return error.BadDesignation;
        return name;
    }

    test designation {
        // The bare form is a run of three or more letters.
        var plain: Cursor = .{ .text = "CST6CDT" };
        try std.testing.expectEqualStrings("CST", try plain.designation());

        // The bracketed form is what lets a name hold digits and signs,
        // which is how the numeric zone abbreviations are written.
        var bracketed: Cursor = .{ .text = "<-03>3" };
        try std.testing.expectEqualStrings("-03", try bracketed.designation());
        // The closing bracket is consumed too, leaving the offset next.
        try std.testing.expectEqualStrings("3", bracketed.text[bracketed.index..]);

        var too_short: Cursor = .{ .text = "ES5" };
        try std.testing.expectError(error.BadDesignation, too_short.designation());

        var unclosed: Cursor = .{ .text = "<ABC" };
        try std.testing.expectError(error.BadDesignation, unclosed.designation());
    }

    /// Reads `[+|-]hh[:mm[:ss]]` and returns it in seconds, keeping POSIX's
    /// sign convention.
    fn offset(self: *Cursor) ParseError!i32 {
        if (self.done()) return error.Truncated;

        var sign: i32 = 1;
        switch (self.peek()) {
            '+' => self.index += 1,
            '-' => {
                sign = -1;
                self.index += 1;
            },
            else => {},
        }

        // POSIX caps the hours of an offset at 24, but the times attached
        // to a rule may run further, so callers that need the wider range
        // use `ruleTime`.
        const hours = try self.number(24);
        var seconds = hours * std.time.s_per_hour;
        if (!self.done() and self.peek() == ':') {
            self.index += 1;
            seconds += try self.number(59) * std.time.s_per_min;
            if (!self.done() and self.peek() == ':') {
                self.index += 1;
                seconds += try self.number(59);
            }
        }
        return sign * seconds;
    }

    test offset {
        // POSIX writes offsets west-positive, the opposite of the sign
        // this library uses everywhere else, and that is kept here: the
        // conversion happens in `parse`.
        var hours: Cursor = .{ .text = "6" };
        try std.testing.expectEqual(@as(i32, 6 * std.time.s_per_hour), try hours.offset());

        var negative: Cursor = .{ .text = "-5:30" };
        try std.testing.expectEqual(
            @as(i32, -(5 * std.time.s_per_hour + 30 * std.time.s_per_min)),
            try negative.offset(),
        );

        var seconds: Cursor = .{ .text = "5:30:45" };
        try std.testing.expectEqual(
            @as(i32, 5 * std.time.s_per_hour + 30 * std.time.s_per_min + 45),
            try seconds.offset(),
        );

        // An offset is capped at 24 hours; `ruleTime` is what goes wider.
        var too_big: Cursor = .{ .text = "25" };
        try std.testing.expectError(error.BadOffset, too_big.offset());
    }

    /// Reads the `/time` of a rule, which unlike a zone offset may run to
    /// 167 hours either side of midnight so that a rule can name a moment
    /// in a neighbouring week.
    fn ruleTime(self: *Cursor) ParseError!i32 {
        // `peek` requires the caller to have checked, and this is the
        // caller: a rule ending in its separator, `M3.2.0/`, left nothing
        // to read and this looked at it anyway.
        if (self.done()) return error.Truncated;

        var sign: i32 = 1;
        switch (self.peek()) {
            '+' => self.index += 1,
            '-' => {
                sign = -1;
                self.index += 1;
            },
            else => {},
        }

        var seconds = try self.number(167) * std.time.s_per_hour;
        if (!self.done() and self.peek() == ':') {
            self.index += 1;
            seconds += try self.number(59) * std.time.s_per_min;
            if (!self.done() and self.peek() == ':') {
                self.index += 1;
                seconds += try self.number(59);
            }
        }
        return sign * seconds;
    }

    test ruleTime {
        var cursor: Cursor = .{ .text = "2:00" };
        try std.testing.expectEqual(@as(i32, 2 * std.time.s_per_hour), try cursor.ruleTime());

        // The wider range is the point: a rule may name a moment in the
        // week either side, which an offset could not express.
        var far: Cursor = .{ .text = "167" };
        try std.testing.expectEqual(@as(i32, 167 * std.time.s_per_hour), try far.ruleTime());

        var negative: Cursor = .{ .text = "-2" };
        try std.testing.expectEqual(@as(i32, -2 * std.time.s_per_hour), try negative.ruleTime());

        var too_big: Cursor = .{ .text = "168" };
        try std.testing.expectError(error.BadOffset, too_big.ruleTime());

        // A rule that ends at its own separator has no time to read, and
        // used to read one byte past the end looking for it.
        var empty: Cursor = .{ .text = "" };
        try std.testing.expectError(error.Truncated, empty.ruleTime());
    }

    /// Reads a run of digits whose value must not exceed `max`.
    fn number(self: *Cursor, max: i32) ParseError!i32 {
        const start = self.index;
        while (!self.done() and std.ascii.isDigit(self.peek())) self.index += 1;
        if (self.index == start) return error.BadOffset;

        var value: i32 = 0;
        for (self.text[start..self.index]) |digit| {
            value = std.math.mul(i32, value, 10) catch return error.BadOffset;
            value = std.math.add(i32, value, digit - '0') catch return error.BadOffset;
            if (value > max) return error.BadOffset;
        }
        return value;
    }

    test number {
        var cursor: Cursor = .{ .text = "11" };
        try std.testing.expectEqual(@as(i32, 11), try cursor.number(12));

        // The cap is checked as the digits arrive, so a value that would
        // overflow on the way to it is caught rather than wrapping.
        var over: Cursor = .{ .text = "13" };
        try std.testing.expectError(error.BadOffset, over.number(12));

        var huge: Cursor = .{ .text = "99999999999" };
        try std.testing.expectError(error.BadOffset, huge.number(365));

        var empty: Cursor = .{ .text = "x" };
        try std.testing.expectError(error.BadOffset, empty.number(12));
    }

    /// Reads a `rule[/time]` pair.
    fn transition(self: *Cursor) ParseError!Transition {
        if (self.done()) return error.Truncated;

        const rule: Rule = switch (self.peek()) {
            'J' => rule: {
                self.index += 1;
                const day = try self.number(365);
                if (day < 1) return error.BadRule;
                break :rule .{ .julian_no_leap = @intCast(day) };
            },
            'M' => rule: {
                self.index += 1;
                const month = try self.number(12);
                if (month < 1) return error.BadRule;
                try self.expect('.');
                const week = try self.number(5);
                if (week < 1) return error.BadRule;
                try self.expect('.');
                const weekday = try self.number(6);
                break :rule .{ .month_week_day = .{
                    .month = std.enums.fromInt(Month, month) orelse return error.BadRule,
                    .week = @intCast(week),
                    .weekday = std.enums.fromInt(DayOfWeek, weekday) orelse return error.BadRule,
                } };
            },
            else => .{ .julian = @intCast(try self.number(365)) },
        };

        if (!self.done() and self.peek() == '/') {
            self.index += 1;
            return .{ .rule = rule, .time = try self.ruleTime() };
        }
        return .{ .rule = rule };
    }

    test transition {
        // `Mm.w.d`, the form nearly every real zone uses.
        var month_week_day: Cursor = .{ .text = "M3.2.0" };
        const us = try month_week_day.transition();
        try std.testing.expectEqual(Month.Mar, us.rule.month_week_day.month);
        try std.testing.expectEqual(@as(u8, 2), us.rule.month_week_day.week);
        try std.testing.expectEqual(DayOfWeek.Sun, us.rule.month_week_day.weekday);

        // The time defaults to 02:00 local when the rule does not give one.
        try std.testing.expectEqual(@as(i32, 2 * std.time.s_per_hour), us.time);

        var timed: Cursor = .{ .text = "M10.1.0/3:00" };
        try std.testing.expectEqual(@as(i32, 3 * std.time.s_per_hour), (try timed.transition()).time);

        var julian: Cursor = .{ .text = "J60" };
        try std.testing.expectEqual(@as(u16, 60), (try julian.transition()).rule.julian_no_leap);

        // A leading digit with no J is the zero-based form.
        var zero_based: Cursor = .{ .text = "59" };
        try std.testing.expectEqual(@as(u16, 59), (try zero_based.transition()).rule.julian);
    }
};

const testing = std.testing;

test parse {
    const rule = try parse("CST6CDT,M3.2.0,M11.1.0");
    try testing.expectEqualStrings("CST", rule.std_designation);

    // POSIX writes offsets west-positive; everything here is seconds east
    // of UTC, so the sign is flipped on the way in.
    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), rule.std_offset);

    // A daylight saving offset that is not written is one hour ahead of
    // standard time, which is what makes `CST6CDT` a complete rule.
    try testing.expectEqualStrings("CDT", rule.dst.?.designation);
    try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), rule.dst.?.offset);

    // A zone with no daylight saving time at all has no `dst` half. The
    // brackets are what let the name hold a sign and digits.
    const fixed = try parse("<-03>3");
    try testing.expectEqualStrings("-03", fixed.std_designation);
    try testing.expectEqual(@as(?Dst, null), fixed.dst);

    // Naming a daylight saving time without saying when it applies is
    // something POSIX allows but this cannot evaluate.
    try testing.expectError(error.MissingRules, parse("EST5EDT"));
}

test "parse a rule with no daylight saving time" {
    const rule = try parse("IST-5:30");
    try testing.expectEqualStrings("IST", rule.std_designation);
    // POSIX writes offsets west-positive, so "-5:30" is 5.5 hours east.
    try testing.expectEqual(@as(i32, 5 * 3600 + 1800), rule.std_offset);
    try testing.expectEqual(@as(?Dst, null), rule.dst);

    const local_type = rule.typeAt(1721044800);
    try testing.expectEqual(@as(i32, 19800), local_type.offset);
    try testing.expect(!local_type.is_dst);
    try testing.expectEqualStrings("IST", local_type.designation);
}

test "parse an angle bracket designation" {
    const rule = try parse("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0");
    try testing.expectEqualStrings("+1030", rule.std_designation);
    try testing.expectEqual(@as(i32, 10 * 3600 + 1800), rule.std_offset);
    try testing.expectEqualStrings("+11", rule.dst.?.designation);
    try testing.expectEqual(@as(i32, 11 * 3600), rule.dst.?.offset);

    // Lord Howe in January is on daylight time, being south of the equator.
    const local_type = rule.typeAt(1705320000);
    try testing.expectEqual(@as(i32, 39600), local_type.offset);
    try testing.expect(local_type.is_dst);
    try testing.expectEqualStrings("+11", local_type.designation);
}

test "the United States rule switches on the right instants" {
    const rule = try parse("CST6CDT,M3.2.0,M11.1.0");
    try testing.expectEqual(@as(i32, -6 * 3600), rule.std_offset);
    // An absent daylight offset means one hour ahead of standard time.
    try testing.expectEqual(@as(i32, -5 * 3600), rule.dst.?.offset);

    // Daylight time began at 2024-03-10 08:00 UTC, which is 02:00 local
    // standard time, and ended at 2024-11-03 07:00 UTC, which is 02:00
    // local daylight time. The two switch times are read against
    // different offsets, which is why they are not twelve hours apart.
    try testing.expect(!rule.typeAt(1710057599).is_dst);
    try testing.expect(rule.typeAt(1710057600).is_dst);
    try testing.expect(rule.typeAt(1730617199).is_dst);
    try testing.expect(!rule.typeAt(1730617200).is_dst);

    try testing.expectEqualStrings("CST", rule.typeAt(1705320000).designation);
    try testing.expectEqualStrings("CDT", rule.typeAt(1721044800).designation);
}

test "a southern hemisphere rule spans the new year" {
    const rule = try parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    try testing.expectEqual(@as(i32, 10 * 3600), rule.std_offset);
    try testing.expectEqual(@as(i32, 11 * 3600), rule.dst.?.offset);

    // Daylight time runs from October to April, so July is standard time
    // and January is not.
    try testing.expect(!rule.typeAt(1721044800).is_dst);
    try testing.expect(rule.typeAt(1705320000).is_dst);

    try testing.expect(!rule.typeAt(1728143999).is_dst);
    try testing.expect(rule.typeAt(1728144000).is_dst);
    try testing.expect(rule.typeAt(1712419199).is_dst);
    try testing.expect(!rule.typeAt(1712419200).is_dst);
}

test "a rule with a quarter hour switch time" {
    const rule = try parse("<+1245>-12:45<+1345>,M9.5.0/2:45,M4.1.0/3:45");
    try testing.expectEqual(@as(i32, 12 * 3600 + 45 * 60), rule.std_offset);
    // An absent daylight offset is still one hour ahead.
    try testing.expectEqual(@as(i32, 13 * 3600 + 45 * 60), rule.dst.?.offset);
    try testing.expectEqual(@as(i32, 2 * 3600 + 45 * 60), rule.dst.?.start.time);
    try testing.expectEqual(@as(i32, 3 * 3600 + 45 * 60), rule.dst.?.end.time);
}

test "week five means the last such weekday of the month" {
    const rule = try parse("IST-1GMT0,M10.5.0,M3.5.0/1");
    const start = rule.dst.?.start.rule;

    // October 2024 has Sundays on the 6th, 13th, 20th and 27th, so the
    // fifth Sunday is the last one rather than one in November.
    const october = start.dayOfMonth(2024);
    try testing.expectEqual(Month.Oct, october.month);
    try testing.expectEqual(@as(Day, 27), october.day);

    // 2021 had five Sundays in October, ending on the 31st.
    try testing.expectEqual(@as(Day, 31), start.dayOfMonth(2021).day);
}

test "julian day rules" {
    // J60 skips February 29, so it is March 1 in every year.
    const skipping: Rule = .{ .julian_no_leap = 60 };
    try testing.expectEqual(Month.Mar, skipping.dayOfMonth(2024).month);
    try testing.expectEqual(@as(Day, 1), skipping.dayOfMonth(2024).day);
    try testing.expectEqual(Month.Mar, skipping.dayOfMonth(2023).month);
    try testing.expectEqual(@as(Day, 1), skipping.dayOfMonth(2023).day);

    // The zero based form counts February 29, so day 59 is the 29th in a
    // leap year and March 1 otherwise.
    const counting: Rule = .{ .julian = 59 };
    try testing.expectEqual(Month.Feb, counting.dayOfMonth(2024).month);
    try testing.expectEqual(@as(Day, 29), counting.dayOfMonth(2024).day);
    try testing.expectEqual(Month.Mar, counting.dayOfMonth(2023).month);
    try testing.expectEqual(@as(Day, 1), counting.dayOfMonth(2023).day);

    // Day 0 is January 1 and J1 is also January 1.
    try testing.expectEqual(@as(Day, 1), (Rule{ .julian = 0 }).dayOfMonth(2024).day);
    try testing.expectEqual(@as(Day, 1), (Rule{ .julian_no_leap = 1 }).dayOfMonth(2024).day);
}

test "parse rejects malformed rules" {
    // A designation must be at least three characters.
    try testing.expectError(error.BadDesignation, parse("ES5"));
    try testing.expectError(error.BadDesignation, parse("<AB>5"));
    try testing.expectError(error.BadDesignation, parse("<ABC5"));
    // An offset is required.
    try testing.expectError(error.Truncated, parse("EST"));
    // Daylight saving time without switch dates would be a guess.
    try testing.expectError(error.MissingRules, parse("EST5EDT"));
    // Out of range pieces.
    try testing.expectError(error.BadOffset, parse("EST25"));
    try testing.expectError(error.BadOffset, parse("EST5EDT4,M13.1.0,M11.1.0"));
    try testing.expectError(error.BadRule, parse("EST5EDT4,M3.1.0"));
    try testing.expectError(error.BadRule, parse("EST5EDT4,M3.0.0,M11.1.0"));
    try testing.expectError(error.Truncated, parse(""));
}
