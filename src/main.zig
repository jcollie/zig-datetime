const std = @import("std");

pub const Year = @import("year.zig").Year;
pub const Month = @import("month.zig").Month;
pub const Day = @import("day.zig").Day;
pub const Hour = @import("hour.zig").Hour;
pub const Minute = @import("minute.zig").Minute;
pub const Second = @import("second.zig").Second;
pub const Nanosecond = @import("nanosecond.zig").Nanosecond;
pub const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
pub const Date = @import("Date.zig");
pub const DateTime = @import("DateTime.zig");
pub const Instant = @import("Instant.zig");
pub const si = @import("si.zig");

// test "bigTest" {
//     const year_start: Year = -1000000;
//     const year_end = -year_start;
//     var prev_z: i32 = Date.toCivilDays(.{ .year = year_start, .month = .Jan, .day = 1 }) - 1;
//     try std.testing.expect(prev_z < 0);
//     var prev_wd = DayOfWeek.weekdayFromDays(prev_z);
//     try std.testing.expect(0 <= @intFromEnum(prev_wd) and @intFromEnum(prev_wd) <= 6);
//     var y: Year = year_start;
//     while (y < year_end) {
//         var it = Month.iterator();
//         while (it.next()) |m| {
//             std.debug.print("{}\n", .{m});
//             var day: Day = 1;
//             const end_of_month = m.lastDay(y);
//             while (day <= end_of_month) {
//                 const date_0: Date = .{
//                     .year = y,
//                     .month = m,
//                     .day = day,
//                 };
//                 const z = date_0.toDaysSinceStartOfEra();
//                 try std.testing.expect(prev_z < z);
//                 try std.testing.expect(z == prev_z + 1);
//                 const date_1 = Date.fromDaysSinceStartOfEra(z);
//                 try std.testing.expect(y == date_1.year);
//                 try std.testing.expect(m == date_1.month);
//                 try std.testing.expect(day == date_1.day);
//                 const wd = DayOfWeek.fromDaysSinceStartOfEra(z);
//                 try std.testing.expect(0 <= @intFromEnum(wd) and @intFromEnum(wd) <= 6);
//                 try std.testing.expect(wd == prev_wd.next());
//                 try std.testing.expect(prev_wd == wd.prev());
//                 prev_z = z;
//                 prev_wd = wd;
//                 day += 1;
//             }
//         }
//         y += 1;
//     }
// }

test {
    std.testing.refAllDecls(@This());
}
