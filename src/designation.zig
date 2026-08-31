// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The abbreviation a timezone is known by at some instant, such as "CST"
//! or "-04", stored by value so that a `DateTime` can carry one.
//!
//! A zone's designations live in the TZif bytes it was parsed from, and
//! `tzif.Type` borrows them from there. A `DateTime` cannot: it is a plain
//! value that gets copied, compared and stored, and a slice into a zone's
//! bytes would tie its lifetime to that zone and would compare as a
//! pointer rather than as text. So the bytes are copied into the value.

const std = @import("std");

/// A zone abbreviation, NUL padded to a fixed width.
///
/// The length is where the padding starts rather than a field of its own,
/// which costs a byte less and is unambiguous because a designation is a
/// NUL terminated string in the file it came from and so cannot hold one.
pub const Designation = struct {
    bytes: [max_len]u8 = @splat(0),

    /// The longest designation this can hold.
    ///
    /// Across the 1241 files of tzdata 2026c there are 177 distinct
    /// designations and the longest is five characters: the numeric ones
    /// such as `+0545` and `-1130`. Six covers every one of them with a
    /// character to spare.
    ///
    /// Six rather than more because it is free and more is not: a
    /// `DateTime` is 20 bytes without this and 24 with it at four or six,
    /// where eight takes it to 28 and twelve to 32. It is a value that
    /// gets passed and copied, so the width is worth spending only where
    /// it buys something.
    pub const max_len = 6;

    /// Returns the designation `text` names, or an empty one when it will
    /// not fit or holds a NUL.
    ///
    /// Refusing rather than truncating is deliberate: a designation cut
    /// short reads like a real abbreviation of some other zone, where an
    /// empty one says only that it is not known. Nothing in the IANA
    /// database comes close to the limit, so this is about a hand written
    /// POSIX rule such as `<AVERYLONGNAME>5` rather than about real data.
    pub fn from(text: []const u8) Designation {
        if (text.len > max_len) return .{};
        if (std.mem.indexOfScalar(u8, text, 0) != null) return .{};

        var result: Designation = .{};
        @memcpy(result.bytes[0..text.len], text);
        return result;
    }

    test from {
        try std.testing.expectEqualStrings("CST", Designation.from("CST").slice());
        try std.testing.expectEqualStrings("+0545", Designation.from("+0545").slice());
        try std.testing.expectEqualStrings("", Designation.from("").slice());

        // Too long to hold, so not held at all rather than cut down to
        // something that would read as a different zone.
        try std.testing.expectEqualStrings("", Designation.from("AVERYLONGNAME").slice());
        try std.testing.expectEqualStrings("", Designation.from("ABCDEFG").slice());

        // Exactly the limit still fits.
        try std.testing.expectEqualStrings("ABCDEF", Designation.from("ABCDEF").slice());
    }

    /// The designation as text, empty when it is not known.
    ///
    /// The slice points into the value it was taken from, so that value
    /// has to outlive it: read it from a `DateTime` held in a variable
    /// rather than from one returned and dropped in the same expression.
    pub fn slice(self: *const Designation) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.bytes, 0) orelse max_len;
        return self.bytes[0..end];
    }

    test slice {
        const cdt: Designation = .from("CDT");
        try std.testing.expectEqualStrings("CDT", cdt.slice());

        // A designation nobody set reads as empty rather than as padding.
        const unset: Designation = .{};
        try std.testing.expectEqualStrings("", unset.slice());
        try std.testing.expectEqual(@as(usize, 0), unset.slice().len);
    }

    /// Whether this is the designation `text` names.
    ///
    /// Saves taking a slice of a value only to compare it, which is where
    /// the lifetime `slice` warns about is easiest to get wrong.
    pub fn eql(self: Designation, text: []const u8) bool {
        var other = self;
        return std.mem.eql(u8, other.slice(), text);
    }

    test eql {
        const cst: Designation = .from("CST");
        try std.testing.expect(cst.eql("CST"));
        try std.testing.expect(!cst.eql("CDT"));
        try std.testing.expect(!cst.eql("CS"));

        // Which is the point: this needs no variable to point into.
        try std.testing.expect(Designation.from("CDT").eql("CDT"));
        try std.testing.expect((Designation{}).eql(""));
    }
};
