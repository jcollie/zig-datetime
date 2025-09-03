const std = @import("std");

pub const Year = i32;
// pub const Year = enum(i32) {
//     _,

//     pub fn order(self: Year, other: Year) std.math.Order {
//         return std.math.order(@intFromEnum(self), @intFromEnum(other));
//     }

//     pub fn prev(self: Year) Year {
//         return @enumFromInt(@intFromEnum(self) - 1);
//     }

//     pub fn next(self: Year) Year {
//         return @enumFromInt(@intFromEnum(self) + 1);
//     }
// };
