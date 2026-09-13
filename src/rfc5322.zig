// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Parsing of the `date-time` of RFC 5322 section 3.3, which is what an
//! internet message writes in its `Date:` header.
//!
//! The grammar accepted here is the current one, with the obsolete
//! productions of section 4.3 left out:
//!
//!     date-time   = [ day-name "," ] day month year
//!                   hour ":" minute [ ":" second ] zone [CFWS]
//!     day         = 1*2DIGIT
//!     year        = 4*DIGIT
//!     hour        = 2DIGIT
//!     minute      = 2DIGIT
//!     second      = 2DIGIT
//!     zone        = ( "+" / "-" ) 4DIGIT
//!
//! so `Fri, 21 Nov 1997 09:55:06 -0600` parses and `20 Jun 82 12:34 EST`
//! does not. That second one is two obsolete forms at once -- a two digit
//! year and an alphabetic zone -- and `rfc822` is the parser that reads
//! them. The division between the two modules is between forms that
//! change what a date *means* and forms that do not: a two digit year has
//! to be guessed at a century and an alphabetic zone is ambiguous between
//! the handful RFC 822 named and the hundreds in use, so refusing them is
//! what a strict parser is for. A caller that wants the lenient reading
//! can fall back to `rfc822.parse` on `error.ParseError`; where both
//! accept an input they agree about what it says.
//!
//! Two things this does that `rfc822` does not:
//!
//!   * **Comments and folding.** RFC 5322 lets a `CFWS` stand wherever
//!     the grammar has whitespace, so `Thu, 13 (the thirteenth) Feb 1969
//!     23:32:54 -0330 (Newfoundland)` is one date with two comments in
//!     it. Comments nest, they may contain `\`-escaped characters, and a
//!     header that was folded across lines carries `CRLF` followed by
//!     whitespace in the middle of them. All of that is consumed and
//!     discarded; see `Cursor.cfws`.
//!
//!   * **The unknown offset.** Section 3.3 gives `-0000` a meaning
//!     `+0000` does not have: the time is UTC, but it was written by
//!     something that would not say what local zone it was in, so the
//!     date carries no zone information at all. Both leave
//!     `DateTime.offset` zero, so the distinction is reported separately
//!     as `ParseResult.unknown_offset`.
//!
//! As section 3.3 requires, a date must be semantically valid as well as
//! well formed: a day name that disagrees with the date it precedes is
//! `error.ParseError`, and so is a day past the end of its month.

const std = @import("std");

const DateTime = @import("DateTime.zig");
const Day = @import("day.zig").Day;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Month = @import("month.zig").Month;
const Second = @import("second.zig").Second;
const Year = @import("year.zig").Year;

/// What `parse` can fail with. As in `rfc822`, the grammar has no failure
/// worth telling apart from any other, so there is only the one error.
pub const ParseError = error{ParseError};

/// The result of a successful parse: the prefix of the input that was
/// consumed, the value it parsed to, and what the zone said about itself.
pub const ParseResult = struct {
    /// The text `parse` consumed, which is a prefix of what it was given.
    /// The trailing `[CFWS]` is part of `date-time`, so a comment after
    /// the zone is inside this rather than left over -- which is the one
    /// place `rfc822.parse` and this disagree about where a date ends.
    str: []const u8,
    /// The local wall-clock time exactly as written, with its offset from
    /// UTC in `DateTime.offset`. `value.toUtc()` converts it.
    value: DateTime,
    /// Whether the zone was written `-0000`, which RFC 5322 section 3.3
    /// defines as "UTC, and the sender declined to say what its own zone
    /// was". `DateTime.offset` is zero either way, so this is the only
    /// thing that tells such a date from one that said `+0000`.
    unknown_offset: bool,
};

/// Parses an RFC 5322 `date-time` at the start of `value`.
///
/// Leading whitespace and comments are skipped, so a header value may be
/// passed in without trimming it first; the grammar puts an optional
/// `CFWS` in front of both the day name and the day of the month, and
/// this is that. Text after the date's trailing `CFWS` is left
/// unconsumed, and `ParseResult.str` is where it ends.
///
/// The parse is a single left-to-right pass with no backtracking but one:
/// a trailing comment that is never closed is not a `CFWS`, so the
/// optional group at the end does not match it, and the cursor goes back
/// to before the `(` rather than failing a date that was already
/// complete.
pub fn parse(value: []const u8) ParseError!ParseResult {
    var cursor: Cursor = .{ .text = value };

    // Both openings of the grammar begin with an optional CFWS -- one
    // before `day-name` and one before `day` -- so whichever of them is
    // coming, this is its leading whitespace.
    _ = try cursor.cfws();

    // [ day-name "," ]. No day name begins with a digit, so a leading
    // name is never ambiguous with the day of the month. The comma
    // belongs to `date-time` rather than to `day-of-week` and is not
    // optional; leaving it out is `obs-day-of-week`.
    const day_of_week: ?DayOfWeek = day_of_week: {
        const result = DayOfWeek.parseShortStr(cursor.rest()) catch break :day_of_week null;
        cursor.index += result.str.len;
        try cursor.literal(',');
        _ = try cursor.cfws();
        break :day_of_week result.value;
    };

    // date = day month year
    const day: Day = day: {
        const parsed = try cursor.digits(1, 2);
        // Checked before narrowing, because two digits reach 99 and `Day`
        // is six bits wide: an `@intCast` of 99 into it is a panic rather
        // than something a later range check could catch.
        if (parsed.value < 1 or parsed.value > 31) return error.ParseError;
        break :day @intCast(parsed.value);
    };
    try cursor.requiredCfws();

    // Month names are exactly the three letter abbreviations, which is
    // the whole of `short_map`'s key set, so the lookup is one probe at a
    // fixed width rather than a search over prefixes.
    const month: Month = month: {
        const rest = cursor.rest();
        if (rest.len < 3) return error.ParseError;
        break :month Month.short_map.get(rest[0..3]) orelse return error.ParseError;
    };
    cursor.index += 3;
    try cursor.requiredCfws();

    // `4*DIGIT` has no upper bound, so the cap is what `Year` can hold:
    // nine digits fit an `i32` and ten do not. A tenth digit is refused
    // outright rather than left behind to fail somewhere less legible.
    const year: Year = year: {
        const parsed = try cursor.digits(4, 9);
        if (cursor.atDigit()) return error.ParseError;
        break :year @intCast(parsed.value);
    };

    if (day > month.lastDay(year)) return error.ParseError;
    try cursor.requiredCfws();

    // time = time-of-day zone, where every field of the time-of-day is
    // exactly two digits and nothing may come between them and their
    // colons. A third digit needs no check of its own: it is not a colon,
    // so the separator that follows fails on it.
    const hour: Hour = hour: {
        const parsed = try cursor.digits(2, 2);
        if (parsed.value > 23) return error.ParseError;
        break :hour @intCast(parsed.value);
    };
    try cursor.literal(':');

    const minute: Minute = minute: {
        const parsed = try cursor.digits(2, 2);
        if (parsed.value > 59) return error.ParseError;
        break :minute @intCast(parsed.value);
    };

    const second: Second = second: {
        if (!cursor.eat(':')) break :second 0;
        // Section 3.3 gives the range as 00:00:00 through 23:59:60, so 60
        // is allowed and a leap second parses.
        const parsed = try cursor.digits(2, 2);
        if (parsed.value > 60) return error.ParseError;
        break :second @intCast(parsed.value);
    };
    try cursor.requiredCfws();

    const zone = try cursor.zone();

    // date-time ends with an optional CFWS, so a trailing comment is part
    // of the date. An unterminated one is not a CFWS, and the optional
    // group simply does not match: the cursor is put back and the text is
    // left to the caller rather than failing a complete date.
    const before_trailing = cursor.index;
    _ = cursor.cfws() catch {
        cursor.index = before_trailing;
    };

    var datetime: DateTime = .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .nanosecond = 0,
        .weekday = .Thu,
        .offset = zone.offset,
    };
    datetime.updateDayOfWeek();

    // Section 3.3: the day of the week, when it is there, must be the one
    // the date implies. A date that disagrees with itself is rejected
    // rather than having one half of it believed over the other.
    if (day_of_week) |expected| {
        if (datetime.weekday != expected) return error.ParseError;
    }

    return .{
        .str = value[0..cursor.index],
        .value = datetime,
        .unknown_offset = zone.unknown,
    };
}

/// A run of digits: its value and how many of them there were.
const Digits = struct {
    value: u32,
    len: usize,
};

/// A parsed `zone`, which is an offset plus the one thing an offset
/// cannot carry.
const Zone = struct {
    /// Seconds east of UTC.
    offset: i32,
    /// Whether the text was `-0000` rather than `+0000`; see
    /// `ParseResult.unknown_offset`.
    unknown: bool,
};

/// A position in the text being parsed.
///
/// The position is an index rather than a shrinking slice, so that
/// advancing is an addition to one integer instead of rebuilding a
/// pointer and a length each time.
const Cursor = struct {
    text: []const u8,
    index: usize = 0,

    /// The text from the cursor onwards.
    fn rest(self: Cursor) []const u8 {
        return self.text[self.index..];
    }

    test rest {
        var cursor: Cursor = .{ .text = "21 Nov 1997" };
        try std.testing.expectEqualStrings("21 Nov 1997", cursor.rest());

        cursor.index = 3;
        try std.testing.expectEqualStrings("Nov 1997", cursor.rest());
    }

    /// Whether the input is exhausted.
    fn done(self: Cursor) bool {
        return self.index >= self.text.len;
    }

    test done {
        var cursor: Cursor = .{ .text = "-" };
        try std.testing.expect(!cursor.done());

        cursor.index = 1;
        try std.testing.expect(cursor.done());
    }

    /// The character at the cursor. The caller must have checked `done`.
    fn peek(self: Cursor) u8 {
        return self.text[self.index];
    }

    test peek {
        const cursor: Cursor = .{ .text = "-0600" };
        try std.testing.expectEqual(@as(u8, '-'), cursor.peek());
    }

    /// The character `ahead` positions along, or null if the input ends
    /// first. Folding needs this: a `CRLF` is only whitespace when a
    /// space or tab follows it, which cannot be decided from the `CR`.
    fn peekAt(self: Cursor, ahead: usize) ?u8 {
        const at = self.index + ahead;
        if (at >= self.text.len) return null;
        return self.text[at];
    }

    test peekAt {
        const cursor: Cursor = .{ .text = "\r\n " };
        try std.testing.expectEqual(@as(?u8, '\r'), cursor.peekAt(0));
        try std.testing.expectEqual(@as(?u8, ' '), cursor.peekAt(2));

        // Past the end is null rather than an error, so a lookahead near
        // the end of the input needs no length check of its own.
        try std.testing.expectEqual(@as(?u8, null), cursor.peekAt(3));
    }

    /// Whether a digit is next. Used to refuse a run of digits longer
    /// than the field it was read into.
    fn atDigit(self: Cursor) bool {
        return !self.done() and std.ascii.isDigit(self.peek());
    }

    test atDigit {
        var cursor: Cursor = .{ .text = "12x" };
        try std.testing.expect(cursor.atDigit());

        cursor.index = 2;
        try std.testing.expect(!cursor.atDigit());

        cursor.index = 3;
        try std.testing.expect(!cursor.atDigit());
    }

    /// Consumes `char` if it is next, and reports whether it was.
    fn eat(self: *Cursor, char: u8) bool {
        if (self.done() or self.peek() != char) return false;
        self.index += 1;
        return true;
    }

    test eat {
        // The seconds are optional, so their colon is tried rather than
        // required, and a refusal costs the caller nothing.
        var cursor: Cursor = .{ .text = ":06 -0600" };
        try std.testing.expect(cursor.eat(':'));
        try std.testing.expectEqual(@as(usize, 1), cursor.index);

        try std.testing.expect(!cursor.eat(':'));
        try std.testing.expectEqual(@as(usize, 1), cursor.index);
    }

    /// Consumes `char`, which must be next.
    fn literal(self: *Cursor, char: u8) ParseError!void {
        if (!self.eat(char)) return error.ParseError;
    }

    test literal {
        // The comma after the day name is not optional in RFC 5322; only
        // `obs-day-of-week` leaves it out.
        var cursor: Cursor = .{ .text = ", 21 Nov" };
        try cursor.literal(',');
        try std.testing.expectEqual(@as(usize, 1), cursor.index);

        try std.testing.expectError(error.ParseError, cursor.literal(','));
    }

    /// Consumes any run of spaces and tabs, reporting whether there was
    /// one. This is `*WSP`, the part of folding whitespace that does not
    /// involve a line break.
    fn wsp(self: *Cursor) bool {
        const before = self.index;
        while (!self.done() and (self.peek() == ' ' or self.peek() == '\t')) self.index += 1;
        return self.index > before;
    }

    test wsp {
        var cursor: Cursor = .{ .text = "  \tNov" };
        try std.testing.expect(cursor.wsp());
        try std.testing.expectEqualStrings("Nov", cursor.rest());

        // Finding none is not a failure here, only a false.
        try std.testing.expect(!cursor.wsp());
        try std.testing.expectEqualStrings("Nov", cursor.rest());
    }

    /// Consumes one `FWS` -- folding whitespace -- and reports whether
    /// there was one.
    ///
    /// `FWS` is `[*WSP CRLF] 1*WSP`: a run of spaces and tabs, which may
    /// have a single line break folded into it so long as whitespace
    /// resumes on the next line. The lookahead past the `CRLF` is what
    /// makes that work, and it is why a bare `CRLF` at the end of a
    /// header is not whitespace: nothing continues it, so the run stops
    /// in front of it and whatever wanted a separator there fails.
    fn fws(self: *Cursor) bool {
        const before = self.index;

        _ = self.wsp();
        if (!self.done() and self.peek() == '\r' and
            self.peekAt(1) == '\n' and
            (self.peekAt(2) == ' ' or self.peekAt(2) == '\t'))
        {
            self.index += 2;
            _ = self.wsp();
        }

        return self.index > before;
    }

    test fws {
        // Without a line break it is just the run of spaces and tabs.
        var plain: Cursor = .{ .text = " \t Nov" };
        try std.testing.expect(plain.fws());
        try std.testing.expectEqualStrings("Nov", plain.rest());

        // A header folded across two lines: the break and the whitespace
        // on either side of it are one separator.
        var folded: Cursor = .{ .text = "\r\n\tNov" };
        try std.testing.expect(folded.fws());
        try std.testing.expectEqualStrings("Nov", folded.rest());

        var both: Cursor = .{ .text = "  \r\n   Nov" };
        try std.testing.expect(both.fws());
        try std.testing.expectEqualStrings("Nov", both.rest());

        // A line break that nothing continues is not folding whitespace.
        // The spaces in front of it still are, so the cursor stops
        // exactly at the CR.
        var unfolded: Cursor = .{ .text = "  \r\nNov" };
        try std.testing.expect(unfolded.fws());
        try std.testing.expectEqualStrings("\r\nNov", unfolded.rest());

        var none: Cursor = .{ .text = "Nov" };
        try std.testing.expect(!none.fws());
    }

    /// Consumes one `comment` -- a parenthesised aside -- and reports
    /// whether there was one. An unterminated comment is
    /// `error.ParseError`.
    ///
    /// Comments nest, so this counts depth rather than recursing: input
    /// here is untrusted by construction, and a thousand opening
    /// parentheses would be a thousand stack frames. Inside, `\` quotes
    /// the character after it -- which is how a comment holds a
    /// parenthesis of its own -- and folding whitespace is allowed
    /// between the pieces, so a comment may itself be folded across
    /// lines.
    ///
    /// Nothing is kept. A comment carries no part of the date's value, so
    /// reading one is only a matter of finding where it ends.
    fn comment(self: *Cursor) ParseError!bool {
        if (!self.eat('(')) return false;

        var depth: usize = 1;
        while (depth > 0) {
            if (self.done()) return error.ParseError;

            switch (self.peek()) {
                '(' => {
                    depth += 1;
                    self.index += 1;
                },
                ')' => {
                    depth -= 1;
                    self.index += 1;
                },
                // quoted-pair: a backslash and the visible character or
                // whitespace it quotes, which is the only way a comment
                // can hold a bare parenthesis or backslash.
                '\\' => {
                    const quoted = self.peekAt(1) orelse return error.ParseError;
                    if (!isVchar(quoted) and quoted != ' ' and quoted != '\t') return error.ParseError;
                    self.index += 2;
                },
                ' ', '\t', '\r' => if (!self.fws()) return error.ParseError,
                else => |char| {
                    if (!isCtext(char)) return error.ParseError;
                    self.index += 1;
                },
            }
        }

        return true;
    }

    test comment {
        var simple: Cursor = .{ .text = "(Newfoundland Time) rest" };
        try std.testing.expect(try simple.comment());
        try std.testing.expectEqualStrings(" rest", simple.rest());

        // Comments nest, and the outer one ends at the parenthesis that
        // balances it rather than at the first one it meets.
        var nested: Cursor = .{ .text = "(the (very) first)!" };
        try std.testing.expect(try nested.comment());
        try std.testing.expectEqualStrings("!", nested.rest());

        // A backslash quotes what follows, so this holds one unbalanced
        // parenthesis and ends where it should.
        var quoted: Cursor = .{ .text = "(a smile \\) here)!" };
        try std.testing.expect(try quoted.comment());
        try std.testing.expectEqualStrings("!", quoted.rest());

        // A comment may be folded across lines like anything else.
        var folded: Cursor = .{ .text = "(over\r\n two lines)!" };
        try std.testing.expect(try folded.comment());
        try std.testing.expectEqualStrings("!", folded.rest());

        // Not a comment at all, which is not a failure.
        var absent: Cursor = .{ .text = "Nov" };
        try std.testing.expect(!try absent.comment());
        try std.testing.expectEqualStrings("Nov", absent.rest());

        var unterminated: Cursor = .{ .text = "(never closed" };
        try std.testing.expectError(error.ParseError, unterminated.comment());

        var dangling: Cursor = .{ .text = "(trailing escape \\" };
        try std.testing.expectError(error.ParseError, dangling.comment());
    }

    /// Consumes a `CFWS` -- any mixture of folding whitespace and
    /// comments -- and reports whether there was one.
    ///
    /// RFC 5322 spells this `(1*([FWS] comment) [FWS]) / FWS`, which is
    /// to say: alternating, in either order, with at least one of
    /// something. Taking whichever of the two comes next until neither
    /// does accepts exactly that set.
    ///
    /// Which of the two is coming is decided from the byte at the cursor
    /// rather than by trying each in turn. Most separators in a real date
    /// are a single space, and this is called at every one of them, so
    /// the difference between one dispatch and two speculative calls is
    /// most of what the parse costs over `rfc822`'s.
    fn cfws(self: *Cursor) ParseError!bool {
        var any = false;
        while (!self.done()) {
            switch (self.peek()) {
                // A `CR` only begins folding whitespace when a line
                // continues it, so `fws` may still decline it, and that
                // is the end of the run rather than an error.
                ' ', '\t', '\r' => {
                    if (!self.fws()) break;
                    any = true;
                },
                '(' => {
                    _ = try self.comment();
                    any = true;
                },
                else => break,
            }
        }
        return any;
    }

    test cfws {
        // Whitespace and comments in any arrangement are one separator.
        var mixed: Cursor = .{ .text = " (a) \t (b) Nov" };
        try std.testing.expect(try mixed.cfws());
        try std.testing.expectEqualStrings("Nov", mixed.rest());

        // A comment with no whitespace around it still separates.
        var bare: Cursor = .{ .text = "(a)Nov" };
        try std.testing.expect(try bare.cfws());
        try std.testing.expectEqualStrings("Nov", bare.rest());

        var none: Cursor = .{ .text = "Nov" };
        try std.testing.expect(!try none.cfws());
        try std.testing.expectEqualStrings("Nov", none.rest());
    }

    /// Consumes a `CFWS` where the grammar requires one.
    ///
    /// The grammar's required separators are `FWS` rather than `CFWS`,
    /// and a comment standing in for one is formally `obs-day`,
    /// `obs-year` and their relatives. They are accepted anyway, because
    /// a comment says nothing about the value -- refusing one would turn
    /// away a date this parser could read perfectly well, which is not
    /// what the strictness here is for.
    fn requiredCfws(self: *Cursor) ParseError!void {
        if (!try self.cfws()) return error.ParseError;
    }

    test requiredCfws {
        var cursor: Cursor = .{ .text = " Nov" };
        try cursor.requiredCfws();
        try std.testing.expectEqualStrings("Nov", cursor.rest());

        // Where the grammar needs a separator, having none is an error.
        try std.testing.expectError(error.ParseError, cursor.requiredCfws());
    }

    /// Consumes between `min_len` and `max_len` ASCII digits and returns
    /// their value along with how many were read.
    ///
    /// `max_len` must be at most nine, which is the most decimal digits
    /// that always fit a `u32`, so the accumulation cannot overflow and
    /// the run is measured and converted in one pass rather than scanned
    /// once for its length and again for its value.
    fn digits(self: *Cursor, min_len: usize, max_len: usize) ParseError!Digits {
        std.debug.assert(max_len <= 9);

        const from = self.rest();
        var len: usize = 0;
        var value: u32 = 0;
        while (len < max_len and len < from.len and std.ascii.isDigit(from[len])) : (len += 1) {
            value = value * 10 + (from[len] - '0');
        }
        if (len < min_len) return error.ParseError;

        self.index += len;
        return .{ .value = value, .len = len };
    }

    test digits {
        var four: Cursor = .{ .text = "1997" };
        const year = try four.digits(4, 9);
        try std.testing.expectEqual(@as(u32, 1997), year.value);
        try std.testing.expectEqual(@as(usize, 4), year.len);

        // Reading stops at `max_len` even when more digits follow, which
        // is what lets a caller notice a field that was written too long.
        var capped: Cursor = .{ .text = "123456" };
        try std.testing.expectEqual(@as(u32, 12), (try capped.digits(2, 2)).value);
        try std.testing.expect(capped.atDigit());

        // Nine digits is the widest field asked for, and the widest that
        // fits the accumulator.
        var wide: Cursor = .{ .text = "999999999" };
        try std.testing.expectEqual(@as(u32, 999_999_999), (try wide.digits(4, 9)).value);

        var short: Cursor = .{ .text = "997 " };
        try std.testing.expectError(error.ParseError, short.digits(4, 9));

        var none: Cursor = .{ .text = "Nov" };
        try std.testing.expectError(error.ParseError, none.digits(1, 2));
    }

    /// Parses a `zone` -- a sign and four digits -- into seconds east of
    /// UTC.
    ///
    /// The four digits are two fields written as one number, so they are
    /// read as one and split by division: the hundreds are the hours and
    /// the remainder the minutes. Section 3.3 constrains only the
    /// minutes, to 00 through 59; the hours are held to 23 as well, both
    /// because `rfc822.parse` does and because an offset of more than a
    /// day is not a zone anything could mean.
    ///
    /// The alphabetic zones -- `GMT`, `EST`, the single letter military
    /// ones -- are `obs-zone` and are not accepted here. `rfc822.parse`
    /// reads them.
    fn zone(self: *Cursor) ParseError!Zone {
        if (self.done()) return error.ParseError;

        const negative = switch (self.peek()) {
            '+' => false,
            '-' => true,
            else => return error.ParseError,
        };
        self.index += 1;

        const parsed = try self.digits(4, 4);
        if (self.atDigit()) return error.ParseError;

        const hours = parsed.value / 100;
        const minutes = parsed.value % 100;
        if (hours > 23 or minutes > 59) return error.ParseError;

        const magnitude = @as(i32, @intCast(hours)) * std.time.s_per_hour +
            @as(i32, @intCast(minutes)) * std.time.s_per_min;

        return .{
            .offset = if (negative) -magnitude else magnitude,
            // Section 3.3: "-0000" is UTC from something that would not
            // say what zone it was in. Only that exact spelling means it.
            .unknown = negative and magnitude == 0,
        };
    }

    test zone {
        var west: Cursor = .{ .text = "-0600" };
        const parsed = try west.zone();
        try std.testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), parsed.offset);
        try std.testing.expect(!parsed.unknown);

        // Not every offset is a whole number of hours.
        var half: Cursor = .{ .text = "+0530" };
        try std.testing.expectEqual(
            @as(i32, 5 * std.time.s_per_hour + 30 * std.time.s_per_min),
            (try half.zone()).offset,
        );

        // The two spellings of zero differ in what they claim, not in
        // what they are worth.
        var known: Cursor = .{ .text = "+0000" };
        try std.testing.expect(!(try known.zone()).unknown);

        var unknown: Cursor = .{ .text = "-0000" };
        const withheld = try unknown.zone();
        try std.testing.expectEqual(@as(i32, 0), withheld.offset);
        try std.testing.expect(withheld.unknown);

        // Alphabetic zones are the obsolete syntax and belong to
        // `rfc822`.
        var named: Cursor = .{ .text = "GMT" };
        try std.testing.expectError(error.ParseError, named.zone());
    }
};

/// Whether `char` is `VCHAR`: a visible ASCII character, which is what a
/// backslash inside a comment is allowed to quote.
fn isVchar(char: u8) bool {
    return char >= 0x21 and char <= 0x7e;
}

test isVchar {
    try std.testing.expect(isVchar('!'));
    try std.testing.expect(isVchar('('));
    try std.testing.expect(isVchar('~'));

    // Space and the controls are not visible characters; whitespace is
    // quotable inside a comment, but as `WSP` rather than as `VCHAR`.
    try std.testing.expect(!isVchar(' '));
    try std.testing.expect(!isVchar('\t'));
    try std.testing.expect(!isVchar(0x7f));
}

/// Whether `char` is `ctext`: a printable ASCII character that may stand
/// on its own inside a comment.
///
/// RFC 5322 writes the set as three ranges with two gaps in it, and the
/// gaps are the three characters a comment gives a meaning of its own:
/// the parentheses that delimit it and the backslash that quotes. Any of
/// those may still appear, quoted or balanced -- what the set excludes is
/// reading them as ordinary text.
fn isCtext(char: u8) bool {
    return switch (char) {
        0x21...0x27, 0x2a...0x5b, 0x5d...0x7e => true,
        else => false,
    };
}

test isCtext {
    try std.testing.expect(isCtext('!'));
    try std.testing.expect(isCtext('a'));
    try std.testing.expect(isCtext('~'));

    // The three characters the comment syntax reserves.
    try std.testing.expect(!isCtext('('));
    try std.testing.expect(!isCtext(')'));
    try std.testing.expect(!isCtext('\\'));

    // Whitespace is `FWS`, not `ctext`, and controls are neither.
    try std.testing.expect(!isCtext(' '));
    try std.testing.expect(!isCtext('\r'));
    try std.testing.expect(!isCtext(0x7f));
}

test parse {
    const result = try parse("Fri, 21 Nov 1997 09:55:06 -0600");
    try std.testing.expectEqual(@as(Year, 1997), result.value.year);
    try std.testing.expectEqual(Month.Nov, result.value.month);
    try std.testing.expectEqual(@as(Day, 21), result.value.day);
    try std.testing.expectEqual(@as(Hour, 9), result.value.hour);
    try std.testing.expectEqual(DayOfWeek.Fri, result.value.weekday);
    try std.testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), result.value.offset);

    // The day name and the seconds are optional; the zone is not.
    const terse = try parse("21 Nov 1997 09:55 +0000");
    try std.testing.expectEqual(@as(Second, 0), terse.value.second);

    // A comment may stand anywhere whitespace may, and is part of the
    // date rather than left over after it.
    const commented = try parse("Thu, 13 (the thirteenth) Feb 1969 23:32:54 -0330 (Newfoundland)");
    try std.testing.expectEqual(@as(Day, 13), commented.value.day);
    try std.testing.expectEqualStrings(
        "Thu, 13 (the thirteenth) Feb 1969 23:32:54 -0330 (Newfoundland)",
        commented.str,
    );

    // "-0000" is UTC from a sender that would not name its own zone.
    try std.testing.expect((try parse("21 Nov 1997 09:55:06 -0000")).unknown_offset);
    try std.testing.expect(!(try parse("21 Nov 1997 09:55:06 +0000")).unknown_offset);

    // The obsolete forms are `rfc822.parse`'s business, not this one's.
    try std.testing.expectError(error.ParseError, parse("20 Jun 82 12:34 EST"));

    // A day name that disagrees with the date is rejected rather than
    // believed.
    try std.testing.expectError(error.ParseError, parse("Mon, 21 Nov 1997 09:55:06 -0600"));
}

test "parse accepts the current syntax" {
    const cases = [_]struct { value: []const u8, expected: DateTime }{
        // RFC 5322 appendix A.1.1, the canonical example.
        .{
            .value = "Fri, 21 Nov 1997 09:55:06 -0600",
            .expected = .{
                .year = 1997,
                .month = .Nov,
                .day = 21,
                .hour = 9,
                .minute = 55,
                .second = 6,
                .weekday = .Fri,
                .offset = -6 * std.time.s_per_hour,
            },
        },
        // No day name, one digit day of the month, no seconds.
        .{
            .value = "1 Jul 2003 10:52:37 +0200",
            .expected = .{
                .year = 2003,
                .month = .Jul,
                .day = 1,
                .hour = 10,
                .minute = 52,
                .second = 37,
                .weekday = .Tue,
                .offset = 2 * std.time.s_per_hour,
            },
        },
        .{
            .value = "Mon, 24 Nov 1997 14:22 +0000",
            .expected = .{
                .year = 1997,
                .month = .Nov,
                .day = 24,
                .hour = 14,
                .minute = 22,
                .second = 0,
                .weekday = .Mon,
                .offset = 0,
            },
        },
        // An offset that is not a whole number of hours.
        .{
            .value = "Thu, 13 Feb 1969 23:32:54 -0330",
            .expected = .{
                .year = 1969,
                .month = .Feb,
                .day = 13,
                .hour = 23,
                .minute = 32,
                .second = 54,
                .weekday = .Thu,
                .offset = -(3 * std.time.s_per_hour + 30 * std.time.s_per_min),
            },
        },
        // A leap second on a leap day, both of which section 3.3 allows.
        .{
            .value = "Sat, 29 Feb 2020 23:59:60 +0000",
            .expected = .{
                .year = 2020,
                .month = .Feb,
                .day = 29,
                .hour = 23,
                .minute = 59,
                .second = 60,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // Names are matched case-insensitively, and the separators may be
        // runs of spaces and tabs.
        .{
            .value = "fri,\t21  nov  1997  09:55:06  -0600",
            .expected = .{
                .year = 1997,
                .month = .Nov,
                .day = 21,
                .hour = 9,
                .minute = 55,
                .second = 6,
                .weekday = .Fri,
                .offset = -6 * std.time.s_per_hour,
            },
        },
        // `4*DIGIT` has no upper bound, so a year past four digits is
        // well formed rather than a mistake.
        .{
            .value = "1 Jan 10000 00:00:00 +0000",
            .expected = .{
                .year = 10000,
                .month = .Jan,
                .day = 1,
                .weekday = .Sat,
                .offset = 0,
            },
        },
    };

    for (cases) |case| {
        const result = try parse(case.value);
        try std.testing.expectEqual(case.expected, result.value);
        try std.testing.expectEqualStrings(case.value, result.str);
    }
}

test "parse reads a header that was folded across lines" {
    // What a long `Date:` header looks like after the message was folded
    // for transmission but before anything unfolded it: a CRLF inside the
    // whitespace, with the line that follows indented.
    const folded = "Thu,\r\n 13 Feb 1969\r\n\t23:32:54 -0330";

    const result = try parse(folded);
    try std.testing.expectEqual(@as(Day, 13), result.value.day);
    try std.testing.expectEqual(Month.Feb, result.value.month);
    try std.testing.expectEqual(@as(Hour, 23), result.value.hour);
    try std.testing.expectEqualStrings(folded, result.str);
}

test "parse consumes comments wherever whitespace may go" {
    const cases = [_][]const u8{
        "(leading) Fri, 21 Nov 1997 09:55:06 -0600",
        "Fri, (day) 21 Nov 1997 09:55:06 -0600",
        "Fri, 21 (of) Nov (in) 1997 (at) 09:55:06 (zone) -0600",
        "Fri, 21 Nov 1997 09:55:06 -0600 (trailing)",
        // Comments nest, hold quoted characters, and may be folded.
        "Fri, 21 Nov 1997 09:55:06 -0600 (a (nested) one)\r\n (with \\) an escape)",
        // A comment with no whitespace around it is still a separator.
        "Fri,(no space)21(at all)Nov(here)1997(or here)09:55:06(nor here)-0600",
    };

    for (cases) |case| {
        const result = try parse(case);
        try std.testing.expectEqual(@as(Year, 1997), result.value.year);
        try std.testing.expectEqual(@as(Day, 21), result.value.day);
        try std.testing.expectEqual(@as(Second, 6), result.value.second);
        try std.testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), result.value.offset);
        // The trailing CFWS is part of `date-time`, so every one of these
        // is consumed whole.
        try std.testing.expectEqualStrings(case, result.str);
    }
}

test "parse stops at the end of the date" {
    // Text that is not part of the date is the caller's business.
    {
        const result = try parse("Fri, 21 Nov 1997 09:55:06 -0600 Fri");
        try std.testing.expectEqualStrings("Fri, 21 Nov 1997 09:55:06 -0600 ", result.str);
    }
    // A trailing comment that is never closed is not a `CFWS`, so the
    // optional group at the end matches nothing and the date -- which was
    // complete without it -- stands.
    {
        const result = try parse("Fri, 21 Nov 1997 09:55:06 -0600 (never closed");
        try std.testing.expectEqualStrings("Fri, 21 Nov 1997 09:55:06 -0600", result.str);
        try std.testing.expectEqual(@as(Year, 1997), result.value.year);
    }
}

test "parse rejects the obsolete syntax" {
    // Every one of these is a form RFC 5322 section 4.3 keeps only for
    // reading old messages, and every one of them `rfc822.parse` accepts.
    const cases = [_][]const u8{
        "20 Jun 82 12:34 -0500", // obs-year: two digits
        "1 Jan 100 00:00:00 +0000", // obs-year: three digits
        "Sun 06 Nov 1994 08:49:37 +0000", // obs-day-of-week: no comma
        "06 Nov 1994 08:49:37 GMT", // obs-zone: an alphabetic zone
        "06 Nov 1994 08:49:37 EST",
        "06 Nov 1994 08:49:37 Z", // obs-zone: a military zone
        "06 Nov 1994 08 :49:37 +0000", // obs-hour: a separator at the colon
        "06 Nov 1994 08: 49:37 +0000", // obs-minute, likewise
        "06 Nov 1994 08:49 :37 +0000", // obs-minute again, at the second
        "06 Nov 1994 08:49: 37 +0000", // obs-second
    };

    for (cases) |case| {
        try std.testing.expectError(error.ParseError, parse(case));
    }

    // The same dates written the current way, so that the list above is
    // known to be failing on the obsolete form and not on something else
    // it happens to contain.
    _ = try parse("20 Jun 1982 12:34 -0500");
    _ = try parse("1 Jan 0100 00:00:00 +0000");
    _ = try parse("Sun, 06 Nov 1994 08:49:37 +0000");
    _ = try parse("06 Nov 1994 08:49:37 +0000");
}

test "parse rejects malformed input" {
    const cases = [_][]const u8{
        "",
        "Fri, 21 Nov 1997 09:55:06", // no zone
        "Mon, 21 Nov 1997 09:55:06 -0600", // 21 Nov 1997 was a Friday
        "Fri, 21 Nov 1997", // no time
        "21 Nov 1997 09", // no minute
        "32 Jan 2024 00:00:00 +0000", // no such day of the month
        "0 Jan 2024 00:00:00 +0000",
        "30 Feb 2024 00:00:00 +0000", // day out of range for the month
        "29 Feb 2023 00:00:00 +0000", // 2023 is not a leap year
        "21 Nov 1997 24:55:06 +0000", // hour out of range
        "21 Nov 1997 09:60:06 +0000", // minute out of range
        "21 Nov 1997 09:55:61 +0000", // second out of range
        "21 Nov 1997 009:55:06 +0000", // fields are exactly two digits
        "21 Nov 1997 9:55:06 +0000",
        "21 Nov 1997 09:5:06 +0000",
        "21 Nov 1997 09:55:6 +0000",
        "21 November 1997 09:55:06 +0000", // long month names are not RFC 5322
        "21 Nov 1997 09:55:06 +060", // the offset is exactly four digits
        "21 Nov 1997 09:55:06 +06000",
        "21 Nov 1997 09:55:06 +0560", // minutes of the offset out of range
        "21 Nov 1997 09:55:06 +2400", // hours of the offset out of range
        "21 Nov 1997 09:55:06 0600", // the offset needs its sign
        "21Nov 1997 09:55:06 +0000", // components must be separated
        "21 Nov1997 09:55:06 +0000",
        "21 Nov 1997 09:55:06+0000",
        "21 Nov 12345678901 09:55:06 +0000", // a year wider than `Year` holds
        "Fri, 21 Nov 1997 09:55:06 (unclosed -0600", // a comment inside the date
        "21 Nov 1997 09:55:06 (bad \\\x7f escape) +0000", // not a quotable character
        "21 Nov 1997\r\n09:55:06 +0000", // a line break that nothing continues
    };

    for (cases) |case| {
        try std.testing.expectError(error.ParseError, parse(case));
    }
}

test "parsed offsets convert to UTC" {
    const parsed = try parse("Fri, 21 Nov 1997 09:55:06 -0600");

    try std.testing.expectEqual(DateTime{
        .year = 1997,
        .month = .Nov,
        .day = 21,
        .hour = 15,
        .minute = 55,
        .second = 6,
        .weekday = .Fri,
        .offset = 0,
    }, parsed.value.toUtc());
}

test "round trip through DateTime.format" {
    // `date-time` written the way section 3.3 says to generate it, which
    // is the one spelling of it that formatting can produce.
    const value = "Fri, 21 Nov 1997 09:55:06 -0600";

    const parsed = try parse(value);
    const formatted = try parsed.value.formatAlloc(std.testing.allocator, "ddd, DD MMM YYYY HH:mm:ss ZZ");
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings(value, formatted);
}

test "the obsolete forms this refuses are the ones rfc822 reads" {
    // The division of labour between the two modules, asserted from both
    // sides so that it cannot quietly stop being true. Each of these is
    // well formed RFC 822 and obsolete RFC 5322, and the lenient parser
    // is what a caller falls back to.
    const rfc822 = @import("rfc822.zig");

    const obsolete = [_][]const u8{
        "20 Jun 82 12:34 -0500",
        "1 Jan 100 00:00:00 Z",
        "Sun 06 Nov 1994 08:49:37 +0000",
        "06 Nov 1994 08:49:37 GMT",
        "06 Nov 1994 8:49:37 +0000",
    };

    for (obsolete) |case| {
        try std.testing.expectError(error.ParseError, parse(case));
        _ = try rfc822.parse(case);
    }
}

test "where both parsers accept an input they agree about it" {
    // The other half of the claim: strictness is about which texts are
    // read, not about what they are read as. Anything both accept has to
    // come back the same, or falling back from one to the other would
    // change the answer rather than only widening what is allowed.
    const rfc822 = @import("rfc822.zig");

    const shared = [_][]const u8{
        "Fri, 21 Nov 1997 09:55:06 -0600",
        "1 Jul 2003 10:52:37 +0200",
        "Mon, 24 Nov 1997 14:22 +0000",
        "Thu, 13 Feb 1969 23:32:54 -0330",
        "Sat, 29 Feb 2020 23:59:60 +0000",
        "21 Nov 1997 09:55:06 -0000",
        "fri,\t21  nov  1997  09:55:06  -0600",
    };

    for (shared) |case| {
        const strict = try parse(case);
        const lenient = try rfc822.parse(case);

        try std.testing.expectEqual(lenient.value, strict.value);
        try std.testing.expectEqualStrings(lenient.str, strict.str);
    }

    // `unknown_offset` is the one thing only this parser reports, and it
    // is why the two results can be equal while the strict one still says
    // more: RFC 822 has nothing to say about the difference.
    try std.testing.expect((try parse("21 Nov 1997 09:55:06 -0000")).unknown_offset);
    try std.testing.expectEqual(
        @as(i32, 0),
        (try rfc822.parse("21 Nov 1997 09:55:06 -0000")).value.offset,
    );
}
