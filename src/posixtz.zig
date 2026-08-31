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

    /// Returns the day of the month this rule picks out in `year`.
    fn dayOfMonth(self: Rule, year: Year) struct { month: Month, day: Day } {
        switch (self) {
            .month_week_day => |spec| {
                const first: Date = .{ .year = year, .month = spec.month, .day = 1 };
                const first_weekday = @intFromEnum(first.dayOfWeek());
                const wanted = @intFromEnum(spec.weekday);

                // The first `wanted` weekday of the month, then forward by
                // whole weeks. Week 5 means "last", which is the same as
                // going too far and stepping back a week.
                var day: u16 = 1 + (7 + @as(u16, wanted) - first_weekday) % 7;
                day += (@as(u16, spec.week) - 1) * 7;
                const last = spec.month.lastDay(year);
                while (day > last) day -= 7;

                return .{ .month = spec.month, .day = @intCast(day) };
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

                var month: Month = .Jan;
                var remaining = day_of_year;
                while (remaining > month.lastDay(year)) {
                    remaining -= month.lastDay(year);
                    month = month.next();
                }
                return .{ .month = month, .day = @intCast(remaining) };
            },
        }
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
    fn timestamp(self: Transition, year: Year, offset_before: i32) i64 {
        const day = self.rule.dayOfMonth(year);
        const date: Date = .{ .year = year, .month = day.month, .day = day.day };
        const midnight = @as(i64, date.toDaysSinceStartOfEra()) * std.time.s_per_day;
        return midnight + self.time - offset_before;
    }

    test timestamp {
        // The second Sunday of March 2024 is the 10th, and the switch
        // defaults to 02:00 local time. The offset in effect just before
        // it is standard time, which is what turns that into UTC.
        const transition: Transition = .{
            .rule = .{ .month_week_day = .{ .month = .Mar, .week = 2, .weekday = .Sun } },
        };

        const at = transition.timestamp(2024, -6 * std.time.s_per_hour);
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
    /// total either way, and `typeAt`, which needs only its own year, can
    /// disagree with it out there.
    ///
    /// The bounds come from the switches either side of it, which may
    /// belong to the neighbouring years, so the switches for three years
    /// are computed and the pair bracketing `timestamp` is taken.
    pub fn spanAt(self: Posix, timestamp: i64) Span {
        const dst = self.dst orelse return .{
            .local_type = .{
                .offset = self.std_offset,
                .is_dst = false,
                .designation = self.std_designation,
            },
            .start = std.math.minInt(i64),
            .end = std.math.maxInt(i64),
        };

        // Which year's rules apply is decided in local standard time,
        // which is what POSIX means by the rules being "local".
        // Saturating, because a caller may hand in any `i64` and the
        // sum of an extreme one and an offset is not one.
        const local = timestamp +| self.std_offset;
        const year = Date.fromDaysSinceStartOfEra(Date.daysFromSecondsSaturating(local)).year;

        // Each switch is expressed in the time that is in effect just
        // before it happens: standard time going in, daylight time coming
        // back out.
        // Each switch is carried with what it opens, so that the walk
        // below knows which kind bounded the span without working the
        // question out a second time from the answer.
        const Switch = struct { at: i64, opens_dst: bool };

        var switches: [6]Switch = undefined;
        var count: usize = 0;
        // Saturating again: `year` may already be the first or last a
        // `Year` can hold, when the timestamp was outside the calendar.
        // A repeated year only puts a duplicate in the list below, which
        // the sort and the walk do not mind.
        for ([_]Year{ year -| 1, year, year +| 1 }) |each| {
            switches[count] = .{
                .at = dst.start.timestamp(each, self.std_offset),
                .opens_dst = true,
            };
            count += 1;
            switches[count] = .{
                .at = dst.end.timestamp(each, dst.offset),
                .opens_dst = false,
            };
            count += 1;
        }

        const order = struct {
            fn lessThan(_: void, a: Switch, b: Switch) bool {
                return a.at < b.at;
            }
        };
        std.mem.sort(Switch, switches[0..count], {}, order.lessThan);

        var start: i64 = std.math.minInt(i64);
        var end: i64 = std.math.maxInt(i64);
        var in_dst = false;
        for (switches[0..count]) |each| {
            if (each.at <= timestamp) {
                start = each.at;
                // Whether this span is the daylight one follows from
                // which switch opened it.
                in_dst = each.opens_dst;
            } else {
                end = each.at;
                break;
            }
        }

        return .{
            .local_type = if (in_dst) .{
                .offset = dst.offset,
                .is_dst = true,
                .designation = dst.designation,
            } else .{
                .offset = self.std_offset,
                .is_dst = false,
                .designation = self.std_designation,
            },
            .start = start,
            .end = end,
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

        // Midwinter is standard time, and its span is bounded by the switches
        // in the years either side, which is why three years are computed.
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
    /// This used to repeat `spanAt`'s search over one year rather than
    /// three, which was about a quarter quicker, and it was wrong for
    /// rules whose two switches do not sit tidily inside the year that
    /// names them. A switch time may be up to 167 hours either side of
    /// its day and so spill into a neighbouring year, and two switches
    /// landing in the same week can swap order from year to year. Fuzzing
    /// found both, which is two more than were found by reading it, so
    /// the shortcut is gone rather than patched: the cases it has to be
    /// right about are not ones anybody has managed to enumerate.
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
