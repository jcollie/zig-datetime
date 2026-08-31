// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The month of the year, its length, and where it starts in the year.
//!
//! Months are numbered from January = 1, so that the enum value is the
//! month number that a date is written with and no conversion is needed
//! on the way in or out of text.

const std = @import("std");

const Year = @import("year.zig").Year;
const Day = @import("day.zig").Day;
const leap = @import("leap.zig");

/// A month of the year, numbered January = 1 through December = 12 so that
/// the enum value is the number a date is written with.
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

    /// Returns the month number (1-12) as integer type `T`. `T` must have at
    /// least 4 bits if unsigned, or 5 bits if signed.
    pub fn as(self: Month, comptime T: type) T {
        const info = @typeInfo(T);
        if (info != .int) @compileError("can't convert to anything but an int");
        switch (info.int.signedness) {
            .signed => if (info.int.bits < 5) @compileError("must have at least 5 bits"),
            .unsigned => if (info.int.bits < 4) @compileError("must have at least 4 bits"),
        }
        return @intCast(@intFromEnum(self));
    }

    test as {
        try std.testing.expectEqual(@as(u4, 1), Month.Jan.as(u4));
        try std.testing.expectEqual(@as(i32, 12), Month.Dec.as(i32));
    }

    /// What `parseInt` and the name parsers can fail with.
    pub const ParseError = error{
        TooShort,
        TooLong,
        Overflow,
        Underflow,
        IllegalCharacter,
    } || std.fmt.ParseIntError;

    /// Parses a one- or two-digit month number ("1"-"12") into a `Month`.
    pub fn parseInt(str: []const u8) ParseError!Month {
        if (str.len == 0) return error.TooShort;
        if (str.len > 2) return error.TooLong;

        for (str) |c| if (!std.ascii.isDigit(c)) return error.IllegalCharacter;

        const month = @import("read.zig").digits(str);

        if (month < 1) return error.Underflow;
        if (month > 12) return error.Overflow;

        return std.enums.fromInt(Month, @as(u4, @intCast(month))) orelse unreachable;
    }

    test parseInt {
        try std.testing.expectEqual(Month.Mar, try parseInt("3"));
        // A leading zero is accepted, since dates are written with one.
        try std.testing.expectEqual(Month.Mar, try parseInt("03"));
        try std.testing.expectEqual(Month.Dec, try parseInt("12"));

        try std.testing.expectError(error.Overflow, parseInt("13"));
        try std.testing.expectError(error.Underflow, parseInt("0"));
        try std.testing.expectError(error.TooShort, parseInt(""));
        try std.testing.expectError(error.IllegalCharacter, parseInt("1x"));
    }

    /// Returns the calendar month number, January = 1 through December = 12.
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

    test monthNumber {
        try std.testing.expectEqual(@as(u4, 1), Month.Jan.monthNumber());
        try std.testing.expectEqual(@as(u4, 12), Month.Dec.monthNumber());
    }

    /// Returns the month after this one, wrapping from December to January.
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

    test next {
        try std.testing.expectEqual(Month.Feb, Month.Jan.next());
        // December wraps round to January.
        try std.testing.expectEqual(Month.Jan, Month.Dec.next());
    }

    /// Returns the month before this one, wrapping from January to December.
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

    test prev {
        try std.testing.expectEqual(Month.Nov, Month.Dec.prev());
        // January wraps back to December.
        try std.testing.expectEqual(Month.Dec, Month.Jan.prev());
    }

    /// Returns the number of the last day of this month (28-31) in `year`,
    /// accounting for leap years.
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

    test lastDay {
        try std.testing.expectEqual(@as(Day, 31), Month.Jan.lastDay(2024));
        try std.testing.expectEqual(@as(Day, 30), Month.Apr.lastDay(2024));

        // Only February depends on the year.
        try std.testing.expectEqual(@as(Day, 29), Month.Feb.lastDay(2024));
        try std.testing.expectEqual(@as(Day, 28), Month.Feb.lastDay(2025));
    }

    /// Returns the quarter of the year (1-4) containing this month.
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

    test quarter {
        try std.testing.expectEqual(@as(u3, 1), Month.Mar.quarter());
        try std.testing.expectEqual(@as(u3, 2), Month.Apr.quarter());
        try std.testing.expectEqual(@as(u3, 4), Month.Dec.quarter());
    }

    /// Returns the three-letter English name ("Jan" ... "Dec").
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

    test shortName {
        try std.testing.expectEqualStrings("Jan", Month.Jan.shortName());
        try std.testing.expectEqualStrings("Sep", Month.Sep.shortName());
    }

    /// Returns the full English name ("January" ... "December").
    pub fn longName(self: Month) []const u8 {
        return switch (self) {
            .Jan => "January",
            .Feb => "February",
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

    test longName {
        try std.testing.expectEqualStrings("January", Month.Jan.longName());
        // May is the one name that is the same at both lengths.
        try std.testing.expectEqualStrings("May", Month.May.longName());
    }

    /// Returns the number of days in `year` that pass before the first of
    /// this month, accounting for leap years.
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

    test daysBefore {
        // Nothing passes before January, and January's 31 days before
        // February whatever the year.
        try std.testing.expectEqual(@as(u9, 0), Month.Jan.daysBefore(2024));
        try std.testing.expectEqual(@as(u9, 31), Month.Feb.daysBefore(2024));

        // From March on, a leap year has put one more day behind it.
        try std.testing.expectEqual(@as(u9, 60), Month.Mar.daysBefore(2024));
        try std.testing.expectEqual(@as(u9, 59), Month.Mar.daysBefore(2025));
    }

    /// Walks the months in order. The cursor is nulled once `next` wraps
    /// back around to January, which is what ends the iteration; there is
    /// no separate count to keep.
    pub const Iterator = struct {
        index: ?Month,

        /// An iterator positioned at January.
        pub const init: Iterator = .{ .index = .Jan };

        /// Returns the next month, or null once December has been returned.
        ///
        /// This has no doctest of its own: a doctest is named by a bare
        /// identifier, and `next` here would be ambiguous with `Month.next`
        /// in the enclosing scope. See the one on `Month.iterator`.
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

    /// Returns an iterator over the months January through December.
    pub fn iterator() Iterator {
        return .init;
    }

    test iterator {
        var count: usize = 0;
        var last: ?Month = null;

        var it = iterator();
        while (it.next()) |month| {
            count += 1;
            last = month;
        }

        try std.testing.expectEqual(@as(usize, 12), count);
        try std.testing.expectEqual(Month.Dec, last.?);
    }

    /// The three-letter month names, "jan" through "dec". Comparison
    /// ignores case, so only lower-case keys are carried.
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

    /// The full month names, "january" through "december".
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

    /// Every prefix of every month name that names exactly one month, from
    /// two letters up to the full name. The ambiguous ones are absent for
    /// that reason: "ma" could be March or May and "ju" could be June or
    /// July, so those four names only enter the map at three letters.
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
