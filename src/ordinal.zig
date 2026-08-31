// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Recognizing the English ordinal suffixes when parsing a formatted date,
//! so that a format string's `Do` can read "15th" back off the wire.
//!
//! Parsing only needs to know that a suffix is there, not which one it is,
//! because the number in front of it has already been read. The map here
//! is therefore a set: every value is `true`, and a lookup miss is what
//! says the two bytes were not a suffix. See `print.ordinal` for the
//! writing side, which does have to pick the right one.

const std = @import("std");

/// Byte-for-byte string equality, used as the map's comparison function.
fn exact(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test exact {
    // The map is keyed on exact bytes rather than folded case, because a
    // suffix only ever appears lower case in a formatted date and
    // accepting other spellings would be inventing syntax.
    try std.testing.expect(exact("st", "st"));
    try std.testing.expect(!exact("st", "ST"));
    try std.testing.expect(!exact("st", "s"));
}

/// The English ordinal suffixes, as a set. Only the presence of a key
/// matters; every value is `true`.
pub const map = std.StaticStringMapWithEql(bool, exact).initComptime(
    .{
        .{ "th", true },
        .{ "st", true },
        .{ "nd", true },
        .{ "rd", true },
    },
);

test map {
    // Only membership matters: a hit says the two bytes were a suffix.
    try std.testing.expect(map.get("st") != null);
    try std.testing.expect(map.get("nd") != null);
    try std.testing.expect(map.get("th") != null);
    try std.testing.expect(map.get("xx") == null);
}
