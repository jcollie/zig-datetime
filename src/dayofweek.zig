const std = @import("std");
const log = std.log.scoped(.day_of_week);

const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const Date = @import("Date.zig");

pub const DayOfWeek = enum(u3) {
    Sun = 0,
    Mon = 1,
    Tue = 2,
    Wed = 3,
    Thu = 4,
    Fri = 5,
    Sat = 6,

    pub const ParseError = error{ParseError};
    pub const ParseStringResult = struct {
        str: []const u8,
        value: DayOfWeek,
    };

    /// Parses a two-letter day name ("Su" ... "Sa") at the start of `left`,
    /// case-insensitively.
    pub fn parseVeryShortStr(left: []const u8) ParseError!ParseStringResult {
        return parseWithMap(DayOfWeek.very_short_map, left);
    }

    /// Parses a three-letter day name ("Sun" ... "Sat") at the start of
    /// `left`, case-insensitively.
    pub fn parseShortStr(left: []const u8) ParseError!ParseStringResult {
        return parseWithMap(DayOfWeek.short_map, left);
    }

    /// Parses a full day name ("Sunday" ... "Saturday") at the start of
    /// `left`, case-insensitively.
    pub fn parseLongStr(left: []const u8) ParseError!ParseStringResult {
        return parseWithMap(DayOfWeek.long_map, left);
    }

    /// Returns the shortest prefix of `left` found in `map` along with its
    /// value, or `error.ParseError` if no prefix matches.
    fn parseWithMap(map: MapType, left: []const u8) ParseError!ParseStringResult {
        for (1..left.len + 1) |l| {
            if (map.get(left[0..l])) |dow| {
                return .{
                    .str = left[0..l],
                    .value = dow,
                };
            }
        }
        return error.ParseError;
    }

    /// Returns the day after this one, wrapping from Saturday to Sunday.
    pub fn next(self: DayOfWeek) DayOfWeek {
        return switch (self) {
            .Sun => .Mon,
            .Mon => .Tue,
            .Tue => .Wed,
            .Wed => .Thu,
            .Thu => .Fri,
            .Fri => .Sat,
            .Sat => .Sun,
        };
    }

    /// Returns the day before this one, wrapping from Sunday to Saturday.
    pub fn prev(self: DayOfWeek) DayOfWeek {
        return switch (self) {
            .Sun => .Sat,
            .Mon => .Sun,
            .Tue => .Mon,
            .Wed => .Tue,
            .Thu => .Wed,
            .Fri => .Thu,
            .Sat => .Fri,
        };
    }

    /// Returns the two-letter English name ("Su" ... "Sa").
    pub fn veryShortName(self: DayOfWeek) []const u8 {
        return switch (self) {
            .Sun => "Su",
            .Mon => "Mo",
            .Tue => "Tu",
            .Wed => "We",
            .Thu => "Th",
            .Fri => "Fr",
            .Sat => "Sa",
        };
    }

    /// Returns the three-letter English name ("Sun" ... "Sat").
    pub fn shortName(self: DayOfWeek) []const u8 {
        return switch (self) {
            .Sun => "Sun",
            .Mon => "Mon",
            .Tue => "Tue",
            .Wed => "Wed",
            .Thu => "Thu",
            .Fri => "Fri",
            .Sat => "Sat",
        };
    }

    /// Returns the full English name ("Sunday" ... "Saturday").
    pub fn longName(self: DayOfWeek) []const u8 {
        return switch (self) {
            .Sun => "Sunday",
            .Mon => "Monday",
            .Tue => "Tuesday",
            .Wed => "Wednesday",
            .Thu => "Thursday",
            .Fri => "Friday",
            .Sat => "Saturday",
        };
    }

    /// Returns the weekday number, Sunday = 0 through Saturday = 6.
    pub fn weekdayNumber(self: DayOfWeek) u3 {
        return @intFromEnum(self);
    }

    /// Returns the ISO 8601 weekday number, Monday = 1 through Sunday = 7.
    pub fn isoWeekdayNumber(self: DayOfWeek) u3 {
        return if (self == .Sun) 7 else @intFromEnum(self);
    }

    /// Returns the day of the week that falls `days` days after 1970-01-01
    /// (which was a Thursday); negative values count backward.
    pub fn fromDaysSinceStartOfEra(days: Date.DaysType) DayOfWeek {
        const result = if (days >= -4)
            @rem(days + 4, 7)
        else
            @rem(days + 5, 7) + 6;
        std.debug.assert(result >= 0 and result <= 6);
        return @enumFromInt(result);
    }

    pub const MapType = std.StaticStringMapWithEql(DayOfWeek, std.ascii.eqlIgnoreCase);

    pub const very_short_map = MapType.initComptime(
        .{
            .{ "su", .Sun },
            .{ "mo", .Mon },
            .{ "tu", .Tue },
            .{ "we", .Wed },
            .{ "th", .Thu },
            .{ "fr", .Fri },
            .{ "sa", .Sat },
        },
    );

    pub const short_map = MapType.initComptime(
        .{
            .{ "sun", .Sun },
            .{ "mon", .Mon },
            .{ "tue", .Tue },
            .{ "wed", .Wed },
            .{ "thu", .Thu },
            .{ "fri", .Fri },
            .{ "sat", .Sat },
        },
    );

    pub const long_map = MapType.initComptime(
        .{
            .{ "sunday", .Sun },
            .{ "monday", .Mon },
            .{ "tuesday", .Tue },
            .{ "wednesday", .Wed },
            .{ "thursday", .Thu },
            .{ "friday", .Fri },
            .{ "saturday", .Sat },
        },
    );

    pub const any_map = MapType.initComptime(
        .{
            .{ "su", .Sun },
            .{ "mo", .Mon },
            .{ "tu", .Tue },
            .{ "we", .Wed },
            .{ "th", .Thu },
            .{ "fr", .Fri },
            .{ "sa", .Sat },

            .{ "sun", .Sun },
            .{ "mon", .Mon },
            .{ "tue", .Tue },
            .{ "wed", .Wed },
            .{ "thu", .Thu },
            .{ "fri", .Fri },
            .{ "sat", .Sat },

            .{ "sund", .Sun },
            .{ "mond", .Mon },
            .{ "tues", .Tue },
            .{ "wedn", .Wed },
            .{ "thur", .Thu },
            .{ "frid", .Fri },
            .{ "satu", .Sat },

            .{ "sunda", .Sun },
            .{ "monda", .Mon },
            .{ "tuesd", .Tue },
            .{ "wedne", .Wed },
            .{ "thurs", .Thu },
            .{ "frida", .Fri },
            .{ "satur", .Sat },

            .{ "tuesda", .Tue },
            .{ "wednes", .Wed },
            .{ "thursd", .Thu },
            .{ "saturd", .Sat },

            .{ "wednesd", .Wed },
            .{ "thursda", .Thu },
            .{ "saturda", .Sat },

            .{ "wednesda", .Wed },

            .{ "sunday", .Sun },
            .{ "monday", .Mon },
            .{ "tuesday", .Tue },
            .{ "wednesday", .Wed },
            .{ "thursday", .Thu },
            .{ "friday", .Fri },
            .{ "saturday", .Sat },
        },
    );
};

/// Returns the number of days (0-6) counting forward from `start` to `end`.
pub fn weekdayDifference(start: DayOfWeek, end: DayOfWeek) u3 {
    const d = @as(i4, end.weekdayNumber()) - @as(i4, start.weekdayNumber());
    return if (d >= 0) @intCast(d) else @intCast(d + 7);
}

test "weekdayDifference" {
    const difference = [7][7]u3{
        [_]u3{ 0, 1, 2, 3, 4, 5, 6 },
        [_]u3{ 6, 0, 1, 2, 3, 4, 5 },
        [_]u3{ 5, 6, 0, 1, 2, 3, 4 },
        [_]u3{ 4, 5, 6, 0, 1, 2, 3 },
        [_]u3{ 3, 4, 5, 6, 0, 1, 2 },
        [_]u3{ 2, 3, 4, 5, 6, 0, 1 },
        [_]u3{ 1, 2, 3, 4, 5, 6, 0 },
    };
    for (0..6) |start| {
        for (0..6) |end| {
            const result = weekdayDifference(
                @as(DayOfWeek, @enumFromInt(start)),
                @as(DayOfWeek, @enumFromInt(end)),
            );
            try std.testing.expectEqual(difference[start][end], result);
        }
    }
}

test "weekdayFromDays" {
    const tests = [_]struct { days: i32, result: DayOfWeek }{
        .{
            .days = -1,
            .result = .Wed,
        },
        .{
            .days = 0,
            .result = .Thu,
        },
        .{
            .days = 1,
            .result = .Fri,
        },
        .{
            .days = 19605,
            .result = .Tue,
        },
    };

    for (tests) |case| {
        const result = DayOfWeek.fromDaysSinceStartOfEra(case.days);
        try std.testing.expectEqual(case.result, result);
    }
}
