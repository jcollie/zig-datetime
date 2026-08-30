const std = @import("std");
const log = std.log.scoped(.read);
const Nanosecond = @import("nanosecond.zig").Nanosecond;

/// Returns the run of ASCII digits at the beginning of `text`, at most
/// `maxlen` bytes long; the result is empty if `text` does not start with a
/// digit.
pub fn int(text: []const u8, maxlen: usize) []const u8 {
    if (text.len == 0) return text[0..0];

    for (0..@min(text.len, maxlen)) |i| {
        if (!std.ascii.isDigit(text[i])) return text[0..i];
    }

    return text[0..maxlen];
}

/// Parses exactly `length` digits (1-9) at the start of `text` as a decimal
/// fraction of a second and returns it scaled to nanoseconds, so "12" with
/// length 2 yields 120000000.
pub fn nanosecond(text: []const u8, length: usize) !Nanosecond {
    if (length == 0) return error.TooShort;
    if (length > 9) return error.TooLong;
    const v = int(text, length);
    if (v.len != length) return error.TooShort;
    return try std.fmt.parseInt(Nanosecond, v, 10) * try std.math.powi(Nanosecond, 10, 9 - @as(Nanosecond, @intCast(length)));
}
