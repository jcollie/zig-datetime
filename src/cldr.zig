// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Formatting with CLDR date patterns, the vocabulary the Unicode
//! Consortium defines in UTS #35 and that ICU, Java, .NET and every
//! `Intl.DateTimeFormat` in a browser are speaking underneath.
//!
//! A pattern is a run of letters, where the letter says which field and
//! how many of it says how that field is written: `y` is the year, `M`
//! the month as a number, `MMM` the month abbreviated, `MMMM` the month
//! spelled out and `MMMMM` the month as a single letter. So
//! `yyyy-MM-dd` is a numeric date and `EEEE, d MMMM y` is a spelled one.
//! Anything that is not a letter is copied through, and text inside
//! single quotes is copied through even if it is: `'at' HH:mm`.
//!
//! That makes it a third vocabulary beside the sequences in
//! `formatsequence`, which moment.js established, and the layouts in
//! `golayout`, which Go did. The three overlap and disagree -- `D` is the
//! day of the month to moment and the day of the year to CLDR, and `Y`
//! is the calendar year to moment and the week-numbering year to CLDR --
//! so they are kept apart rather than merged, and a pattern means here
//! what UTS #35 says it means.
//!
//! What CLDR brings that neither of the others has is that the locale
//! carries its own patterns. A caller that does not want to decide how a
//! date is written asks for a length instead:
//!
//! ```
//! try cldr.formatDateTime(value, .medium, .short, locale, writer);
//! ```
//!
//! and gets `Mar 5, 2024, 2:30 PM` in one language, `5 mars 2024, 14:30`
//! in another and `2024/03/05 14:30` in a third, because `dateFormat`,
//! `timeFormat` and the pattern that joins them are data rather than
//! something this library decided.
//!
//! Two entry points, because CLDR patterns arrive both ways. `format`
//! takes the pattern at comptime, tokenizes it while this is compiled and
//! rejects a pattern that is not a pattern with a compile error;
//! `formatRuntime` takes one that was not known until the program ran,
//! which is what the locale's own patterns are. Both walk the same field
//! writer, so the two cannot drift apart.
//!
//! ICU is the reference implementation of UTS #35 and
//! `tools/oracle_cldr.cpp` checks against it: both sides format the same
//! corpus in every embedded locale and the results are diffed. Where this
//! deliberately differs from ICU it is written down on the piece that
//! differs.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Month = @import("month.zig").Month;
const Year = @import("year.zig").Year;
const cldrlocale = @import("cldrlocale.zig");

/// The locale data a pattern is written against; see `cldrlocale`.
pub const Locale = cldrlocale.Locale;
/// Which of CLDR's two grammatical contexts a name is asked for in.
pub const Context = cldrlocale.Context;
/// How long a name is.
pub const Width = cldrlocale.Width;
/// How long a weekday name is.
pub const WeekdayWidth = cldrlocale.WeekdayWidth;
/// Which of the four lengths of a locale's own pattern is wanted.
pub const Length = cldrlocale.Length;
/// One of the locale's opinions about a combination of fields.
pub const AvailableFormat = cldrlocale.AvailableFormat;
/// The twelve day periods CLDR names.
pub const DayPeriod = cldrlocale.DayPeriod;
/// When one of those periods runs, which `B` is written from.
pub const DayPeriodRule = cldrlocale.DayPeriodRule;
/// English, which is built in whatever the build asked for.
pub const en = cldrlocale.en;
/// Every locale this build carries, sorted by tag.
pub const all = cldrlocale.all;
/// Whether this build carries the generated locales.
pub const embedded = cldrlocale.embedded;
/// The CLDR release the generated locales came from.
pub const cldr_version = cldrlocale.cldr_version;
/// Returns the locale `tag` names, or null when this build lacks it.
pub const byName = cldrlocale.byName;

/// One field of a pattern: which letter it is and how many of it there
/// were.
///
/// The count is not a repetition. `M` and `MM` are the month as one or
/// two digits, `MMM` and `MMMM` and `MMMMM` are three different lengths
/// of its name, and which meanings a letter gives which counts is the
/// whole of UTS #35's table of pattern characters.
pub const Field = struct {
    letter: u8,
    count: u8,
};

/// A pattern is a run of these: text to copy through, or a field to fill
/// in.
pub const Chunk = union(enum) {
    literal: []const u8,
    field: Field,
};

/// What can be wrong with a pattern.
pub const PatternError = error{
    /// A single quote opened a literal that the pattern ended inside of.
    UnterminatedQuote,
    /// A letter that UTS #35 does not give a meaning, or gives one this
    /// library cannot answer. Every ASCII letter is reserved by UTS #35
    /// whether or not it names a field, so an unassigned one is an error
    /// rather than text.
    UnknownField,
    /// A letter that names a field, repeated a number of times that field
    /// has no meaning for: `OO`, or `MMMMMM`.
    InvalidFieldWidth,
};

/// Walks a pattern a chunk at a time.
///
/// Written as a cursor rather than as a function returning a list so that
/// the same code serves both entry points: `tokenize` runs it at comptime
/// to build a list for `format` to unroll, and `formatRuntime` runs it as
/// it writes. A quoted literal is yielded piece by piece rather than as
/// one string, because `''` inside quotes stands for a single quote and
/// the result is therefore not a contiguous slice of the pattern; the
/// pieces are written one after another and nothing downstream can tell.
pub const Scanner = struct {
    pattern: []const u8,
    index: usize = 0,
    /// Whether the cursor is inside a quoted literal, which changes what
    /// every byte means: no letter is a field there and a quote is either
    /// the end of the literal or, doubled, one quote of its own.
    in_quote: bool = false,

    /// Returns the next chunk, or null at the end of the pattern.
    pub fn next(self: *Scanner) PatternError!?Chunk {
        while (true) {
            if (self.index >= self.pattern.len) {
                if (self.in_quote) return error.UnterminatedQuote;
                return null;
            }

            const first = self.pattern[self.index];

            // A doubled quote is one quote, inside a literal or outside
            // it, and does not open or close anything. Checked before
            // either of the single-quote cases below, which is what keeps
            // `'don''t'` one literal rather than two.
            if (first == '\'' and
                self.index + 1 < self.pattern.len and
                self.pattern[self.index + 1] == '\'')
            {
                self.index += 2;
                return .{ .literal = "'" };
            }

            if (self.in_quote) {
                if (first == '\'') {
                    self.index += 1;
                    self.in_quote = false;
                    continue;
                }
                // Text up to the next quote, whatever that quote turns
                // out to mean.
                var at = self.index;
                while (at < self.pattern.len and self.pattern[at] != '\'') at += 1;
                const text = self.pattern[self.index..at];
                self.index = at;
                return .{ .literal = text };
            }

            if (first == '\'') {
                self.index += 1;
                self.in_quote = true;
                continue;
            }

            if (isPatternLetter(first)) {
                var at = self.index;
                while (at < self.pattern.len and self.pattern[at] == first) at += 1;
                const count = at - self.index;
                self.index = at;
                // A run longer than any field could want is still a run,
                // and `check` is what rejects it; saturating keeps the
                // count in a byte without turning a long run into a short
                // one that might be valid.
                const field: Field = .{ .letter = first, .count = @intCast(@min(count, 255)) };
                try check(field);
                return .{ .field = field };
            }

            // Everything else is text, taken as far as the next thing
            // that is not.
            var at = self.index;
            while (at < self.pattern.len and
                self.pattern[at] != '\'' and
                !isPatternLetter(self.pattern[at])) at += 1;
            const text = self.pattern[self.index..at];
            self.index = at;
            return .{ .literal = text };
        }
    }
};

test Scanner {
    // A quoted literal with a doubled quote inside it stays one literal,
    // yielded in pieces: "don", "'", "t".
    var scanner: Scanner = .{ .pattern = "'don''t' H" };
    try std.testing.expectEqualStrings("don", (try scanner.next()).?.literal);
    try std.testing.expectEqualStrings("'", (try scanner.next()).?.literal);
    try std.testing.expectEqualStrings("t", (try scanner.next()).?.literal);
    try std.testing.expectEqualStrings(" ", (try scanner.next()).?.literal);
    try std.testing.expectEqual(@as(u8, 'H'), (try scanner.next()).?.field.letter);
    try std.testing.expectEqual(@as(?Chunk, null), try scanner.next());

    // An empty quoted literal is a single quote, which is the same thing
    // as a doubled quote outside one.
    var empty: Scanner = .{ .pattern = "''" };
    try std.testing.expectEqualStrings("'", (try empty.next()).?.literal);
    try std.testing.expectEqual(@as(?Chunk, null), try empty.next());

    // A literal the pattern ends inside of.
    var unterminated: Scanner = .{ .pattern = "'oops" };
    try std.testing.expectEqualStrings("oops", (try unterminated.next()).?.literal);
    try std.testing.expectError(error.UnterminatedQuote, unterminated.next());
}

/// Whether `byte` is a letter UTS #35 reserves for pattern fields.
///
/// All of A through Z and a through z, whether or not the letter names
/// anything, which is what makes an unassigned letter an error rather
/// than text a caller forgot to quote.
fn isPatternLetter(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z');
}

/// Returns an error when `field` is not one this library writes.
///
/// The counts here are UTS #35's table of pattern characters, narrowed in
/// three places by what a `DateTime` actually knows:
///
///   * `V`, `VV` and `VVV` name a zone -- its short identifier, its long
///     one, and the city it is kept by -- and a `DateTime` carries an
///     offset from UTC rather than a zone. ICU, given a zone that is
///     nothing but an offset, answers `unk` and `Unknown Location`;
///     writing those would be inventing an answer, so they are refused.
///     `VVVV` is allowed because its fallback, the localized GMT format,
///     is something an offset can truthfully say.
///
///   * `j`, `J` and `C` belong to skeletons rather than to patterns: they
///     ask for whichever of the twelve and twenty-four hour clocks the
///     locale prefers, and a skeleton is resolved into a pattern before
///     anything is formatted. ICU writes nothing for them. A field that
///     silently vanishes is worse than one that will not compile, so
///     they are refused here.
///
///   * Counts beyond the ones UTS #35 assigns are refused rather than
///     falling back. ICU writes `MMMMMM` as a six digit month number and
///     `OO` as nothing at all; both are far enough from what the pattern
///     appears to ask for that answering is worse than declining.
pub fn check(field: Field) PatternError!void {
    const count = field.count;
    const ok = switch (field.letter) {
        // Era, and the three year fields. A year takes any count, which
        // is its minimum width, with two meaning the last two digits.
        'G' => count <= 5,
        'y', 'Y', 'u', 'r' => true,
        'U' => count <= 5,

        // Quarter and month, numeric at one and two and named above.
        'Q', 'q', 'M', 'L' => count <= 5,

        // Week of the year and week of the month.
        'w' => count <= 2,
        'W' => count == 1,

        // Day of the month, day of the year, day of the week within the
        // month, and the day number itself.
        'd' => count <= 2,
        'D' => count <= 3,
        'F' => count == 1,
        'g' => true,

        // Weekday, named or numbered.
        'E' => count >= 1 and count <= 6,
        'e', 'c' => count >= 1 and count <= 6,

        // The three ways of naming a part of the day.
        'a', 'b', 'B' => count <= 5,

        // The four clocks, the minute, the second, the fraction, and the
        // milliseconds elapsed in the day.
        'h', 'H', 'K', 'k', 'm', 's', 'S', 'A' => true,

        // Zones. See the note above for the ones that are missing.
        //
        // `z` takes one through three for the short form, all three
        // meaning the same thing, and four for the long one; CLDR's own
        // data writes `zzz`, so the three are not a formality. `v` and
        // `O` have only the two counts.
        'z' => count >= 1 and count <= 4,
        'v' => count == 1 or count == 4,
        'Z' => count <= 5,
        'O' => count == 1 or count == 4,
        'V' => count == 4,
        'X', 'x' => count >= 1 and count <= 5,

        else => return error.UnknownField,
    };
    if (!ok) return error.InvalidFieldWidth;
}

test check {
    try check(.{ .letter = 'M', .count = 4 });
    try check(.{ .letter = 'y', .count = 9 });

    // A letter UTS #35 reserves but does not assign.
    try std.testing.expectError(error.UnknownField, check(.{ .letter = 'P', .count = 1 }));

    // A letter that names a field, at a count it has no meaning for.
    try std.testing.expectError(error.InvalidFieldWidth, check(.{ .letter = 'M', .count = 6 }));
    try std.testing.expectError(error.InvalidFieldWidth, check(.{ .letter = 'O', .count = 2 }));

    // `zzz` is the short zone form, which CLDR's own data writes, where
    // `vvv` is nothing.
    try check(.{ .letter = 'z', .count = 3 });
    try std.testing.expectError(error.InvalidFieldWidth, check(.{ .letter = 'v', .count = 3 }));

    // Skeleton-only letters, which a pattern cannot answer.
    try std.testing.expectError(error.UnknownField, check(.{ .letter = 'j', .count = 1 }));

    // The three zone fields that name a zone rather than an offset.
    try std.testing.expectError(error.InvalidFieldWidth, check(.{ .letter = 'V', .count = 1 }));
    try check(.{ .letter = 'V', .count = 4 });
}

/// Splits `pattern` into chunks at compile time, and refuses one that is
/// not a pattern.
///
/// The error is raised with `@compileError` rather than returned, because
/// a pattern written into the source is a mistake in the source: there is
/// nothing a caller could do with `error.UnknownField` at run time except
/// notice it. `formatRuntime` returns it instead, since a pattern that
/// arrived as data may well be wrong.
pub fn tokenize(comptime pattern: []const u8) []const Chunk {
    comptime {
        @setEvalBranchQuota(100000);

        var chunks: []const Chunk = &.{};
        var scanner: Scanner = .{ .pattern = pattern };
        while (true) {
            const chunk = scanner.next() catch |err| @compileError(switch (err) {
                error.UnterminatedQuote => "CLDR pattern '" ++ pattern ++
                    "' opens a quoted literal that is never closed",
                error.UnknownField => "CLDR pattern '" ++ pattern ++
                    "' uses a letter that names no field; UTS #35 reserves every " ++
                    "ASCII letter, so text that is not a field has to be quoted",
                error.InvalidFieldWidth => "CLDR pattern '" ++ pattern ++
                    "' repeats a field letter a number of times that letter has no meaning for",
            }) orelse break;
            chunks = chunks ++ &[_]Chunk{chunk};
        }
        return chunks;
    }
}

test tokenize {
    const date = comptime tokenize("yyyy-MM-dd");
    try std.testing.expectEqual(@as(usize, 5), date.len);
    try std.testing.expectEqual(@as(u8, 'y'), date[0].field.letter);
    try std.testing.expectEqual(@as(u8, 4), date[0].field.count);
    try std.testing.expectEqualStrings("-", date[1].literal);
    try std.testing.expectEqual(@as(u8, 'M'), date[2].field.letter);

    // A quoted literal keeps letters that would otherwise be fields.
    const quoted = comptime tokenize("'at' H");
    try std.testing.expectEqualStrings("at", quoted[0].literal);
    try std.testing.expectEqualStrings(" ", quoted[1].literal);
    try std.testing.expectEqual(@as(u8, 'H'), quoted[2].field.letter);

    // A doubled quote is one quote, inside a literal or outside it.
    const apostrophe = comptime tokenize("''");
    try std.testing.expectEqual(@as(usize, 1), apostrophe.len);
    try std.testing.expectEqualStrings("'", apostrophe[0].literal);
}

/// Writes `value` under `pattern`, in `locale`.
///
/// The pattern is comptime, so it is taken apart and checked while this is
/// compiled and what is left at run time is a straight line of writes.
/// The field writer itself is an ordinary switch rather than an unrolled
/// one, because `formatRuntime` has to walk the same fields and one
/// implementation that both use cannot drift from itself.
pub fn format(
    value: DateTime,
    comptime pattern: []const u8,
    locale: Locale,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const chunks = comptime tokenize(pattern);
    inline for (chunks) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .field => |field| try writeField(value, field, locale, writer),
    };
}

test format {
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .weekday = .Tue,
        .hour = 14,
        .minute = 30,
        .second = 45,
    };

    var numeric = std.Io.Writer.fixed(&buffer);
    try format(value, "yyyy-MM-dd HH:mm:ss", en, &numeric);
    try std.testing.expectEqualStrings("2024-03-05 14:30:45", numeric.buffered());

    var spelled = std.Io.Writer.fixed(&buffer);
    try format(value, "EEEE, MMMM d, y", en, &spelled);
    try std.testing.expectEqualStrings("Tuesday, March 5, 2024", spelled.buffered());

    // A quoted literal, which is how a letter is written as itself.
    var quoted = std.Io.Writer.fixed(&buffer);
    try format(value, "yyyy-MM-dd'T'HH:mm:ss", en, &quoted);
    try std.testing.expectEqualStrings("2024-03-05T14:30:45", quoted.buffered());
}

/// Writes `value` under a pattern that was not known until now.
///
/// This is what the locale's own patterns go through, and what a pattern
/// read from a configuration file or a message catalogue goes through.
/// It returns the errors `format` raises at compile time, since a pattern
/// that arrived as data can be wrong in a way the program has to survive.
pub fn formatRuntime(
    value: DateTime,
    pattern: []const u8,
    locale: Locale,
    writer: *std.Io.Writer,
) (PatternError || std.Io.Writer.Error)!void {
    var scanner: Scanner = .{ .pattern = pattern };
    while (try scanner.next()) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .field => |field| try writeField(value, field, locale, writer),
    };
}

test formatRuntime {
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .weekday = .Tue };

    var written = std.Io.Writer.fixed(&buffer);
    try formatRuntime(value, "d MMM y", en, &written);
    try std.testing.expectEqualStrings("5 Mar 2024", written.buffered());

    // The same mistakes `format` refuses to compile come back as errors
    // here, because a pattern read from data is allowed to be wrong.
    var discard = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.UnknownField, formatRuntime(value, "yyyy P", en, &discard));
    try std.testing.expectError(error.UnterminatedQuote, formatRuntime(value, "'oops", en, &discard));
}

// ----- Skeletons -----

/// The most letters a skeleton may hold.
///
/// CLDR's own longest is nine (`GyMMMEEEEd`), and a skeleton is written by
/// a program rather than a person, so this is generous rather than tight.
pub const max_skeleton = 32;

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
};

/// A skeleton in the spelling CLDR's own keys use.
///
/// Three normalizations, each of which is a way of writing the same
/// request that would otherwise fail to match the key holding the answer:
///
///   - `j` is the hour on whichever clock the locale prefers, which is
///     the whole reason it exists; `J` is the same without a meridiem and
///     `C` the same allowing one, and all three become `h` or `H` here.
///     They are the only letters `check` refuses that mean something,
///     because they are questions a *pattern* cannot answer and a
///     skeleton can.
///   - `c` and `e` are other spellings of the weekday; a key always
///     writes `E`.
///   - `E`, `EE` and `EEE` are all the abbreviated weekday, and a key
///     always writes one. Left alone, `EEE` matches neither `yMMMEd` nor
///     `yMMMEEEEd`, and the nearest by score is the wide one -- which in
///     Japanese is a different pattern rather than the same one with a
///     longer name in it, `y年M月d日EEEE` against `y年M月d日(E)`. The
///     parentheses would go missing along with the exact match.
///
/// Nothing else is touched: the order of the fields is the caller's, and
/// matching is on the text.
pub fn canonicalSkeleton(
    skeleton: []const u8,
    locale: Locale,
    buffer: *[max_skeleton]u8,
) SkeletonError![]const u8 {
    var length: usize = 0;
    var index: usize = 0;
    while (index < skeleton.len) {
        const letter = skeleton[index];
        if (!std.ascii.isAlphabetic(letter)) return error.NotAField;

        var count: usize = 0;
        while (index + count < skeleton.len and skeleton[index + count] == letter) count += 1;
        index += count;

        var write = letter;
        switch (letter) {
            'j', 'J', 'C' => write = if (locale.prefersTwelveHour()) 'h' else 'H',
            'c', 'e' => write = 'E',
            else => {},
        }
        if (write == 'E' and count <= 3) count = 1;

        if (length + count > buffer.len) return error.SkeletonTooLong;
        @memset(buffer[length..][0..count], write);
        length += count;
    }
    return buffer[0..length];
}

test canonicalSkeleton {
    var buffer: [max_skeleton]u8 = undefined;

    // English prefers the twelve-hour clock, so `j` is `h` there.
    try std.testing.expectEqualStrings("hm", try canonicalSkeleton("jm", en, &buffer));

    // The three spellings of an abbreviated weekday are one spelling.
    try std.testing.expectEqualStrings("yMMMEd", try canonicalSkeleton("yMMMEEEd", en, &buffer));
    try std.testing.expectEqualStrings("yMMMEd", try canonicalSkeleton("yMMMccd", en, &buffer));

    // The wide and narrow weekdays are left as they are.
    try std.testing.expectEqualStrings("yMMMEEEEd", try canonicalSkeleton("yMMMEEEEd", en, &buffer));

    try std.testing.expectError(error.NotAField, canonicalSkeleton("y-M", en, &buffer));
}

/// Finds the locale's pattern for `skeleton`, or the nearest thing to it.
///
/// An exact match is the usual answer, since CLDR lists the combinations
/// people actually ask for. Failing that the best match is scored: having
/// a field at all is most of it, and then how nearly the widths agree --
/// with crossing between a number and a name counted as a far bigger
/// difference than one digit, because it is. Without that, German scores
/// `yMMdd` ("dd.MM.y") and `yMMMd` ("d. MMM y") the same for a request
/// wanting a named month and picks whichever it saw first.
///
/// The skeleton is matched as given; put it through `canonicalSkeleton`
/// first unless it is already in CLDR's spelling.
pub fn matchSkeleton(skeleton: []const u8, locale: Locale) ?AvailableFormat {
    var best: ?AvailableFormat = null;
    var best_score: isize = std.math.minInt(isize);

    for (locale.available_formats) |available| {
        if (std.mem.eql(u8, available.skeleton, skeleton)) return available;

        var score: isize = 0;
        for ("GyYuMLQqwWEecdDFghHKkmsSaBbzZOvVXx") |letter| {
            const wanted = std.mem.count(u8, skeleton, &.{letter});
            const has = std.mem.count(u8, available.skeleton, &.{letter});
            if (wanted == 0 and has == 0) continue;

            if (wanted == 0 or has == 0) {
                score -= 16;
                continue;
            }
            score += 16;

            const wanted_is_text = wanted >= 3;
            const has_is_text = has >= 3;
            if (wanted_is_text != has_is_text) {
                score -= 8;
            } else {
                score -= @intCast(@max(wanted, has) - @min(wanted, has));
            }
        }

        if (score > best_score) {
            best_score = score;
            best = available;
        }
    }

    return best;
}

/// How many of `letter` to write, given what the pattern says and what
/// the request and the matched entry's key say.
///
/// The rule is not "make the pattern match the request", which sounds
/// right and is wrong. For each field: if the request asks for a width
/// the matched entry was *filed under* differently, take the request;
/// otherwise leave the pattern exactly as the locale wrote it. The
/// difference is the entry's declared skeleton rather than the widths in
/// the pattern, and the two disagree on purpose -- Japanese files
/// `y年M月d日` under `yMMMd`, where the key says "abbreviated month" and
/// the pattern writes the numeral, because in Japanese that *is* the
/// abbreviated month. Rewriting its `M` as `MMM` would look the name up
/// and produce "9月月".
fn adjustedCount(
    letter: u8,
    count: usize,
    skeleton: []const u8,
    declared: []const u8,
) usize {
    // `c` and `e` are the weekday under other names, and a key spells it
    // `E`; `L` is the stand-alone month, and a key spells it `M`.
    const field: u8 = switch (letter) {
        'c', 'e' => 'E',
        'L' => 'M',
        else => letter,
    };

    const requested = std.mem.count(u8, skeleton, &.{field});
    if (requested == 0) return count;

    // The era is the one field whose declared width says nothing. Every
    // one of CLDR's `availableFormats` keys spells it with a single `G`,
    // while hundreds of the patterns behind them write `GGGG` or `GGGGG`,
    // so a comparison against the key can never fire and the pattern's own
    // width would always win however wide a one was asked for. Take the
    // request every time, since the key had no opinion to override.
    if (field == 'G') return requested;

    // The month is the one field that is a number at one width and a name
    // at another, and the two are never interchangeable; see above.
    if ((field == 'M') and (count >= 3) != (requested >= 3)) return count;

    const declared_count = std.mem.count(u8, declared, &.{field});
    return if (requested != declared_count) requested else count;
}

/// Writes `value` with the pattern the locale keeps for `skeleton`.
///
/// This is the third way of asking for a date, beside a pattern and one
/// of the locale's four lengths, and it is the one that lets a caller name
/// the fields it wants without deciding how they are arranged: ask for
/// `yMMMd` and English writes "Mar 5, 2024", German "5. März 2024" and
/// Japanese "2024年3月5日", each in the order and with the punctuation
/// that language uses.
///
/// The locale must carry `available_formats`, which none of the generated
/// ones do; see `cldrlocale.AvailableFormat` for why, and supply your own
/// `Locale` or fill the field in on a copy of one of these.
///
/// The matched pattern's field widths are adjusted towards the request
/// where the entry's key and the request disagree, which is what makes a
/// two-digit day out of a locale that files a one-digit one. That is done
/// while writing rather than by building a new pattern, so nothing here
/// needs a buffer to hold one.
pub fn formatSkeleton(
    value: DateTime,
    skeleton: []const u8,
    locale: Locale,
    writer: *std.Io.Writer,
) (SkeletonError || PatternError || std.Io.Writer.Error)!void {
    if (locale.available_formats.len == 0) return error.NoSkeletonData;

    var buffer: [max_skeleton]u8 = undefined;
    const wanted = try canonicalSkeleton(skeleton, locale, &buffer);
    const matched = matchSkeleton(wanted, locale).?;

    var scanner: Scanner = .{ .pattern = matched.pattern };
    while (try scanner.next()) |chunk| switch (chunk) {
        .literal => |text| try writer.writeAll(text),
        .field => |field| {
            const count = adjustedCount(field.letter, field.count, wanted, matched.skeleton);
            const adjusted: Field = .{ .letter = field.letter, .count = @intCast(count) };
            // The widened field has to be a field the library can write:
            // a request for a five-letter era is fine and a five-letter
            // day is not, and `check` is what knows the difference.
            try check(adjusted);
            try writeField(value, adjusted, locale, writer);
        },
    };
}

test formatSkeleton {
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .weekday = .Tue };

    // A locale that carries none says so rather than guessing.
    var none = std.Io.Writer.fixed(&buffer);
    try std.testing.expectError(error.NoSkeletonData, formatSkeleton(value, "yMMMd", en, &none));

    var with = en;
    with.available_formats = &.{
        .{ .skeleton = "yMMMd", .pattern = "MMM d, y" },
        .{ .skeleton = "yMMMEd", .pattern = "E, MMM d, y" },
        .{ .skeleton = "Gy", .pattern = "y GGGGG" },
    };

    var exact = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "yMMMd", with, &exact);
    try std.testing.expectEqualStrings("Mar 5, 2024", exact.buffered());

    // `EEE` is the abbreviated weekday and finds the `E` entry.
    var weekday = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "yMMMEEEd", with, &weekday);
    try std.testing.expectEqualStrings("Tue, Mar 5, 2024", weekday.buffered());

    // The day is widened to what was asked for, because the entry is filed
    // under a one-digit day and the request wants two.
    var padded = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "yMMMdd", with, &padded);
    try std.testing.expectEqualStrings("Mar 05, 2024", padded.buffered());

    // The era takes the request even though the key cannot disagree: the
    // pattern says narrow and a short one was asked for.
    var era = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "Gy", with, &era);
    try std.testing.expectEqualStrings("2024 AD", era.buffered());

    var narrow = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "GGGGGy", with, &narrow);
    try std.testing.expectEqualStrings("2024 A", narrow.buffered());
}

test "a skeleton falls back to the nearest entry the locale has" {
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .weekday = .Tue };

    var locale = en;
    locale.available_formats = &.{
        .{ .skeleton = "yMMMd", .pattern = "MMM d, y" },
        .{ .skeleton = "yMMdd", .pattern = "MM/dd/y" },
    };

    // A long month is nearer the abbreviated entry than the numeric one,
    // because crossing between a name and a number costs more than a
    // letter of width does.
    var written = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "yMMMMd", locale, &written);
    try std.testing.expectEqualStrings("March 5, 2024", written.buffered());
}

test "the month is not widened across the line between a number and a name" {
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5 };

    // Japanese files `y年M月d日` under `yMMMd`: the key calls the month
    // abbreviated and the pattern writes a numeral, because that is what
    // an abbreviated month is in Japanese. Widening the `M` to `MMMM`
    // because a long month was asked for would write the name and produce
    // a month followed by 月月.
    var locale = en;
    locale.available_formats = &.{.{ .skeleton = "yMMMd", .pattern = "y'年'M'月'd'日'" }};

    var written = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(value, "yMMMMd", locale, &written);
    try std.testing.expectEqualStrings("2024年3月5日", written.buffered());
}

test "a skeleton reaches the week-numbering year, and the locale's week rule" {
    var buffer: [64]u8 = undefined;

    // Colognian files the year and month as `Y-MM`, and `Y` is the year the
    // *week* belongs to rather than the calendar year. Germany keeps the
    // ISO rule: weeks begin on Monday and week 1 is the one holding
    // January 4th.
    var locale = en;
    locale.available_formats = &.{.{ .skeleton = "yM", .pattern = "Y-MM" }};
    locale.first_day = .Mon;
    locale.min_days_in_first_week = 4;

    // 2024-12-30 is a Monday, and under that rule it opens week 1 of 2025.
    var turn = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(.{ .year = 2024, .month = .Dec, .day = 30 }, "yM", locale, &turn);
    try std.testing.expectEqualStrings("2025-12", turn.buffered());

    // 2023-01-01 is a Sunday, the last day of week 52 of 2022.
    var back = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(.{ .year = 2023, .month = .Jan, .day = 1 }, "yM", locale, &back);
    try std.testing.expectEqualStrings("2022-01", back.buffered());

    // The rule is read rather than assumed: under the American one, where
    // weeks begin on Sunday and week 1 holds January 1st, that same day
    // falls in week 1 of 2023.
    locale.first_day = .Sun;
    locale.min_days_in_first_week = 1;
    var american = std.Io.Writer.fixed(&buffer);
    try formatSkeleton(.{ .year = 2023, .month = .Jan, .day = 1 }, "yM", locale, &american);
    try std.testing.expectEqualStrings("2023-01", american.buffered());
}

/// Writes `value` as the locale's own date of the given length.
pub fn formatDate(
    value: DateTime,
    length: Length,
    locale: Locale,
    writer: *std.Io.Writer,
) (PatternError || std.Io.Writer.Error)!void {
    try formatRuntime(value, locale.dateFormat(length), locale, writer);
}

/// Writes `value` as the locale's own time of the given length.
pub fn formatTime(
    value: DateTime,
    length: Length,
    locale: Locale,
    writer: *std.Io.Writer,
) (PatternError || std.Io.Writer.Error)!void {
    try formatRuntime(value, locale.timeFormat(length), locale, writer);
}

/// Writes `value` as the locale's own date and time, each of its own
/// length.
///
/// The two are joined by the locale's pattern for a date and a time of
/// day, in which `{1}` stands for the date and `{0}` for the time. That
/// is `dateTimeAtTimeFormat` rather than `dateTimeFormat`: the difference
/// is the word between them, "Tuesday, March 5, 2024 at 2:30 PM" against
/// "Tuesday, March 5, 2024, 2:30 PM", and the first is what this is --
/// a date joined to a particular time of day. It is what ICU joins a date
/// style to a time style with too.
///
/// Which of the four joining patterns is used is chosen by the date's
/// length, which is CLDR's rule: English says "at" after a full or long
/// date and writes a comma after a short one, and that is a property of
/// how much room the date takes rather than of the time.
pub fn formatDateTime(
    value: DateTime,
    date_length: Length,
    time_length: Length,
    locale: Locale,
    writer: *std.Io.Writer,
) (PatternError || std.Io.Writer.Error)!void {
    const glue = locale.dateTimeAtTimeFormat(date_length);

    // The glue is a pattern with two placeholders in it, so its text is
    // quoted the way a pattern quotes text -- English's is `{1} 'at' {0}`
    // and the quotes are what keep `at` from being the day of the year
    // and the meridiem. Walked here rather than substituted into a string
    // and tokenized, which would be the same answer and would need a
    // buffer to hold the result.
    var index: usize = 0;
    var in_quote = false;
    while (index < glue.len) {
        const byte = glue[index];

        if (byte == '\'') {
            if (index + 1 < glue.len and glue[index + 1] == '\'') {
                try writer.writeByte('\'');
                index += 2;
            } else {
                in_quote = !in_quote;
                index += 1;
            }
            continue;
        }

        if (!in_quote and byte == '{' and index + 2 < glue.len and glue[index + 2] == '}') {
            switch (glue[index + 1]) {
                '0' => {
                    try formatTime(value, time_length, locale, writer);
                    index += 3;
                    continue;
                },
                '1' => {
                    try formatDate(value, date_length, locale, writer);
                    index += 3;
                    continue;
                },
                else => {},
            }
        }

        try writer.writeByte(byte);
        index += 1;
    }
}

test formatDateTime {
    var buffer: [128]u8 = undefined;
    const value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .weekday = .Tue,
        .hour = 14,
        .minute = 30,
        .second = 45,
    };

    var short = std.Io.Writer.fixed(&buffer);
    try formatDateTime(value, .short, .short, en, &short);
    try std.testing.expectEqualStrings("3/5/24, 2:30 PM", short.buffered());

    // A full date takes the joining pattern with the word in it, and the
    // quotes around that word are what keep `at` from being read as two
    // fields.
    var full = std.Io.Writer.fixed(&buffer);
    try formatDateTime(value, .full, .medium, en, &full);
    try std.testing.expectEqualStrings("Tuesday, March 5, 2024 at 2:30:45 PM", full.buffered());
}

/// Writes `value` into a buffer of its own, which the caller owns.
///
/// A convenience for the common case of wanting a string rather than a
/// stream; everything it does, a caller can do with an
/// `std.Io.Writer.Allocating` and `format`.
pub fn formatAlloc(
    value: DateTime,
    comptime pattern: []const u8,
    locale: Locale,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    format(value, pattern, locale, &out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    return out.toOwnedSlice();
}

test formatAlloc {
    const value: DateTime = .{ .year = 2024, .month = .Mar, .day = 5, .weekday = .Tue };
    const text = try formatAlloc(value, "y-MM-dd", en, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("2024-03-05", text);
}

/// Writes the one field `field` names.
///
/// This is the whole of UTS #35's table of pattern characters, in the
/// order that table gives them. `check` has already said the pairing of
/// letter and count is one that appears here, so the `else` arms are
/// unreachable rather than permissive.
fn writeField(
    value: DateTime,
    field: Field,
    locale: Locale,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const count = field.count;
    const date: Date = .{ .year = value.year, .month = value.month, .day = value.day };

    switch (field.letter) {
        // ----- Era -----

        // `G` through `GGG` abbreviate it, `GGGG` spells it out, `GGGGG`
        // reduces it to a letter.
        'G' => try writer.writeAll(locale.eraName(value.year, nameWidth(count, 3))),

        // ----- Year -----

        // `y` is the year of the era, so it counts upwards on both sides
        // of the boundary: astronomical year 0 is 1 BC and -1 is 2 BC.
        'y' => try writeYear(writer, locale, eraYear(value.year), count),

        // `Y` is the year the week belongs to, which is not always the
        // calendar year: the last days of December can fall in week 1 of
        // the year after. Written astronomically rather than by era,
        // which is ICU's behaviour and the reason `Y` and `y` can differ
        // by more than a year before the common era.
        'Y' => {
            const week = date.weekOfYear(locale.first_day, @intCast(locale.min_days_in_first_week));
            try writeSignedYear(writer, locale, week.year, count);
        },

        // `u` and `r` are both the astronomical year, counting through
        // zero into the negatives. They differ only for a non-Gregorian
        // calendar, where `r` is the Gregorian year the date falls in and
        // `u` the calendar's own; this library has only the one calendar,
        // so they are the same field written twice.
        'u', 'r' => try writeSignedNumber(writer, locale, value.year, count),

        // `U` is the cyclic year name of a calendar that has one, such as
        // the sixty year cycle of the Chinese calendar. The Gregorian
        // calendar has none, so UTS #35 says to fall back to the year --
        // and ICU falls back to `y` whole, count rule and all, so `UU` is
        // two digits and `UUUU` is padded to four.
        'U' => try writeYear(writer, locale, eraYear(value.year), count),

        // ----- Quarter -----

        // `Q` numbers it, `QQQ` abbreviates it, `QQQQ` spells it out,
        // `QQQQQ` reduces it to a digit of its own. `q` is the same field
        // in the other grammatical context.
        'Q', 'q' => {
            const quarter = value.month.quarter();
            if (count <= 2) {
                try writeNumber(writer, locale, quarter, count);
            } else {
                try writer.writeAll(locale.quarterName(
                    quarter,
                    if (field.letter == 'Q') .format else .stand_alone,
                    nameWidth(count, 3),
                ));
            }
        },

        // ----- Month -----

        // `M` and `MM` number it, `MMM` abbreviates it, `MMMM` spells it
        // out, `MMMMM` reduces it to a letter. `L` is the same field in
        // the stand-alone context, which is what a Slavic language needs
        // to write "март" rather than "марта".
        'M', 'L' => {
            if (count <= 2) {
                try writeNumber(writer, locale, value.month.monthNumber(), count);
            } else {
                try writer.writeAll(locale.monthName(
                    value.month,
                    if (field.letter == 'M') .format else .stand_alone,
                    nameWidth(count, 3),
                ));
            }
        },

        // ----- Week -----

        // The week of the year under the locale's own rule, which is the
        // ISO 8601 one for most of Europe and the Sunday-and-January-1st
        // one for the United States.
        'w' => {
            const week = date.weekOfYear(locale.first_day, @intCast(locale.min_days_in_first_week));
            try writeNumber(writer, locale, week.week, count);
        },

        // The week of the month, by the same rule applied to the month
        // instead of the year.
        'W' => try writeNumber(writer, locale, weekOfMonth(date, locale), 1),

        // ----- Day -----

        'd' => try writeNumber(writer, locale, value.day, count),
        'D' => try writeNumber(writer, locale, dayOfYear(date), count),

        // Which Tuesday of the month this is, counting from one. Not a
        // week number: the 1st through the 7th are always the first
        // whatever-day, however the weeks happen to fall.
        'F' => try writeNumber(writer, locale, (value.day - 1) / 7 + 1, 1),

        // The day number itself, which ICU calls the Julian day: days
        // since noon on the 1st of January 4713 BC, demarcated at local
        // midnight rather than at noon. 2440588 is the day the Unix epoch
        // falls on, which is what turns one count into the other.
        'g' => try writeSignedNumber(writer, locale, @as(i64, date.toDaysSinceStartOfEra()) + 2440588, count),

        // ----- Weekday -----

        // `E` through `EEE` abbreviate it, `EEEE` spells it out, `EEEEE`
        // reduces it to a letter, `EEEEEE` gives the short form that is
        // the shortest still distinct one.
        'E' => try writer.writeAll(locale.weekdayName(value.weekday, .format, weekdayWidth(count, 3))),

        // `e` and `c` are the same names, with two differences: numbered
        // forms at counts one and two, and `c` reading the stand-alone
        // names. The number is local -- it counts from whichever day the
        // locale's week begins on -- where `E` is always a name and
        // nothing is ever the ISO number here.
        //
        // `cc` writes the same unpadded number as `c`, which is ICU's
        // behaviour rather than UTS #35's: the table assigns `c` one
        // numeric form and says nothing about two, and padding a weekday
        // to two digits is not something any locale asks for.
        'e', 'c' => {
            if (count <= 2) {
                const local = localWeekday(value.weekday, locale.first_day);
                try writeNumber(writer, locale, local, if (field.letter == 'e') count else 1);
            } else {
                try writer.writeAll(locale.weekdayName(
                    value.weekday,
                    if (field.letter == 'e') .format else .stand_alone,
                    weekdayWidth(count, 3),
                ));
            }
        },

        // ----- Period of the day -----

        // `a` is the meridiem and nothing else: AM or PM, whatever the
        // hour.
        'a' => try writer.writeAll(locale.dayPeriodName(
            if (value.hour < 12) .am else .pm,
            .format,
            nameWidth(count, 3),
        )),

        // `b` is the meridiem, except that noon has a name of its own
        // where the language gives it one. Which hours count as noon is
        // the locale's rule rather than the twelfth hour by definition:
        // English and French name noon and so write it for the whole of
        // the twelve o'clock hour, while German and Chinese have no noon
        // rule and write the meridiem right through it.
        //
        // Midnight is not named, although CLDR gives most languages a
        // word for it and this carries the word. CLDR deprecated the
        // `midnight` day period -- it is ambiguous about which end of a
        // day it means -- and ICU does not select it, so neither does
        // this. `Locale.dayPeriodName` will still write it for a caller
        // who asks for it by name.
        'b' => {
            const width = nameWidth(count, 3);
            const period = locale.dayPeriodAt(value.hour);
            const named = period == .noon or period == .midnight;
            const name = if (named) locale.dayPeriodName(period.?, .format, width) else "";
            if (name.len > 0) {
                try writer.writeAll(name);
            } else {
                try writer.writeAll(locale.dayPeriodName(
                    if (value.hour < 12) .am else .pm,
                    .format,
                    width,
                ));
            }
        },

        // `B` is the flexible day period: "in the morning", "at night",
        // 下午. Which one an hour falls in is the locale's own rule, and a
        // language CLDR has no rules for, or one that has a rule but no
        // name for what it found, falls back to the meridiem.
        'B' => {
            const width = nameWidth(count, 3);
            const period = locale.dayPeriodAt(value.hour);
            const name = if (period) |each| locale.dayPeriodName(each, .format, width) else "";
            if (name.len > 0) {
                try writer.writeAll(name);
            } else {
                try writer.writeAll(locale.dayPeriodName(
                    if (value.hour < 12) .am else .pm,
                    .format,
                    width,
                ));
            }
        },

        // ----- Hour -----

        // The four clocks UTS #35 distinguishes, which differ only in
        // where they put the zero: `h` runs 1 to 12, `K` runs 0 to 11,
        // `H` runs 0 to 23, and `k` runs 1 to 24.
        'h' => try writeNumber(writer, locale, if (value.hour % 12 == 0) 12 else value.hour % 12, count),
        'K' => try writeNumber(writer, locale, value.hour % 12, count),
        'H' => try writeNumber(writer, locale, value.hour, count),
        'k' => try writeNumber(writer, locale, if (value.hour == 0) 24 else value.hour, count),

        // ----- Minute and second -----

        'm' => try writeNumber(writer, locale, value.minute, count),
        's' => try writeNumber(writer, locale, value.second, count),

        // The fraction of a second, to as many places as the count asks
        // for, truncated rather than rounded.
        //
        // ICU holds milliseconds and pads with zeros past the third
        // place; this holds nanoseconds and writes them, so `SSSSSS` of
        // .123456789 is 123456 here and 123000 there. For any value ICU
        // can represent the two agree, and beyond that the library is not
        // going to lie about a value it has. The same choice, for the same
        // reason, as `formatsequence` makes against moment.js.
        'S' => try writeFraction(writer, locale, value.nanosecond, count),

        // How many milliseconds of the day have elapsed, which is the one
        // field that rolls the whole time of day into a single number.
        'A' => {
            const elapsed = (@as(u64, value.hour) * 3600 + @as(u64, value.minute) * 60 + value.second) * 1000 +
                value.nanosecond / std.time.ns_per_ms;
            try writeNumber(writer, locale, elapsed, count);
        },

        // ----- Zone -----

        // `z` asks for the zone's abbreviation -- CST, AEDT -- and `v`
        // for its name without reference to daylight saving. Both need a
        // zone, and a `DateTime` is a reading and an offset rather than a
        // zone, so both take UTS #35's fallback: the localized GMT
        // format, short at one and long at four. `V` at four is the
        // generic location format, whose fallback is the same.
        //
        // The abbreviation a zone did supply is on the value rather than
        // here, put there by the zone that knew it, and is six bytes
        // stored in the `DateTime` rather than a slice into the zone:
        //
        // ```
        // const local = zone.atTimestamp(1720000000);
        // std.debug.print("{s}\n", .{local.designation.slice()});   // CDT
        // ```
        //
        // It is deliberately not written here. `z` means the zone's name
        // and this does not know the zone; writing an abbreviation into a
        // field whose fallback is defined would make the pattern mean one
        // thing when the value came from a zone and another when it came
        // from a parser.
        'z', 'v', 'V' => try writeLocalizedGmt(writer, locale, value.offset, count < 4),

        // `Z` through `ZZZ` are the RFC 822 offset, `ZZZZ` is the long
        // localized GMT format, and `ZZZZZ` is the ISO 8601 extended one.
        'Z' => switch (count) {
            1, 2, 3 => try writeIsoOffset(writer, value.offset, .{
                .colon = false,
                .minutes = .always,
                .seconds = .when_nonzero,
                .zulu_at_zero = false,
            }),
            4 => try writeLocalizedGmt(writer, locale, value.offset, false),
            else => try writeIsoOffset(writer, value.offset, .{
                .colon = true,
                .minutes = .always,
                .seconds = .when_nonzero,
                .zulu_at_zero = true,
            }),
        },

        // `O` is the localized GMT format asked for by name rather than
        // reached as a fallback.
        'O' => try writeLocalizedGmt(writer, locale, value.offset, count < 4),

        // The ISO 8601 offsets. `X` writes the ISO UTC indicator `Z` when
        // the offset is zero and `x` writes `+00` and its longer
        // spellings instead, which is the only difference between the two
        // letters. The count chooses between the basic and extended
        // spellings and says whether minutes and seconds are written when
        // they are zero.
        //
        // These are never written in the locale's digits. An ISO 8601
        // offset is a fixed syntax rather than a rendering of a number,
        // and ICU agrees: a Persian date carries a Persian month and an
        // ASCII offset.
        'X', 'x' => try writeIsoOffset(writer, value.offset, .{
            .colon = count == 3 or count == 5,
            .minutes = if (count == 1) .when_nonzero else .always,
            .seconds = if (count >= 4) .when_nonzero else .never,
            .zulu_at_zero = field.letter == 'X',
        }),

        else => unreachable,
    }
}

/// Which of the three widths a count asks for, where `named_from` is the
/// count at which the field stops being a number.
///
/// The shape is the same for every named field: the abbreviated name for
/// everything up to and including the first named count, the wide name
/// one past it, the narrow name one past that.
fn nameWidth(count: u8, named_from: u8) Width {
    if (count <= named_from) return .abbreviated;
    return if (count == named_from + 1) .wide else .narrow;
}

test nameWidth {
    // `MMM`, `MMMM`, `MMMMM`.
    try std.testing.expectEqual(Width.abbreviated, nameWidth(3, 3));
    try std.testing.expectEqual(Width.wide, nameWidth(4, 3));
    try std.testing.expectEqual(Width.narrow, nameWidth(5, 3));

    // `G`, `GG` and `GGG` are all the abbreviated era.
    try std.testing.expectEqual(Width.abbreviated, nameWidth(1, 3));
}

/// The same for weekdays, which have a fourth width one past the narrow
/// one.
fn weekdayWidth(count: u8, named_from: u8) WeekdayWidth {
    if (count <= named_from) return .abbreviated;
    return switch (count - named_from) {
        1 => .wide,
        2 => .narrow,
        else => .short,
    };
}

test weekdayWidth {
    try std.testing.expectEqual(WeekdayWidth.abbreviated, weekdayWidth(3, 3));
    try std.testing.expectEqual(WeekdayWidth.wide, weekdayWidth(4, 3));
    try std.testing.expectEqual(WeekdayWidth.narrow, weekdayWidth(5, 3));

    // `EEEEEE`, the one width that is not in the same order as the
    // others: shorter than the narrow name's width but a longer name.
    try std.testing.expectEqual(WeekdayWidth.short, weekdayWidth(6, 3));
}

/// The year of its era, counting upwards on both sides of the boundary.
///
/// `Year` is astronomical -- 0 is 1 BC, -1 is 2 BC -- and `y` is not, so
/// everything at or below zero is reflected. The two have to agree with
/// `Locale.eraName`, which puts the boundary in the same place.
fn eraYear(year: Year) u64 {
    return if (year > 0) @intCast(year) else @intCast(1 - @as(i64, year));
}

test eraYear {
    try std.testing.expectEqual(@as(u64, 2024), eraYear(2024));
    try std.testing.expectEqual(@as(u64, 1), eraYear(1));

    // Astronomical zero is the first year before the common era.
    try std.testing.expectEqual(@as(u64, 1), eraYear(0));
    try std.testing.expectEqual(@as(u64, 2), eraYear(-1));
}

/// The day of the year, 1 through 365 or 366.
fn dayOfYear(date: Date) u16 {
    return @as(u16, date.month.daysBefore(date.year)) + date.day;
}

test dayOfYear {
    try std.testing.expectEqual(@as(u16, 1), dayOfYear(.{ .year = 2024, .month = .Jan, .day = 1 }));
    try std.testing.expectEqual(@as(u16, 65), dayOfYear(.{ .year = 2024, .month = .Mar, .day = 5 }));

    // 2024 was a leap year, so its last day is the 366th.
    try std.testing.expectEqual(@as(u16, 366), dayOfYear(.{ .year = 2024, .month = .Dec, .day = 31 }));
    try std.testing.expectEqual(@as(u16, 365), dayOfYear(.{ .year = 2023, .month = .Dec, .day = 31 }));
}

/// Which day of the locale's week this is, counting from one.
///
/// `d` in the moment vocabulary is always Sunday-based and `E` there is
/// always the ISO number; CLDR has neither, and `e` is local to whichever
/// day the locale starts its week on. A locale whose week begins on
/// Monday numbers Monday 1 and Sunday 7.
fn localWeekday(weekday: DayOfWeek, first_day: DayOfWeek) u8 {
    const from_sunday: u8 = weekday.weekdayNumber();
    const first: u8 = first_day.weekdayNumber();
    return (from_sunday + 7 - first) % 7 + 1;
}

test localWeekday {
    // A week beginning on Sunday numbers Sunday 1 and Tuesday 3.
    try std.testing.expectEqual(@as(u8, 1), localWeekday(.Sun, .Sun));
    try std.testing.expectEqual(@as(u8, 3), localWeekday(.Tue, .Sun));

    // One beginning on Monday numbers Monday 1 and pushes Sunday to 7.
    try std.testing.expectEqual(@as(u8, 1), localWeekday(.Mon, .Mon));
    try std.testing.expectEqual(@as(u8, 2), localWeekday(.Tue, .Mon));
    try std.testing.expectEqual(@as(u8, 7), localWeekday(.Sun, .Mon));
}

/// Which week of its month a date falls in, under the locale's week rule.
///
/// The same rule as the week of the year, applied to a period that starts
/// on the 1st of the month instead of the 1st of January: find which day
/// of the week the period began on, count whole weeks from there, and add
/// one if the days before the first week boundary were enough to make a
/// week of their own by the locale's reckoning. So the 5th of March 2024
/// is in week 2 where the week starts on Sunday and one day is enough,
/// and in week 1 where it starts on Monday and four days are needed.
///
/// This is the formulation in ICU's `Calendar::weekNumber`, followed
/// rather than rederived so that the two cannot disagree; `Date` has no
/// equivalent because nothing but CLDR asks for it.
fn weekOfMonth(date: Date, locale: Locale) u8 {
    const day_of_period: i32 = date.day;
    const day_of_week: i32 = date.dayOfWeek().weekdayNumber();
    const first: i32 = locale.first_day.weekdayNumber();

    // Which day of the week the 1st of the month was, counted from the
    // day the locale's week begins on.
    var period_start = @mod(day_of_week - first - day_of_period + 1, 7);
    if (period_start < 0) period_start += 7;

    var week = @divTrunc(day_of_period + period_start - 1, 7);
    if (7 - period_start >= locale.min_days_in_first_week) week += 1;
    return @intCast(week);
}

test weekOfMonth {
    const fifth_of_march: Date = .{ .year = 2024, .month = .Mar, .day = 5 };

    // English starts its week on Sunday and needs one day, so the 1st and
    // 2nd of March are week 1 and the 3rd begins week 2.
    try std.testing.expectEqual(@as(u8, 2), weekOfMonth(fifth_of_march, en));
    try std.testing.expectEqual(@as(u8, 1), weekOfMonth(.{ .year = 2024, .month = .Mar, .day = 1 }, en));

    // Under the ISO rule the first two days are too few to be a week of
    // their own, so the same date falls in week 1.
    var iso = en;
    iso.first_day = .Mon;
    iso.min_days_in_first_week = 4;
    try std.testing.expectEqual(@as(u8, 1), weekOfMonth(fifth_of_march, iso));
}

/// Writes `n` in the locale's digits, zero padded to at least
/// `min_digits`.
///
/// The digits are part of the locale rather than something done to the
/// output afterwards: a Bengali date is written in Bengali digits, and
/// CLDR says so by giving the locale a default numbering system. Because
/// a digit in such a system is several bytes, the padding is counted in
/// digits and the zero is the system's own zero rather than `'0'`.
fn writeNumber(writer: *std.Io.Writer, locale: Locale, n: u64, min_digits: u8) std.Io.Writer.Error!void {
    // Twenty digits is the most a `u64` can need, and a count asking for
    // more than that is padding, which is written separately.
    var buffer: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{n}) catch unreachable;

    const padding = if (min_digits > text.len) min_digits - text.len else 0;

    if (locale.digits) |digits| {
        for (0..padding) |_| try writer.writeAll(digits[0]);
        for (text) |digit| try writer.writeAll(digits[digit - '0']);
    } else {
        try writer.splatByteAll('0', padding);
        try writer.writeAll(text);
    }
}

test writeNumber {
    var buffer: [32]u8 = undefined;

    var plain = std.Io.Writer.fixed(&buffer);
    try writeNumber(&plain, en, 5, 2);
    try std.testing.expectEqualStrings("05", plain.buffered());

    // The count is a minimum, not a width: a number too long for it is
    // written whole.
    var wide = std.Io.Writer.fixed(&buffer);
    try writeNumber(&wide, en, 2024, 2);
    try std.testing.expectEqualStrings("2024", wide.buffered());

    // A locale with digits of its own uses them, and pads with its own
    // zero.
    const bengali_digits = [10][]const u8{ "০", "১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯" };
    var bengali = en;
    bengali.digits = &bengali_digits;
    var written = std.Io.Writer.fixed(&buffer);
    try writeNumber(&written, bengali, 5, 2);
    try std.testing.expectEqualStrings("০৫", written.buffered());
}

/// Writes a possibly negative number, which is what the astronomical year
/// fields need.
///
/// The sign is an ASCII hyphen. CLDR has a minus sign of its own for
/// numbers in several locales, and ICU does not use it here either: the
/// year fields go through the same path as every other integer field.
fn writeSignedNumber(writer: *std.Io.Writer, locale: Locale, n: i64, min_digits: u8) std.Io.Writer.Error!void {
    if (n < 0) {
        try writer.writeByte('-');
        // Negated in a wider type, because the most negative `i64` has no
        // positive counterpart.
        try writeNumber(writer, locale, @intCast(-@as(i128, n)), min_digits);
    } else {
        try writeNumber(writer, locale, @intCast(n), min_digits);
    }
}

test writeSignedNumber {
    var buffer: [32]u8 = undefined;

    var negative = std.Io.Writer.fixed(&buffer);
    try writeSignedNumber(&negative, en, -90, 4);
    try std.testing.expectEqualStrings("-0090", negative.buffered());

    var positive = std.Io.Writer.fixed(&buffer);
    try writeSignedNumber(&positive, en, 2024, 1);
    try std.testing.expectEqualStrings("2024", positive.buffered());
}

/// Writes a year, where a count of exactly two means the last two digits.
///
/// That is the one place a count is a width rather than a minimum: `yy`
/// of 2024 is `24` and of 5 is `05`, while `yyy` of 5 is `005`. Every
/// other count is the minimum number of digits, so `y` of 2024 is the
/// whole year and `yyyyy` of 2024 is `02024`.
fn writeYear(writer: *std.Io.Writer, locale: Locale, year: u64, count: u8) std.Io.Writer.Error!void {
    if (count == 2) {
        try writeNumber(writer, locale, year % 100, 2);
    } else {
        try writeNumber(writer, locale, year, count);
    }
}

test writeYear {
    var buffer: [32]u8 = undefined;

    var two = std.Io.Writer.fixed(&buffer);
    try writeYear(&two, en, 2024, 2);
    try std.testing.expectEqualStrings("24", two.buffered());

    var four = std.Io.Writer.fixed(&buffer);
    try writeYear(&four, en, 2024, 4);
    try std.testing.expectEqualStrings("2024", four.buffered());

    // Five asks for a minimum of five, which a four digit year pads to.
    var five = std.Io.Writer.fixed(&buffer);
    try writeYear(&five, en, 2024, 5);
    try std.testing.expectEqualStrings("02024", five.buffered());

    // Two is a width, so a single digit year is padded rather than left
    // alone.
    var early = std.Io.Writer.fixed(&buffer);
    try writeYear(&early, en, 5, 2);
    try std.testing.expectEqualStrings("05", early.buffered());
}

/// The same rule applied to a year that may be negative.
fn writeSignedYear(writer: *std.Io.Writer, locale: Locale, year: Year, count: u8) std.Io.Writer.Error!void {
    if (year < 0) {
        try writer.writeByte('-');
        try writeYear(writer, locale, @intCast(-@as(i64, year)), count);
    } else {
        try writeYear(writer, locale, @intCast(year), count);
    }
}

/// Writes the first `count` digits of a fraction of a second.
///
/// The field holds nanoseconds, so there are nine digits to draw on and a
/// count past nine is padded with zeros. Truncated rather than rounded,
/// which is what every other implementation of this field does: `S` of
/// .999 is 9 and not 10.
fn writeFraction(writer: *std.Io.Writer, locale: Locale, nanosecond: u32, count: u8) std.Io.Writer.Error!void {
    var buffer: [9]u8 = undefined;
    _ = std.fmt.bufPrint(&buffer, "{d:0>9}", .{nanosecond}) catch unreachable;

    for (0..count) |place| {
        const digit: u8 = if (place < buffer.len) buffer[place] else '0';
        if (locale.digits) |digits| {
            try writer.writeAll(digits[digit - '0']);
        } else {
            try writer.writeByte(digit);
        }
    }
}

test writeFraction {
    var buffer: [32]u8 = undefined;

    var milli = std.Io.Writer.fixed(&buffer);
    try writeFraction(&milli, en, 123_000_000, 3);
    try std.testing.expectEqualStrings("123", milli.buffered());

    // Truncated, not rounded.
    var one = std.Io.Writer.fixed(&buffer);
    try writeFraction(&one, en, 999_000_000, 1);
    try std.testing.expectEqualStrings("9", one.buffered());

    // Nanoseconds really are written, which is where this parts company
    // with an implementation that holds milliseconds.
    var nano = std.Io.Writer.fixed(&buffer);
    try writeFraction(&nano, en, 123_456_789, 6);
    try std.testing.expectEqualStrings("123456", nano.buffered());

    // Past the ninth place there is nothing left but zeros.
    var over = std.Io.Writer.fixed(&buffer);
    try writeFraction(&over, en, 123_456_789, 11);
    try std.testing.expectEqualStrings("12345678900", over.buffered());
}

/// What an offset written as its own digits looks like: which separators,
/// and which fields are written when they are zero.
const IsoShape = struct {
    /// Whether the fields are separated by colons, which is the difference
    /// between ISO 8601's basic and extended spellings.
    colon: bool,
    /// Whether the minutes are written when they are zero.
    minutes: enum { always, when_nonzero },
    /// Whether the seconds are written at all, and if so whether when
    /// zero. No zone in the IANA database has had a sub-minute offset
    /// since 1972, but plenty had one before that, and an offset that
    /// cannot say so would be wrong about them.
    seconds: enum { never, when_nonzero },
    /// Whether a zero offset is written as the ISO 8601 UTC indicator
    /// rather than as a signed zero. This is the only difference between
    /// the `X` fields and the `x` ones.
    zulu_at_zero: bool,
};

/// Writes `offset` seconds east of UTC in one of ISO 8601's spellings.
///
/// Always in ASCII digits, whatever the locale. An ISO 8601 offset is a
/// fixed syntax rather than a rendering of a number, and a Persian date
/// carries a Persian month beside an ASCII offset in ICU too.
fn writeIsoOffset(writer: *std.Io.Writer, offset: i32, shape: IsoShape) std.Io.Writer.Error!void {
    if (offset == 0 and shape.zulu_at_zero) {
        try writer.writeByte('Z');
        return;
    }

    const magnitude: u32 = @abs(offset);
    const hours = magnitude / 3600;
    const minutes = magnitude % 3600 / 60;
    const seconds = magnitude % 60;

    try writer.writeByte(if (offset < 0) '-' else '+');
    try writer.print("{d:0>2}", .{hours});

    const write_seconds = shape.seconds == .when_nonzero and seconds != 0;
    if (shape.minutes == .always or minutes != 0 or write_seconds) {
        if (shape.colon) try writer.writeByte(':');
        try writer.print("{d:0>2}", .{minutes});
    }
    if (write_seconds) {
        if (shape.colon) try writer.writeByte(':');
        try writer.print("{d:0>2}", .{seconds});
    }
}

test writeIsoOffset {
    var buffer: [32]u8 = undefined;
    const extended: IsoShape = .{
        .colon = true,
        .minutes = .always,
        .seconds = .when_nonzero,
        .zulu_at_zero = true,
    };

    var ordinary = std.Io.Writer.fixed(&buffer);
    try writeIsoOffset(&ordinary, -5 * 3600, extended);
    try std.testing.expectEqualStrings("-05:00", ordinary.buffered());

    var zulu = std.Io.Writer.fixed(&buffer);
    try writeIsoOffset(&zulu, 0, extended);
    try std.testing.expectEqualStrings("Z", zulu.buffered());

    // America/Chicago's local mean time, which is the kind of offset the
    // seconds field is for.
    var lmt = std.Io.Writer.fixed(&buffer);
    try writeIsoOffset(&lmt, -21036, extended);
    try std.testing.expectEqualStrings("-05:50:36", lmt.buffered());

    // The shortest spelling, which drops the minutes when they are zero
    // and never writes seconds at all.
    const shortest: IsoShape = .{
        .colon = false,
        .minutes = .when_nonzero,
        .seconds = .never,
        .zulu_at_zero = true,
    };
    var hours_only = std.Io.Writer.fixed(&buffer);
    try writeIsoOffset(&hours_only, -5 * 3600, shortest);
    try std.testing.expectEqualStrings("-05", hours_only.buffered());

    var with_minutes = std.Io.Writer.fixed(&buffer);
    try writeIsoOffset(&with_minutes, -21036, shortest);
    try std.testing.expectEqualStrings("-0550", with_minutes.buffered());
}

/// The pieces of a locale's `hourFormat`, which is a miniature pattern
/// rather than a string to substitute into.
///
/// Every locale's is the same shape -- a sign, an hour field, a separator
/// and a minute field -- but none of the four pieces is the same in all of
/// them: the sign may be a hyphen, a real minus sign, an en dash, or any
/// of those behind a bidirectional mark; the hour may be `H` or `HH`; and
/// the separator may be a colon, a full stop, or nothing.
const HourPattern = struct {
    /// Everything before the hour field, which is the sign.
    prefix: []const u8,
    /// How many digits the hour field asks for.
    ///
    /// Read out of the pattern and then not used, because ICU does not
    /// use it either: the long form pads the hour to two digits and the
    /// short one writes it unpadded, whatever the pattern said. Czech's
    /// is `+H:mm` and its long form is still `GMT+05:00`. It is parsed
    /// anyway because it is what separates the prefix from the separator.
    hour_digits: u8,
    /// Everything between the hour field and the minute field.
    separator: []const u8,
    /// Everything after the minute field, which is nothing in any locale
    /// CLDR ships but is carried rather than assumed away.
    suffix: []const u8,
};

/// Reads a locale's `hourFormat` into its pieces.
///
/// A pattern that is not the expected shape falls back to the ISO
/// spelling rather than being refused, because the alternative is a
/// locale that cannot write an offset at all: this is data from a file,
/// and the field that is wrong is the one least worth failing over.
fn parseHourPattern(pattern: []const u8) HourPattern {
    const hour_at = std.mem.findScalar(u8, pattern, 'H') orelse return .{
        .prefix = "+",
        .hour_digits = 2,
        .separator = ":",
        .suffix = "",
    };

    var after_hour = hour_at;
    while (after_hour < pattern.len and pattern[after_hour] == 'H') after_hour += 1;

    const minute_at = std.mem.findScalarPos(u8, pattern, after_hour, 'm') orelse pattern.len;
    var after_minute = minute_at;
    while (after_minute < pattern.len and pattern[after_minute] == 'm') after_minute += 1;

    return .{
        .prefix = pattern[0..hour_at],
        .hour_digits = @intCast(after_hour - hour_at),
        .separator = pattern[after_hour..minute_at],
        .suffix = pattern[after_minute..],
    };
}

test parseHourPattern {
    const ordinary = parseHourPattern("+HH:mm");
    try std.testing.expectEqualStrings("+", ordinary.prefix);
    try std.testing.expectEqual(@as(u8, 2), ordinary.hour_digits);
    try std.testing.expectEqualStrings(":", ordinary.separator);

    // Indonesian separates with a full stop, Amharic with nothing, and
    // French's sign is a real minus rather than a hyphen.
    try std.testing.expectEqualStrings(".", parseHourPattern("-HH.mm").separator);
    try std.testing.expectEqualStrings("", parseHourPattern("+HHmm").separator);
    try std.testing.expectEqualStrings("−", parseHourPattern("−HH:mm").prefix);

    // A single `H` asks for an unpadded hour even in the long form.
    try std.testing.expectEqual(@as(u8, 1), parseHourPattern("+H:mm").hour_digits);
}

/// Writes `offset` in the locale's own way of saying "so far from
/// Greenwich".
///
/// This is UTS #35's localized GMT format, and it is the fallback every
/// zone field lands on when there is no zone to name. The offset goes
/// through the locale's `hourFormat`, and the result goes inside its
/// `gmtFormat`, so English gets `GMT-05:00`, French `UTC−05:00` and
/// Persian `‎−۰۵:۰۰ گرینویچ`.
///
/// The short form is not a separate pattern but the long one with two
/// things taken out: the hour loses its padding, and the minutes are
/// dropped when there is nothing in them. So `GMT-05:00` becomes `GMT-5`,
/// while `GMT+01:30` becomes `GMT+1:30` because there is something to
/// keep. Seconds are written in either form when the offset has them,
/// after a second copy of the separator, since no locale's `hourFormat`
/// mentions seconds and there is nowhere else to take the spelling from.
///
/// A zero offset is written as a signed zero -- `GMT+0`, `GMT+00:00` --
/// and not as the locale's `gmtZeroFormat`. UTS #35 reads as though the
/// zero format belongs here, and ICU does not use it in any pattern
/// field: given a zone that is nothing but a zero offset it writes the
/// sign and the digits. ICU is the reference implementation and is what
/// `tools/oracle_cldr.cpp` holds this to, so the zero format is carried
/// on the `Locale` for a caller that wants it and is not written here.
fn writeLocalizedGmt(
    writer: *std.Io.Writer,
    locale: Locale,
    offset: i32,
    short: bool,
) std.Io.Writer.Error!void {
    const hour_pattern = parseHourPattern(
        if (offset < 0) locale.hour_format_negative else locale.hour_format_positive,
    );

    const magnitude: u32 = @abs(offset);
    const hours = magnitude / 3600;
    const minutes = magnitude % 3600 / 60;
    const seconds = magnitude % 60;

    // `gmtFormat` is the one place CLDR does use a placeholder rather than
    // a pattern, so the offset is written between the two halves of it.
    const split = std.mem.find(u8, locale.gmt_format, "{0}") orelse locale.gmt_format.len;
    try writer.writeAll(locale.gmt_format[0..split]);

    try writer.writeAll(hour_pattern.prefix);
    try writeNumber(writer, locale, hours, if (short) 1 else 2);

    // The short form of a whole number of hours stops at the hour, and
    // stops completely: no separator, no minutes, and none of whatever
    // followed the minutes in the locale's pattern. That last part
    // matters for Hebrew, whose pattern ends in a bidirectional mark, and
    // is what ICU does because it derives its hour-only pattern by
    // truncating the hour-and-minute one after the hour field rather than
    // by leaving pieces out of it.
    if (!short or minutes != 0 or seconds != 0) {
        try writer.writeAll(hour_pattern.separator);
        try writeNumber(writer, locale, minutes, 2);
        if (seconds != 0) {
            try writer.writeAll(hour_pattern.separator);
            try writeNumber(writer, locale, seconds, 2);
        }
        try writer.writeAll(hour_pattern.suffix);
    }

    if (split < locale.gmt_format.len) {
        try writer.writeAll(locale.gmt_format[split + 3 ..]);
    }
}

test writeLocalizedGmt {
    var buffer: [64]u8 = undefined;

    var long = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&long, en, -5 * 3600, false);
    try std.testing.expectEqualStrings("GMT-05:00", long.buffered());

    // The short form drops the padding and the empty minutes.
    var short = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&short, en, -5 * 3600, true);
    try std.testing.expectEqualStrings("GMT-5", short.buffered());

    // And keeps the minutes when there is something in them.
    var half = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&half, en, 5400, true);
    try std.testing.expectEqualStrings("GMT+1:30", half.buffered());

    // A sub-minute offset writes its seconds after a second separator.
    var lmt = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&lmt, en, -21036, false);
    try std.testing.expectEqualStrings("GMT-05:50:36", lmt.buffered());

    // Zero is a signed zero rather than the locale's zero format, which
    // is what ICU writes for a zone that is nothing but an offset.
    var zero = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&zero, en, 0, false);
    try std.testing.expectEqualStrings("GMT+00:00", zero.buffered());

    var zero_short = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&zero_short, en, 0, true);
    try std.testing.expectEqualStrings("GMT+0", zero_short.buffered());

    // A pattern asking for an unpadded hour does not get one in the long
    // form, which pads to two whatever the pattern said.
    var czech = en;
    czech.hour_format_positive = "+H:mm";
    czech.hour_format_negative = "-H:mm";
    var padded = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&padded, czech, -5 * 3600, false);
    try std.testing.expectEqualStrings("GMT-05:00", padded.buffered());

    // A locale whose wrapper puts the name after the offset, and whose
    // sign is not a hyphen.
    var french = en;
    french.gmt_format = "UTC{0}";
    french.gmt_zero_format = "UTC";
    french.hour_format_negative = "−HH:mm";
    var wrapped = std.Io.Writer.fixed(&buffer);
    try writeLocalizedGmt(&wrapped, french, -5 * 3600, false);
    try std.testing.expectEqualStrings("UTC−05:00", wrapped.buffered());
}

test "fractional seconds keep the precision the value has" {
    // The one place this deliberately writes something ICU cannot, and so
    // the one place `tools/oracle_cldr.cpp` cannot check: ICU holds
    // milliseconds and pads with zeros past the third place, where this
    // holds nanoseconds and writes them. For any value ICU can represent
    // the two agree, which is why the oracle's corpus stops at the
    // millisecond; beyond that the library is not going to lie about a
    // value it has. The same choice, for the same reason, as
    // `formatsequence` makes against moment.js.
    var buffer: [64]u8 = undefined;
    const value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .weekday = .Tue,
        .hour = 14,
        .minute = 30,
        .second = 45,
        .nanosecond = 123_456_789,
    };

    var written = std.Io.Writer.fixed(&buffer);
    try format(value, "HH:mm:ss.SSSSSSSSS", en, &written);
    try std.testing.expectEqualStrings("14:30:45.123456789", written.buffered());

    // What ICU would write for the same value, since it has only the
    // first three digits: 123000000.
    var milli = std.Io.Writer.fixed(&buffer);
    try format(value, "HH:mm:ss.SSS", en, &milli);
    try std.testing.expectEqualStrings("14:30:45.123", milli.buffered());
}

test "every embedded locale's own patterns are patterns" {
    // A locale's twelve patterns come out of CLDR and go straight into
    // `formatRuntime`, so a field this library refuses that CLDR's own
    // data uses would be an error at run time in a locale nobody tried.
    // `zig build oracle-cldr` would catch it too, but only on a machine
    // with ICU, and this is the kind of thing that should fail in the
    // ordinary test run.
    var buffer: [512]u8 = undefined;
    const value: DateTime = .{
        .year = 2024,
        .month = .Mar,
        .day = 5,
        .weekday = .Tue,
        .hour = 14,
        .minute = 30,
        .second = 45,
        .offset = -5 * 3600,
    };

    for (all) |locale| {
        for ([_]Length{ .full, .long, .medium, .short }) |length| {
            var date = std.Io.Writer.fixed(&buffer);
            formatDate(value, length, locale, &date) catch |err| {
                std.debug.print("{s} date {t}: {t}\n", .{ locale.tag, length, err });
                return error.TestUnexpectedResult;
            };

            var time = std.Io.Writer.fixed(&buffer);
            formatTime(value, length, locale, &time) catch |err| {
                std.debug.print("{s} time {t}: {t}\n", .{ locale.tag, length, err });
                return error.TestUnexpectedResult;
            };

            var both = std.Io.Writer.fixed(&buffer);
            formatDateTime(value, length, length, locale, &both) catch |err| {
                std.debug.print("{s} date and time {t}: {t}\n", .{ locale.tag, length, err });
                return error.TestUnexpectedResult;
            };

            try std.testing.expect(both.buffered().len >= date.buffered().len);
        }
    }
}
