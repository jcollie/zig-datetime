const std = @import("std");

const Year = @import("year.zig").Year;
const Day = @import("day.zig").Day;
const leap = @import("leap.zig");

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

    pub fn as(self: Month, comptime T: type) T {
        const info = @typeInfo(T);
        if (info != .int) @compileError("can't convert to anything but an int");
        switch (info.bits.signedness) {
            .signed => if (info.int.bits < 5) @compileError("must have at least 5 bits"),
            .unsigned => if (info.int.bits < 4) @compileError("must have at least 4 bits"),
        }
        return @intCast(@intFromEnum(self));
    }

    pub const ParseError = error{
        TooShort,
        TooLong,
        Overflow,
        Underflow,
        IllegalCharacter,
    } || std.fmt.ParseIntError;

    pub fn parseInt(str: []const u8) ParseError!Month {
        if (str.len == 0) return error.TooShort;
        if (str.len > 2) return error.TooLong;

        for (str) |c| if (!std.ascii.isDigit(c)) return error.IllegalCharacter;

        const month = try std.fmt.parseInt(
            @typeInfo(Month).@"enum".tag_type,
            str,
            10,
        );

        if (month < 1) return error.Underflow;
        if (month > 12) return error.Overflow;

        return std.meta.intToEnum(Month, month) catch unreachable;
    }

    pub fn monthNumber(self: Month) u4 {
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

    pub fn next(self: Month) Month {
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

    pub fn prev(self: Month) Month {
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

    pub fn lastDay(self: Month, year: Year) Day {
        return switch (self) {
            .Jan => 31,
            .Feb => if (leap.is(year)) 29 else 28,
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

    pub fn quarter(self: Month) u3 {
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

    pub fn shortName(self: Month) []const u8 {
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

    pub fn longName(self: Month) []const u8 {
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

    pub fn daysBefore(self: Month, year: Year) u9 {
        return switch (self) {
            .Jan => 0,
            .Feb => 31,
            .Mar => if (leap.is(year)) 60 else 59,
            .Apr => if (leap.is(year)) 91 else 90,
            .May => if (leap.is(year)) 121 else 120,
            .Jun => if (leap.is(year)) 152 else 151,
            .Jul => if (leap.is(year)) 182 else 181,
            .Aug => if (leap.is(year)) 213 else 212,
            .Sep => if (leap.is(year)) 244 else 243,
            .Oct => if (leap.is(year)) 274 else 273,
            .Nov => if (leap.is(year)) 305 else 304,
            .Dec => if (leap.is(year)) 335 else 334,
        };
    }

    pub const Iterator = struct {
        index: ?Month,

        pub const init: Iterator = .{ .index = .Jan };

        pub fn next(self: *Iterator) ?Month {
            defer {
                if (self.index) |i| {
                    const n = i.next();
                    if (n == .Jan)
                        self.index = null
                    else
                        self.index = n;
                }
            }
            return self.index;
        }
    };

    pub fn iterator() Iterator {
        return .init;
    }

    pub const short_map = std.StaticStringMapWithEql(Month, std.ascii.eqlIgnoreCase).initComptime(
        .{
            .{ "jan", .Jan },
            .{ "feb", .Feb },
            .{ "mar", .Mar },
            .{ "apr", .Apr },
            .{ "may", .May },
            .{ "jun", .Jun },
            .{ "jul", .Jul },
            .{ "aug", .Aug },
            .{ "sep", .Sep },
            .{ "oct", .Oct },
            .{ "nov", .Nov },
            .{ "dec", .Dec },
        },
    );

    pub const long_map = std.StaticStringMapWithEql(Month, std.ascii.eqlIgnoreCase).initComptime(
        .{
            .{ "january", .Jan },
            .{ "february", .Feb },
            .{ "march", .Mar },
            .{ "april", .Apr },
            .{ "may", .May },
            .{ "june", .Jun },
            .{ "july", .Jul },
            .{ "august", .Aug },
            .{ "september", .Sep },
            .{ "october", .Oct },
            .{ "november", .Nov },
            .{ "december", .Dec },
        },
    );

    pub const any_map = std.StaticStringMapWithEql(Month, std.ascii.eqlIgnoreCase).initComptime(
        .{
            .{ "ja", .Jan },
            .{ "fe", .Feb },
            .{ "ap", .Apr },
            .{ "au", .Aug },
            .{ "se", .Sep },
            .{ "oc", .Oct },
            .{ "no", .Nov },
            .{ "de", .Dec },

            .{ "jan", .Jan },
            .{ "feb", .Feb },
            .{ "mar", .Mar },
            .{ "apr", .Apr },
            .{ "may", .May },
            .{ "jun", .Jun },
            .{ "jul", .Jul },
            .{ "aug", .Aug },
            .{ "sep", .Sep },
            .{ "oct", .Oct },
            .{ "nov", .Nov },
            .{ "dec", .Dec },

            .{ "janu", .Jan },
            .{ "febr", .Feb },
            .{ "marc", .Mar },
            .{ "apri", .Apr },
            .{ "augu", .Aug },
            .{ "sept", .Sep },
            .{ "octo", .Oct },
            .{ "nove", .Nov },
            .{ "dece", .Dec },

            .{ "janua", .Jan },
            .{ "febru", .Feb },
            .{ "augus", .Aug },
            .{ "septe", .Sep },
            .{ "octob", .Oct },
            .{ "novem", .Nov },
            .{ "decem", .Dec },

            .{ "januar", .Jan },
            .{ "februa", .Feb },
            .{ "septem", .Sep },
            .{ "octobe", .Oct },
            .{ "novemb", .Nov },
            .{ "decemb", .Dec },

            .{ "februar", .Feb },
            .{ "septemb", .Sep },
            .{ "novembe", .Nov },
            .{ "decembe", .Dec },

            .{ "septembe", .Sep },

            .{ "january", .Jan },
            .{ "february", .Feb },
            .{ "march", .Mar },
            .{ "april", .Apr },
            .{ "may", .May },
            .{ "june", .Jun },
            .{ "july", .Jul },
            .{ "august", .Aug },
            .{ "september", .Sep },
            .{ "october", .Oct },
            .{ "november", .Nov },
            .{ "december", .Dec },
        },
    );
};

test "iterator" {
    var it = Month.iterator();
    try std.testing.expectEqual(.Jan, it.next());
    try std.testing.expectEqual(.Feb, it.next());
    try std.testing.expectEqual(.Mar, it.next());
    try std.testing.expectEqual(.Apr, it.next());
    try std.testing.expectEqual(.May, it.next());
    try std.testing.expectEqual(.Jun, it.next());
    try std.testing.expectEqual(.Jul, it.next());
    try std.testing.expectEqual(.Aug, it.next());
    try std.testing.expectEqual(.Sep, it.next());
    try std.testing.expectEqual(.Oct, it.next());
    try std.testing.expectEqual(.Nov, it.next());
    try std.testing.expectEqual(.Dec, it.next());
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(null, it.next());
}
