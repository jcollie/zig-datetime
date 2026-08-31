// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

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
