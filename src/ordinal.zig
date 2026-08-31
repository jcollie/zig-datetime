// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Recognizing the English ordinal suffixes when parsing a formatted date,
//! so that a format string's `Do` can read "15th" back off the wire.
//!
//! Parsing only needs to know that a suffix is there, not which one it is,
//! because the number in front of it has already been read. The maps here
//! are therefore sets: every value is `true`, and a lookup miss is what
//! says the two bytes were not a suffix. See `print.ordinal` for the
//! writing side, which does have to pick the right one.

const std = @import("std");

/// Byte-for-byte string equality, used as the map's comparison function.
fn exact(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Returns a namespace whose `map` recognizes the English ordinal suffixes
/// ("st", "nd", "rd", "th") in the given style: plain ASCII for `.normal`,
/// Unicode superscript letters for `.superscript`.
pub fn Ordinal(comptime style: enum { normal, superscript }) type {
    return struct {
        /// The suffixes of this style, as a set. Only the presence of a key
        /// matters; every value is `true`.
        pub const map = switch (style) {
            .normal => std.StaticStringMapWithEql(bool, exact).initComptime(
                .{
                    .{ "th", true },
                    .{ "st", true },
                    .{ "nd", true },
                    .{ "rd", true },
                },
            ),
            .superscript => std.StaticStringMapWithEql(bool, exact).initComptime(
                .{
                    .{ "ᵗʰ", true },
                    .{ "ˢᵗ", true },
                    .{ "ⁿᵈ", true },
                    .{ "ʳᵈ", true },
                },
            ),
        };
    };
}
