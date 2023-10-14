const std = @import("std");

pub const Day = u6;

pub const Month = enum(u4) {
    Jan = 1,
    Feb = 2,
    Mar = 3,
    Apr = 4,
    May = 5,
    Jun = 6,
    Jul = 7,
    Aug = 8,
    Sep = 9,
    Oct = 10,
    Nov = 11,
    Dec = 12,

    const Self = @This();

    pub fn monthNumber(self: Self) u4 {
        return switch (self) {
            .Jan => 1,
            .Feb => 2,
            .Mar => 3,
            .Apr => 4,
            .May => 5,
            .Jun => 6,
            .Jul => 7,
            .Aug => 8,
            .Sep => 9,
            .Oct => 10,
            .Nov => 11,
            .Dec => 12,
        };
    }

    pub fn next(self: Self) Self {
        return switch (self) {
            .Jan => .Feb,
            .Feb => .Mar,
            .Mar => .Apr,
            .Apr => .May,
            .May => .Jun,
            .Jun => .Jul,
            .Jul => .Aug,
            .Aug => .Sep,
            .Sep => .Oct,
            .Oct => .Nov,
            .Nov => .Dec,
            .Dec => .Jan,
        };
    }

    pub fn prev(self: Self) Self {
        return switch (self) {
            .Jan => .Dec,
            .Feb => .Jan,
            .Mar => .Feb,
            .Apr => .Mar,
            .May => .Apr,
            .Jun => .May,
            .Jul => .Jun,
            .Aug => .Jul,
            .Sep => .Aug,
            .Oct => .Sep,
            .Nov => .Oct,
            .Dec => .Nov,
        };
    }

    pub fn lastDay(self: Self, year: Year) Day {
        return switch (self) {
            .Jan => 31,
            .Feb => if (isLeap(year)) 29 else 28,
            .Mar => 31,
            .Apr => 30,
            .May => 31,
            .Jun => 30,
            .Jul => 31,
            .Aug => 31,
            .Sep => 30,
            .Oct => 31,
            .Nov => 30,
            .Dec => 31,
        };
    }

    pub fn quarter(self: Self) u3 {
        return switch (self) {
            .Jan => 1,
            .Feb => 1,
            .Mar => 1,
            .Apr => 2,
            .May => 2,
            .Jun => 2,
            .Jul => 3,
            .Aug => 3,
            .Sep => 3,
            .Oct => 4,
            .Nov => 4,
            .Dec => 4,
        };
    }

    pub fn shortName(self: Self) []const u8 {
        return switch (self) {
            .Jan => "Jan",
            .Feb => "Feb",
            .Mar => "Mar",
            .Apr => "Apr",
            .May => "May",
            .Jun => "Jun",
            .Jul => "Jul",
            .Aug => "Aug",
            .Sep => "Sep",
            .Oct => "Oct",
            .Nov => "Nov",
            .Dec => "Dec",
        };
    }

    pub fn longName(self: Self) []const u8 {
        return switch (self) {
            .Jan => "January",
            .Feb => "Febuary",
            .Mar => "March",
            .Apr => "April",
            .May => "May",
            .Jun => "June",
            .Jul => "July",
            .Aug => "August",
            .Sep => "September",
            .Oct => "October",
            .Nov => "November",
            .Dec => "December",
        };
    }

    pub fn daysBefore(self: Self, year: i32) u9 {
        // var days = 0;
        // var month = .Jan;
        // while (month != self) {
        //     days += month.lastDay(year);
        //     month = month.next();
        // }
        // return days;
        return switch (self) {
            .Jan => 0,
            .Feb => 31,
            .Mar => if (isLeap(year)) 60 else 59,
            .Apr => if (isLeap(year)) 91 else 90,
            .May => if (isLeap(year)) 121 else 120,
            .Jun => if (isLeap(year)) 152 else 151,
            .Jul => if (isLeap(year)) 182 else 181,
            .Aug => if (isLeap(year)) 213 else 212,
            .Sep => if (isLeap(year)) 244 else 243,
            .Oct => if (isLeap(year)) 274 else 273,
            .Nov => if (isLeap(year)) 305 else 304,
            .Dec => if (isLeap(year)) 335 else 334,
        };
    }
};

pub const Year = i32;
pub const Second = u6;
pub const Minute = u6;
pub const Hour = u5;

pub fn writeTwelveHour(hour: Hour, case: enum { lower, upper }, writer: anytype) !void {
    if (hour < 12) switch (case) {
        .lower => try writer.writeAll("am"),
        .upper => try writer.writeAll("AM"),
    } else switch (case) {
        .lower => try writer.writeAll("pm"),
        .upper => try writer.writeAll("PM"),
    }
}

pub const Nanosecond = u30;

// https://github.com/nektro/zig-time

pub const DateTime = struct {
    nanosecond: Nanosecond, // [0..999999999]
    second: Second, // [0..61]
    minute: Minute, // [0..59]
    hour: Hour, // [0-23]
    day: Day, // [0-31]
    month: Month, // [1-12]
    year: Year,
    weekday: DayOfWeek,

    const Self = @This();

    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (fmt.len == 0) @compileError("DateTime: format string can't be empty");

        @setEvalBranchQuota(100000);

        comptime var s = 0;
        comptime var e = 0;
        comptime var next: ?FormatSeq = null;
        inline for (fmt, 0..) |c, i| {
            e = i + 1;
            // std.debug.print("test: {s}\n", .{fmt[s..e]});
            if (comptime std.meta.stringToEnum(FormatSeq, fmt[s..e])) |tag| {
                // std.debug.print("next {any}\n", .{tag});
                next = tag;
                if (i < fmt.len - 1) continue;
            }

            if (next) |tag| {
                // std.debug.print("tag {any}\n", .{tag});
                switch (tag) {
                    .M => try writer.print("{}", .{@intFromEnum(self.month)}),
                    .Mo => try printOrdinal(writer, @intFromEnum(self.month)),
                    .MO => try printOrdinalSuperscript(writer, @intFromEnum(self.month)),
                    .Mm => try writer.writeAll(self.month.veryShortName()),
                    .MM => try writer.print("{:0>2}", .{@intFromEnum(self.month)}),
                    .MMM => try writer.writeAll(self.month.shortName()),
                    .MMMM => try writer.writeAll(self.month.longName()),

                    .Q => try writer.print("{}", .{self.month.quarter()}),
                    .Qo => try printOrdinal(writer, self.month.quarter()),
                    .QO => try printOrdinalSuperscript(writer, self.month.quarter()),

                    .D => try writer.print("{}", .{self.day}),
                    .Do => try printOrdinal(writer, self.day),
                    .DO => try printOrdinalSuperscript(writer, self.day),
                    .DD => try writer.print("{:0>2}", .{self.day}),

                    .DDD => try writer.print("{}", .{self.dayOfThisYear()}),
                    .DDDo => try printOrdinal(writer, self.dayOfThisYear()),
                    .DDDO => try printOrdinalSuperscript(writer, self.dayOfThisYear()),
                    .DDDD => try writer.print("{:0>3}", .{self.dayOfThisYear()}),

                    .d => try writer.print("{}", .{self.weekday.weekdayNumber()}),
                    .do => try printOrdinal(writer, self.weekday.weekdayNumber()),
                    .dO => try printOrdinalSuperscript(writer, self.weekday.weekdayNumber()),
                    .dd => try writer.writeAll(self.weekday.veryShortName()),
                    .ddd => try writer.writeAll(self.weekday.shortName()),
                    .dddd => try writer.writeAll(self.weekday.longName()),

                    .e => try writer.print("{}", .{self.weekday.weekdayNumber()}),
                    .E => try writer.print("{}", .{self.weekday.isoWeekdayNumber()}),

                    .w => try writer.print("{}", .{self.dayOfThisYear() / 7}),
                    .wo => try printOrdinal(writer, self.dayOfThisYear() / 7),
                    .wO => try printOrdinalSuperscript(writer, self.dayOfThisYear() / 7),
                    .ww => try writer.print("{:0>2}", .{self.dayOfThisYear() / 7}),

                    .YY => try writer.print("{d:0>2}", .{self.year % 100}),
                    .YYY => try writer.print("{d}", .{self.year}),
                    .YYYY => {
                        if (self.year < 0) {
                            try writer.writeAll("-");
                        }
                        try writer.print("{d:0>4}", .{@abs(self.year)});
                    },

                    .A => try writeTwelveHour(self.hour, .upper),
                    .a => try writeTwelveHour(self.hour, .lower),

                    .H => try writer.print("{}", .{self.hour}),
                    .HH => try writer.print("{:0>2}", .{self.hour}),
                    .h => try writer.print("{}", .{wrap(self.hour, 12)}),
                    .hh => try writer.print("{:0>2}", .{wrap(self.hour, 12)}),
                    .k => try writer.print("{}", .{wrap(self.hour, 24)}),
                    .kk => try writer.print("{:0>2}", .{wrap(self.hour, 24)}),

                    .m => try writer.print("{}", .{self.minute}),
                    .mm => try writer.print("{:0>2}", .{self.minute}),

                    .s => try writer.print("{d}", .{self.second}),
                    .ss => try writer.print("{d:0>2}", .{self.second}),

                    .S => try writer.print("{d:>1}", .{self.nanosecond / tenthsPerNanoSecond}),
                    .SS => try writer.print("{d:0>2}", .{self.nanosecond / hundredthsPerNanoSecond}),
                    .SSS => try writer.print("{d:0>3}", .{self.nanosecond / milliSecondsPerNanoSecond}),
                    .SSSS => try writer.print("{d:0>4}", .{self.nanosecond / (milliSecondsPerNanoSecond / 10)}),
                    .SSSSS => try writer.print("{d:0>5}", .{self.nanosecond / (milliSecondsPerNanoSecond / 100)}),
                    .SSSSSS => try writer.print("{d:0>6}", .{self.nanosecond / microSecondsPerNanoSecond}),
                    .SSSSSSS => try writer.print("{d:0>7}", .{self.nanosecond / (microSecondsPerNanoSecond / 10)}),
                    .SSSSSSSS => try writer.print("{d:0>8}", .{self.nanosecond / (microSecondsPerNanoSecond / 100)}),
                    .SSSSSSSSS => try writer.print("{d:0>9}", .{self.nanosecond}),

                    // .z => try writer.writeAll(@tagName(self.timezone)),
                    // .Z => try writer.writeAll("+00:00"),
                    // .ZZ => try writer.writeAll("+0000"),

                    // .x => try writer.print("{}", .{self.toUnixMilli()}),
                    // .X => try writer.print("{}", .{self.toUnix()}),
                }
                next = null;
                s = i;
            }

            switch (c) {
                ',', ' ', ':', '-', '.', 'T', 'W' => {
                    try writer.writeAll(&.{c});
                    s = i + 1;
                    continue;
                },
                else => {},
            }
        }
    }

    pub fn formatAlloc(self: Self, alloc: std.mem.Allocator, comptime fmt: []const u8) ![]const u8 {
        var list = std.ArrayList(u8).init(alloc);
        defer list.deinit();

        try self.format(fmt, .{}, list.writer());
        return list.toOwnedSlice();
    }

    const FormatSeq = enum {
        M, // 1 2 ... 11 12 (month, numeric)
        Mo, // 1st 2nd ... 11th 12th (month, numeric ordinal)
        MO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ ... 11ᵗʰ 12ᵗʰ
        MM, // 01 02 ... 11 12 (month, numeric ordinal)
        Mm, // Ja, Fe, Ma ... No, De (very short month name)
        MMM, // Jan Feb ... Nov Dec (short month name)
        MMMM, // January February ... November December (long month name)
        Q, // 1 2 3 4 (quarter)
        Qo, // 1st 2nd 3rd 4th (quarter)
        QO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ 4ᵗʰ (quarter)
        D, // 1 2 ... 30 31 (day of the month)
        Do, // 1st 2nd ... 30th 31st (day of the month, ordinal)
        DO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ... 30ᵗʰ 31ˢᵗ (day of the month, ordinal)
        DD, // 01 02 ... 30 31 (day of the month, zero padded)
        DDD, // 1 2 ... 364 365
        DDDo, // 1st 2nd ... 364th 365th (day of the year, ordinal)
        DDDO, // 1ˢᵗ 2ⁿᵈ ... 364ᵗʰ 365ᵗʰ (day of the year, ordinal)
        DDDD, // 001 002 ... 364 365 (day of the year)
        d, // 0 1 ... 5 6 (day of the week)
        do, // 0th 1st 2nd 3rd ... 5th 6th (day of the week, ordinal)
        dO, // 0ᵗʰ 1ˢᵗ 2ⁿᵈ 3ʳᵈ ... 5ᵗʰ 6ᵗʰ (day of the week, ordinal)
        dd, // Su Mo ... Fr Sa (day of the week, very short name)
        ddd, // Sun Mon ... Fri Sat (day of the week, short name)
        dddd, // Sunday Monday ... Friday Saturday (day of the week, long name)
        e, // 0 1 ... 5 6 (locale)
        E, // 1 2 ... 6 7 (ISO)
        w, // 1 2 ... 52 53
        wo, // 1st 2nd 3rd 4th ... 52nd 53rd
        wO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ 4th ... 52ⁿᵈ 53ʳᵈ
        ww, // 01 02 ... 52 53
        YY, // 70 71 ... 29 30 (year, last two digits only)
        YYY, // 1 2 ... 1970 1971 ... 2029 2030 (year)
        YYYY, // 0001 0002 ... 1970 1971 ... 2029 2030 (year, zero padded to 4 digits)
        // N, // BC AD
        // NN, // Before Christ ... Anno Domini
        A, // AM PM (ante/post meridian, upper case)
        a, // am pm (ante/post meridian, lower case)
        H, // 0 1 ... 22 23 (hour, zero padded)
        HH, // 00 01 ... 22 23 (hour, zero padded)
        h, // 1 2 ... 11 12 (hour, 12 hour clock)
        hh, // 01 02 ... 11 12 (hour, 12 hour clock, zero padded)
        k, // 1 2 ... 23 24
        kk, // 01 02 ... 23 24
        m, // 0 1 ... 58 59 (minute)
        mm, // 00 01 ... 58 59 (minute, zero padded)
        s, // 0 1 ... 58 59 (second)
        ss, // 00 01 ... 58 59 (second, zero padded)
        S, // 0 1 ... 8 9 (tenths of a second)
        SS, // 00 01 ... 98 99(hundredths second fraction)
        SSS, // 000 001 ... 998 999 (milliseconds)
        SSSS, // 0000 0000 ... 9998 9999 (hundreds of microseconds)
        SSSSS, // 00000 00000 ... 99998 99999 (tens of microseconds)
        SSSSSS, // 000000 000000 ... 999998 999999 (microseconds)
        SSSSSSS, // 0000000 00000000 ... 9999998 9999999 (hundreds of nanoseconds)
        SSSSSSSS, // 00000000 000000000 ... 99999998 99999999 (tens of nanoseconds)
        SSSSSSSSS, // 000000000 000000000 ... 999999998 999999999 (nanoseconds)
        // z, // EST CST ... MST PST
        // Z, // -07:00 -06:00 ... +06:00 +07:00
        // ZZ, // -0700 -0600 ... +0600 +0700
        // x, // unix milli
        // X, // unix
    };

    pub fn dayOfThisYear(self: Self) u9 {
        return self.month.daysBefore(self.year) + self.day;
    }
};

test "formatTest" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const epoch = DateTime{
        .nanosecond = 123456789,
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = .Jan,
        .year = 1970,
        .weekday = .Fri,
    };
    const cases = [_]struct { datetime: DateTime, fmt: []const u8, result: []const u8 }{
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSSS",
            .result = "1970-01-01T00:00:00.123456789",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSS",
            .result = "1970-01-01T00:00:00.12345678",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSS",
            .result = "1970-01-01T00:00:00.1234567",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSS",
            .result = "1970-01-01T00:00:00.123456",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSS",
            .result = "1970-01-01T00:00:00.12345",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSS",
            .result = "1970-01-01T00:00:00.1234",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSS",
            .result = "1970-01-01T00:00:00.123",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SS",
            .result = "1970-01-01T00:00:00.12",
        },
        .{
            .datetime = epoch,
            .fmt = "YYYY-MM-DDTHH:mm:ss.S",
            .result = "1970-01-01T00:00:00.1",
        },
    };

    inline for (cases) |case| {
        var array = std.ArrayList(u8).init(allocator);
        defer array.deinit();

        try case.datetime.format(case.fmt, .{}, array.writer());

        std.testing.expect(std.mem.eql(u8, array.items, case.result)) catch |err| {
            std.debug.print("{s} {s} {s}\n", .{
                case.fmt,
                case.result,
                array.items,
            });
            return err;
        };
    }
}

pub const tenthsPerNanoSecond = hundredthsPerNanoSecond * 10;
pub const hundredthsPerNanoSecond = milliSecondsPerNanoSecond * 10;
pub const milliSecondsPerNanoSecond = microSecondsPerNanoSecond * 1_000;
pub const microSecondsPerNanoSecond = 1_000;
pub const nanoSecondsPerSecond = microSecondsPerSecond * 1_000;
pub const microSecondsPerSecond = milliSecondsPerSecond * 1_000;
pub const milliSecondsPerSecond = 1_000;
pub const secondsPerMinute = 60;
pub const minutesPerHour = 60;
pub const secondsPerHour = minutesPerHour * secondsPerMinute;
pub const hoursPerDay = 24;
pub const secondsPerDay = hoursPerDay * minutesPerHour * secondsPerMinute;

pub const Instant = struct {
    timestamp: i128,
    timezone: []const u8,

    const Self = @This();

    pub fn now() Self {
        return Self{
            .timestamp = std.time.nanoTimestamp(),
            .timezone = "UTC",
        };
    }

    pub fn utc() Self {
        return Self{
            .timestamp = std.time.nanoTimestamp(),
            .timezone = "UTC",
        };
    }

    pub fn fromNanoTimeStamp(timestamp: i128) Self {
        return Self{
            .timestamp = timestamp,
            .timezone = "UTC",
        };
    }

    pub fn asDateTime(self: Self) DateTime {
        const nanosecond: Nanosecond = @intCast(@mod(
            self.timestamp,
            nanoSecondsPerSecond,
        ));
        var seconds = @divTrunc(
            self.timestamp,
            nanoSecondsPerSecond,
        );
        const second: Second = @intCast(@mod(
            seconds,
            secondsPerMinute,
        ));
        seconds -= second;

        const minute: Minute = @intCast(@divTrunc(
            @mod(
                seconds,
                secondsPerHour,
            ),
            secondsPerMinute,
        ));
        seconds -= @as(u32, minute) * secondsPerMinute;

        const hour: Hour = @intCast(@divTrunc(
            @mod(
                seconds,
                secondsPerDay,
            ),
            secondsPerHour,
        ));
        seconds -= @as(u32, hour) * secondsPerHour;

        const days: i32 = @intCast(@divTrunc(
            seconds,
            secondsPerDay,
        ));

        const date = civilFromDays(days);

        return DateTime{
            .year = date.year,
            .month = date.month,
            .day = date.day,
            .hour = hour,
            .minute = minute,
            .second = second,
            .nanosecond = nanosecond,
            .weekday = weekdayFromDays(days),
        };
    }
    // pub fn format(self: @This()) []const u8 {
    //     std.debug.print("{i} {i} {i} {i} {i} {i} {i}", .{ year, month, mday, hour, minute, second, nanosecond });
    // }
};

test "instantTest" {
    const cases = [_]struct {
        instant: Instant,
        datetime: DateTime,
    }{
        .{
            .instant = Instant{
                .timestamp = 0,
                .timezone = "UTC",
            },
            .datetime = DateTime{
                .year = 1970,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 0,
                .second = 0,
                .nanosecond = 0,
                .weekday = .Thu,
            },
        },
        .{
            .instant = Instant{
                .timestamp = 1697316872549526016,
                .timezone = "UTC",
            },
            .datetime = DateTime{
                .year = 2023,
                .month = .Oct,
                .day = 14,
                .hour = 20,
                .minute = 54,
                .second = 32,
                .nanosecond = 549526016,
                .weekday = .Sat,
            },
        },
    };

    inline for (cases) |case| {
        const datetime = case.instant.asDateTime();
        try std.testing.expectEqual(case.datetime, datetime);
    }
}

pub fn daysFromCivil(year: Year, month: Month, d: Day) i32 {
    std.debug.assert(d >= 1 and d <= month.lastDay(year));

    const janOrFeb = month == .Jan or month == .Feb;

    const m = month.monthNumber();

    const y = year - (if (janOrFeb) @as(Year, 1) else @as(Year, 0));

    const era = @divTrunc(
        if (y >= 0) y else y - 399,
        400,
    );

    const yoe = y - era * 400;
    std.debug.assert(yoe >= 0 and yoe <= 399);

    const doy = @divTrunc(
        153 * (m + (if (!janOrFeb) @as(i32, -3) else @as(i32, 9))) + 2,
        5,
    ) + d - 1;
    std.debug.assert(doy >= 0 and doy <= 365);

    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    std.debug.assert(doe >= 0 and doe <= 146096);

    return era * 146097 + doe - 719468;
}

test "daysFromCivil" {
    const tests = [_]struct { year: Year, month: Month, day: Day, result: i128 }{
        .{ .year = 1970, .month = .Jan, .day = 1, .result = 0 },
        .{ .year = 1970, .month = .Jan, .day = 2, .result = 1 },
        .{ .year = 1969, .month = .Dec, .day = 31, .result = -1 },
    };

    for (tests) |case| {
        const result = daysFromCivil(case.year, case.month, case.day);
        try std.testing.expect(std.meta.eql(case.result, result));
    }
}

const Date = struct {
    year: Year,
    month: Month,
    day: Day,
};

pub fn civilFromDays(days: i32) Date {
    const z = days + 719468;

    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);

    const doe = (z - era * 146097);
    std.debug.assert(doe >= 0 and doe <= 146096);

    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    std.debug.assert(yoe >= 0 and yoe <= 399);

    const y = yoe + era * 400;

    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    std.debug.assert(doy >= 0 and doy <= 365);

    const mp = @divTrunc(5 * doy + 2, 153);
    std.debug.assert(mp >= 0 and mp <= 11);

    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    std.debug.assert(d >= 1 and d <= 31);

    const m = mp + (if (mp < 10) @as(i32, 3) else @as(i32, -9));
    std.debug.assert(m >= 1 and m <= 12);

    return Date{
        .year = y + (if (m <= 2) @as(Year, 1) else @as(Year, 0)),
        .month = @enumFromInt(m),
        .day = @intCast(d),
    };
}

test "civilFromDays" {
    const tests = [_]struct { days: i32, result: Date }{
        .{
            .days = 0,
            .result = Date{
                .year = 1970,
                .month = .Jan,
                .day = 1,
            },
        },
        .{
            .days = 1,
            .result = Date{
                .year = 1970,
                .month = .Jan,
                .day = 2,
            },
        },
        .{
            .days = -1,
            .result = Date{
                .year = 1969,
                .month = .Dec,
                .day = 31,
            },
        },
        .{
            .days = 19605,
            .result = Date{
                .year = 2023,
                .month = .Sep,
                .day = 5,
            },
        },
    };

    for (tests) |case| {
        const result = civilFromDays(case.days);
        try std.testing.expectEqual(case.result, result);
    }
}

const DayOfWeek = enum(u3) {
    Sun = 0,
    Mon = 1,
    Tue = 2,
    Wed = 3,
    Thu = 4,
    Fri = 5,
    Sat = 6,

    const Self = @This();

    pub fn next(self: Self) Self {
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

    pub fn prev(self: Self) Self {
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

    pub fn veryShortName(self: Self) []const u8 {
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

    pub fn shortName(self: Self) []const u8 {
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

    pub fn longName(self: Self) []const u8 {
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

    pub fn weekdayNumber(self: Self) u3 {
        return @intFromEnum(self);
    }

    pub fn isoWeekdayNumber(self: Self) u3 {
        return if (self == .Sun) 7 else @intFromEnum(self);
    }
};

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
            // try std.debug.print("{any} {any} {any}\n", .{})
            try std.testing.expect(result == difference[start][end]);
        }
    }
}

pub fn weekdayFromDays(z: i32) DayOfWeek {
    return @as(
        DayOfWeek,
        @enumFromInt(if (z >= -4) @rem(z + 4, 7) else @rem(z + 5, 7) + 6),
    );
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
        const result = weekdayFromDays(case.days);
        try std.testing.expect(std.meta.eql(case.result, result));
    }
}

fn printOrdinal(writer: anytype, num: u16) !void {
    try writer.print("{}", .{num});
    try writer.writeAll(if (num >= 11 and num <= 13) "th" else switch (num % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    });
}

test "testPrintOrdinal" {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    const cases = [_]struct { number: u16, result: []const u8 }{
        .{
            .number = 0,
            .result = "0th",
        },
        .{
            .number = 1,
            .result = "1st",
        },
        .{
            .number = 2,
            .result = "2nd",
        },
        .{
            .number = 3,
            .result = "3rd",
        },
        .{
            .number = 4,
            .result = "4th",
        },
        .{
            .number = 11,
            .result = "11th",
        },
        .{
            .number = 12,
            .result = "12th",
        },
        .{
            .number = 13,
            .result = "13th",
        },
        .{
            .number = 14,
            .result = "14th",
        },
        .{
            .number = 31,
            .result = "31st",
        },
    };

    inline for (cases) |case| {
        var array = std.ArrayList(u8).init(allocator);
        defer array.deinit();

        try printOrdinal(array.writer(), case.number);
        std.testing.expect(std.mem.eql(u8, array.items, case.result)) catch |err| {
            std.debug.print("{d} failed {s} != {s}\n", .{ case.number, array.items, case.result });
            return err;
        };
    }
}

fn printOrdinalSuperscript(writer: anytype, num: u16) !void {
    try writer.print("{}", .{num});
    try writer.writeAll(if (num >= 11 and num <= 13) "ᵗʰ" else switch (num % 10) {
        1 => "ˢᵗ",
        2 => "ⁿᵈ",
        3 => "ʳᵈ",
        else => "ᵗʰ",
    });
}

test "testPrintOrdinalSuperscript" {
    // var buffer: [1024]u8 = undefined;
    // var fbs = std.io.fixedBufferStream(buffer);
    // const allocator = fba.allocator();

    const cases = [_]struct { number: u16, result: []const u8 }{
        .{
            .number = 0,
            .result = "0ᵗʰ",
        },
        .{
            .number = 1,
            .result = "1ˢᵗ",
        },
        .{
            .number = 2,
            .result = "2ⁿᵈ",
        },
        .{
            .number = 3,
            .result = "3ʳᵈ",
        },
        .{
            .number = 4,
            .result = "4ᵗʰ",
        },
        .{
            .number = 11,
            .result = "11ᵗʰ",
        },
        .{
            .number = 12,
            .result = "12ᵗʰ",
        },
        .{
            .number = 13,
            .result = "13ᵗʰ",
        },
        .{
            .number = 14,
            .result = "14ᵗʰ",
        },
        .{
            .number = 31,
            .result = "31ˢᵗ",
        },
    };

    inline for (cases) |case| {
        var buffer: [16]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buffer);
        var writer = stream.writer();

        try printOrdinalSuperscript(writer, case.number);
        std.testing.expect(std.mem.eql(u8, stream.getWritten(), case.result)) catch |err| {
            std.debug.print("{d} failed {s} != {s}\n", .{ case.number, stream.getWritten(), case.result });
            return err;
        };
    }
}

fn printLongName(writer: anytype, index: u16, names: []const []const u8) !void {
    try writer.writeAll(names[index]);
}

fn wrap(val: u16, at: u16) u16 {
    var tmp = val % at;
    return if (tmp == 0) at else tmp;
}

test "asDateTime" {
    _ = Instant.utc().asDateTime();
}

fn isLeap(year: i32) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

test "isLeap" {
    try std.testing.expectEqual(false, isLeap(2005));
    try std.testing.expectEqual(true, isLeap(2096));
    try std.testing.expectEqual(false, isLeap(2100));
    try std.testing.expectEqual(true, isLeap(2400));
}

test "bigTest" {
    const ystart = -1000000;
    var prev_z: i32 = daysFromCivil(ystart, .Jan, 1) - 1;
    try std.testing.expect(prev_z < 0);
    var prev_wd = weekdayFromDays(prev_z);
    try std.testing.expect(0 <= @intFromEnum(prev_wd) and @intFromEnum(prev_wd) <= 6);
    var y: Year = ystart;
    while (y <= -ystart) {
        for ([_]Month{ .Jan, .Feb, .Mar, .Apr, .May, .Jun, .Jul, .Aug, .Sep, .Oct, .Nov, .Dec }) |m| {
            var d: Day = 1;
            const e = m.lastDay(y);
            while (d <= e) {
                // std.debug.print("{d} {d} {d}\n", .{ y, @intFromEnum(m), d });
                const z = daysFromCivil(y, m, d);
                // std.debug.print("{d} {d}\n", .{ prev_z, z });
                try std.testing.expect(prev_z < z);
                try std.testing.expect(z == prev_z + 1);
                const date = civilFromDays(z);
                try std.testing.expect(y == date.year);
                try std.testing.expect(m == date.month);
                try std.testing.expect(d == date.day);
                const wd = weekdayFromDays(z);
                try std.testing.expect(0 <= @intFromEnum(wd) and @intFromEnum(wd) <= 6);
                try std.testing.expect(wd == prev_wd.next());
                try std.testing.expect(prev_wd == wd.prev());
                prev_z = z;
                prev_wd = wd;
                d += 1;
            }
        }
        y += 1;
    }
}
