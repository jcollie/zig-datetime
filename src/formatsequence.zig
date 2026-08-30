const std = @import("std");

pub const FormatTag = enum {
    /// 1 2 ... 11 12 (month, numeric)
    M,
    /// 1st 2nd ... 11th 12th (month, numeric ordinal)
    Mo,
    /// 1ˢᵗ 2ⁿᵈ 3ʳᵈ ... 11ᵗʰ 12ᵗʰ
    MO,
    /// 01 02 ... 11 12 (month, numeric ordinal)
    MM,
    // /// Ja, Fe, Ma ... No, De (very short month name)
    // Mm,
    MMM, // Jan Feb ... Nov Dec (short month name)
    MMMM, // January February ... November December (long month name)
    Q, // 1 2 3 4 (quarter)
    Qo, // 1st 2nd 3rd 4th (quarter)
    QO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ 4ᵗʰ (quarter)
    D, // 1 2 ... 30 31 (day of the month)
    Do, // 1st 2nd ... 30th 31st (day of the month, ordinal)
    DO, // 1ˢᵗ 2ⁿᵈ 3ʳᵈ... 30ᵗʰ 31ˢᵗ (day of the month, ordinal)
    DD, // 01 02 ... 30 31 (day of the month, zero padded)
    DDD, // 1 2 ... 364 365 366
    DDDo, // 1st 2nd ... 364th 365th 366th (day of the year, ordinal)
    DDDO, // 1ˢᵗ 2ⁿᵈ ... 364ᵗʰ 365ᵗʰ 366ᵗʰ(day of the year, ordinal)
    DDDD, // 001 002 ... 364 365 365 (day of the year)
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
    // @"±YYYY",
    // /// BCE/CE (BC and AD will be accepted for parsing, but not emitted on
    // /// formatting).
    // N,
    // /// Before Common Era/Common Era (Before Christ and Anno Domini will be
    // /// accepted for parsing but will not be emitted when formatted).
    // NN,
    /// AM PM (ante/post meridian, upper case)
    A,
    /// am pm (ante/post meridian, lower case)
    a,
    /// 0 1 ... 22 23 (hour, zero padded)
    H,
    /// 00 01 ... 22 23 (hour, zero padded)
    HH,
    /// 12 1 2 ... 11 12 (hour, 12 hour clock)
    h,
    /// 12 01 02 ... 11 (hour, 12 hour clock, zero padded)
    hh,
    /// 24 1 2 ... 23
    k,
    /// 24 01 02 ... 23
    kk,
    m, // 0 1 ... 58 59 (minute)
    mm, // 00 01 ... 58 59 (minute, zero padded)
    s, // 0 1 ... 58 59 60 (second)
    ss, // 00 01 ... 58 59 60 (second, zero padded)
    S, // 0 1 ... 8 9 (tenths of a second)
    SS, // 00 01 ... 98 99(hundredths of a second)
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

    /// Truncates a nanosecond value to the precision of this `S...` tag,
    /// e.g. `.SSS` reduces it to milliseconds. `tag` must be one of the
    /// fractional-second sequences.
    pub fn convertFractionalSeconds(comptime tag: FormatTag, value: u30) u30 {
        const name = comptime @tagName(tag);
        comptime var count: i8 = undefined;
        inline for (name, 1..) |c, i| {
            if (c != 'S') @compileError(name ++ " is not a fractional second format sequence");
            count = i;
        }
        if (count > 9) @compileError("fractional seconds smaller than nanoseconds are not supported");
        if (count == 9) return value;
        const exponent = 9 - count;
        const factor = std.math.pow(u30, 10, exponent);
        return @as(u30, @divTrunc(value, factor));
    }

    test "cnv" {
        const cases = [_]struct { tag: FormatTag, expected: u30, value: u30 }{
            .{ .tag = .S, .expected = 1, .value = 123456789 },
            .{ .tag = .SS, .expected = 12, .value = 123456789 },
            .{ .tag = .SSS, .expected = 123, .value = 123456789 },
            .{ .tag = .SSSS, .expected = 1234, .value = 123456789 },
            .{ .tag = .SSSSS, .expected = 12345, .value = 123456789 },
            .{ .tag = .SSSSSS, .expected = 123456, .value = 123456789 },
            .{ .tag = .SSSSSSS, .expected = 1234567, .value = 123456789 },
            .{ .tag = .SSSSSSSS, .expected = 12345678, .value = 123456789 },
            .{ .tag = .SSSSSSSSS, .expected = 123456789, .value = 123456789 },
        };
        inline for (cases) |case| {
            try std.testing.expectEqual(case.expected, convertFractionalSeconds(case.tag, case.value));
        }
    }

    /// Splits a format string into `FormatTag` sequences and literal
    /// characters, always taking the longest tag that matches.
    pub const Tokenizer = struct {
        index: usize,
        format_string: []const u8,

        pub const Token = union(enum) {
            char: u8,
            tag: FormatTag,
        };

        /// Creates a tokenizer positioned at the start of `format_string`.
        pub fn init(format_string: []const u8) Tokenizer {
            return .{
                .index = 0,
                .format_string = format_string,
            };
        }

        /// Returns the next token, or null when the format string is
        /// exhausted.
        pub fn next(self: *Tokenizer) ?Token {
            if (self.index >= self.format_string.len) return null;
            var tag_: ?FormatTag = null;
            var tag_len: usize = 0;
            inline for (@typeInfo(FormatTag).@"enum".fields) |field| {
                if (field.name.len > tag_len and
                    self.index + field.name.len <= self.format_string.len and
                    std.mem.eql(u8, field.name, self.format_string[self.index..][0..field.name.len]))
                {
                    tag_ = @enumFromInt(field.value);
                    tag_len = field.name.len;
                }
            }
            if (tag_) |tag| {
                defer self.index += @tagName(tag).len;
                return .{
                    .tag = tag,
                };
            }
            defer self.index += 1;
            return .{
                .char = self.format_string[self.index],
            };
        }
    };
};
