// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Turning a skeleton into a pattern: ICU's `DateTimePatternGenerator`,
//! ported from ICU 79.1's `getBestPattern`.
//!
//! A skeleton names the fields wanted and how wide, `yMMMd` or `Hmm`, and
//! says nothing about their order or what goes between them. A locale's
//! answer is a pattern, `MMM d, y` in English and `d. MMM y` in German,
//! and the work is choosing which of the locale's patterns to start from
//! and how to bend it toward what was asked for. ICU is the reference
//! implementation of that and is what every browser's
//! `Intl.DateTimeFormat` calls, so this follows it step by step rather
//! than doing something that merely looks similar: two implementations
//! that agree on most skeletons and disagree on the rest are worse than
//! one, because nobody can say in advance which ones are the rest.
//!
//! The steps, in ICU's order:
//!
//!   1. The metacharacters `j`, `J` and `C` become a concrete hour,
//!      `h` or `H` by the locale's clock, with a day period beside `h`.
//!   2. The skeleton is read into one slot per *kind* of field -- era,
//!      year, month, weekday, hour and so on, sixteen of them -- each
//!      holding the letter and its count and a type number that encodes
//!      whether it is a number or a name and how long. Two requests that
//!      differ only in a way that does not matter, `E` and `EEE`, get the
//!      same type.
//!   3. Every pattern the locale has is read the same way, and the one
//!      whose types are nearest is taken. Nearest is a sum over the
//!      slots: a field the request has and the pattern lacks costs 0x1000,
//!      one the pattern has and the request lacks costs 0x10000, and a
//!      field both have costs the difference of their types, which is
//!      small for one digit against two and large for a number against a
//!      name.
//!   4. The chosen pattern's fields are rewritten toward the request,
//!      under rules about when the locale's own width wins; see `adjust`.
//!   5. If no single pattern had every field, the date fields and the time
//!      fields are matched separately and the two halves joined with the
//!      locale's pattern for a date at a time.
//!
//! What the locale's patterns *are* is the part that is easy to get
//! wrong. ICU's table is not only CLDR's `availableFormats`: before those
//! it holds sixteen single-field patterns, one per kind of field, and the
//! locale's own four time and four date formats with skeletons read off
//! them, and an `availableFormats` entry replaces one of those only when
//! their types agree exactly. So British English holds both `Hm` →
//! `HH:mm` from `availableFormats` and `HHmm` → `HH:mm` from its short
//! time, and which of them a request for `Hmm` lands on decides whether
//! asking for the hour's own width gives `H:mm` or `HH:mm`. It gives
//! `H:mm`, in ICU and so here.

const std = @import("std");

const cldrlocale = @import("cldrlocale.zig");
const Locale = cldrlocale.Locale;
const Length = cldrlocale.Length;

/// The most letters a skeleton may hold.
///
/// CLDR's own longest is nine (`GyMMMEEEEd`), and a skeleton is written by
/// a program rather than a person, so this is generous rather than tight.
pub const max_skeleton = 32;

/// The most bytes a pattern made from a skeleton may hold, which is the
/// size of the buffer `cldr.formatSkeleton` keeps on the stack for one.
///
/// A date, the locale's glue and a time, in a script that takes three
/// bytes a letter, come to a little over a hundred; this leaves room for
/// a locale that quotes a good deal of text.
pub const max_pattern = 512;

/// What can be wrong with a skeleton.
pub const SkeletonError = error{
    /// More than `max_skeleton` letters.
    SkeletonTooLong,
    /// A byte that is not a pattern letter. A skeleton names fields and
    /// nothing else: it has no punctuation, no spaces and no literals.
    NotAField,
    /// The locale carries no `available_formats`, so there is nothing to
    /// match against. Every locale generated here is in that position on
    /// purpose; see `cldrlocale.AvailableFormat`.
    NoSkeletonData,
    /// The pattern made from the skeleton would not fit in the buffer it
    /// is being written into.
    PatternTooLong,
};

/// Which numeric fields take the width the request asked for rather than
/// the one the locale's pattern wrote.
///
/// These are ICU's `UDATPG_MATCH_HOUR_FIELD_LENGTH` and its neighbors, and
/// they are off by default for the same reason ICU's are: the locale's
/// choice of `HH` or `H` is a statement about how times are written there,
/// and a skeleton asking for `H` is usually saying "the hour" rather than
/// "one digit". Turning one on says the width was meant.
///
/// ECMA-402 means it for the hour: `Intl.DateTimeFormat` with `hour:
/// "numeric"` writes "8:05" on a twenty-four hour clock, because V8 and
/// SpiderMonkey ask ICU with `match_hour_field_length` set. An
/// implementation of `Intl` wants it on, and only the hour.
pub const SkeletonOptions = struct {
    /// Take the request's width for `h`, `H`, `k` and `K`.
    match_hour_field_length: bool = false,
    /// Take the request's width for `m`.
    match_minute_field_length: bool = false,
    /// Take the request's width for `s`.
    match_second_field_length: bool = false,
};

// ----- The table of field letters -----

/// The sixteen kinds of field a skeleton is read into, in ICU's order,
/// which is also the order of `UDateTimePatternField`. The order matters
/// twice: the first eleven are the date half when a request is split in
/// two, and a pattern's place in ICU's table depends on its first field.
const Kind = enum(u4) {
    era,
    year,
    quarter,
    month,
    week_of_year,
    week_of_month,
    weekday,
    day_of_year,
    day_of_week_in_month,
    day,
    day_period,
    hour,
    minute,
    second,
    fractional_second,
    zone,
};

const kind_count = @typeInfo(Kind).@"enum".field_names.len;

/// A set of kinds, one bit each.
const Mask = u16;

fn bit(kind: Kind) Mask {
    return @as(Mask, 1) << @backingInt(kind);
}

/// The date half: everything before the day period.
const date_mask: Mask = bit(.day_period) - 1;
/// The time half: the day period and everything after it.
const time_mask: Mask = ~date_mask;
const fraction_mask: Mask = bit(.fractional_second);
const second_and_fraction_mask: Mask = bit(.second) | bit(.fractional_second);

// The type numbers, ICU's `DT_*`. A number is positive and has its count
// added to it, so one digit and two differ by one; a name is negative and
// its length is in which of these it is. `delta` separates the letters
// that are the same kind of field said differently -- `M` and `L`, `h`
// and `H` -- by more than a length does and less than a number does from
// a name.
const numeric = 0x100;
const delta = 0x10;
const narrow = -0x101;
const shorter = -0x102;
const short = -0x103;
const long = -0x104;

/// What a request costs for a field the pattern lacks, and for a field
/// the pattern has that the request did not ask for. An extra field is
/// worse, because writing something nobody asked for is a wrong answer,
/// while leaving something out can be made good by appending it.
const missing_field = 0x1000;
const extra_field = 0x10000;

/// One row of ICU's `dtTypes`: a letter, what kind of field it is, its
/// type number, and the shortest count at which this row applies. A
/// letter with several rows takes the last one whose `min` it reaches.
const Row = struct {
    letter: u8,
    kind: Kind,
    type: i32,
    min: u8,
};

const rows = [_]Row{
    .{ .letter = 'G', .kind = .era, .type = short, .min = 1 },
    .{ .letter = 'G', .kind = .era, .type = long, .min = 4 },
    .{ .letter = 'G', .kind = .era, .type = narrow, .min = 5 },

    .{ .letter = 'y', .kind = .year, .type = numeric, .min = 1 },
    .{ .letter = 'Y', .kind = .year, .type = numeric + delta, .min = 1 },
    .{ .letter = 'u', .kind = .year, .type = numeric + 2 * delta, .min = 1 },
    .{ .letter = 'r', .kind = .year, .type = numeric + 3 * delta, .min = 1 },
    .{ .letter = 'U', .kind = .year, .type = short, .min = 1 },
    .{ .letter = 'U', .kind = .year, .type = long, .min = 4 },
    .{ .letter = 'U', .kind = .year, .type = narrow, .min = 5 },

    .{ .letter = 'Q', .kind = .quarter, .type = numeric, .min = 1 },
    .{ .letter = 'Q', .kind = .quarter, .type = short, .min = 3 },
    .{ .letter = 'Q', .kind = .quarter, .type = long, .min = 4 },
    .{ .letter = 'Q', .kind = .quarter, .type = narrow, .min = 5 },
    .{ .letter = 'q', .kind = .quarter, .type = numeric + delta, .min = 1 },
    .{ .letter = 'q', .kind = .quarter, .type = short - delta, .min = 3 },
    .{ .letter = 'q', .kind = .quarter, .type = long - delta, .min = 4 },
    .{ .letter = 'q', .kind = .quarter, .type = narrow - delta, .min = 5 },

    .{ .letter = 'M', .kind = .month, .type = numeric, .min = 1 },
    .{ .letter = 'M', .kind = .month, .type = short, .min = 3 },
    .{ .letter = 'M', .kind = .month, .type = long, .min = 4 },
    .{ .letter = 'M', .kind = .month, .type = narrow, .min = 5 },
    .{ .letter = 'L', .kind = .month, .type = numeric + delta, .min = 1 },
    .{ .letter = 'L', .kind = .month, .type = short - delta, .min = 3 },
    .{ .letter = 'L', .kind = .month, .type = long - delta, .min = 4 },
    .{ .letter = 'L', .kind = .month, .type = narrow - delta, .min = 5 },
    .{ .letter = 'l', .kind = .month, .type = numeric + delta, .min = 1 },

    .{ .letter = 'w', .kind = .week_of_year, .type = numeric, .min = 1 },

    .{ .letter = 'W', .kind = .week_of_month, .type = numeric, .min = 1 },

    .{ .letter = 'E', .kind = .weekday, .type = short, .min = 1 },
    .{ .letter = 'E', .kind = .weekday, .type = long, .min = 4 },
    .{ .letter = 'E', .kind = .weekday, .type = narrow, .min = 5 },
    .{ .letter = 'E', .kind = .weekday, .type = shorter, .min = 6 },
    .{ .letter = 'c', .kind = .weekday, .type = numeric + 2 * delta, .min = 1 },
    .{ .letter = 'c', .kind = .weekday, .type = short - 2 * delta, .min = 3 },
    .{ .letter = 'c', .kind = .weekday, .type = long - 2 * delta, .min = 4 },
    .{ .letter = 'c', .kind = .weekday, .type = narrow - 2 * delta, .min = 5 },
    .{ .letter = 'c', .kind = .weekday, .type = shorter - 2 * delta, .min = 6 },
    .{ .letter = 'e', .kind = .weekday, .type = numeric + delta, .min = 1 },
    .{ .letter = 'e', .kind = .weekday, .type = short - delta, .min = 3 },
    .{ .letter = 'e', .kind = .weekday, .type = long - delta, .min = 4 },
    .{ .letter = 'e', .kind = .weekday, .type = narrow - delta, .min = 5 },
    .{ .letter = 'e', .kind = .weekday, .type = shorter - delta, .min = 6 },

    .{ .letter = 'd', .kind = .day, .type = numeric, .min = 1 },
    .{ .letter = 'd', .kind = .day, .type = short, .min = 3 },
    .{ .letter = 'g', .kind = .day, .type = numeric + delta, .min = 1 },

    .{ .letter = 'D', .kind = .day_of_year, .type = numeric, .min = 1 },

    .{ .letter = 'F', .kind = .day_of_week_in_month, .type = numeric, .min = 1 },

    .{ .letter = 'a', .kind = .day_period, .type = short, .min = 1 },
    .{ .letter = 'a', .kind = .day_period, .type = long, .min = 4 },
    .{ .letter = 'a', .kind = .day_period, .type = narrow, .min = 5 },
    .{ .letter = 'b', .kind = .day_period, .type = short - delta, .min = 1 },
    .{ .letter = 'b', .kind = .day_period, .type = long - delta, .min = 4 },
    .{ .letter = 'b', .kind = .day_period, .type = narrow - delta, .min = 5 },
    .{ .letter = 'B', .kind = .day_period, .type = short - 3 * delta, .min = 1 },
    .{ .letter = 'B', .kind = .day_period, .type = long - 3 * delta, .min = 4 },
    .{ .letter = 'B', .kind = .day_period, .type = narrow - 3 * delta, .min = 5 },

    .{ .letter = 'H', .kind = .hour, .type = numeric + 10 * delta, .min = 1 },
    .{ .letter = 'k', .kind = .hour, .type = numeric + 11 * delta, .min = 1 },
    .{ .letter = 'h', .kind = .hour, .type = numeric, .min = 1 },
    .{ .letter = 'K', .kind = .hour, .type = numeric + delta, .min = 1 },
    .{ .letter = 'J', .kind = .hour, .type = numeric + 5 * delta, .min = 1 },
    .{ .letter = 'j', .kind = .hour, .type = numeric + 6 * delta, .min = 1 },
    .{ .letter = 'C', .kind = .hour, .type = numeric + 7 * delta, .min = 1 },

    .{ .letter = 'm', .kind = .minute, .type = numeric, .min = 1 },

    .{ .letter = 's', .kind = .second, .type = numeric, .min = 1 },
    .{ .letter = 'A', .kind = .second, .type = numeric + delta, .min = 1 },

    .{ .letter = 'S', .kind = .fractional_second, .type = numeric, .min = 1 },

    .{ .letter = 'v', .kind = .zone, .type = short - 2 * delta, .min = 1 },
    .{ .letter = 'v', .kind = .zone, .type = long - 2 * delta, .min = 4 },
    .{ .letter = 'z', .kind = .zone, .type = short, .min = 1 },
    .{ .letter = 'z', .kind = .zone, .type = long, .min = 4 },
    .{ .letter = 'Z', .kind = .zone, .type = narrow - delta, .min = 1 },
    .{ .letter = 'Z', .kind = .zone, .type = long - delta, .min = 4 },
    .{ .letter = 'Z', .kind = .zone, .type = short - delta, .min = 5 },
    .{ .letter = 'O', .kind = .zone, .type = short - delta, .min = 1 },
    .{ .letter = 'O', .kind = .zone, .type = long - delta, .min = 4 },
    .{ .letter = 'V', .kind = .zone, .type = short - delta, .min = 1 },
    .{ .letter = 'V', .kind = .zone, .type = long - delta, .min = 2 },
    .{ .letter = 'V', .kind = .zone, .type = long - 1 - delta, .min = 3 },
    .{ .letter = 'V', .kind = .zone, .type = long - 2 - delta, .min = 4 },
    .{ .letter = 'X', .kind = .zone, .type = narrow - delta, .min = 1 },
    .{ .letter = 'X', .kind = .zone, .type = short - delta, .min = 2 },
    .{ .letter = 'X', .kind = .zone, .type = long - delta, .min = 4 },
    .{ .letter = 'x', .kind = .zone, .type = narrow - delta, .min = 1 },
    .{ .letter = 'x', .kind = .zone, .type = short - delta, .min = 2 },
    .{ .letter = 'x', .kind = .zone, .type = long - delta, .min = 4 },
};

/// The row a run of `count` copies of `letter` reads as, or null for a
/// letter that is not a field.
///
/// The last of the letter's rows whose `min` the count reaches, which is
/// how `EEEE` is the long weekday while `E`, `EE` and `EEE` are all the
/// short one. This is ICU's `getCanonicalIndex`.
fn rowFor(letter: u8, count: usize) ?*const Row {
    var index: usize = 0;
    while (index < rows.len) : (index += 1) {
        if (rows[index].letter != letter) continue;
        while (index + 1 < rows.len and rows[index + 1].letter == letter and rows[index + 1].min <= count) {
            index += 1;
        }
        return &rows[index];
    }
    return null;
}

test rowFor {
    try std.testing.expectEqual(short, rowFor('E', 3).?.type);
    try std.testing.expectEqual(long, rowFor('E', 4).?.type);
    try std.testing.expectEqual(Kind.hour, rowFor('k', 2).?.kind);
    try std.testing.expectEqual(null, rowFor('P', 1));
}

/// The first row for a kind, which is what a field ICU adds on its own
/// behalf is made of: an `s` when a fraction was asked for without
/// seconds, an `a` beside a twelve-hour hour.
fn firstRow(kind: Kind) *const Row {
    for (&rows) |*row| if (row.kind == kind) return row;
    unreachable;
}

// ----- Reading patterns and skeletons -----

/// A piece of a pattern: a run of one letter, or literal text exactly as
/// it was written -- quotes and all, so that a pattern rewritten field by
/// field copies its text through untouched.
const Token = union(enum) {
    literal: []const u8,
    field: struct { letter: u8, count: usize, text: []const u8 },
};

const Tokens = struct {
    pattern: []const u8,
    index: usize = 0,

    fn next(self: *Tokens) ?Token {
        const pattern = self.pattern;
        if (self.index >= pattern.len) return null;
        const start = self.index;
        const byte = pattern[start];

        if (std.ascii.isAlphabetic(byte)) {
            while (self.index < pattern.len and pattern[self.index] == byte) self.index += 1;
            return .{ .field = .{ .letter = byte, .count = self.index - start, .text = pattern[start..self.index] } };
        }

        if (byte == '\'') {
            self.index += 1;
            // `''` on its own is an apostrophe, not an empty quotation.
            if (self.index < pattern.len and pattern[self.index] == '\'') {
                self.index += 1;
                return .{ .literal = pattern[start..self.index] };
            }
            while (self.index < pattern.len) {
                if (pattern[self.index] == '\'') {
                    if (self.index + 1 < pattern.len and pattern[self.index + 1] == '\'') {
                        self.index += 2;
                        continue;
                    }
                    self.index += 1;
                    break;
                }
                self.index += 1;
            }
            return .{ .literal = pattern[start..self.index] };
        }

        while (self.index < pattern.len and
            !std.ascii.isAlphabetic(pattern[self.index]) and
            pattern[self.index] != '\'') self.index += 1;
        return .{ .literal = pattern[start..self.index] };
    }
};

test Tokens {
    var tokens: Tokens = .{ .pattern = "d 'de' MMMM, h:mm a''" };
    const expected = [_][]const u8{ "d", " ", "'de'", " ", "MMMM", ", ", "h", ":", "mm", " ", "a", "''" };
    for (expected) |want| {
        const got = switch (tokens.next().?) {
            .literal => |text| text,
            .field => |field| field.text,
        };
        try std.testing.expectEqualStrings(want, got);
    }
    try std.testing.expectEqual(null, tokens.next());
}

/// A pattern or a skeleton read into one slot per kind of field: ICU's
/// `PtnSkeleton`.
///
/// Each slot holds the letter and count as written (`original`), the
/// letter and count of the row it read as (`base`, which is what two
/// spellings of the same request share), and the type number the distance
/// between two of these is measured in. A kind the text does not mention
/// is zero throughout.
const Skeleton = struct {
    letters: [kind_count]u8 = @splat(0),
    counts: [kind_count]u8 = @splat(0),
    base_letters: [kind_count]u8 = @splat(0),
    base_counts: [kind_count]u8 = @splat(0),
    types: [kind_count]i32 = @splat(0),

    fn set(self: *Skeleton, row: *const Row, letter: u8, count: usize) void {
        const slot = @backingInt(row.kind);
        self.letters[slot] = letter;
        self.counts[slot] = @intCast(@min(count, std.math.maxInt(u8)));
        self.base_letters[slot] = row.letter;
        self.base_counts[slot] = row.min;
        self.types[slot] = if (row.type > 0) row.type + @as(i32, self.counts[slot]) else row.type;
    }

    fn clear(self: *Skeleton, kind: Kind) void {
        const slot = @backingInt(kind);
        self.letters[slot] = 0;
        self.counts[slot] = 0;
        self.base_letters[slot] = 0;
        self.base_counts[slot] = 0;
        self.types[slot] = 0;
    }

    fn has(self: Skeleton, kind: Kind) bool {
        return self.counts[@backingInt(kind)] != 0;
    }

    /// Reads `text`, a pattern or a skeleton; ICU's `DateTimeMatcher::set`.
    ///
    /// Quoted text is skipped and so is a letter that is not a field, and
    /// a kind written twice keeps the second. Then two things ICU does on
    /// the reader's behalf, because they are what a person writing the
    /// skeleton meant:
    ///
    ///   - minutes and a fraction with no seconds between them get the
    ///     seconds, since `mm.SSS` with the seconds missing is no time
    ///     anybody writes;
    ///   - a twelve-hour hour gets a day period if it has none, and a
    ///     twenty-four-hour hour loses any it has. `hm` and `ahm` are the
    ///     same request, which is what lets a key spelled without the `a`
    ///     match a pattern written with it.
    fn read(text: []const u8) Skeleton {
        var self: Skeleton = .{};
        var tokens: Tokens = .{ .pattern = text };
        while (tokens.next()) |token| switch (token) {
            .literal => {},
            .field => |field| if (rowFor(field.letter, field.count)) |row| self.set(row, field.letter, field.count),
        };

        if (self.has(.minute) and self.has(.fractional_second) and !self.has(.second)) {
            const row = firstRow(.second);
            self.set(row, row.letter, row.min);
        }

        if (self.has(.hour)) {
            const hour = self.letters[@backingInt(Kind.hour)];
            if (hour == 'h' or hour == 'K') {
                if (!self.has(.day_period)) {
                    const row = firstRow(.day_period);
                    self.set(row, row.letter, row.min);
                }
            } else {
                self.clear(.day_period);
            }
        }
        return self;
    }

    fn mask(self: Skeleton) Mask {
        var out: Mask = 0;
        for (self.counts, 0..) |count, slot| {
            if (count != 0) out |= @as(Mask, 1) << @intCast(slot);
        }
        return out;
    }

    fn sameOriginal(self: Skeleton, other: Skeleton) bool {
        return std.mem.eql(u8, &self.letters, &other.letters) and std.mem.eql(u8, &self.counts, &other.counts);
    }

    fn sameBase(self: Skeleton, other: Skeleton) bool {
        return std.mem.eql(u8, &self.base_letters, &other.base_letters) and
            std.mem.eql(u8, &self.base_counts, &other.base_counts);
    }

    fn sameTypes(self: Skeleton, other: Skeleton) bool {
        return std.mem.eql(i32, &self.types, &other.types);
    }

    /// Which of ICU's 52 lists this lands in: the first letter of its base
    /// pattern, `A` to `Z` and then `a` to `z`. Patterns are visited list
    /// by list, so this decides which of two equally near patterns wins.
    fn bucket(self: Skeleton) u8 {
        for (self.base_counts, self.base_letters) |count, letter| {
            if (count == 0) continue;
            return if (std.ascii.isUpper(letter)) letter - 'A' else 26 + (letter - 'a');
        }
        return 52;
    }
};

test "a skeleton reads a twelve-hour hour with its day period" {
    // `hmm`, spelled without a day period, and `h:mm a`, written with
    // one, are the same request.
    const key = Skeleton.read("hmm");
    const pattern = Skeleton.read("h:mm a");
    try std.testing.expect(key.sameTypes(pattern));

    // And a twenty-four-hour hour drops one.
    try std.testing.expect(!Skeleton.read("Ha").has(.day_period));

    // Minutes and a fraction get the seconds between them.
    try std.testing.expect(Skeleton.read("mSSS").has(.second));
}

const Distance = struct {
    value: i32 = 0,
    missing: Mask = 0,
    extra: Mask = 0,
};

/// How far `trial` is from `request`, counting only the kinds of the
/// request in `include`; ICU's `getDistance`.
fn distance(request: *const Skeleton, include: Mask, trial: *const Skeleton) Distance {
    var out: Distance = .{};
    for (0..kind_count) |slot| {
        const one = @as(Mask, 1) << @intCast(slot);
        const mine = if (include & one == 0) 0 else request.types[slot];
        const theirs = trial.types[slot];
        if (mine == theirs) continue;
        if (mine == 0) {
            out.value += extra_field;
            out.extra |= one;
        } else if (theirs == 0) {
            out.value += missing_field;
            out.missing |= one;
        } else {
            out.value += @intCast(@abs(mine - theirs));
        }
    }
    return out;
}

// ----- The locale's table of patterns -----

/// The single-field patterns ICU starts its table with, one per kind of
/// field, so that a request for just the day or just the seconds always
/// has something to land on.
const canonical_items = "GyQMwWEDFdaHmsSv";

/// The entries ICU makes from the locale before it reads a single
/// `availableFormats` key: the canonical items, then the four time formats
/// and the four date formats, longest first. Their skeletons are read off
/// the patterns rather than given, which is what `specified` being null
/// records later.
const derived_count = canonical_items.len + 8;

const Derived = struct {
    pattern: []const u8,
    skeleton: Skeleton,
    /// False when an earlier entry had the same base pattern, in which
    /// case ICU never added this one: the medium date is dropped when it
    /// differs from the short one only in widths.
    live: bool,
};

fn derivedEntries(locale: Locale) [derived_count]Derived {
    var out: [derived_count]Derived = undefined;
    for (canonical_items, 0..) |_, index| {
        const pattern = canonical_items[index..][0..1];
        out[index] = .{ .pattern = pattern, .skeleton = .read(pattern), .live = true };
    }
    const lengths = [_]Length{ .full, .long, .medium, .short };
    for (lengths, 0..) |length, index| {
        const time = locale.timeFormat(length);
        out[canonical_items.len + index] = .{ .pattern = time, .skeleton = .read(time), .live = true };
        const date = locale.dateFormat(length);
        out[canonical_items.len + 4 + index] = .{ .pattern = date, .skeleton = .read(date), .live = true };
    }
    for (out[canonical_items.len..], canonical_items.len..) |*entry, index| {
        for (out[0..index]) |earlier| {
            if (earlier.live and earlier.skeleton.sameBase(entry.skeleton)) {
                entry.live = false;
                break;
            }
        }
    }
    return out;
}

/// The pattern a search settled on, before any rewriting.
const Raw = struct {
    pattern: []const u8,
    /// The skeleton the pattern was filed under, when it came from
    /// `availableFormats` with one; null for a pattern whose skeleton was
    /// read off the pattern itself. `adjust` treats the two differently.
    specified: ?Skeleton,
    distance: Distance,
};

/// The nearest pattern in the locale's table to the kinds of `request`
/// in `include`; ICU's `getBestRaw`.
///
/// ICU walks its table once and keeps the first entry with the smallest
/// distance, preferring among equals the one missing the *most*
/// significant field -- it compares the masks as numbers. Which entry is
/// first is a matter of where it sits in the table, so each candidate here
/// carries the position ICU would give it, and the comparison uses that
/// rather than the order the candidates happen to be looked at in.
/// A candidate whose skeleton spells a numeric year with exactly two
/// letters may carry literal text that only reads right beside a two-digit
/// year (English `MMM d, ’yy`), so ICU 79 lets it answer only a request
/// that also asks for two. A non-numeric year on either side is not
/// checked.
fn yearLengthCompatible(request: *const Skeleton, trial: *const Skeleton) bool {
    const slot = @backingInt(Kind.year);
    if (request.types[slot] <= 0 or trial.types[slot] <= 0) return true;
    return trial.counts[slot] != 2 or request.counts[slot] == 2;
}

test yearLengthCompatible {
    const two: Skeleton = .read("yyMMMd");
    const any: Skeleton = .read("yMMMd");
    try std.testing.expect(!yearLengthCompatible(&any, &two));
    try std.testing.expect(yearLengthCompatible(&two, &two));
    try std.testing.expect(yearLengthCompatible(&two, &any));
}

fn bestRaw(request: *const Skeleton, include: Mask, locale: Locale, derived: *const [derived_count]Derived) Raw {
    var best: ?Raw = null;
    var best_order: u64 = std.math.maxInt(u64);

    const consider = struct {
        fn consider(
            best_: *?Raw,
            best_order_: *u64,
            candidate: Raw,
            order: u64,
        ) void {
            if (best_.*) |current| {
                const d = candidate.distance;
                const c = current.distance;
                if (d.value > c.value) return;
                if (d.value == c.value) {
                    if (d.missing < c.missing) return;
                    if (d.missing == c.missing and order > best_order_.*) return;
                }
            }
            best_.* = candidate;
            best_order_.* = order;
        }
    }.consider;

    // Which availableFormats entry, if any, took over each derived entry.
    // ICU replaces a derived pattern in place when a key with exactly the
    // same types arrives, keeping the derived entry's skeleton and its
    // place in the table and taking the key's pattern, and a second such
    // key replaces it again.
    var replaced_by: [derived_count]?usize = @splat(null);

    const formats = locale.available_formats;
    for (formats, 0..) |available, index| {
        // A key ICU has already read is not read again.
        const seen = for (formats[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.skeleton, available.skeleton)) break true;
        } else false;
        if (seen) continue;

        const skeleton: Skeleton = .read(available.skeleton);
        if (skeleton.mask() == 0) continue;

        // A key whose skeleton is spelled exactly like one an earlier key
        // already replaced is ignored, as ICU ignores a parent locale's
        // entry once the locale has its own.
        const shadowed = for (derived, replaced_by) |entry, by| {
            if (entry.live and by != null and entry.skeleton.sameOriginal(skeleton)) break true;
        } else false;
        if (shadowed) continue;

        const target = for (derived, 0..) |entry, slot| {
            if (entry.live and entry.skeleton.sameBase(skeleton) and entry.skeleton.sameTypes(skeleton)) break slot;
        } else null;

        if (target) |slot| {
            replaced_by[slot] = index;
            continue;
        }

        // Two keys with the same types and different spellings would make
        // ICU replace the first with the second; CLDR has no such pairs,
        // so both are kept here.
        if (!yearLengthCompatible(request, &skeleton)) continue;
        consider(&best, &best_order, .{
            .pattern = available.pattern,
            .specified = skeleton,
            .distance = distance(request, include, &skeleton),
        }, (@as(u64, skeleton.bucket()) << 32) | (derived_count + index));
    }

    for (derived, replaced_by, 0..) |*entry, by, slot| {
        if (!entry.live) continue;
        if (!yearLengthCompatible(request, &entry.skeleton)) continue;
        consider(&best, &best_order, .{
            .pattern = if (by) |index| formats[index].pattern else entry.pattern,
            .specified = if (by != null) entry.skeleton else null,
            .distance = distance(request, include, &entry.skeleton),
        }, (@as(u64, entry.skeleton.bucket()) << 32) | slot);
    }

    // The canonical items cover every kind, so there is always something.
    return best.?;
}

// ----- Rewriting the pattern toward the request -----

const Flags = struct {
    /// Append the request's fraction of a second after the seconds.
    fix_fraction: bool = false,
    /// The request said `J`: the hour on the locale's clock, whatever
    /// letter the pattern used.
    uses_cap_j: bool = false,
};

const Context = struct {
    request: *const Skeleton,
    options: SkeletonOptions,
    flags: Flags,
    locale: Locale,
    /// `h` or `H`, whichever the locale's clock is.
    hour_letter: u8,
};

/// Writes `pattern` with its fields bent toward the request; ICU's
/// `adjustFieldTypes`.
///
/// A field the request did not ask for is copied as it is. One it did
/// takes the request's width, except in three cases where the locale's
/// own width is kept:
///
///   1. The hour, the minute and the second, unless the matching option
///      in `SkeletonOptions` is on. A locale that writes `HH` means it.
///   2. The pattern came from `availableFormats` and its key already had
///      the width the request asks for. Japanese files `y年M月d日` under
///      `yMMMd`, where the key says "abbreviated month" and the pattern
///      writes the numeral, because that is what an abbreviated month is
///      in Japanese; a request for `yMMMd` takes the pattern as it is.
///   3. The pattern came from `availableFormats` and one side is a number
///      where the other is a name. Widening that `M` to `MMMM` for a
///      request for the long month would look the name up and write it
///      before 月.
///
/// The letter written is the request's, except for the hour, the month,
/// the weekday and a calendar year, which keep the pattern's -- `L` stays
/// `L` and `c` stays `c` -- and an hour that is then moved onto the
/// locale's clock.
///
/// With `fix_fraction` set this is instead the pass that adds a fraction
/// of a second the pattern did not have: the locale's decimal separator
/// and the request's `S` run go in after each `s`.
fn adjust(pattern: []const u8, specified: ?*const Skeleton, context: Context, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const request = context.request;
    var tokens: Tokens = .{ .pattern = pattern };
    while (tokens.next()) |token| switch (token) {
        .literal => |text| try writer.writeAll(text),
        .field => |field| {
            const row = rowFor(field.letter, field.count) orelse {
                try writer.writeAll(field.text);
                continue;
            };
            const kind = row.kind;
            const slot = @backingInt(kind);

            if (context.flags.fix_fraction and kind == .second) {
                try writer.writeAll(field.text);
                try writer.writeAll(context.locale.decimal);
                const fraction = @backingInt(Kind.fractional_second);
                try writer.splatByteAll(request.letters[fraction], request.counts[fraction]);
                continue;
            }

            if (request.types[slot] == 0) {
                try writer.writeAll(field.text);
                continue;
            }

            const wanted_letter = request.letters[slot];
            var wanted_count: usize = request.counts[slot];
            // `E` to `EEE` are one width, and it is the third.
            if (wanted_letter == 'E' and wanted_count < 3) wanted_count = 3;

            var count = wanted_count;
            const keep_width = switch (kind) {
                .hour => !context.options.match_hour_field_length,
                .minute => !context.options.match_minute_field_length,
                .second => !context.options.match_second_field_length,
                else => false,
            };
            if (keep_width) {
                count = field.count;
            } else if (specified) |key| {
                // `c` and `e` are left out because they change meaning
                // with width, where every other letter only changes length.
                if (wanted_letter != 'c' and wanted_letter != 'e') {
                    const pattern_is_number = row.type > 0;
                    const request_is_number = request.types[slot] > 0;
                    if (key.counts[slot] == wanted_count or pattern_is_number != request_is_number) {
                        count = field.count;
                    }
                }
            }

            var letter = switch (kind) {
                .hour, .month, .weekday => field.letter,
                .year => if (wanted_letter == 'Y') wanted_letter else field.letter,
                else => wanted_letter,
            };
            if (letter == 'E' and count < 3) letter = 'e';

            if (kind == .hour) {
                const clock = context.hour_letter;
                if (context.flags.uses_cap_j or wanted_letter == clock) {
                    letter = clock;
                } else if (wanted_letter == 'k' and clock == 'H') {
                    letter = 'H';
                } else if (wanted_letter == 'K' and clock == 'h') {
                    letter = 'h';
                }
            }

            try writer.splatByteAll(letter, count);
        },
    };
}

// ----- Putting it together -----

/// The appendItems CLDR gives a field the pattern could not hold, for the
/// kinds where it is the plain "{0} {1}" -- the pattern, a space, the
/// field -- in every locale. The others write the field's localized
/// *name* beside it, "{0} ({2}: {1})", and this library carries no field
/// names, so a field of those kinds that no pattern holds is left out.
fn appendsPlainly(kind: Kind) bool {
    return switch (kind) {
        .era, .year, .weekday, .zone => true,
        else => false,
    };
}

const Buffers = struct {
    first: [max_pattern]u8 = undefined,
    second: [max_pattern]u8 = undefined,
    third: [max_pattern]u8 = undefined,
};

/// The pattern for the kinds of the request in `wanted`, made from as
/// many of the locale's patterns as it takes; ICU's `getBestAppending`.
fn bestAppending(
    wanted: Mask,
    context: Context,
    derived: *const [derived_count]Derived,
    out: []u8,
) std.Io.Writer.Error![]const u8 {
    if (wanted == 0) return out[0..0];

    var scratch: Buffers = .{};
    var raw = bestRaw(context.request, wanted, context.locale, derived);
    var result: std.Io.Writer = .fixed(out);
    try adjust(raw.pattern, if (raw.specified) |*key| key else null, context, &result);

    var missing = raw.distance.missing;
    var last: Mask = 0;
    var specified = raw.specified;
    while (missing != 0) {
        if (last == missing) break;

        // Only the fraction is missing, and the seconds it goes after are
        // there: that is the one gap filled by rewriting rather than by
        // appending.
        if (missing & second_and_fraction_mask == fraction_mask and
            wanted & second_and_fraction_mask == second_and_fraction_mask)
        {
            const before = scratch.first[0..result.end];
            @memcpy(before, result.buffered());
            result = .fixed(out);
            var fixing = context;
            fixing.flags.fix_fraction = true;
            try adjust(before, if (specified) |*key| key else null, fixing, &result);
            missing &= ~fraction_mask;
            continue;
        }

        const starting = missing;
        raw = bestRaw(context.request, missing, context.locale, derived);
        specified = raw.specified;
        missing = raw.distance.missing;

        const found = starting & ~missing;
        if (found != 0) {
            const top: Kind = @fromBackingInt(@intCast(15 - @clz(found)));
            if (appendsPlainly(top)) {
                var piece: std.Io.Writer = .fixed(&scratch.second);
                try adjust(raw.pattern, if (specified) |*key| key else null, context, &piece);
                try result.writeByte(' ');
                try result.writeAll(piece.buffered());
            }
        }
        last = missing;
    }
    return result.buffered();
}

/// Rewrites `j`, `J` and `C` into a concrete hour; ICU's
/// `mapSkeletonMetacharacters`.
///
/// `j` is the hour on the locale's clock, and on a twelve-hour clock comes
/// with the day period: an odd run gives a one-digit hour and an even run
/// two, and the length of the run also says how long a day period --
/// abbreviated up to two, wide at three or four, narrow at five or six.
/// `C` is the same here; ICU consults CLDR's table of which hour cycles a
/// region allows, which can give it a flexible day period, and this
/// library has only the locale's own preference. `J` is the hour without a
/// day period, read as `H` and moved onto the locale's clock when the
/// pattern is written.
fn mapMetacharacters(
    skeleton: []const u8,
    hour_letter: u8,
    flags: *Flags,
    buffer: *[max_skeleton]u8,
) SkeletonError![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    var index: usize = 0;
    while (index < skeleton.len) {
        const letter = skeleton[index];
        if (!std.ascii.isAlphabetic(letter)) return error.NotAField;

        if (letter == 'j' or letter == 'C') {
            var extra: usize = 0;
            while (index + 1 < skeleton.len and skeleton[index + 1] == letter) {
                extra += 1;
                index += 1;
            }
            index += 1;
            const hour_count = 1 + (extra & 1);
            var period_count: usize = if (extra < 2) 1 else 3 + (extra >> 1);
            if (hour_letter == 'H' or hour_letter == 'k') period_count = 0;
            writer.splatByteAll('a', period_count) catch return error.SkeletonTooLong;
            writer.splatByteAll(hour_letter, hour_count) catch return error.SkeletonTooLong;
            continue;
        }

        if (letter == 'J') {
            writer.writeByte('H') catch return error.SkeletonTooLong;
            flags.uses_cap_j = true;
        } else {
            writer.writeByte(letter) catch return error.SkeletonTooLong;
        }
        index += 1;
    }
    return writer.buffered();
}

/// The pattern the locale would write `skeleton` with, in `buffer`.
///
/// This is ICU's `DateTimePatternGenerator::getBestPattern`, and the
/// answer is meant to be the same pattern ICU gives for the same locale
/// data; see the top of this file for how it gets there. `skeleton`
/// names fields and widths in any order: `yMMMd`, `Hmm`, `jmsSSS`.
///
/// The locale must carry `available_formats`; see
/// `cldrlocale.AvailableFormat` for why the generated ones do not.
///
/// Where it differs from ICU, it is for want of data rather than by
/// choice. A field no pattern of the locale's holds is appended to the
/// pattern the way CLDR says to only when that is a plain space -- an
/// era, a year, a weekday, a zone -- because the other kinds are appended
/// with the field's localized name, which this library does not carry;
/// a field of those kinds that nothing holds is left out. And `C` is read
/// as `j`.
pub fn bestPattern(
    skeleton: []const u8,
    locale: Locale,
    options: SkeletonOptions,
    buffer: []u8,
) SkeletonError![]const u8 {
    if (locale.available_formats.len == 0) return error.NoSkeletonData;
    if (skeleton.len > max_skeleton) return error.SkeletonTooLong;

    const hour_letter: u8 = if (locale.prefersTwelveHour()) 'h' else 'H';
    var flags: Flags = .{};
    var mapped_buffer: [max_skeleton]u8 = undefined;
    const mapped = try mapMetacharacters(skeleton, hour_letter, &flags, &mapped_buffer);

    const request: Skeleton = .read(mapped);
    const derived = derivedEntries(locale);
    const context: Context = .{
        .request = &request,
        .options = options,
        .flags = flags,
        .locale = locale,
        .hour_letter = hour_letter,
    };

    return compose(request, context, &derived, buffer) catch error.PatternTooLong;
}

fn compose(
    request: Skeleton,
    context: Context,
    derived: *const [derived_count]Derived,
    buffer: []u8,
) std.Io.Writer.Error![]const u8 {
    var out: std.Io.Writer = .fixed(buffer);

    const raw = bestRaw(&request, std.math.maxInt(Mask), context.locale, derived);
    if (raw.distance.missing == 0 and raw.distance.extra == 0) {
        try adjust(raw.pattern, if (raw.specified) |*key| key else null, context, &out);
        return out.buffered();
    }

    // No one pattern has every field and nothing else, so the date and the
    // time are found separately and joined.
    var halves: Buffers = .{};
    const needed = request.mask();
    const date = try bestAppending(needed & date_mask, context, derived, &halves.first);
    const time = try bestAppending(needed & time_mask, context, derived, &halves.second);
    if (date.len == 0) {
        try out.writeAll(time);
        return out.buffered();
    }
    if (time.len == 0) {
        try out.writeAll(date);
        return out.buffered();
    }

    // Which of the four joining patterns, by how long the month is: CLDR's
    // rule, and the same one `cldr.formatDateTime` follows by the date's
    // length.
    const month = @backingInt(Kind.month);
    const length: Length = switch (request.base_counts[month]) {
        4 => if (request.has(.weekday)) .full else .long,
        3 => .medium,
        else => .short,
    };
    const glue = context.locale.dateTimeAtTimeFormat(length);
    var index: usize = 0;
    while (index < glue.len) {
        if (glue[index] == '{' and index + 2 < glue.len and glue[index + 2] == '}') {
            switch (glue[index + 1]) {
                '0' => {
                    try out.writeAll(time);
                    index += 3;
                    continue;
                },
                '1' => {
                    try out.writeAll(date);
                    index += 3;
                    continue;
                },
                else => {},
            }
        }
        try out.writeByte(glue[index]);
        index += 1;
    }
    return out.buffered();
}

// ----- Tests -----

/// English with a handful of CLDR 49's availableFormats, enough to reach
/// each rule above. The real table has eighty-odd entries.
fn testEnglish() Locale {
    var locale = cldrlocale.en;
    locale.available_formats = &.{
        .{ .skeleton = "Ed", .pattern = "d E" },
        .{ .skeleton = "Hm", .pattern = "HH:mm" },
        .{ .skeleton = "Hms", .pattern = "HH:mm:ss" },
        .{ .skeleton = "MMMd", .pattern = "MMM d" },
        .{ .skeleton = "hm", .pattern = "h:mm a" },
        .{ .skeleton = "hms", .pattern = "h:mm:ss a" },
        .{ .skeleton = "ms", .pattern = "mm:ss" },
        .{ .skeleton = "yMMMd", .pattern = "MMM d, y" },
        .{ .skeleton = "yMMMEd", .pattern = "EEE, MMM d, y" },
        .{ .skeleton = "yMd", .pattern = "M/d/y" },
        .{ .skeleton = "yyMMMd", .pattern = "MMM d, ’yy" },
    };
    return locale;
}

fn expectPattern(expected: []const u8, skeleton: []const u8, locale: Locale, options: SkeletonOptions) !void {
    var buffer: [max_pattern]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try bestPattern(skeleton, locale, options, &buffer));
}

test bestPattern {
    const en = testEnglish();

    // An exact key.
    try expectPattern("MMM d, y", "yMMMd", en, .{});
    // `j` is the twelve-hour clock in English.
    try expectPattern("h:mm a", "jm", en, .{});
    // A two-digit day where the key has one.
    try expectPattern("MMM dd, y", "yMMMdd", en, .{});

    // A fraction of a second the pattern has no room for is written after
    // the seconds, with the locale's decimal separator.
    try expectPattern("mm:ss.SSS", "mmssSSS", en, .{});
    try expectPattern("h:mm:ss.SS a", "hmsSS", en, .{});
    // Minutes and a fraction bring the seconds with them.
    try expectPattern("mm:ss.SSS", "mSSS", en, .{});

    // The hour's width is the locale's unless the request's is asked for.
    try expectPattern("h:mm a", "hhmm", en, .{});
    try expectPattern("hh:mm a", "hhmm", en, .{ .match_hour_field_length = true });

    // A date and a time with no pattern holding both are joined with the
    // locale's glue, chosen by the month's length.
    try expectPattern("MMM d, y, h:mm a", "yMMMdjm", en, .{});
}

test "a two-digit year's pattern answers only a two-digit request" {
    const en = testEnglish();
    // `yyMMMd` is nearer a four-digit year than `yMMMd` is, but its
    // apostrophe only reads right before two digits.
    try expectPattern("MMM d, yyyy", "yyyyMMMd", en, .{});
    try expectPattern("MMM d, ’yy", "yyMMMd", en, .{});
}

test "the decimal separator is the locale's" {
    var de = testEnglish();
    de.decimal = ",";
    try expectPattern("mm:ss,SSS", "mmssSSS", de, .{});
}

test "the hour's width follows the request only where ICU's does" {
    // British English, in the part that matters: `Hm` is filed as
    // `HH:mm`, and so is the short time. Asking for the hour's own width
    // with `Hmm` lands on the short time's entry, whose skeleton was read
    // off the pattern, and so takes the request's one digit; asking with
    // `Hm` lands on the key, which already says one digit and so keeps
    // the locale's two. Both are what ICU 79.1 answers.
    var gb = cldrlocale.en;
    var times = cldrlocale.en.time_formats.*;
    times[@backingInt(Length.short)] = "HH:mm";
    times[@backingInt(Length.medium)] = "HH:mm:ss";
    gb.time_formats = &times;
    gb.available_formats = &.{.{ .skeleton = "Hm", .pattern = "HH:mm" }};

    try expectPattern("HH:mm", "Hmm", gb, .{});
    try expectPattern("H:mm", "Hmm", gb, .{ .match_hour_field_length = true });
    try expectPattern("HH:mm", "Hm", gb, .{ .match_hour_field_length = true });
}

test "the width of a number filed as a name is the locale's" {
    // Japanese files `y年M月d日` under `yMMMd`: the key calls the month
    // abbreviated and the pattern writes a numeral, because that is what an
    // abbreviated month is in Japanese. A request for the long month keeps
    // the numeral rather than writing the name before 月.
    var ja = cldrlocale.en;
    ja.date_formats = &[4][]const u8{ "y年M月d日EEEE", "y年M月d日", "y/MM/dd", "y/MM/dd" };
    ja.available_formats = &.{.{ .skeleton = "yMMMd", .pattern = "y年M月d日" }};
    try expectPattern("y年M月d日", "yMMMMd", ja, .{});
}

test "a skeleton is refused when it is not one" {
    var buffer: [max_pattern]u8 = undefined;
    try std.testing.expectError(error.NoSkeletonData, bestPattern("yMd", cldrlocale.en, .{}, &buffer));
    try std.testing.expectError(error.NotAField, bestPattern("y-M", testEnglish(), .{}, &buffer));
    try std.testing.expectError(error.SkeletonTooLong, bestPattern("yMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM", testEnglish(), .{}, &buffer));
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.PatternTooLong, bestPattern("yMMMd", testEnglish(), .{}, &small));
}
