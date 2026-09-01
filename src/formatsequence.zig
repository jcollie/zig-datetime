// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The vocabulary of the format strings that `DateTime.format` and
//! `DateTime.parse` are driven by, in the style moment.js established.
//!
//! Every sequence is a variant of `FormatTag`, spelled exactly as it
//! appears in a format string, which is what lets `Tokenizer` recognize
//! them by reflecting over the enum's field names rather than from a table
//! that would have to be kept in step. Sequences overlap by design — `M`,
//! `MM`, `MMM` and `MMMM` all start alike — so the tokenizer always takes
//! the longest field name that matches at the cursor, and anything that
//! matches nothing is passed through as a literal character.

const std = @import("std");

/// One sequence of a format string. The field names are the sequences
/// themselves, which is what `Tokenizer` matches against.
pub const FormatTag = enum {
    /// 1 2 ... 11 12 (month, numeric)
    M,
    /// 1st 2nd ... 11th 12th (month, numeric ordinal)
    Mo,
    /// 01 02 ... 11 12 (month, numeric, zero padded)
    MM,
    // /// Ja, Fe, Ma ... No, De (very short month name)
    // Mm,
    MMM, // Jan Feb ... Nov Dec (short month name)
    MMMM, // January February ... November December (long month name)
    Q, // 1 2 3 4 (quarter)
    Qo, // 1st 2nd 3rd 4th (quarter)
    D, // 1 2 ... 30 31 (day of the month)
    Do, // 1st 2nd ... 30th 31st (day of the month, ordinal)
    DD, // 01 02 ... 30 31 (day of the month, zero padded)
    DDD, // 1 2 ... 364 365 366
    DDDo, // 1st 2nd ... 364th 365th 366th (day of the year, ordinal)
    DDDD, // 001 002 ... 364 365 365 (day of the year)
    d, // 0 1 ... 5 6 (day of the week)
    do, // 0th 1st 2nd 3rd ... 5th 6th (day of the week, ordinal)
    dd, // Su Mo ... Fr Sa (day of the week, very short name)
    ddd, // Sun Mon ... Fri Sat (day of the week, short name)
    dddd, // Sunday Monday ... Friday Saturday (day of the week, long name)
    e, // 0 1 ... 5 6 (locale)
    E, // 1 2 ... 6 7 (ISO)
    /// 1 2 ... 52 53 (week of the year)
    ///
    /// This is the week under the English-language convention, where a
    /// week begins on Sunday and week 1 holds January 1st, matching what
    /// moment.js's default locale means by `w`. `W` is the ISO 8601 week,
    /// which is the other rule. See `Date.weekOfYear`.
    ///
    /// The week-numbering year is not always the calendar year that
    /// `YYYY` writes, so pair these with `gg`, not with `YY`.
    w,
    /// 1st 2nd 3rd 4th ... 52nd 53rd (week of the year, ordinal)
    wo,
    /// 01 02 ... 52 53 (week of the year, zero padded)
    ww,
    /// 1 2 ... 52 53 (ISO 8601 week of the year)
    ///
    /// Weeks begin on Monday and week 1 holds January 4th. Pair these
    /// with `GG` rather than with `YY`. See `Date.isoWeek`.
    W,
    /// 1st 2nd 3rd 4th ... 52nd 53rd (ISO week, ordinal)
    Wo,
    /// 01 02 ... 52 53 (ISO week, zero padded)
    WW,
    /// 70 71 ... 29 30 (week-numbering year, last two digits)
    ///
    /// The year the week written by `w` belongs to, which at the turn of
    /// a year is not the calendar year.
    gg,
    /// 1970 1971 ... 2029 2030 (week-numbering year)
    gggg,
    /// 02024 (week-numbering year, zero padded to five digits)
    ggggg,
    /// 70 71 ... 29 30 (ISO week-numbering year, last two digits)
    ///
    /// The year the week written by `W` belongs to.
    GG,
    /// 1970 1971 ... 2029 2030 (ISO week-numbering year)
    GGGG,
    /// 02024 (ISO week-numbering year, zero padded to five digits)
    GGGGG,
    /// 70 71 ... 29 30 (year, last two digits only)
    YY,
    /// 0001 0002 ... 1970 1971 ... 2029 2030 (year, zero padded to four
    /// digits, with a leading minus before the common era)
    YYYY,
    /// 02024 (year, zero padded to five digits)
    YYYYY,
    /// +002024 (year, always signed, zero padded to six digits)
    ///
    /// This is ISO 8601's expanded year, which the standard allows only by
    /// prior agreement between the parties exchanging the data; `iso8601`
    /// deliberately does not parse it.
    YYYYYY,
    /// 1 2 ... 1970 1971 ... 2029 2030 (year, unpadded)
    ///
    /// Note that `YYY` is not a sequence: it reads as `YY` followed by
    /// this, which is what moment.js makes of it too.
    Y,
    /// 1 2 ... 1970 1971 ... 2029 2030 (era year, unpadded)
    ///
    /// The year counted within its era, which for the common era is the
    /// year itself. `yy`, `yyy` and `yyyy` all mean the same thing, as
    /// they do in moment.js.
    y,
    /// 1st 2nd ... 2029th 2030th (era year, ordinal)
    yo,
    /// Same as `y`.
    yy,
    /// Same as `y`.
    yyy,
    /// Same as `y`.
    yyyy,
    /// AD (era, abbreviated)
    N,
    /// Same as `N`.
    NN,
    /// Same as `N`.
    NNN,
    /// Anno Domini (era, in full)
    NNNN,
    /// Same as `N`.
    NNNNN,
    // @"±YYYY",
    // /// BCE/CE (BC and AD will be accepted for parsing, but not emitted on
    // /// formatting).
    // N,
    // /// Before Common Era/Common Era (Before Christ and Anno Domini will be
    // /// accepted for parsing but will not be emitted when formatted).
    // NN,
    /// AM PM (ante/post meridian, upper case)
    A,
    /// am pm (ante/post meridian, lower case)
    a,
    /// 0 1 ... 22 23 (hour)
    H,
    /// 00 01 ... 22 23 (hour, zero padded)
    HH,
    /// 12 1 2 ... 11 12 (hour, 12 hour clock)
    h,
    /// 12 01 02 ... 11 (hour, 12 hour clock, zero padded)
    hh,
    /// 24 1 2 ... 23
    k,
    /// 24 01 02 ... 23
    kk,
    m, // 0 1 ... 58 59 (minute)
    mm, // 00 01 ... 58 59 (minute, zero padded)
    s, // 0 1 ... 58 59 60 (second)
    ss, // 00 01 ... 58 59 60 (second, zero padded)
    S, // 0 1 ... 8 9 (tenths of a second)
    SS, // 00 01 ... 98 99(hundredths of a second)
    SSS, // 000 001 ... 998 999 (milliseconds)
    SSSS, // 0000 0000 ... 9998 9999 (hundreds of microseconds)
    SSSSS, // 00000 00000 ... 99998 99999 (tens of microseconds)
    SSSSSS, // 000000 000000 ... 999998 999999 (microseconds)
    SSSSSSS, // 0000000 00000000 ... 9999998 9999999 (hundreds of nanoseconds)
    SSSSSSSS, // 00000000 000000000 ... 99999998 99999999 (tens of nanoseconds)
    SSSSSSSSS, // 000000000 000000000 ... 999999998 999999999 (nanoseconds)
    /// 1430 (hour and minute, run together, hour unpadded)
    ///
    /// One sequence rather than `H` beside `mm`, which is what moment.js
    /// makes of these four spellings too.
    Hmm,
    /// 143005 (hour, minute and second, run together)
    Hmmss,
    /// 230 (hour on the 12 hour clock and minute, run together)
    hmm,
    /// 23005 (hour on the 12 hour clock, minute and second)
    hmmss,
    /// 1710513005 (seconds since the Unix epoch)
    X,
    /// 1710513005000 (milliseconds since the Unix epoch)
    x,
    /// UTC (zone abbreviation)
    ///
    /// This is always "UTC", whatever the offset, which looks wrong and is
    /// what moment.js does: its `z` reports the abbreviation of a moment
    /// built in UTC mode, and a moment carrying an explicit offset counts
    /// as one. `moment.parseZone("2024-03-15T09:30:00-05:00").format("z")`
    /// is "UTC" there too.
    ///
    /// Every `DateTime` here carries an explicit offset and there is no
    /// ambient local mode, so all of them answer to that case. A real
    /// abbreviation such as "CDT" is not available: a `DateTime` holds an
    /// offset and no designation, and moment does not have one either
    /// without the separate moment-timezone package. Read the designation
    /// off `TimeZone.typeAt` if that is what is wanted.
    z,
    /// Coordinated Universal Time (zone name). The same caveat as `z`.
    zz,
    /// -07:00 -06:00 ... +06:00 +07:00 (offset from UTC). Note that this
    /// makes a bare `Z` in a format string an offset rather than the
    /// literal Zulu marker of ISO 8601.
    Z,
    /// -0700 -0600 ... +0600 +0700 (offset from UTC, no separator)
    ZZ,
    // x, // unix milli
    // X, // unix

    // The localized sequences, which stand for a whole format string
    // rather than for a value: "the usual way to write a date here",
    // without having to know what that is. What each stands for is the
    // locale's, so these are read from `locale.LongDateFormat` when they
    // are written rather than replaced before anything is read. See
    // `isLocalized` and `DateTime.formatWith`.

    /// 8:30 PM (time of day)
    LT,
    /// 8:30:25 PM (time of day with seconds)
    LTS,
    /// 03/15/2024 (date in figures)
    L,
    /// March 15, 2024 (date with the month named)
    LL,
    /// March 15, 2024 8:30 PM (`LL` with the time)
    LLL,
    /// Friday, March 15, 2024 8:30 PM (`LLL` with the weekday)
    LLLL,
    /// 3/15/2024 (`L`, shortened)
    ///
    /// moment does not let a locale name the lower case spellings. It
    /// takes the upper case one and drops a letter from each of `MMMM`,
    /// `MM`, `DD` and `dddd`, which is what `abbreviate` does here.
    l,
    /// Mar 15, 2024 (`LL`, shortened)
    ll,
    /// Mar 15, 2024 8:30 PM (`LLL`, shortened)
    lll,
    /// Fri, Mar 15, 2024 8:30 PM (`LLLL`, shortened)
    llll,

    /// Whether `tag` stands for a whole format string rather than for a
    /// value, and so has to be looked up in a locale and written out
    /// through another pass.
    pub fn isLocalized(tag: FormatTag) bool {
        return switch (tag) {
            .LT, .LTS, .L, .LL, .LLL, .LLLL, .l, .ll, .lll, .llll => true,
            else => false,
        };
    }

    test isLocalized {
        try std.testing.expect(FormatTag.LLLL.isLocalized());
        try std.testing.expect(FormatTag.l.isLocalized());
        // `Z` is an offset and `M` a month, whatever they look like.
        try std.testing.expect(!FormatTag.Z.isLocalized());
        try std.testing.expect(!FormatTag.MMMM.isLocalized());
    }

    /// Whether `tag` names a date, and so can be read back off one.
    ///
    /// The rest name something a date does not determine, or something
    /// that determines no part of it: a quarter and an era are too coarse
    /// to place anything, a zone name is not an offset, the run-together
    /// sequences have no separator to read by, and a Unix timestamp is a
    /// whole date rather than a field of one.
    ///
    /// `parseWith` asks this while it is being compiled, so a format
    /// string that names one of them is a compile error rather than
    /// something a caller has to handle.
    pub fn isParsable(tag: FormatTag) bool {
        return switch (tag) {
            .Q,
            .Qo,
            .yo,
            .N,
            .NN,
            .NNN,
            .NNNN,
            .NNNNN,
            .YYYYY,
            .YYYYYY,
            .Hmm,
            .Hmmss,
            .hmm,
            .hmmss,
            .X,
            .x,
            .z,
            .zz,
            .ggggg,
            .GGGGG,
            => false,
            else => true,
        };
    }

    test isParsable {
        try std.testing.expect(FormatTag.YYYY.isParsable());
        try std.testing.expect(FormatTag.MMMM.isParsable());
        // A localized sequence stands for a string of parsable ones.
        try std.testing.expect(FormatTag.LLLL.isParsable());

        // A quarter names three months and so places nothing, and a zone
        // name is not an offset.
        try std.testing.expect(!FormatTag.Q.isParsable());
        try std.testing.expect(!FormatTag.z.isParsable());
        try std.testing.expect(!FormatTag.X.isParsable());
    }

    /// Whether `tag` is one of the lower case localized spellings, whose
    /// expansion is the upper case one with a letter taken off the padded
    /// sequences.
    pub fn isAbbreviated(tag: FormatTag) bool {
        return switch (tag) {
            .l, .ll, .lll, .llll => true,
            else => false,
        };
    }

    test isAbbreviated {
        try std.testing.expect(FormatTag.llll.isAbbreviated());
        try std.testing.expect(!FormatTag.LLLL.isAbbreviated());
    }

    /// Returns the sequence a lower case localized spelling writes in
    /// place of `tag`.
    ///
    /// moment builds its lower case expansions by taking the upper case
    /// string and running `/MMMM|MM|DD|dddd/g` over it, dropping the
    /// first letter of whatever matches. Doing it a sequence at a time
    /// rather than a substring at a time is the same rule without a
    /// string to build: those four are the only ones that shorten, and a
    /// sequence is exactly what the regular expression was finding.
    pub fn abbreviate(tag: FormatTag) FormatTag {
        return switch (tag) {
            .MMMM => .MMM,
            .MM => .M,
            .DD => .D,
            .dddd => .ddd,
            else => tag,
        };
    }

    test abbreviate {
        try std.testing.expectEqual(FormatTag.MMM, FormatTag.MMMM.abbreviate());
        try std.testing.expectEqual(FormatTag.D, FormatTag.DD.abbreviate());
        try std.testing.expectEqual(FormatTag.ddd, FormatTag.dddd.abbreviate());

        // Everything else is left alone, including the sequences that
        // merely look like they would shorten.
        try std.testing.expectEqual(FormatTag.MMM, FormatTag.MMM.abbreviate());
        try std.testing.expectEqual(FormatTag.YYYY, FormatTag.YYYY.abbreviate());
        try std.testing.expectEqual(FormatTag.dd, FormatTag.dd.abbreviate());
    }

    /// Truncates a nanosecond value to the precision of this `S...` tag,
    /// e.g. `.SSS` reduces it to milliseconds. `tag` must be one of the
    /// fractional-second sequences.
    pub fn convertFractionalSeconds(comptime tag: FormatTag, value: u30) u30 {
        const name = comptime @tagName(tag);
        comptime var count: i8 = undefined;
        inline for (name, 1..) |c, i| {
            if (c != 'S') @compileError(name ++ " is not a fractional second format sequence");
            count = i;
        }
        if (count > 9) @compileError("fractional seconds smaller than nanoseconds are not supported");
        if (count == 9) return value;
        const exponent = 9 - count;
        const factor = std.math.pow(u30, 10, exponent);
        return @as(u30, @divTrunc(value, factor));
    }

    test convertFractionalSeconds {
        const cases = [_]struct { tag: FormatTag, expected: u30, value: u30 }{
            .{ .tag = .S, .expected = 1, .value = 123456789 },
            .{ .tag = .SS, .expected = 12, .value = 123456789 },
            .{ .tag = .SSS, .expected = 123, .value = 123456789 },
            .{ .tag = .SSSS, .expected = 1234, .value = 123456789 },
            .{ .tag = .SSSSS, .expected = 12345, .value = 123456789 },
            .{ .tag = .SSSSSS, .expected = 123456, .value = 123456789 },
            .{ .tag = .SSSSSSS, .expected = 1234567, .value = 123456789 },
            .{ .tag = .SSSSSSSS, .expected = 12345678, .value = 123456789 },
            .{ .tag = .SSSSSSSSS, .expected = 123456789, .value = 123456789 },
        };
        inline for (cases) |case| {
            try std.testing.expectEqual(case.expected, convertFractionalSeconds(case.tag, case.value));
        }
    }

    /// Splits a format string into `FormatTag` sequences and literal
    /// characters, always taking the longest tag that matches.
    pub const Tokenizer = struct {
        index: usize,
        format_string: []const u8,

        /// What the tokenizer produces: either a recognized sequence or a
        /// run of characters to be copied through as-is.
        ///
        /// A literal is a slice rather than a byte because bracketed text
        /// arrives all at once, and because an escape can produce nothing
        /// at all; see `next`.
        pub const Token = union(enum) {
            literal: []const u8,
            tag: FormatTag,
        };

        /// Creates a tokenizer positioned at the start of `format_string`.
        pub fn init(format_string: []const u8) Tokenizer {
            return .{
                .index = 0,
                .format_string = format_string,
            };
        }

        test init {
            var it: Tokenizer = .init("YYYY");
            try std.testing.expectEqual(FormatTag.YYYY, it.next().?.tag);
            try std.testing.expectEqual(@as(?Token, null), it.next());
        }

        /// Returns the length of the sequence beginning at `index`, or
        /// null when nothing there is one.
        fn tagAt(self: Tokenizer, index: usize) ?FormatTag {
            var found: ?FormatTag = null;
            var length: usize = 0;
            inline for (@typeInfo(FormatTag).@"enum".fields) |field| {
                if (field.name.len > length and
                    index + field.name.len <= self.format_string.len and
                    std.mem.eql(u8, field.name, self.format_string[index..][0..field.name.len]))
                {
                    found = @enumFromInt(field.value);
                    length = field.name.len;
                }
            }
            return found;
        }

        /// Returns the next token, or null when the format string is
        /// exhausted.
        ///
        /// Three things can appear. Text in square brackets is a literal,
        /// which is how a format string writes something that would
        /// otherwise be read as a sequence. A backslash makes a literal of
        /// whatever follows it, sequence or single character. Anything
        /// else is the longest sequence that matches, or one character
        /// passed through when none does.
        ///
        /// The corners are moment.js's, and are followed deliberately
        /// rather than tidied. A `[` with no `]` after it is a literal
        /// bracket rather than an error, and so is a `[` that would have
        /// to nest. A backslash before another backslash yields nothing
        /// at all, because moment strips every backslash out of the run it
        /// matched, and a trailing backslash likewise. See
        /// `tools/oracle.js`, which checks all of it.
        pub fn next(self: *Tokenizer) ?Token {
            if (self.index >= self.format_string.len) return null;

            const rest = self.format_string[self.index..];

            if (rest[0] == '[') {
                // The closing bracket has to come before any second
                // opening one, which is what makes `[a[b]` a literal
                // bracket followed by `a` and then the literal `b`.
                if (std.mem.indexOfAny(u8, rest[1..], "[]")) |offset| {
                    if (rest[1 + offset] == ']') {
                        defer self.index += offset + 2;
                        return .{ .literal = rest[1..][0..offset] };
                    }
                }
                defer self.index += 1;
                return .{ .literal = rest[0..1] };
            }

            if (rest[0] == '\\') {
                // A backslash with nothing after it, and a backslash
                // before another backslash, both come to nothing.
                if (rest.len == 1) {
                    defer self.index += 1;
                    return .{ .literal = rest[0..0] };
                }
                if (rest[1] == '\\') {
                    defer self.index += 2;
                    return .{ .literal = rest[0..0] };
                }

                const length = if (self.tagAt(self.index + 1)) |tag| @tagName(tag).len else 1;
                defer self.index += 1 + length;
                return .{ .literal = rest[1..][0..length] };
            }

            if (self.tagAt(self.index)) |tag| {
                defer self.index += @tagName(tag).len;
                return .{ .tag = tag };
            }

            defer self.index += 1;
            return .{ .literal = rest[0..1] };
        }

        test next {
            // The longest sequence that matches wins, so "MM" is one tag
            // and not two of `M`, while the dash matches nothing and comes
            // back as a literal.
            var it: Tokenizer = .init("MM-D");
            try std.testing.expectEqual(FormatTag.MM, it.next().?.tag);
            try std.testing.expectEqualStrings("-", it.next().?.literal);
            try std.testing.expectEqual(FormatTag.D, it.next().?.tag);
            try std.testing.expectEqual(@as(?Token, null), it.next());

            // Brackets make a literal of what would otherwise be read as
            // a sequence.
            var bracketed: Tokenizer = .init("[Y]YYYY");
            try std.testing.expectEqualStrings("Y", bracketed.next().?.literal);
            try std.testing.expectEqual(FormatTag.YYYY, bracketed.next().?.tag);

            // A bracket that never closes is just a bracket.
            var unclosed: Tokenizer = .init("[MM");
            try std.testing.expectEqualStrings("[", unclosed.next().?.literal);
            try std.testing.expectEqual(FormatTag.MM, unclosed.next().?.tag);

            // A backslash takes the whole sequence after it, not one
            // character of it.
            var escaped: Tokenizer = .init("\\MMD");
            try std.testing.expectEqualStrings("MM", escaped.next().?.literal);
            try std.testing.expectEqual(FormatTag.D, escaped.next().?.tag);
        }
    };
};
