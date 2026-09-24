// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! What the `std.json` hooks on `Date`, `DateTime`, `Instant`, `Duration`,
//! `Interval` and `RecurringInterval` have in common.
//!
//! Each of those types is a JSON **string** holding its ISO 8601 spelling,
//! `"2024-03-15T14:30:00Z"` and `"P1Y2M"`, rather than an object of its
//! fields. The string is what every other JSON reader and writer of dates
//! already speaks — JavaScript's `Date.toJSON` writes one — and each of
//! these types has a parser for it here, so the value survives the trip
//! out and back.
//!
//! `std.json` finds a hook by looking for a method with the right name on
//! the type being read or written, so each type declares three: one to
//! write it, one to read it from a token stream, and one to read it from a
//! `std.json.Value` that has already been parsed. What those have to do is
//! the same for all six types apart from the text in the middle, and that
//! is what is here. The six `read*` functions are that text, one per type.

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const Duration = @import("Duration.zig");
const Instant = @import("Instant.zig");
const Interval = @import("interval.zig").Interval;
const RecurringInterval = @import("interval.zig").RecurringInterval;
const iso8601 = @import("iso8601.zig");

/// How reading a type's text can fail, spelled in errors `std.json` already
/// has so that they fit its error sets.
///
/// Text that is not the representation at all is `InvalidCharacter`, which
/// is what `std.json` answers for a string that should have been a number
/// and is not. A representation whose components are out of range — a
/// month of 13, an interval that runs backwards, a duration too long to
/// add — is `Overflow`, which is its answer for a number too large for
/// the integer it was read into.
pub const TextError = error{ InvalidCharacter, Overflow };

fn textError(err: iso8601.ParseError) TextError {
    return switch (err) {
        error.OutOfRange => error.Overflow,
        error.ParseError, error.MixedFormats, error.BadFraction => error.InvalidCharacter,
    };
}

test textError {
    try std.testing.expectEqual(error.Overflow, textError(error.OutOfRange));
    try std.testing.expectEqual(error.InvalidCharacter, textError(error.MixedFormats));
}

/// Writes `value` as a JSON string, with `write` supplying what goes
/// between the quotes.
///
/// It writes to the `Stringify`'s underlying writer directly, between
/// `beginWriteRaw` and `endWriteRaw`, rather than formatting into a buffer
/// and handing that to `jw.write`. That needs no buffer sized for the
/// longest thing any of these can write, and it is safe because nothing
/// these write needs escaping: every character of an ISO 8601
/// representation is printable ASCII, and none is a quote or a backslash.
pub fn stringify(
    jw: anytype,
    value: anytype,
    comptime write: fn (*std.Io.Writer, @TypeOf(value)) std.Io.Writer.Error!void,
) std.Io.Writer.Error!void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    try write(jw.writer, value);
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

test stringify {
    const text = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        .{ .when = Date{ .year = 2024, .month = .Mar, .day = 15 } },
        .{},
    );
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("{\"when\":\"2024-03-15\"}", text);
}

/// Reads a `T` from the next token of `source`, which has to be a string,
/// by handing its contents to `read`.
///
/// The token is asked for with `.alloc_if_needed`, the same as `std.json`
/// asks for a number, so a string is normally a slice of the input and is
/// copied only when it had escapes to undo or crossed a buffer boundary of
/// a streaming reader. Either way the value read out of it holds no pointer
/// into it, so the copy is freed before this returns and nothing is left
/// allocated.
pub fn parse(
    comptime T: type,
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
    comptime read: fn ([]const u8) TextError!T,
) std.json.ParseError(@TypeOf(source.*))!T {
    const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
    return switch (token) {
        .string => |text| read(text),
        .allocated_string => |text| {
            defer allocator.free(text);
            return read(text);
        },
        .allocated_number => |text| {
            allocator.free(text);
            return error.UnexpectedToken;
        },
        else => error.UnexpectedToken,
    };
}

test parse {
    const parsed = try std.json.parseFromSlice(Date, std.testing.allocator, "\"2024-03-15\"", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, parsed.value);

    // An escape makes the scanner copy the string; the copy is freed.
    const escaped = try std.json.parseFromSlice(Date, std.testing.allocator, "\"2024\\u002d03-15\"", .{});
    defer escaped.deinit();
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, escaped.value);

    // Anything but a string is the wrong token, a number included.
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Date, std.testing.allocator, "20240315", .{}));
    try std.testing.expectError(error.UnexpectedToken, std.json.parseFromSlice(Date, std.testing.allocator, "null", .{}));
}

/// Reads a `T` from a `std.json.Value` that has already been parsed, which
/// has to be a string, by handing its contents to `read`.
pub fn parseFromValue(
    comptime T: type,
    source: std.json.Value,
    comptime read: fn ([]const u8) TextError!T,
) std.json.ParseFromValueError!T {
    return switch (source) {
        .string => |text| read(text),
        else => error.UnexpectedToken,
    };
}

test parseFromValue {
    try std.testing.expectEqual(
        Date{ .year = 2024, .month = .Mar, .day = 15 },
        try parseFromValue(Date, .{ .string = "2024-03-15" }, readDate),
    );
    try std.testing.expectError(error.UnexpectedToken, parseFromValue(Date, .{ .integer = 20240315 }, readDate));
}

/// `text` as a `Date`: a calendar, ordinal or week date naming a day, and
/// nothing more. A time of day is refused rather than dropped, since a
/// `Date` has nowhere to keep it, and so is a date reduced to a month or a
/// year, which does not name a day.
pub fn readDate(text: []const u8) TextError!Date {
    const result = iso8601.parse(text) catch |err| return textError(err);
    if (result.str.len != text.len) return error.InvalidCharacter;
    if (result.precision != .day or result.has_offset) return error.InvalidCharacter;
    return result.value.asDate();
}

test readDate {
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, try readDate("2024-03-15"));
    try std.testing.expectEqual(Date{ .year = 2024, .month = .Mar, .day = 15 }, try readDate("2024-075"));
    try std.testing.expectError(error.InvalidCharacter, readDate("2024-03-15T14:30"));
    try std.testing.expectError(error.InvalidCharacter, readDate("2024-03"));
    try std.testing.expectError(error.InvalidCharacter, readDate("2024-03-15 "));
    try std.testing.expectError(error.Overflow, readDate("2024-02-30"));
}

/// Whether an endpoint `iso8601.parse` read is a complete date and time:
/// named down to the second, and carrying its offset from UTC.
///
/// This is the check that keeps the readers from filling in what the text
/// left out. `iso8601.parse` reads a reduced representation by defaulting
/// the components it did not see, midnight for a missing time and zero for
/// missing seconds, and reads a time without a zone with an offset of zero,
/// and its result says so with `precision` and `has_offset`. A `DateTime`
/// or an `Instant` has no field to carry either, so a value read from such
/// text would look complete and not be: `2024-03-15T14:30` would come back
/// indistinguishable from `2024-03-15T14:30:00Z`. Refusing it is the only
/// answer that does not make something up.
///
/// What passes is exactly the shape of RFC 3339's `date-time`, which is
/// what JSON Schema's `date-time` format means and what JSON producers
/// write, extended only to the week and ordinal dates and the basic form,
/// which name a day just as exactly. In ISO 8601-1:2019's terms that is a
/// complete representation of a date and time of day with a time shift or
/// `Z`: 5.4.2.1 for calendar dates, 5.4.2.2 for ordinal and 5.4.2.3 for
/// week dates, less any of 5.4.3's reduced times.
fn isComplete(has_offset: bool, precision: iso8601.Precision) bool {
    return has_offset and precision == .second;
}

test isComplete {
    try std.testing.expect(isComplete(true, .second));
    try std.testing.expect(!isComplete(false, .second));
    try std.testing.expect(!isComplete(true, .minute));
}

/// `text` as a `DateTime`: a date and time named down to the second, with
/// its offset from UTC — the shape of RFC 3339's `date-time`. See
/// `isComplete` for why anything less is refused rather than completed.
///
/// A fraction of the second is kept, and an offset of any size `iso8601`
/// reads is kept as it was written, which is the point of reading into a
/// `DateTime` rather than an `Instant`. `iso8601.parse` itself stays
/// lenient, and is the way to read a local time on purpose: its
/// `has_offset` says when it was one.
pub fn readDateTime(text: []const u8) TextError!DateTime {
    const result = iso8601.parse(text) catch |err| return textError(err);
    if (result.str.len != text.len) return error.InvalidCharacter;
    if (!isComplete(result.has_offset, result.precision)) return error.InvalidCharacter;
    return result.value;
}

test readDateTime {
    try std.testing.expectEqual(
        DateTime{ .year = 2024, .month = .Mar, .day = 15, .hour = 14, .minute = 30, .offset = -5 * 3600, .weekday = .Fri },
        try readDateTime("2024-03-15T14:30:00-05:00"),
    );
    try std.testing.expectEqual(
        DateTime{ .year = 2024, .month = .Mar, .day = 15, .hour = 14, .minute = 30, .nanosecond = 500_000_000, .weekday = .Fri },
        try readDateTime("2024-03-15T14:30:00.5Z"),
    );
    // A local time, which would have come back looking like UTC.
    try std.testing.expectError(error.InvalidCharacter, readDateTime("2024-03-15T14:30:00"));
    // Reduced, which would have had its missing components made up.
    try std.testing.expectError(error.InvalidCharacter, readDateTime("2024-03-15T14:30Z"));
    try std.testing.expectError(error.InvalidCharacter, readDateTime("2024-03-15"));
    try std.testing.expectError(error.InvalidCharacter, readDateTime("2024-03-15T14:30:00Z trailing"));
    try std.testing.expectError(error.Overflow, readDateTime("2024-03-15T25:00:00Z"));
}

/// `text` as an `Instant`: a date and time held to the same shape as
/// `readDateTime`, then taken to the instant it names by removing its
/// offset.
///
/// The offset is used and not kept, because an `Instant` is a point on the
/// timeline and has nowhere to put one. Where the local offset is part of
/// what the value means — a forecast for a place, a meeting in a zone —
/// the field wants to be a `DateTime`, which keeps it.
pub fn readInstant(text: []const u8) TextError!Instant {
    return (try readDateTime(text)).toInstant();
}

test readInstant {
    try std.testing.expectEqual(Instant{ .timestamp = 0 }, try readInstant("1970-01-01T00:00:00Z"));
    try std.testing.expectEqual(Instant{ .timestamp = 0 }, try readInstant("1969-12-31T19:00:00-05:00"));
    try std.testing.expectError(error.InvalidCharacter, readInstant("1970-01-01T00:00:00"));
    try std.testing.expectError(error.InvalidCharacter, readInstant("1970-01-01T00:00Z"));
}

/// `text` as a `Duration`: whatever `iso8601.parseDuration` reads, as long
/// as it reads all of it.
pub fn readDuration(text: []const u8) TextError!Duration {
    const result = iso8601.parseDuration(text) catch |err| return textError(err);
    if (result.str.len != text.len) return error.InvalidCharacter;
    return result.value;
}

test readDuration {
    try std.testing.expect((try readDuration("P1Y2M")).eql(.{ .months = 14 }));
    // Fields that disagree in sign, which is what `Duration.format` writes
    // for them, so the hooks read back what they wrote.
    try std.testing.expect((try readDuration("P1M-1D")).eql(.{ .months = 1, .days = -1 }));
    try std.testing.expectError(error.InvalidCharacter, readDuration("P1Y2"));
}

/// `text` as an `Interval`: whatever `iso8601.parseInterval` reads, as
/// long as it reads all of it and every endpoint it wrote is complete in
/// the sense of `isComplete`, named to the second with an offset.
///
/// An end with no zone of its own passes when the start has one, because
/// it is in the start's zone: that is ISO 8601's rule for the part after
/// the separator, not a default, and the text did say which zone, once. An
/// abbreviated end reads to the start's precision by construction.
pub fn readInterval(text: []const u8) TextError!Interval {
    const result = iso8601.parseInterval(text) catch |err| return textError(err);
    if (result.str.len != text.len) return error.InvalidCharacter;
    inline for (.{ result.start, result.end }) |endpoint| {
        if (endpoint) |e| if (!isComplete(e.has_offset, e.precision)) return error.InvalidCharacter;
    }
    return result.value;
}

test readInterval {
    const interval = try readInterval("2024-03-15T00:00:00Z/P1D");
    try std.testing.expect(interval.duration().?.eql(.{ .days = 1 }));

    // An end takes the start's zone, which the text did give, whether it is
    // abbreviated or written out in full.
    const afternoon = try readInterval("2024-03-15T13:30:00-05:00/15:30:00");
    try std.testing.expectEqual(@as(i32, -5 * 3600), afternoon.end().offset);
    const full = try readInterval("2024-03-15T13:30:00-05:00/2024-03-15T15:30:00");
    try std.testing.expectEqual(@as(i32, -5 * 3600), full.end().offset);

    // Either endpoint local or reduced is refused, whichever form.
    for ([_][]const u8{
        "2024-03-15/P1D",
        "2024-03-15T00:00:00/P1D",
        "P1D/2024-03-15T00:00:00",
        "2024-03-15T00:00:00/2024-03-16T00:00:00Z",
        "2024-03-15T00:00Z/2024-03-16T00:00Z",
    }) |bad| {
        std.testing.expectError(error.InvalidCharacter, readInterval(bad)) catch |err| {
            std.debug.print("read but should not have: \"{s}\"\n", .{bad});
            return err;
        };
    }
    try std.testing.expectError(error.Overflow, readInterval("2024-03-16T00:00:00Z/2024-03-15T00:00:00Z"));
}

/// `text` as a `RecurringInterval`: whatever
/// `iso8601.parseRecurringInterval` reads, as long as it reads all of it and
/// the interval after the `R` passes `readInterval`'s check on its
/// endpoints.
pub fn readRecurringInterval(text: []const u8) TextError!RecurringInterval {
    const result = iso8601.parseRecurringInterval(text) catch |err| return textError(err);
    if (result.str.len != text.len) return error.InvalidCharacter;
    inline for (.{ result.start, result.end }) |endpoint| {
        if (endpoint) |e| if (!isComplete(e.has_offset, e.precision)) return error.InvalidCharacter;
    }
    return result.value;
}

test readRecurringInterval {
    const series = try readRecurringInterval("R5/2024-03-15T09:00:00-05:00/P1W");
    try std.testing.expectEqual(@as(?u64, 5), series.count);
    try std.testing.expectError(error.InvalidCharacter, readRecurringInterval("R5/2024-03-15T09:00:00/P1W"));
    try std.testing.expectError(error.Overflow, readRecurringInterval("R0/2024-03-15T09:00:00Z/P1W"));
}

/// `Instant.jsonStringify`'s text: the instant in UTC, by way of
/// `Instant.asDateTime` and `iso8601.writeDateTime`.
pub fn writeInstant(writer: *std.Io.Writer, instant: Instant) std.Io.Writer.Error!void {
    return iso8601.writeDateTime(writer, instant.asDateTime());
}

test writeInstant {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeInstant(&w, .{ .timestamp = 1 });
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000000001Z", w.buffered());
}

/// `Duration.jsonStringify`'s text, which is `Duration.format`.
pub fn writeDuration(writer: *std.Io.Writer, duration: Duration) std.Io.Writer.Error!void {
    return duration.format(writer);
}

test writeDuration {
    var buf: [32]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeDuration(&w, .{ .months = 14 });
    try std.testing.expectEqualStrings("P1Y2M", w.buffered());
}

/// `Interval.jsonStringify`'s text, which is `Interval.format`.
pub fn writeInterval(writer: *std.Io.Writer, interval: Interval) std.Io.Writer.Error!void {
    return interval.format(writer);
}

test writeInterval {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeInterval(&w, .{ .start_duration = .{ .start = .{ .year = 2024, .month = .Mar, .day = 15 }, .duration = .{ .days = 1 } } });
    try std.testing.expectEqualStrings("2024-03-15T00:00:00Z/P1D", w.buffered());
}

// The README's example, which is also the case these hooks exist for: the
// types as fields of a record, read and written whole.
test "a record of the types reads and writes whole" {
    const Event = struct {
        name: []const u8,
        at: DateTime,
        lasts: Duration,
        on: Date,
        logged: Instant,
        window: Interval,
    };
    const text =
        \\{"name":"standup","at":"2024-03-15T09:00:00-05:00","lasts":"PT15M","on":"2024-03-15","logged":"2024-03-15T14:00:00.5Z","window":"2024-03-15T09:00:00-05:00/PT15M"}
    ;

    const parsed = try std.json.parseFromSlice(Event, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, -5 * 3600), parsed.value.at.offset);
    try std.testing.expect(parsed.value.lasts.eql(.{ .nanoseconds = 15 * Duration.nanoseconds_per_minute }));

    const written = try std.json.Stringify.valueAlloc(std.testing.allocator, parsed.value, .{});
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings(text, written);
}

/// `RecurringInterval.jsonStringify`'s text, which is
/// `RecurringInterval.format`.
pub fn writeRecurringInterval(writer: *std.Io.Writer, series: RecurringInterval) std.Io.Writer.Error!void {
    return series.format(writer);
}

test writeRecurringInterval {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeRecurringInterval(&w, .{ .count = null, .interval = .{ .start_duration = .{ .start = .{ .year = 2024, .month = .Mar, .day = 15 }, .duration = .{ .days = 7 } } } });
    try std.testing.expectEqualStrings("R/2024-03-15T00:00:00Z/P7D", w.buffered());
}

test {
    std.testing.refAllDecls(@This());
}
