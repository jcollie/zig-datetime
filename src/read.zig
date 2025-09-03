const std = @import("std");
const log = std.log.scoped(.read);
const Nanosecond = @import("nanosecond.zig").Nanosecond;

/// find at most `maxlen` digits at the beginning of the string
pub fn int(text: []const u8, maxlen: usize) []const u8 {
    if (text.len == 0) return text[0..0];

    for (0..@min(text.len, maxlen)) |i| {
        if (!std.ascii.isDigit(text[i])) return text[0..i];
    }

    return text[0..maxlen];
}

pub fn nanosecond(text: []const u8, length: usize) !Nanosecond {
    if (length == 0) return error.TooShort;
    if (length > 9) return error.TooLong;
    const v = int(text, length);
    if (v.len != length) return error.TooShort;
    return try std.fmt.parseInt(Nanosecond, v, 10) * try std.math.powi(Nanosecond, 10, 9 - @as(Nanosecond, @intCast(length)));
}
