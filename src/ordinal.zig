const std = @import("std");

fn exact(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

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
