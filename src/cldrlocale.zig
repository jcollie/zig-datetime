// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The locale data a CLDR date pattern is written against.
//!
//! This is to `cldr` what `locale` is to `formatsequence`: everything
//! about formatting that is not the pattern itself. It is a separate type
//! from `locale.Locale` because CLDR asks questions moment.js has no
//! notion of -- what an era is called, what a quarter is called, which of
//! two grammatical contexts a name is wanted in, how narrow a narrow name
//! is, which flexible day period an hour falls in, and what the locale's
//! own idea of a full or a short date is -- and a type that answered both
//! vocabularies would be answering half of each badly.
//!
//! `en` is built in and is what every entry point without a locale uses.
//! `-Dembed-cldr` adds the rest of CLDR's, generated from the Unicode
//! Consortium's own JSON distribution by `tools/gen_cldr.js`; see
//! `build.zig`. Transcribing a locale by hand would be a divergence built
//! in at the source, so nothing here is transcribed except `en`, which
//! the oracle checks alongside all the others.
//!
//! All of it is plain data. Unlike `locale.Locale`, which carries four
//! function pointers because moment holds the meridiem and the ordinal as
//! JavaScript rather than as tables, every question CLDR asks is answered
//! by a lookup or by a rule that is itself data, so a `Locale` here is a
//! struct a caller can also write out by hand.

const std = @import("std");

const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;
const generated = @import("cldrlocales");
const cldr_options = @import("cldr_options");

/// Which of CLDR's two grammatical contexts a name is asked for in.
///
/// The `format` names are the ones that go in a date beside other
/// fields -- "5 марта" -- and the `stand_alone` ones are how the name is
/// written on its own, as a calendar heading would write it: "март". The
/// pattern letter chooses between them, which is the whole difference
/// between `M` and `L`, between `E` and `c`, and between `Q` and `q`.
/// Most languages write the same thing either way.
pub const Context = enum(u1) { format, stand_alone };

/// How long a name is. CLDR gives three lengths for months, quarters,
/// eras and day periods, and the pattern letter's repeat count picks one.
pub const Width = enum(u2) { wide, abbreviated, narrow };

/// How long a weekday name is. Weekdays have a fourth, between the
/// abbreviated and the narrow one: English's `Tu`, which `EEEEEE` writes
/// and which is meant to be the shortest name that is still distinct.
pub const WeekdayWidth = enum(u2) { wide, abbreviated, short, narrow };

/// Which of the four lengths of a locale's own date or time pattern is
/// wanted. These are what `dateFormat`, `timeFormat` and `dateTimeFormat`
/// return, and are the reason CLDR is worth having: the caller says how
/// much detail it wants and the locale says how that is written.
pub const Length = enum(u2) { full, long, medium, short };

/// The twelve day periods CLDR names.
///
/// `am` and `pm` are the two every locale has. `midnight` and `noon` name
/// the two instants, where a locale has words for them. The numbered ones
/// are the flexible periods: a language may divide the day into as many
/// as two mornings, two afternoons, two evenings and two nights, and
/// which of them an hour falls in is given by `DayPeriodRule`.
pub const DayPeriod = enum(u4) {
    midnight,
    am,
    noon,
    pm,
    morning1,
    morning2,
    afternoon1,
    afternoon2,
    evening1,
    evening2,
    night1,
    night2,
};

/// When one flexible day period runs, in minutes from midnight.
///
/// CLDR writes two shapes of rule and this holds both. A period with an
/// `at` is an instant -- noon and midnight are the only two -- and
/// matches only when the time of day is exactly that minute with no
/// seconds and no fraction left over. Every other period is a half open
/// span, `from` up to but not including `before`, and a span whose
/// `before` is less than its `from` wraps around midnight, which is what
/// a language whose night begins at 21:00 and ends at 06:00 needs.
pub const DayPeriodRule = struct {
    period: DayPeriod,
    /// Minutes from midnight where the period begins, inclusive.
    from: u16,
    /// Minutes from midnight where it ends, exclusive. Midnight at the
    /// end of the day is 1440 rather than 0, which is how CLDR writes it.
    before: u16,
    /// Whether this names an instant rather than a span, in which case
    /// `from` is that instant and `before` is ignored.
    at: bool = false,
};

/// The month names of one context, wide first.
pub const MonthNames = [3][12][]const u8;
/// The weekday names of one context, Sunday first within each width.
pub const WeekdayNames = [4][7][]const u8;
/// The quarter names of one context, first quarter first.
pub const QuarterNames = [3][4][]const u8;
/// The day period names of one context, indexed by `DayPeriod`.
pub const DayPeriodNames = [3][12][]const u8;
/// The two era names of each width: before the common era, then in it.
pub const EraNames = [3][2][]const u8;
/// The four lengths of one of the locale's own patterns.
pub const Patterns = [4][]const u8;

/// One of the locale's opinions about a combination of fields: the
/// skeleton naming them, and the pattern that writes them.
///
/// This is CLDR's `availableFormats`, and it is what makes "the month and
/// the day" come out as "September 9" in English and "9. September" in
/// German. A skeleton says *which* fields are wanted and how wide; the
/// locale says what order they go in and what goes between them, and
/// nothing but its own data can supply that.
///
/// No locale here carries any: CLDR's set is large -- of the order of
/// forty entries apiece across seven hundred locales -- and a library
/// whose subject is the calendar should not make every consumer of it pay
/// for a table most of them will not ask for. So `available_formats` is
/// left empty on the generated locales and a caller that has the data
/// supplies its own `Locale`, or fills the field in on a copy of one of
/// these. `cldr.formatSkeleton` is the algorithm; the data is the
/// caller's.
pub const AvailableFormat = struct {
    /// The field letters in CLDR's canonical order, e.g. `"yMMMd"`.
    skeleton: []const u8,
    /// The pattern to write them with, e.g. `"d MMM y"`.
    pattern: []const u8,
};

/// The language a CLDR pattern is written in.
///
/// Every table has a `format` half that is always there and a
/// `stand_alone` half that is null when the language writes the same
/// names in both contexts, which is most of them. Reading through
/// `monthName` and its neighbours rather than indexing the tables is what
/// makes that fallback invisible to a caller.
pub const Locale = struct {
    /// The CLDR locale identifier, in CLDR's own spelling: "en", "fr",
    /// "pt-BR", "sr-Cyrl-BA". Case is CLDR's, and `byName` folds it.
    tag: []const u8,

    /// The month names as they are written beside a day number.
    months: *const MonthNames,
    /// The month names as they are written on their own, null when the
    /// language does not distinguish the two.
    months_stand_alone: ?*const MonthNames = null,

    /// The weekday names as they are written inside a date.
    weekdays: *const WeekdayNames,
    /// The weekday names as they are written on their own.
    weekdays_stand_alone: ?*const WeekdayNames = null,

    /// The quarter names as they are written inside a date.
    quarters: *const QuarterNames,
    /// The quarter names as they are written on their own.
    quarters_stand_alone: ?*const QuarterNames = null,

    /// The day period names as they are written inside a time.
    day_periods: *const DayPeriodNames,
    /// The day period names as they are written on their own.
    day_periods_stand_alone: ?*const DayPeriodNames = null,

    /// What the two eras are called, at each of the three widths.
    eras: *const EraNames,

    /// The locale's own date patterns, which `G` through `d` are written
    /// into: `dateFormat` returns one and `format` then runs it.
    date_formats: *const Patterns,
    /// The locale's own time patterns.
    time_formats: *const Patterns,
    /// How a date and a time are joined in general. `{1}` stands for the
    /// date and `{0}` for the time, which is CLDR's numbering and is the
    /// way round it is because the time is the first argument. The rest
    /// is a pattern, so text in it is quoted the way a pattern quotes it.
    date_time_formats: *const Patterns,
    /// How a date and a particular time of day are joined, which is not
    /// always the same thing: English joins a full date to a time with
    /// the word "at" and Afrikaans with "om", where the general form has
    /// only a comma. This is the one a formatted date and time uses; see
    /// `cldr.formatDateTime`.
    date_time_at_time_formats: *const Patterns,

    /// What the localized GMT format wraps an offset in, with `{0}`
    /// standing for the offset: "GMT{0}" in English, "UTC{0}" in French,
    /// "{0} گرینویچ" in Persian.
    gmt_format: []const u8 = "GMT{0}",
    /// What CLDR says the locale writes for a zero offset with nothing
    /// after it: "GMT", "UTC", "گرینویچ".
    ///
    /// Carried because it is CLDR's data and a caller building its own
    /// display may want it, and not written by any pattern field: UTS #35
    /// reads as though it belongs in the localized GMT format, and ICU
    /// writes the signed zero there instead. See `cldr.writeLocalizedGmt`.
    gmt_zero_format: []const u8 = "GMT",
    /// The pattern the offset itself is written to when it is east of
    /// UTC, as a miniature pattern of `H`, `HH`, `mm` and `ss` with the
    /// sign as a literal: "+HH:mm".
    hour_format_positive: []const u8 = "+HH:mm",
    /// The same for an offset west of UTC. Held separately rather than
    /// derived because the sign is not always a hyphen: French writes a
    /// real minus sign and Persian puts a bidirectional mark in front.
    hour_format_negative: []const u8 = "-HH:mm",

    /// The locale's own opinions about combinations of fields, keyed by
    /// skeleton; see `AvailableFormat` for why this is empty on every
    /// locale generated here and what to do about it.
    ///
    /// Order matters only in that an exact match is taken as soon as it is
    /// seen; otherwise `cldr.matchSkeleton` scores the whole table.
    available_formats: []const AvailableFormat = &.{},

    /// The day a week begins on here, which `e`, `c` and `w` count from.
    first_day: DayOfWeek = .Sun,
    /// How many days of the new year the first week of the year must
    /// hold, which with `first_day` is the whole of a week rule. One for
    /// the United States, four for the ISO 8601 rule most of Europe uses.
    min_days_in_first_week: u8 = 1,

    /// When each flexible day period runs, which `B` is written from.
    /// Empty for a language CLDR has no rules for, where `B` falls back
    /// to writing the meridiem.
    day_period_rules: []const DayPeriodRule = &.{},

    /// The ten digits of the locale's default numbering system, when that
    /// is not the Western one. Bengali writes a date in Bengali digits
    /// and Persian in Persian ones, and CLDR treats that as part of the
    /// locale rather than as something done to the output afterwards.
    /// Null means the ASCII digits.
    digits: ?*const [10][]const u8 = null,

    /// Returns the name of `month` at `width` in `context`.
    ///
    /// A locale with no stand-alone names of its own answers with its
    /// format ones, which is CLDR's own fallback and is why the tables
    /// are held as `null` rather than as a second copy.
    pub fn monthName(self: Locale, month: Month, context: Context, width: Width) []const u8 {
        const table = switch (context) {
            .format => self.months,
            .stand_alone => self.months_stand_alone orelse self.months,
        };
        return table[@intFromEnum(width)][@intFromEnum(month) - 1];
    }

    test monthName {
        try std.testing.expectEqualStrings("March", en.monthName(.Mar, .format, .wide));
        try std.testing.expectEqualStrings("Mar", en.monthName(.Mar, .format, .abbreviated));
        try std.testing.expectEqualStrings("M", en.monthName(.Mar, .format, .narrow));

        // English writes the same name in both contexts, so the
        // stand-alone table is absent and the format one answers.
        try std.testing.expectEqualStrings("March", en.monthName(.Mar, .stand_alone, .wide));
    }

    /// Returns the name of `weekday` at `width` in `context`.
    ///
    /// The `short` width is the one CLDR gives only to weekdays, and a
    /// locale that does not define it has it filled in from the
    /// abbreviated names by the generator, so there is no fallback to do
    /// here.
    pub fn weekdayName(self: Locale, weekday: DayOfWeek, context: Context, width: WeekdayWidth) []const u8 {
        const table = switch (context) {
            .format => self.weekdays,
            .stand_alone => self.weekdays_stand_alone orelse self.weekdays,
        };
        return table[@intFromEnum(width)][weekday.weekdayNumber()];
    }

    test weekdayName {
        try std.testing.expectEqualStrings("Tuesday", en.weekdayName(.Tue, .format, .wide));
        try std.testing.expectEqualStrings("Tue", en.weekdayName(.Tue, .format, .abbreviated));

        // The width weekdays have and nothing else does: the shortest
        // name that still tells Tuesday from Thursday, where the narrow
        // one does not.
        try std.testing.expectEqualStrings("Tu", en.weekdayName(.Tue, .format, .short));
        try std.testing.expectEqualStrings("T", en.weekdayName(.Tue, .format, .narrow));
    }

    /// Returns the name of `quarter`, which is 1 through 4, at `width` in
    /// `context`.
    pub fn quarterName(self: Locale, quarter: u3, context: Context, width: Width) []const u8 {
        std.debug.assert(quarter >= 1 and quarter <= 4);
        const table = switch (context) {
            .format => self.quarters,
            .stand_alone => self.quarters_stand_alone orelse self.quarters,
        };
        return table[@intFromEnum(width)][quarter - 1];
    }

    test quarterName {
        try std.testing.expectEqualStrings("1st quarter", en.quarterName(1, .format, .wide));
        try std.testing.expectEqualStrings("Q4", en.quarterName(4, .format, .abbreviated));
    }

    /// Returns what the era of `year` is called at `width`.
    ///
    /// `Year` is astronomical, so year 0 is 1 BC and everything at or
    /// below it is before the common era. That is the same boundary
    /// `cldr` writes the era year against, and the two have to agree or a
    /// date would be given the wrong era's name.
    pub fn eraName(self: Locale, year: Year, width: Width) []const u8 {
        return self.eras[@intFromEnum(width)][if (year > 0) 1 else 0];
    }

    test eraName {
        try std.testing.expectEqualStrings("AD", en.eraName(2024, .abbreviated));
        try std.testing.expectEqualStrings("Anno Domini", en.eraName(2024, .wide));

        // Year zero is 1 BC, so the boundary is at 1 rather than at 0.
        try std.testing.expectEqualStrings("BC", en.eraName(0, .abbreviated));
        try std.testing.expectEqualStrings("AD", en.eraName(1, .abbreviated));
    }

    /// Returns the name of `period` at `width` in `context`.
    pub fn dayPeriodName(self: Locale, period: DayPeriod, context: Context, width: Width) []const u8 {
        const table = switch (context) {
            .format => self.day_periods,
            .stand_alone => self.day_periods_stand_alone orelse self.day_periods,
        };
        return table[@intFromEnum(width)][@intFromEnum(period)];
    }

    test dayPeriodName {
        try std.testing.expectEqualStrings("AM", en.dayPeriodName(.am, .format, .abbreviated));
        try std.testing.expectEqualStrings("in the afternoon", en.dayPeriodName(.afternoon1, .format, .wide));

        // Standing on its own it loses the preposition, which is exactly
        // the difference the two contexts are for.
        try std.testing.expectEqualStrings("afternoon", en.dayPeriodName(.afternoon1, .stand_alone, .wide));
    }

    /// Returns which flexible day period `hour` falls in, or null when
    /// this locale has no rules and `B` has nothing to say.
    ///
    /// The hour and nothing finer, which is not a simplification: every
    /// boundary in every one of CLDR's eighty-nine rule sets is on the
    /// hour, so an hour is as much as the rules can distinguish. ICU
    /// resolves them the same way, and the consequence is visible --
    /// half past twelve is "noon" in English, because the instant rule at
    /// 12:00 claims the whole of the hour it names rather than the single
    /// minute.
    ///
    /// That priority is the reason the instant rules are tried first: noon
    /// sits inside the afternoon's span in every locale that has both, and
    /// the more specific answer is the one CLDR means. The spans are then
    /// tried in the order CLDR gives them, and a span whose end is at or
    /// before its start is the one that wraps midnight, which is checked
    /// as two pieces rather than one.
    ///
    /// Midnight is never the answer, although three quarters of CLDR's
    /// rule sets name an instant for it. CLDR deprecated the `midnight`
    /// day period, because a word for midnight does not say which end of
    /// a day it belongs to, and ICU does not select it; the span that
    /// contains it -- the morning, or the night that wrapped around into
    /// it -- is what comes out instead. The rule is still in
    /// `day_period_rules` for a caller that wants to see it.
    pub fn dayPeriodAt(self: Locale, hour: u5) ?DayPeriod {
        if (self.day_period_rules.len == 0) return null;

        const minutes: u16 = @as(u16, hour) * 60;

        for (self.day_period_rules) |rule| {
            if (rule.at and rule.period != .midnight and rule.from == minutes) return rule.period;
        }

        for (self.day_period_rules) |rule| {
            if (rule.at) continue;
            const matched = if (rule.from < rule.before)
                minutes >= rule.from and minutes < rule.before
            else
                minutes >= rule.from or minutes < rule.before;
            if (matched) return rule.period;
        }

        return null;
    }

    test dayPeriodAt {
        // The noon rule wins over the afternoon that contains it, and
        // claims the whole hour rather than the minute it names.
        try std.testing.expectEqual(DayPeriod.noon, en.dayPeriodAt(12).?);
        try std.testing.expectEqual(DayPeriod.afternoon1, en.dayPeriodAt(13).?);

        try std.testing.expectEqual(DayPeriod.evening1, en.dayPeriodAt(19).?);

        // Midnight is deprecated and never chosen, so the start of the
        // day is the morning that also begins there.
        try std.testing.expectEqual(DayPeriod.morning1, en.dayPeriodAt(0).?);

        // English's night wraps midnight: 21:00 up to 24:00 and then on
        // into the small hours, which is one rule and two comparisons.
        try std.testing.expectEqual(DayPeriod.night1, en.dayPeriodAt(23).?);

        // A language CLDR has no rules for has nothing to say, and `B`
        // falls back to the meridiem.
        var ruleless = en;
        ruleless.day_period_rules = &.{};
        try std.testing.expectEqual(@as(?DayPeriod, null), ruleless.dayPeriodAt(12));
    }

    /// Returns the locale's own date pattern of the given length.
    pub fn dateFormat(self: Locale, length: Length) []const u8 {
        return self.date_formats[@intFromEnum(length)];
    }

    /// Returns the locale's own time pattern of the given length.
    pub fn timeFormat(self: Locale, length: Length) []const u8 {
        return self.time_formats[@intFromEnum(length)];
    }

    /// Which hour the locale writes the time on: the twelve-hour clock, or
    /// the twenty-four hour one.
    ///
    /// Read off the locale's own short time pattern rather than from a
    /// table of its own, because that pattern is the answer: a locale that
    /// writes `h` there is a twelve-hour locale and no other source can
    /// disagree with it. `K` counts too, being the other twelve-hour
    /// field, and a quoted run is skipped so that a literal `h` in the
    /// text -- Danish writes `HH.mm`, but a language could quote a word
    /// with an h in it -- does not answer the question.
    ///
    /// This is what the skeleton letter `j` asks for; see
    /// `cldr.formatSkeleton`.
    pub fn prefersTwelveHour(self: Locale) bool {
        const pattern = self.time_formats[@intFromEnum(Length.short)];
        var index: usize = 0;
        while (index < pattern.len) : (index += 1) {
            if (pattern[index] == '\'') {
                index += 1;
                if (index < pattern.len and pattern[index] == '\'') continue;
                while (index < pattern.len and pattern[index] != '\'') index += 1;
                continue;
            }
            if (pattern[index] == 'h' or pattern[index] == 'K') return true;
        }
        return false;
    }

    test prefersTwelveHour {
        try std.testing.expect(en.prefersTwelveHour());
    }

    /// Returns the pattern that joins a date to a time in general, with
    /// `{1}` for the date and `{0}` for the time.
    pub fn dateTimeFormat(self: Locale, length: Length) []const u8 {
        return self.date_time_formats[@intFromEnum(length)];
    }

    /// Returns the pattern that joins a date to a particular time of day,
    /// which is what a formatted date and time is.
    ///
    /// The difference is a word: "Tuesday, March 5, 2024 at 2:30 PM"
    /// rather than "Tuesday, March 5, 2024, 2:30 PM". CLDR added these
    /// alongside the general ones, and they are what ICU joins a date
    /// style to a time style with, so they are what `cldr.formatDateTime`
    /// uses.
    pub fn dateTimeAtTimeFormat(self: Locale, length: Length) []const u8 {
        return self.date_time_at_time_formats[@intFromEnum(length)];
    }

    test dateFormat {
        try std.testing.expectEqualStrings("EEEE, MMMM d, y", en.dateFormat(.full));
        try std.testing.expectEqualStrings("M/d/yy", en.dateFormat(.short));
        try std.testing.expectEqualStrings("h:mm a", en.timeFormat(.short));
        try std.testing.expectEqualStrings("{1}, {0}", en.dateTimeFormat(.short));

        // The general glue is a comma at every length; the one used for a
        // time of day says "at" for the two longest.
        try std.testing.expectEqualStrings("{1} 'at' {0}", en.dateTimeAtTimeFormat(.full));
        try std.testing.expectEqualStrings("{1}, {0}", en.dateTimeAtTimeFormat(.short));
    }
};

const english_months: MonthNames = .{
    .{
        "January", "February", "March",     "April",   "May",      "June",
        "July",    "August",   "September", "October", "November", "December",
    },
    .{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    },
    .{
        "J", "F", "M", "A", "M", "J",
        "J", "A", "S", "O", "N", "D",
    },
};

const english_weekdays: WeekdayNames = .{
    .{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" },
    .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
    .{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" },
    .{ "S", "M", "T", "W", "T", "F", "S" },
};

const english_quarters: QuarterNames = .{
    .{ "1st quarter", "2nd quarter", "3rd quarter", "4th quarter" },
    .{ "Q1", "Q2", "Q3", "Q4" },
    .{ "1", "2", "3", "4" },
};

const english_eras: EraNames = .{
    .{ "Before Christ", "Anno Domini" },
    .{ "BC", "AD" },
    .{ "B", "A" },
};

// In the order `DayPeriod` numbers them, which is not the order CLDR
// writes them in: midnight, am, noon, pm, and then the flexible ones.
// English has one of each flexible period and none of the seconds, which
// are the empty strings.
const english_day_periods: DayPeriodNames = .{
    .{
        "midnight",       "AM", "noon",             "PM",
        "in the morning", "",   "in the afternoon", "",
        "in the evening", "",   "at night",         "",
    },
    .{
        "midnight",       "AM", "noon",             "PM",
        "in the morning", "",   "in the afternoon", "",
        "in the evening", "",   "at night",         "",
    },
    .{
        "mi",             "a", "n",                "p",
        "in the morning", "",  "in the afternoon", "",
        "in the evening", "",  "at night",         "",
    },
};

const english_day_periods_stand_alone: DayPeriodNames = .{
    .{
        "midnight", "AM", "noon",      "PM",
        "morning",  "",   "afternoon", "",
        "evening",  "",   "night",     "",
    },
    .{
        "midnight", "AM", "noon",      "PM",
        "morning",  "",   "afternoon", "",
        "evening",  "",   "night",     "",
    },
    .{
        "midnight", "AM", "noon",      "PM",
        "morning",  "",   "afternoon", "",
        "evening",  "",   "night",     "",
    },
};

const english_date_formats: Patterns = .{ "EEEE, MMMM d, y", "MMMM d, y", "MMM d, y", "M/d/yy" };
const english_time_formats: Patterns = .{ "h:mm:ss a zzzz", "h:mm:ss a z", "h:mm:ss a", "h:mm a" };
const english_date_time_formats: Patterns = .{ "{1}, {0}", "{1}, {0}", "{1}, {0}", "{1}, {0}" };
const english_date_time_at_time_formats: Patterns = .{ "{1} 'at' {0}", "{1} 'at' {0}", "{1}, {0}", "{1}, {0}" };

const english_day_period_rules = [_]DayPeriodRule{
    .{ .period = .midnight, .from = 0, .before = 0, .at = true },
    .{ .period = .noon, .from = 12 * 60, .before = 12 * 60, .at = true },
    .{ .period = .morning1, .from = 0, .before = 12 * 60 },
    .{ .period = .afternoon1, .from = 12 * 60, .before = 18 * 60 },
    .{ .period = .evening1, .from = 18 * 60, .before = 21 * 60 },
    .{ .period = .night1, .from = 21 * 60, .before = 24 * 60 },
};

/// English, which is built into the library whatever the build asked for
/// and is what every entry point without a locale uses.
///
/// Its week rule is the United States one -- weeks begin on Sunday and
/// the week holding January 1st is week 1 -- because CLDR's week data is
/// keyed by region rather than by language and `en` resolves to `en-US`.
pub const en: Locale = .{
    .tag = "en",
    .months = &english_months,
    .weekdays = &english_weekdays,
    .quarters = &english_quarters,
    .day_periods = &english_day_periods,
    .day_periods_stand_alone = &english_day_periods_stand_alone,
    .eras = &english_eras,
    .date_formats = &english_date_formats,
    .time_formats = &english_time_formats,
    .date_time_formats = &english_date_time_formats,
    .date_time_at_time_formats = &english_date_time_at_time_formats,
    .first_day = .Sun,
    .min_days_in_first_week = 1,
    .day_period_rules = &english_day_period_rules,
};

/// Reads one of the generated file's anonymous struct literals as a
/// `Locale`.
///
/// Field by field, because the generated file is a module of its own and
/// so cannot name `Locale`: what it writes is a struct with the same
/// fields and a different type, and Zig does not coerce one to the other.
/// Naming each field here is also what makes a generated file that has
/// drifted a compile error rather than a surprise.
///
/// `raw` is comptime because the tables live inside it and the `Locale`
/// points at them: taking the address of a field of a comptime value is
/// what puts the tables in the binary once each.
fn fromEntry(comptime raw: anytype) Locale {
    const tables = struct {
        const months: MonthNames = raw.months;
        const months_stand_alone: ?MonthNames = raw.months_stand_alone;
        const weekdays: WeekdayNames = raw.weekdays;
        const weekdays_stand_alone: ?WeekdayNames = raw.weekdays_stand_alone;
        const quarters: QuarterNames = raw.quarters;
        const quarters_stand_alone: ?QuarterNames = raw.quarters_stand_alone;
        const day_periods: DayPeriodNames = raw.day_periods;
        const day_periods_stand_alone: ?DayPeriodNames = raw.day_periods_stand_alone;
        const eras: EraNames = raw.eras;
        const date_formats: Patterns = raw.date_formats;
        const time_formats: Patterns = raw.time_formats;
        const date_time_formats: Patterns = raw.date_time_formats;
        const date_time_at_time_formats: Patterns = raw.date_time_at_time_formats;
        const digits: ?[10][]const u8 = raw.digits;

        // The rules arrive as four numbers apiece rather than as a struct
        // -- the day period, the minute it starts, the minute it ends,
        // and whether it is an instant -- because the generated file
        // cannot name `DayPeriodRule` and an anonymous struct with those
        // fields is a different type that will not coerce to it. Four
        // numbers in a fixed order is a shape both sides can name.
        const rules = blk: {
            var out: [raw.day_period_rules.len]DayPeriodRule = undefined;
            for (&out, raw.day_period_rules) |*slot, rule| {
                slot.* = .{
                    .period = @enumFromInt(rule[0]),
                    .from = rule[1],
                    .before = rule[2],
                    .at = rule[3] != 0,
                };
            }
            const final = out;
            break :blk final;
        };
    };

    return .{
        .tag = raw.tag,
        .months = &tables.months,
        .months_stand_alone = if (tables.months_stand_alone) |*names| names else null,
        .weekdays = &tables.weekdays,
        .weekdays_stand_alone = if (tables.weekdays_stand_alone) |*names| names else null,
        .quarters = &tables.quarters,
        .quarters_stand_alone = if (tables.quarters_stand_alone) |*names| names else null,
        .day_periods = &tables.day_periods,
        .day_periods_stand_alone = if (tables.day_periods_stand_alone) |*names| names else null,
        .eras = &tables.eras,
        .date_formats = &tables.date_formats,
        .time_formats = &tables.time_formats,
        .date_time_formats = &tables.date_time_formats,
        .date_time_at_time_formats = &tables.date_time_at_time_formats,
        .gmt_format = raw.gmt_format,
        .gmt_zero_format = raw.gmt_zero_format,
        .hour_format_positive = raw.hour_format_positive,
        .hour_format_negative = raw.hour_format_negative,
        .first_day = @enumFromInt(raw.first_day),
        .min_days_in_first_week = raw.min_days_in_first_week,
        .day_period_rules = &tables.rules,
        .digits = if (tables.digits) |*ten| ten else null,
    };
}

/// Whether `tag` is one the build asked to keep.
///
/// `-Dcldr-locales` is a comma separated list, and empty means all of them,
/// which is the default. Case is folded, because CLDR identifiers are case
/// insensitive by definition and somebody writing `pt-br` on a command line
/// means `pt-BR`.
fn wanted(comptime tag: []const u8) bool {
    const requested = cldr_options.locales;
    if (requested.len == 0) return true;

    var rest: []const u8 = requested;
    while (rest.len > 0) {
        const comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        if (std.ascii.eqlIgnoreCase(rest[0..comma], tag)) return true;
        rest = if (comma == rest.len) rest[comma..] else rest[comma + 1 ..];
    }
    return false;
}

/// The generated locales, sorted by tag. Empty unless the build asked for
/// them with `-Dembed-cldr`, and narrowed to what `-Dcldr-locales` named.
///
/// The table this is built from holds every locale CLDR ships, because it
/// is generated once and committed rather than cut to size by each build.
/// Narrowing here costs a binary nothing it would have saved by narrowing
/// there: an entry no `Locale` is built from is comptime data nothing
/// refers to, and none of its strings reach the output.
pub const all: []const Locale = built: {
    // Every locale builds its own tables, and there can be seven hundred
    // and sixty-six of them.
    @setEvalBranchQuota(10_000_000);

    var count: usize = 0;
    for (generated.entries) |entry| {
        if (wanted(entry.tag)) count += 1;
    }

    var out: [count]Locale = undefined;
    var next: usize = 0;
    for (generated.entries) |entry| {
        if (!wanted(entry.tag)) continue;
        out[next] = fromEntry(entry);
        next += 1;
    }
    const final = out;
    break :built &final;
};

/// Whether this build carries the generated locales. `en` is here either
/// way.
pub const embedded = all.len > 0;

/// The CLDR release the generated locales came from, empty when there are
/// none.
pub const cldr_version = generated.cldr_version;

/// Returns the locale `tag` names, or null when this build does not carry
/// it.
///
/// CLDR identifiers are case insensitive by definition -- `pt-BR` and
/// `pt-br` are the same locale -- so the comparison folds ASCII case
/// rather than requiring the caller to know CLDR's own spelling.
///
/// A tag CLDR does not ship is retried with its last subtag dropped,
/// again until there is nothing left: `en-US` answers with `en`, and
/// `zh-Hans-CN` with `zh-Hans` or failing that `zh`. That matters more
/// than it looks, because CLDR ships no directory for a locale whose
/// content is identical to its parent's -- Brazilian Portuguese is the
/// default content of `pt`, so there is no `pt-BR` to find and only the
/// truncation gets a caller holding an `Accept-Language` header to the
/// right data.
///
/// It is truncation and not CLDR's own parent chain, which has
/// exceptions: the parent of `en-AU` is `en-001` rather than `en`. Those
/// only matter for a tag CLDR does not ship at all, since one it does
/// ship is found exactly, and answering with the language is nearer than
/// answering with nothing.
///
/// Naming a locale like this is what pulls every one of them into the
/// binary; a program that knows which it wants should name it directly.
pub fn byName(tag: []const u8) ?Locale {
    var candidate = tag;
    while (true) {
        if (exactly(candidate)) |found| return found;

        // Drop the last subtag and try again, stopping when there is no
        // separator left rather than when the string is empty, so that a
        // tag of nothing is not looked up.
        var cut = candidate.len;
        while (cut > 0 and candidate[cut - 1] != '-' and candidate[cut - 1] != '_') cut -= 1;
        if (cut == 0) return null;
        candidate = candidate[0 .. cut - 1];
    }
}

/// Returns the locale spelled exactly `tag`, folding case and nothing
/// else.
fn exactly(tag: []const u8) ?Locale {
    if (std.ascii.eqlIgnoreCase(tag, en.tag)) return en;

    // With no generated locales the list is comptime empty, and the
    // search below will not compile against it: indexing a slice whose
    // length is known to be zero is an error however unreachable the
    // index is.
    if (comptime !embedded) return null;

    var low: usize = 0;
    var high: usize = all.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (orderIgnoreCase(all[mid].tag, tag)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return all[mid],
        }
    }
    return null;
}

/// Orders two tags the way the generated table is sorted, which is by
/// ASCII code point with case folded away.
///
/// The table is sorted by the generator using the same rule, so this and
/// `tools/gen_cldr.js` have to agree or the search would step past an
/// entry that is there.
fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    const shortest = @min(a.len, b.len);
    for (a[0..shortest], b[0..shortest]) |left, right| {
        const lower_left = std.ascii.toLower(left);
        const lower_right = std.ascii.toLower(right);
        if (lower_left != lower_right) return if (lower_left < lower_right) .lt else .gt;
    }
    return std.math.order(a.len, b.len);
}

test orderIgnoreCase {
    try std.testing.expectEqual(std.math.Order.eq, orderIgnoreCase("pt-BR", "pt-br"));
    try std.testing.expectEqual(std.math.Order.lt, orderIgnoreCase("en", "fr"));
    try std.testing.expectEqual(std.math.Order.lt, orderIgnoreCase("pt", "pt-BR"));
    try std.testing.expectEqual(std.math.Order.gt, orderIgnoreCase("fr", "en"));
}

test byName {
    // English is always here, whatever the build asked for, and its
    // spelling does not have to be guessed.
    try std.testing.expectEqualStrings("en", byName("en").?.tag);
    try std.testing.expectEqualStrings("en", byName("EN").?.tag);
    try std.testing.expectEqual(@as(?Locale, null), byName("nonesuch"));

    // A tag with subtags CLDR does not ship falls back to the language,
    // which is what an `Accept-Language` header needs.
    try std.testing.expectEqualStrings("en", byName("en-US").?.tag);
    try std.testing.expectEqualStrings("en", byName("en-Latn-GB").?.tag);

    // Only when the table is the whole of CLDR. `-Dcldr-locales` narrows it
    // to what was named, and a build that asked for three of them has no
    // `fr-CA` to find -- which is the option working rather than failing.
    if (embedded and cldr_options.locales.len == 0) {
        try std.testing.expectEqualStrings("fr", byName("fr").?.tag);
        try std.testing.expectEqualStrings("fr-CA", byName("fr-ca").?.tag);

        // CLDR ships no `pt-BR`, because Brazilian Portuguese is the
        // default content of `pt` and a directory holding the same data
        // twice would be a directory to keep in step.
        try std.testing.expectEqualStrings("pt", byName("pt-BR").?.tag);
    }
}

test "every embedded locale answers to its own tag" {
    for (all) |each| {
        const found = byName(each.tag) orelse {
            std.debug.print("byName could not find {s}\n", .{each.tag});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(each.tag, found.tag);
    }
}

test "every embedded locale is fully populated" {
    for (all) |each| {
        // A name that came out empty means the generator read a key CLDR
        // does not have under that spelling, which is silent otherwise:
        // the date would simply be missing a word.
        for ([_]Context{ .format, .stand_alone }) |context| {
            for ([_]Width{ .wide, .abbreviated, .narrow }) |width| {
                var months = Month.iterator();
                while (months.next()) |month| {
                    try std.testing.expect(each.monthName(month, context, width).len > 0);
                }
                for (1..5) |quarter| {
                    try std.testing.expect(each.quarterName(@intCast(quarter), context, width).len > 0);
                }
                // Only the two halves of the day, because the flexible
                // periods are empty for a language that does not name
                // them and that is not a gap.
                try std.testing.expect(each.dayPeriodName(.am, context, width).len > 0);
                try std.testing.expect(each.dayPeriodName(.pm, context, width).len > 0);
            }
            for ([_]WeekdayWidth{ .wide, .abbreviated, .short, .narrow }) |width| {
                for (0..7) |day| {
                    const weekday: DayOfWeek = @enumFromInt(day);
                    try std.testing.expect(each.weekdayName(weekday, context, width).len > 0);
                }
            }
        }

        for ([_]Width{ .wide, .abbreviated, .narrow }) |width| {
            try std.testing.expect(each.eraName(2024, width).len > 0);
            try std.testing.expect(each.eraName(0, width).len > 0);
        }

        for ([_]Length{ .full, .long, .medium, .short }) |length| {
            try std.testing.expect(each.dateFormat(length).len > 0);
            try std.testing.expect(each.timeFormat(length).len > 0);
            try std.testing.expect(each.dateTimeFormat(length).len > 0);
            try std.testing.expect(each.dateTimeAtTimeFormat(length).len > 0);
        }

        try std.testing.expect(each.gmt_format.len > 0);
        try std.testing.expect(each.hour_format_positive.len > 0);
        try std.testing.expect(each.hour_format_negative.len > 0);
        try std.testing.expect(each.min_days_in_first_week >= 1 and each.min_days_in_first_week <= 7);

        if (each.digits) |ten| for (ten) |digit| {
            try std.testing.expect(digit.len > 0);
        };
    }
}
