const DateTime = @This();

const std = @import("std");
const log = std.log.scoped(.date_time);

const Year = @import("year.zig").Year;
const Month = @import("month.zig").Month;
const Day = @import("day.zig").Day;
const Hour = @import("hour.zig").Hour;
const Minute = @import("minute.zig").Minute;
const Second = @import("second.zig").Second;
const Nanosecond = @import("nanosecond.zig").Nanosecond;
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Date = @import("Date.zig");
const Instant = @import("Instant.zig");
const FormatTag = @import("formatsequence.zig").FormatTag;
const writeTwelveHour = @import("hour.zig").writeTwelveHour;
const ordinal = @import("ordinal.zig");
const print = @import("print.zig");
const read = @import("read.zig");

nanosecond: Nanosecond = 0, // [0..999999999]
second: Second = 0, // [0..61]
minute: Minute = 0, // [0..59]
hour: Hour = 0, // [0-23]
day: Day = 1, // [0-31]
month: Month = .Jan, // [1-12]
year: Year = 1970,
weekday: DayOfWeek = .Thu,
/// Offset of this local wall-clock time from UTC, in seconds east of UTC:
/// -18000 for -05:00. Zero means the fields are already UTC. Seconds
/// rather than minutes because historical local mean time offsets are not
/// whole minutes: America/Chicago's is -5:50:36.
offset: i32 = 0,

pub const unix_epoch: DateTime = .{
    .nanosecond = 0,
    .second = 0,
    .minute = 0,
    .hour = 0,
    .day = 1,
    .month = .Jan,
    .year = 1970,
    .weekday = .Thu,
    .offset = 0,
};

/// Returns the current time in UTC, read from the `.real` clock of `io`.
pub fn utc(io: std.Io) DateTime {
    return Instant.utc(io).asDateTime();
}

/// Writes the name at `index` in `names` to `writer`.
fn printLongName(writer: anytype, index: u16, names: []const []const u8) !void {
    try writer.writeAll(names[index]);
}

/// Wraps `val` into the range `[1, at]`, mapping a remainder of 0 to `at`
/// (e.g. hour 0 becomes 12 on a 12-hour clock).
fn wrap(val: anytype, at: @TypeOf(val)) @TypeOf(val) {
    const tmp = val % at;
    return if (tmp == 0) at else tmp;
}

/// Recomputes the `weekday` field from the current `year`, `month`, and `day`.
pub fn updateDayOfWeek(self: *DateTime) void {
    const date: Date = .{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    };
    self.weekday = date.dayOfWeek();
}

/// Writes this date/time to `writer` according to `fmt`, a comptime format
/// string made of `FormatTag` sequences (e.g. "YYYY-MM-DDTHH:mm:ss.SSS").
/// The literal characters `,`, ` `, `:`, `-`, `.`, `T`, and `W` are copied
/// through unchanged; any other character that is not part of a format
/// sequence is a compile error. Flushes `writer` before returning.
pub fn format(self: DateTime, comptime fmt: []const u8, writer: *std.Io.Writer) !void {
    if (fmt.len == 0) @compileError("DateTime: format string can't be empty");

    @setEvalBranchQuota(2000000);

    const tokens: []const FormatTag.Tokenizer.Token = comptime tokens: {
        var count = 0;
        {
            var it: FormatTag.Tokenizer = .init(fmt);
            while (it.next()) |_| count += 1;
        }
        var buf: [count]FormatTag.Tokenizer.Token = undefined;
        var index = 0;
        {
            var it: FormatTag.Tokenizer = .init(fmt);
            while (it.next()) |token| {
                buf[index] = token;
                index += 1;
            }
        }
        const final = buf;
        break :tokens &final;
    };

    inline for (tokens) |token| {
        switch (token) {
            .tag => |format_tag| switch (format_tag) {
                .M => try writer.print("{}", .{@intFromEnum(self.month)}),
                .Mo => try print.ordinal(writer, @intFromEnum(self.month), false),
                .MO => try print.ordinal(writer, @intFromEnum(self.month), true),
                .MM => try writer.print("{:0>2}", .{@intFromEnum(self.month)}),
                .MMM => try writer.writeAll(self.month.shortName()),
                .MMMM => try writer.writeAll(self.month.longName()),

                .Q => try writer.print("{}", .{self.month.quarter()}),
                .Qo => try print.ordinal(writer, self.month.quarter(), false),
                .QO => try print.ordinal(writer, self.month.quarter(), true),

                .D => try writer.print("{}", .{self.day}),
                .Do => try print.ordinal(writer, self.day, false),
                .DO => try print.ordinal(writer, self.day, true),
                .DD => try writer.print("{:0>2}", .{self.day}),

                .DDD => try writer.print("{}", .{self.dayOfThisYear()}),
                .DDDo => try print.ordinal(writer, self.dayOfThisYear(), false),
                .DDDO => try print.ordinal(writer, self.dayOfThisYear(), true),
                .DDDD => try writer.print("{:0>3}", .{self.dayOfThisYear()}),

                .d => try writer.print("{}", .{self.weekday.weekdayNumber()}),
                .do => try print.ordinal(writer, self.weekday.weekdayNumber(), false),
                .dO => try print.ordinal(writer, self.weekday.weekdayNumber(), true),
                .dd => try writer.writeAll(self.weekday.veryShortName()),
                .ddd => try writer.writeAll(self.weekday.shortName()),
                .dddd => try writer.writeAll(self.weekday.longName()),

                .e => try writer.print("{}", .{self.weekday.weekdayNumber()}),
                .E => try writer.print("{}", .{self.weekday.isoWeekdayNumber()}),

                .w => try writer.print("{}", .{self.dayOfThisYear() / 7}),
                .wo => try print.ordinal(writer, self.dayOfThisYear() / 7, false),
                .wO => try print.ordinal(writer, self.dayOfThisYear() / 7, true),
                .ww => try writer.print("{:0>2}", .{self.dayOfThisYear() / 7}),

                .YY => try writer.print("{d:0>2}", .{self.year % 100}),
                .YYY => try writer.print("{d}", .{self.year}),
                .YYYY => {
                    if (self.year < 0) {
                        try writer.writeAll("-");
                    }
                    try writer.print("{d:0>4}", .{@abs(self.year)});
                },

                .A => try writeTwelveHour(self.hour, .upper, writer),
                .a => try writeTwelveHour(self.hour, .lower, writer),

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

                .S,
                .SS,
                .SSS,
                .SSSS,
                .SSSSS,
                .SSSSSS,
                .SSSSSSS,
                .SSSSSSSS,
                .SSSSSSSSS,
                => {
                    try writer.print(
                        std.fmt.comptimePrint("{{d:0>{d}}}", .{@tagName(format_tag).len}),
                        .{
                            format_tag.convertFractionalSeconds(self.nanosecond),
                        },
                    );
                },

                // .N => brk: {
                //     if (self.year < 0) {
                //         writer.writeAll("BCE");
                //         break :brk;
                //     }
                //     if (self.year > 0) {
                //         writer.writeAll("CE");
                //         break :brk;
                //     }
                // },
                // .NN => brk: {
                //     if (self.year < 0) {
                //         writer.writeAll("Before Common Era");
                //         break :brk;
                //     }
                //     if (self.year > 0) {
                //         writer.writeAll("CE");
                //         break :brk;
                //     }
                // },

                .Z => try print.offset(writer, self.offset, .colon),
                .ZZ => try print.offset(writer, self.offset, .none),

                // .x => try writer.print("{}", .{self.toUnixMilli()}),
                // .X => try writer.print("{}", .{self.toUnix()}),
            },
            .char => |c| switch (c) {
                ',', ' ', ':', '-', '.', 'T', 'W' => try writer.writeAll(&.{c}),
                else => @compileError(std.fmt.comptimePrint(
                    "DateTime: unsupported literal character '{c}' in format string",
                    .{c},
                )),
            },
        }
    }

    try writer.flush();
}

/// Like `format`, but returns the formatted string as a slice allocated
/// with `alloc`. The caller owns the returned memory.
pub fn formatAlloc(self: DateTime, alloc: std.mem.Allocator, comptime fmt: []const u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    try self.format(fmt, &buf.writer);
    return try buf.toOwnedSlice();
}

/// Like `formatAlloc`, but the returned slice is terminated with `sentinel`.
pub fn formatAllocSentinel(self: DateTime, alloc: std.mem.Allocator, comptime fmt: []const u8, comptime sentinel: u8) ![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(alloc);
    errdefer buf.deinit();

    try self.format(fmt, &buf.writer);
    return try buf.toOwnedSliceSentinel(sentinel);
}

const AmPm = enum {
    none,
    am,
    pm,
};

pub const ParseError = error{
    IllegalToken,
    InvalidCharacter,
    Overflow,
    ParseError,
    TooLong,
    TooShort,
    Underflow,
} || Month.ParseError || DayOfWeek.ParseError;

/// The result of a successful parse: the prefix of the input that was
/// consumed and the value it parsed to.
pub const ParseResult = struct {
    str: []const u8,
    value: DateTime,
};

/// Parses `value` according to the comptime `format_string`, relative to the
/// Unix epoch: date fields missing from the format string default to
/// 1970-01-01 and time fields default to zero. See `parseRelativeTo`.
pub fn parse(comptime format_string: []const u8, value: []const u8) ParseError!ParseResult {
    return parseRelativeTo(format_string, .unix_epoch, value);
}

/// Parses `value` according to the comptime `format_string`, a string of
/// `FormatTag` sequences (e.g. "MMM D H:mm:ss"). Date fields missing from
/// the format string are taken from `relative_to`; time-of-day fields
/// always default to zero. A parsed day of the week is checked against the
/// computed date and `error.ParseError` is returned on mismatch. The
/// quarter (`Q`) and week-of-year (`w`) sequences cannot be parsed and
/// cause `error.IllegalToken`.
pub fn parseRelativeTo(comptime format_string: []const u8, relative_to: DateTime, value: []const u8) ParseError!ParseResult {
    const tokens: []const FormatTag.Tokenizer.Token = comptime tokens: {
        @setEvalBranchQuota(200000);
        var count = 0;
        {
            var it: FormatTag.Tokenizer = .init(format_string);
            while (it.next()) |token| {
                switch (token) {
                    .tag => |tag| switch (tag) {
                        .Q,
                        .Qo,
                        .QO,
                        .w,
                        .wo,
                        .wO,
                        .ww,
                        => return error.IllegalToken,
                        else => {},
                    },
                    .char => {},
                }
                count += 1;
            }
        }
        var tokens: [count]FormatTag.Tokenizer.Token = undefined;
        var index = 0;
        {
            var it: FormatTag.Tokenizer = .init(format_string);
            while (it.next()) |token| {
                tokens[index] = token;
                index += 1;
            }
        }
        const final = tokens;
        break :tokens &final;
    };

    var datetime: DateTime = relative_to;
    datetime.hour = 0;
    datetime.minute = 0;
    datetime.second = 0;
    datetime.nanosecond = 0;

    var am_pm: AmPm = .none;
    var day_of_week: ?DayOfWeek = null;
    var day_of_year: ?u16 = null;
    var left = value;

    // Unrolled, as `format` does with the same token list. The tokens are
    // comptime known, so this turns a switch over every sequence in the
    // enum into straight-line code for the handful the format string
    // actually uses.
    inline for (tokens) |token| {
        switch (token) {
            .tag => |tag| {
                switch (tag) {
                    .YY => {
                        const year = read.int(left, 2);
                        datetime.year = @as(Year, @intCast(read.digits(year))) + 2000;
                        left = left[year.len..];
                    },
                    .YYYY, .YYY => {
                        datetime.year = year: {
                            const str = read.int(left, 4);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .YYYY and str.len != 4) return error.ParseError;
                            const year: Year = @intCast(read.digits(str));
                            left = left[str.len..];
                            break :year year;
                        };
                    },
                    .MMMM => {
                        datetime.month = month: {
                            for (1..left.len + 1) |l| {
                                if (Month.long_map.get(left[0..l])) |m| {
                                    left = left[l..];
                                    break :month m;
                                }
                            }
                            return error.ParseError;
                        };
                    },
                    .MMM => {
                        datetime.month = month: {
                            for (1..left.len + 1) |l| {
                                if (Month.short_map.get(left[0..l])) |m| {
                                    left = left[l..];
                                    break :month m;
                                }
                            }
                            return error.ParseError;
                        };
                    },
                    .MM, .M => {
                        datetime.month = month: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .MM and str.len != 2) return error.ParseError;
                            defer left = left[str.len..];
                            break :month try Month.parseInt(str);
                        };
                    },
                    .Mo, .MO => {
                        const map = switch (tag) {
                            .Mo => ordinal.Ordinal(.normal).map,
                            .MO => ordinal.Ordinal(.superscript).map,
                            else => unreachable,
                        };
                        datetime.month = month: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            const month = try Month.parseInt(str);
                            left = left[str.len..];
                            for (1..left.len + 1) |l| {
                                if (map.get(left[0..l])) |_| {
                                    left = left[l..];
                                    break :month month;
                                }
                            }
                            return error.ParseError;
                        };
                    },
                    .DD, .D => {
                        datetime.day = day: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .DD and str.len != 2) return error.ParseError;
                            const day = read.digits(str);
                            if (day < 1 or day > 31) return error.ParseError;
                            left = left[str.len..];
                            break :day @intCast(day);
                        };
                    },
                    .Do, .DO => {
                        const map = switch (tag) {
                            .Do => ordinal.Ordinal(.normal).map,
                            .DO => ordinal.Ordinal(.superscript).map,
                            else => unreachable,
                        };
                        datetime.day = day: {
                            const str = read.int(left, 3);
                            if (str.len == 0) return error.ParseError;
                            const day = read.digits(str);
                            if (day < 1 or day > 31) return error.ParseError;
                            left = left[str.len..];
                            for (1..left.len + 1) |l| {
                                if (map.get(left[0..l])) |_| {
                                    left = left[l..];
                                    break :day day;
                                }
                            }
                            return error.ParseError;
                        };
                    },
                    .DDDD, .DDD, .DDDo, .DDDO => {
                        day_of_year = doy: {
                            const str = read.int(left, 3);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .DDDD and str.len != 3) return error.ParseError;
                            const doy = read.digits(str);
                            if (doy < 1 or doy > 366) return error.ParseError;
                            left = left[str.len..];
                            switch (tag) {
                                .DDDo, .DDDO => ordinal: {
                                    const map = switch (tag) {
                                        .DDDo => ordinal.Ordinal(.normal).map,
                                        .DDDO => ordinal.Ordinal(.superscript).map,
                                        else => unreachable,
                                    };
                                    for (1..left.len + 1) |l| {
                                        if (map.get(left[0..l])) |_| {
                                            left = left[l..];
                                            break :ordinal;
                                        }
                                    }
                                    return error.ParseError;
                                },
                                .DDDD, .DDD => {},
                                else => unreachable,
                            }
                            break :doy @intCast(doy);
                        };
                    },
                    .HH, .H, .hh, .h => {
                        datetime.hour = hour: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            switch (tag) {
                                .HH, .hh => if (str.len != 2) return error.ParseError,
                                .H, .h => {},
                                else => unreachable,
                            }
                            const hour = read.digits(str);
                            switch (tag) {
                                .HH, .H => if (hour >= 24) return error.ParseError,
                                .hh, .h => if (hour < 1 or hour > 12) return error.ParseError,
                                else => unreachable,
                            }
                            left = left[str.len..];
                            break :hour @intCast(hour);
                        };
                    },
                    .kk, .k => {
                        datetime.hour = hour: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .kk and str.len != 2) return error.ParseError;
                            var hour = read.digits(str);
                            if (hour > 24) return error.ParseError;
                            if (hour == 24) hour = 0;
                            left = left[str.len..];
                            break :hour @intCast(hour);
                        };
                    },
                    .mm, .m => {
                        datetime.minute = minute: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .mm and str.len != 2) return error.ParseError;
                            const minute = read.digits(str);
                            if (minute > 59) return error.ParseError;
                            left = left[str.len..];
                            break :minute @intCast(minute);
                        };
                    },
                    .ss, .s => {
                        datetime.second = second: {
                            const str = read.int(left, 2);
                            if (str.len == 0) return error.ParseError;
                            if (tag == .ss and str.len != 2) return error.ParseError;
                            const second = read.digits(str);
                            if (second > 60) return error.ParseError;
                            left = left[str.len..];
                            break :second @intCast(second);
                        };
                    },
                    .SSSSSSSSS,
                    .SSSSSSSS,
                    .SSSSSSS,
                    .SSSSSS,
                    .SSSSS,
                    .SSSS,
                    .SSS,
                    .SS,
                    .S,
                    => {
                        const len = @tagName(tag).len;
                        datetime.nanosecond = try read.nanosecond(left, len);
                        left = left[len..];
                    },
                    // .NN => {
                    //     const map = std.StaticStringMapWithEql(i2, std.ascii.eqlIgnoreCase).initComptime(.{
                    //         .{ "Before Christ", -1 },
                    //         .{ "Anno Domini", 1 },
                    //         .{ "Before Common Era", -1 },
                    //         .{ "Common Era", 1 },
                    //     });
                    //     year_sign = sign: {
                    //         for (1..left.len + 1) |l| {
                    //             if (map.get(left[0..l])) |sign| {
                    //                 left = left[l..];
                    //                 break :sign sign;
                    //             }
                    //         }
                    //         return error.ParseError;
                    //     };
                    // },
                    // .N => {
                    //     const map = std.StaticStringMapWithEql(i2, std.ascii.eqlIgnoreCase).initComptime(.{
                    //         .{ "BC", -1 },
                    //         .{ "AD", 1 },
                    //         .{ "BCE", -1 },
                    //         .{ "CE", 1 },
                    //     });
                    //     year_sign = sign: {
                    //         for (1..left.len + 1) |l| {
                    //             if (map.get(left[0..l])) |sign| {
                    //                 left = left[l..];
                    //                 break :sign sign;
                    //             }
                    //         }
                    //         return error.ParseError;
                    //     };
                    // },
                    .A, .a => {
                        const map = std.StaticStringMapWithEql(AmPm, std.ascii.eqlIgnoreCase).initComptime(.{
                            .{ "AM", .am },
                            .{ "PM", .pm },
                        });
                        am_pm = am_pm: {
                            for (1..left.len + 1) |l| {
                                if (map.get(left[0..l])) |sign| {
                                    left = left[l..];
                                    break :am_pm sign;
                                }
                            }
                            return error.ParseError;
                        };
                    },
                    .dddd,
                    .ddd,
                    .dd,
                    => {
                        const result = switch (tag) {
                            .dddd => try DayOfWeek.parseLongStr(left),
                            .ddd => try DayOfWeek.parseShortStr(left),
                            .dd => try DayOfWeek.parseVeryShortStr(left),
                            else => unreachable,
                        };
                        left = left[result.str.len..];
                        day_of_week = result.value;
                    },
                    .d, .e, .E, .do, .dO => {
                        day_of_week = dow: {
                            const str = read.int(left, 1);
                            if (str.len != 1) return error.ParseError;
                            var dow = read.digits(str);
                            switch (tag) {
                                .E => {
                                    if (dow < 1 or dow > 7) return error.ParseError;
                                    dow -= 1;
                                },
                                .d, .e, .do, .dO => {
                                    if (dow > 6) return error.ParseError;
                                },
                                else => unreachable,
                            }
                            left = left[str.len..];
                            switch (tag) {
                                .do, .dO => ordinal: {
                                    const map = switch (tag) {
                                        .do => ordinal.Ordinal(.normal).map,
                                        .dO => ordinal.Ordinal(.superscript).map,
                                        else => unreachable,
                                    };
                                    for (1..left.len + 1) |l| {
                                        if (map.get(left[0..l])) |_| {
                                            left = left[l..];
                                            break :ordinal;
                                        }
                                    }
                                    return error.ParseError;
                                },
                                .d, .e, .E => {},
                                else => unreachable,
                            }
                            break :dow std.enums.fromInt(DayOfWeek, @as(u3, @intCast(dow))) orelse return error.ParseError;
                        };
                    },
                    .Z, .ZZ => {
                        datetime.offset = offset: {
                            if (left.len == 0) return error.ParseError;

                            // ISO 8601 writes a zero offset as "Z"; accept
                            // that spelling as well as "+00:00".
                            if (left[0] == 'Z' or left[0] == 'z') {
                                left = left[1..];
                                break :offset 0;
                            }

                            const sign: i32 = switch (left[0]) {
                                '+' => 1,
                                '-' => -1,
                                else => return error.ParseError,
                            };
                            left = left[1..];

                            const hours = read.int(left, 2);
                            if (hours.len != 2) return error.ParseError;
                            left = left[hours.len..];

                            // The colon is what separates the two forms, so
                            // it is required by Z and rejected by ZZ.
                            if (tag == .Z) {
                                if (left.len == 0 or left[0] != ':') return error.ParseError;
                                left = left[1..];
                            }

                            const minutes = read.int(left, 2);
                            if (minutes.len != 2) return error.ParseError;
                            left = left[minutes.len..];

                            const hour: i32 = @intCast(read.digits(hours));
                            const minute: i32 = @intCast(read.digits(minutes));
                            if (hour > 23 or minute > 59) return error.ParseError;
                            break :offset sign * (hour * std.time.s_per_hour + minute * std.time.s_per_min);
                        };
                    },
                    .Q,
                    .Qo,
                    .QO,
                    .w,
                    .wo,
                    .wO,
                    .ww,
                    => {
                        return error.IllegalToken;
                    },
                    // else => {},
                }
            },
            .char => |char| {
                switch (char) {
                    ',',
                    ' ',
                    ':',
                    '-',
                    '.',
                    'T',
                    'W',
                    => {
                        if (left[0] != char) return error.ParseError;
                        left = left[1..];
                    },
                    else => return error.ParseError,
                }
            },
        }
    }

    switch (am_pm) {
        .none => {},
        .am => {
            if (datetime.hour == 0) return error.ParseError;
            if (datetime.hour > 12) return error.ParseError;
            if (datetime.hour == 12) datetime.hour = 0;
        },
        .pm => {
            if (datetime.hour == 0) return error.ParseError;
            if (datetime.hour > 12) return error.ParseError;
            if (datetime.hour < 12) datetime.hour += 12;
        },
    }

    if (day_of_year) |doy| {
        // A day of the year names a complete date by itself, so it
        // replaces whatever month and day were set, and is checked
        // against the length of the year it landed in.
        const length: u16 = if (Month.Feb.lastDay(datetime.year) == 29) 366 else 365;
        if (doy > length) return error.ParseError;

        var month: Month = .Jan;
        var remaining = doy;
        while (remaining > month.lastDay(datetime.year)) {
            remaining -= month.lastDay(datetime.year);
            month = month.next();
        }
        datetime.month = month;
        datetime.day = @intCast(remaining);
    }

    // Every sequence that moves the date leaves the weekday stale, so it
    // is recomputed once here rather than after each of them.
    datetime.updateDayOfWeek();

    if (day_of_week) |dow| {
        if (datetime.weekday != dow) return error.ParseError;
    }

    return .{
        .str = value[0 .. value.len - left.len],
        .value = datetime,
    };
}

/// Returns the 1-based day of the year (1-366).
pub fn dayOfThisYear(self: DateTime) u9 {
    return self.month.daysBefore(self.year) + self.day;
}

/// Returns the same point in time expressed in UTC, that is with the
/// fields shifted back by `offset` minutes and `offset` itself set to
/// zero. The shift rolls over into the neighbouring day, month, and year
/// as needed, and `weekday` is recomputed to match. Seconds and
/// nanoseconds are carried through untouched, so a value holding a leap
/// second keeps it.
pub fn toUtc(self: DateTime) DateTime {
    if (self.offset == 0) return self;

    // A leap second is the 61st second of its minute and has no meaning
    // once shifted, so it is held back and restored afterwards. Every zone
    // offset that is not a whole number of minutes predates leap seconds
    // by decades, so the two never actually meet.
    const leap_second = self.second == 60;

    const date: Date = .{
        .year = self.year,
        .month = self.month,
        .day = self.day,
    };
    const second_of_day = @as(i32, self.hour) * std.time.s_per_hour +
        @as(i32, self.minute) * std.time.s_per_min +
        @as(i32, if (leap_second) 59 else self.second) -
        self.offset;

    const days = date.toDaysSinceStartOfEra() +
        @as(Date.DaysType, @divFloor(second_of_day, std.time.s_per_day));
    const remainder = @mod(second_of_day, std.time.s_per_day);

    const utc_date = Date.fromDaysSinceStartOfEra(days);
    return .{
        .year = utc_date.year,
        .month = utc_date.month,
        .day = utc_date.day,
        .hour = @intCast(@divTrunc(remainder, std.time.s_per_hour)),
        .minute = @intCast(@divTrunc(@mod(remainder, std.time.s_per_hour), std.time.s_per_min)),
        .second = if (leap_second) 60 else @intCast(@mod(remainder, std.time.s_per_min)),
        .nanosecond = self.nanosecond,
        .weekday = DayOfWeek.fromDaysSinceStartOfEra(days),
        .offset = 0,
    };
}

test "parseTest" {
    const cases = [_]struct { value: []const u8, fmt: []const u8, expected: DateTime }{
        .{
            .value = "1970",
            .fmt = "YYYY",
            .expected = .{
                .year = 1970,
            },
        },
        .{
            .value = "2001",
            .fmt = "YYYY",
            .expected = .{
                .year = 2001,
                .weekday = .Mon,
            },
        },
        .{
            .value = "70",
            .fmt = "YY",
            .expected = .{
                .year = 2070,
                .weekday = .Wed,
            },
        },
        .{
            .value = "123456789",
            .fmt = "SSSSSSSSS",
            .expected = .{
                .nanosecond = 123456789,
            },
        },
        .{
            .value = "12345678",
            .fmt = "SSSSSSSS",
            .expected = .{
                .nanosecond = 123456780,
            },
        },
        .{
            .value = "1234567",
            .fmt = "SSSSSSS",
            .expected = .{
                .nanosecond = 123456700,
            },
        },
        .{
            .value = "123456",
            .fmt = "SSSSSS",
            .expected = .{
                .nanosecond = 123456000,
            },
        },
        .{
            .value = "12345",
            .fmt = "SSSSS",
            .expected = .{
                .nanosecond = 123450000,
            },
        },
        .{
            .value = "1234",
            .fmt = "SSSS",
            .expected = .{
                .nanosecond = 123400000,
            },
        },
        .{
            .value = "123",
            .fmt = "SSS",
            .expected = .{
                .nanosecond = 123000000,
            },
        },
        .{
            .value = "12",
            .fmt = "SS",
            .expected = .{
                .nanosecond = 120000000,
            },
        },
        .{
            .value = "1",
            .fmt = "S",
            .expected = .{
                .nanosecond = 100000000,
            },
        },
        .{
            .value = "january",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jan,
            },
        },
        .{
            .value = "february",
            .fmt = "MMMM",
            .expected = .{
                .month = .Feb,
                .weekday = .Sun,
            },
        },
        .{
            .value = "march",
            .fmt = "MMMM",
            .expected = .{
                .month = .Mar,
                .weekday = .Sun,
            },
        },
        .{
            .value = "april",
            .fmt = "MMMM",
            .expected = .{
                .month = .Apr,
                .weekday = .Wed,
            },
        },
        .{
            .value = "may",
            .fmt = "MMMM",
            .expected = .{
                .month = .May,
                .weekday = .Fri,
            },
        },
        .{
            .value = "june",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jun,
                .weekday = .Mon,
            },
        },
        .{
            .value = "july",
            .fmt = "MMMM",
            .expected = .{
                .month = .Jul,
                .weekday = .Wed,
            },
        },
        .{
            .value = "august",
            .fmt = "MMMM",
            .expected = .{
                .month = .Aug,
                .weekday = .Sat,
            },
        },
        .{
            .value = "september",
            .fmt = "MMMM",
            .expected = .{
                .month = .Sep,
                .weekday = .Tue,
            },
        },
        .{
            .value = "october",
            .fmt = "MMMM",
            .expected = .{
                .month = .Oct,
                .weekday = .Thu,
            },
        },
        .{
            .value = "november",
            .fmt = "MMMM",
            .expected = .{
                .month = .Nov,
                .weekday = .Sun,
            },
        },
        .{
            .value = "december",
            .fmt = "MMMM",
            .expected = .{
                .month = .Dec,
                .weekday = .Tue,
            },
        },
        .{
            .value = "jan",
            .fmt = "MMM",
            .expected = .{
                .month = .Jan,
                .weekday = .Thu,
            },
        },
        .{
            .value = "feb",
            .fmt = "MMM",
            .expected = .{
                .month = .Feb,
                .weekday = .Sun,
            },
        },
        .{
            .value = "mar",
            .fmt = "MMM",
            .expected = .{
                .month = .Mar,
                .weekday = .Sun,
            },
        },
        .{
            .value = "apr",
            .fmt = "MMM",
            .expected = .{
                .month = .Apr,
                .weekday = .Wed,
            },
        },
        .{
            .value = "may",
            .fmt = "MMM",
            .expected = .{
                .month = .May,
                .weekday = .Fri,
            },
        },
        .{
            .value = "jun",
            .fmt = "MMM",
            .expected = .{
                .month = .Jun,
                .weekday = .Mon,
            },
        },
        .{
            .value = "jul",
            .fmt = "MMM",
            .expected = .{
                .month = .Jul,
                .weekday = .Wed,
            },
        },
        .{
            .value = "aug",
            .fmt = "MMM",
            .expected = .{
                .month = .Aug,
                .weekday = .Sat,
            },
        },
        .{
            .value = "sep",
            .fmt = "MMM",
            .expected = .{
                .month = .Sep,
                .weekday = .Tue,
            },
        },
        .{
            .value = "oct",
            .fmt = "MMM",
            .expected = .{
                .month = .Oct,
                .weekday = .Thu,
            },
        },
        .{
            .value = "nov",
            .fmt = "MMM",
            .expected = .{
                .month = .Nov,
                .weekday = .Sun,
            },
        },
        .{
            .value = "dec",
            .fmt = "MMM",
            .expected = .{
                .month = .Dec,
                .weekday = .Tue,
            },
        },
        // .{
        //     .value = "BC",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "AD",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "BCE",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "CE",
        //     .fmt = "N",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "Before Christ",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "Anno Domini",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        // .{
        //     .value = "Before Common Era",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = -1970,
        //     },
        // },
        // .{
        //     .value = "Common Era",
        //     .fmt = "NN",
        //     .expected = .{
        //         .year = 1970,
        //     },
        // },
        .{
            .value = "1pm",
            .fmt = "ha",
            .expected = .{
                .hour = 13,
            },
        },
        .{
            .value = "12pm",
            .fmt = "ha",
            .expected = .{
                .hour = 12,
            },
        },
        .{
            .value = "12am",
            .fmt = "ha",
            .expected = .{
                .hour = 0,
            },
        },
        .{
            .value = "1am",
            .fmt = "ha",
            .expected = .{
                .hour = 1,
            },
        },
        // A day of the year names a complete date on its own.
        .{
            .value = "2024-075",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2024, .month = .Mar, .day = 15, .weekday = .Fri },
        },
        .{
            .value = "2024-200",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2024, .month = .Jul, .day = 18, .weekday = .Thu },
        },
        .{
            .value = "2024-001",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2024, .month = .Jan, .day = 1, .weekday = .Mon },
        },
        // Day 366 exists in a leap year.
        .{
            .value = "2024-366",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2024, .month = .Dec, .day = 31, .weekday = .Tue },
        },
        // The same ordinal is a different date in a common year.
        .{
            .value = "2025-075",
            .fmt = "YYYY-DDD",
            .expected = .{ .year = 2025, .month = .Mar, .day = 16, .weekday = .Sun },
        },
        .{
            .value = "2025-365",
            .fmt = "YYYY-DDDD",
            .expected = .{ .year = 2025, .month = .Dec, .day = 31, .weekday = .Wed },
        },
        // Midnight is a valid reading on a 24-hour clock.
        .{
            .value = "2024-03-15T00:30:00",
            .fmt = "YYYY-MM-DDTHH:mm:ss",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 0,
                .minute = 30,
                .weekday = .Fri,
            },
        },
        .{
            .value = "2024-03-15T08:30:00-04:00",
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = -4 * std.time.s_per_hour,
            },
        },
        .{
            .value = "2024-03-15T08:30:00+0545",
            .fmt = "YYYY-MM-DDTHH:mm:ssZZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
            },
        },
        .{
            .value = "2024-03-15T08:30:00Z",
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
        },
    };

    inline for (cases) |case| {
        log.warn("{s} {s}", .{ case.fmt, case.value });
        const actual = try DateTime.parse(case.fmt, case.value);
        try std.testing.expectEqual(case.expected, actual.value);
    }
}

test "parseRelativeToTest" {
    const cases = [_]struct {
        value: []const u8,
        fmt: []const u8,
        relative_to: DateTime,
        expected: DateTime,
    }{
        .{
            .value = "Mar 22 12:40:39",
            .fmt = "MMM D H:mm:ss",
            .relative_to = .{
                .year = 2025,
                .month = .Jan,
                .day = 1,
                .weekday = .Wed,
            },
            .expected = .{
                .year = 2025,
                .month = .Mar,
                .day = 22,
                .hour = 12,
                .minute = 40,
                .second = 39,
                .weekday = .Sat,
            },
        },
    };

    inline for (cases) |case| {
        log.warn("{s} {s}", .{ case.fmt, case.value });
        const actual = try DateTime.parseRelativeTo(case.fmt, case.relative_to, case.value);
        try std.testing.expectEqual(case.expected, actual.value);
    }
}

test "formatTest" {
    const test_date = DateTime{
        .nanosecond = 123456789,
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = .Jan,
        .year = 1970,
        .weekday = .Fri,
    };

    const offset_date = DateTime{
        .second = 6,
        .minute = 55,
        .hour = 9,
        .day = 21,
        .month = .Nov,
        .year = 1997,
        .weekday = .Fri,
        .offset = -6 * std.time.s_per_hour,
    };

    const cases = [_]struct { datetime: DateTime, fmt: []const u8, result: []const u8 }{
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSSS",
            .result = "1970-01-01T00:00:00.123456789",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSSS",
            .result = "1970-01-01T00:00:00.12345678",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSSS",
            .result = "1970-01-01T00:00:00.1234567",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSSS",
            .result = "1970-01-01T00:00:00.123456",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSSS",
            .result = "1970-01-01T00:00:00.12345",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSSS",
            .result = "1970-01-01T00:00:00.1234",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SSS",
            .result = "1970-01-01T00:00:00.123",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.SS",
            .result = "1970-01-01T00:00:00.12",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ss.S",
            .result = "1970-01-01T00:00:00.1",
        },
        .{
            .datetime = test_date,
            .fmt = "h a",
            .result = "12 am",
        },
        .{
            .datetime = test_date,
            .fmt = "h A",
            .result = "12 AM",
        },
        .{
            .datetime = test_date,
            .fmt = "ha",
            .result = "12am",
        },
        .{
            .datetime = test_date,
            .fmt = "HHmm",
            .result = "0000",
        },
        .{
            .datetime = test_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .result = "1970-01-01T00:00:00+00:00",
        },
        .{
            .datetime = offset_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZ",
            .result = "1997-11-21T09:55:06-06:00",
        },
        .{
            .datetime = offset_date,
            .fmt = "YYYY-MM-DDTHH:mm:ssZZ",
            .result = "1997-11-21T09:55:06-0600",
        },
        // The RFC 822 form that `rfc822.parse` reads.
        .{
            .datetime = offset_date,
            .fmt = "ddd, DD MMM YYYY HH:mm:ss ZZ",
            .result = "Fri, 21 Nov 1997 09:55:06 -0600",
        },
    };

    inline for (cases) |case| {
        var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer buf.deinit();

        try case.datetime.format(case.fmt, &buf.writer);

        try std.testing.expectEqualStrings(case.result, buf.written());
    }
}

test "toUtcTest" {
    const cases = [_]struct { local: DateTime, expected: DateTime }{
        // A whole number of hours, staying within the same day.
        .{
            .local = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 8,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = -5 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 1994,
                .month = .Nov,
                .day = 6,
                .hour = 13,
                .minute = 49,
                .second = 37,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // A positive offset that rolls back over a year boundary.
        .{
            .local = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 30,
                .weekday = .Mon,
                .offset = 5 * std.time.s_per_hour + 45 * std.time.s_per_min,
            },
            .expected = .{
                .year = 2023,
                .month = .Dec,
                .day = 31,
                .hour = 18,
                .minute = 45,
                .weekday = .Sun,
                .offset = 0,
            },
        },
        // A negative offset that rolls forward over a year boundary.
        .{
            .local = .{
                .year = 2023,
                .month = .Dec,
                .day = 31,
                .hour = 23,
                .minute = 0,
                .weekday = .Sun,
                .offset = -5 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 2024,
                .month = .Jan,
                .day = 1,
                .hour = 4,
                .minute = 0,
                .weekday = .Mon,
                .offset = 0,
            },
        },
        // Leap days are crossed correctly.
        .{
            .local = .{
                .year = 2024,
                .month = .Mar,
                .day = 1,
                .hour = 1,
                .minute = 0,
                .weekday = .Fri,
                .offset = 2 * std.time.s_per_hour,
            },
            .expected = .{
                .year = 2024,
                .month = .Feb,
                .day = 29,
                .hour = 23,
                .minute = 0,
                .weekday = .Thu,
                .offset = 0,
            },
        },
        // Seconds and nanoseconds are carried through, so a leap second
        // survives the shift.
        .{
            .local = .{
                .year = 2017,
                .month = .Jan,
                .day = 1,
                .hour = 0,
                .minute = 59,
                .second = 60,
                .nanosecond = 123456789,
                .weekday = .Sun,
                .offset = std.time.s_per_hour,
            },
            .expected = .{
                .year = 2016,
                .month = .Dec,
                .day = 31,
                .hour = 23,
                .minute = 59,
                .second = 60,
                .nanosecond = 123456789,
                .weekday = .Sat,
                .offset = 0,
            },
        },
        // A value that is already UTC is returned unchanged.
        .{
            .local = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
            .expected = .{
                .year = 2024,
                .month = .Mar,
                .day = 15,
                .hour = 8,
                .minute = 30,
                .weekday = .Fri,
                .offset = 0,
            },
        },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case.expected, case.local.toUtc());
        // Converting an already-UTC value again is a no-op.
        try std.testing.expectEqual(case.expected, case.local.toUtc().toUtc());
    }
}

test "day of the year is checked against the length of the year" {
    // 366 only exists in a leap year, and there is no day zero.
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2025-366"));
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2024-367"));
    try std.testing.expectError(error.ParseError, DateTime.parse("YYYY-DDD", "2024-000"));
}
