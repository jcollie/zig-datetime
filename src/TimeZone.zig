//! A timezone: the rules that say what a clock in some place reads at a
//! given instant, and what that reading is called.
//!
//! A zone is built from the bytes of a TZif file, which may come from the
//! operating system's copy of the IANA database or from a copy embedded in
//! the binary. See `tzdb`.

const TimeZone = @This();

const std = @import("std");

const Date = @import("Date.zig");
const DateTime = @import("DateTime.zig");
const DayOfWeek = @import("dayofweek.zig").DayOfWeek;
const Instant = @import("Instant.zig");
const Month = @import("month.zig").Month;
const posixtz = @import("posixtz.zig");
const tzif = @import("tzif.zig");

pub const Type = tzif.Type;

/// The IANA name of the zone, such as "America/Chicago".
name: []const u8,
/// The TZif bytes the zone was parsed from. Everything else borrows from
/// here, so these bytes must outlive the zone.
bytes: []const u8,
/// Whether `bytes` was allocated on the zone's behalf and must be freed.
owned: bool,
data: tzif.Tzif,
/// The parsed footer, which governs every time after the last stored
/// transition. Absent for a version 1 file, which has no footer.
rule: ?posixtz.Posix,

pub const Error = tzif.ParseError || posixtz.ParseError;

/// Builds a zone from TZif bytes that the caller continues to own. Use
/// this for data embedded with `@embedFile`, which needs no allocator.
pub fn fromBytes(name: []const u8, bytes: []const u8) Error!TimeZone {
    return init(name, bytes, false);
}

/// Builds a zone that takes ownership of `bytes`, which `deinit` frees.
pub fn fromOwnedBytes(name: []const u8, bytes: []const u8) Error!TimeZone {
    return init(name, bytes, true);
}

fn init(name: []const u8, bytes: []const u8, owned: bool) Error!TimeZone {
    const data = try tzif.parse(bytes);
    return .{
        .name = name,
        .bytes = bytes,
        .owned = owned,
        .data = data,
        .rule = if (data.footer.len == 0) null else try posixtz.parse(data.footer),
    };
}

/// Frees the bytes of a zone built by `fromOwnedBytes`, and the copy of
/// its name. Does nothing for a zone built by `fromBytes`.
pub fn deinit(self: *TimeZone, gpa: std.mem.Allocator) void {
    if (self.owned) {
        gpa.free(self.bytes);
        gpa.free(self.name);
    }
    self.* = undefined;
}

/// Returns the local time type in effect at `timestamp`, a Unix time in
/// seconds.
pub fn typeAt(self: TimeZone, timestamp: i64) Type {
    if (self.data.typeAtTimestamp(timestamp)) |local_type| return local_type;
    // Past the last stored transition the footer takes over. A file
    // compiled with `zic -b slim` relies on this for everything from the
    // last irregular year onwards.
    if (self.rule) |rule| return rule.typeAt(timestamp);
    return self.data.lastType();
}

/// Returns the offset from UTC in seconds in effect at `timestamp`.
pub fn offsetAt(self: TimeZone, timestamp: i64) i32 {
    return self.typeAt(timestamp).offset;
}

/// Converts an instant to the local wall-clock time in this zone, with
/// `DateTime.offset` set to the offset that was in effect.
pub fn atInstant(self: TimeZone, instant: Instant) DateTime {
    const seconds: i64 = @intCast(@divFloor(instant.timestamp, std.time.ns_per_s));
    const local_type = self.typeAt(seconds);

    const shifted: Instant = .{
        .timestamp = instant.timestamp + @as(i128, local_type.offset) * std.time.ns_per_s,
        .timezone = instant.timezone,
    };
    var datetime = shifted.asDateTime();
    datetime.offset = local_type.offset;
    return datetime;
}

/// Converts a Unix timestamp in seconds to local wall-clock time.
pub fn atTimestamp(self: TimeZone, timestamp: i64) DateTime {
    return self.atInstant(.fromNanoTimeStamp(@as(i128, timestamp) * std.time.ns_per_s));
}

/// What a local wall-clock reading corresponds to in UTC.
///
/// Most readings name exactly one instant, but a clock that springs
/// forward skips a range of readings that never happen, and one that falls
/// back repeats a range that happens twice. Callers have to say which they
/// want, so both cases are reported rather than quietly resolved.
pub const Resolved = union(enum) {
    /// The reading names exactly one instant.
    unique: i64,
    /// The reading never happens: the clock jumped from `before` to
    /// `after` local time at instant `at`, skipping over it.
    gap: struct {
        at: i64,
        before: i32,
        after: i32,
    },
    /// The reading happens twice, once at each instant.
    ambiguous: struct {
        earlier: i64,
        later: i64,
    },

    /// The earliest instant matching the reading, taking the pre-transition
    /// offset for a reading that falls in a gap.
    pub fn earliest(self: Resolved) i64 {
        return switch (self) {
            .unique => |at| at,
            .gap => |g| g.at,
            .ambiguous => |a| a.earlier,
        };
    }

    /// The latest instant matching the reading, taking the post-transition
    /// offset for a reading that falls in a gap.
    pub fn latest(self: Resolved) i64 {
        return switch (self) {
            .unique => |at| at,
            .gap => |g| g.at,
            .ambiguous => |a| a.later,
        };
    }
};

/// Resolves a local wall-clock reading to UTC. The `offset` field of
/// `local` is ignored; the zone decides it.
pub fn resolve(self: TimeZone, local: DateTime) Resolved {
    const reading = localSeconds(local);

    // A candidate instant is `reading` minus some offset, and it is real
    // only if the zone really does use that offset there. Probing a day
    // either side is more than enough, since no transition moves a clock
    // by anything close to that.
    var candidates: [3]i64 = undefined;
    var count: usize = 0;
    for ([_]i64{
        reading - std.time.s_per_day,
        reading,
        reading + std.time.s_per_day,
    }) |probe| {
        const offset = self.offsetAt(probe);
        const candidate = reading - offset;
        if (self.offsetAt(candidate) != offset) continue;
        for (candidates[0..count]) |seen| {
            if (seen == candidate) break;
        } else {
            candidates[count] = candidate;
            count += 1;
        }
    }

    switch (count) {
        1 => return .{ .unique = candidates[0] },
        2 => {
            const earlier = @min(candidates[0], candidates[1]);
            const later = @max(candidates[0], candidates[1]);
            return .{ .ambiguous = .{ .earlier = earlier, .later = later } };
        },
        else => {
            // Nothing matched, so the reading is inside a gap. Report the
            // transition that skipped it, which is where a clock set to
            // this reading would land.
            const before = self.offsetAt(reading - std.time.s_per_day);
            const after = self.offsetAt(reading + std.time.s_per_day);
            return .{ .gap = .{
                .at = reading - before,
                .before = before,
                .after = after,
            } };
        },
    }
}

/// Returns a wall-clock reading as seconds since the epoch, as though the
/// reading were UTC.
fn localSeconds(local: DateTime) i64 {
    const date: Date = .{
        .year = local.year,
        .month = local.month,
        .day = local.day,
    };
    return @as(i64, date.toDaysSinceStartOfEra()) * std.time.s_per_day +
        @as(i64, local.hour) * std.time.s_per_hour +
        @as(i64, local.minute) * std.time.s_per_min +
        @as(i64, local.second);
}

const testing = std.testing;

/// Directories that different systems keep the TZif tree in.
const test_directories = [_][]const u8{
    "/usr/share/zoneinfo",
    "/etc/zoneinfo",
    "/usr/lib/zoneinfo",
    "/usr/share/lib/zoneinfo",
};

/// Loads a zone for a test from whichever copy of the database this
/// machine has, or skips the test when it has none.
fn loadForTest(name: []const u8) !TimeZone {
    for (test_directories) |directory| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, name });
        defer testing.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            testing.allocator,
            .limited(1 << 20),
        ) catch continue;
        errdefer testing.allocator.free(bytes);

        return fromOwnedBytes(try testing.allocator.dupe(u8, name), bytes);
    }
    return error.SkipZigTest;
}

test "the offset in effect at an instant" {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    const cases = [_]struct {
        at: i64,
        offset: i32,
        designation: []const u8,
        is_dst: bool,
    }{
        // Local mean time, before the railways brought standard time. The
        // offset is not a whole number of minutes, which is why the
        // library keeps offsets in seconds.
        .{ .at = -2840097600, .offset = -21036, .designation = "LMT", .is_dst = false },
        .{ .at = -2195899200, .offset = -21600, .designation = "CST", .is_dst = false },
        .{ .at = 1705320000, .offset = -21600, .designation = "CST", .is_dst = false },
        .{ .at = 1721044800, .offset = -18000, .designation = "CDT", .is_dst = true },
        // Far past the last stored transition, so these come from the
        // POSIX rule in the file's footer rather than from its table.
        .{ .at = 4070952000, .offset = -21600, .designation = "CST", .is_dst = false },
        .{ .at = 4086590400, .offset = -18000, .designation = "CDT", .is_dst = true },
    };

    for (cases) |case| {
        const local_type = zone.typeAt(case.at);
        try testing.expectEqual(case.offset, local_type.offset);
        try testing.expectEqual(case.is_dst, local_type.is_dst);
        try testing.expectEqualStrings(case.designation, local_type.designation);
        try testing.expectEqual(case.offset, zone.offsetAt(case.at));
    }
}

test "an instant becomes local wall-clock time" {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // 2024-07-15 12:00 UTC is 07:00 in Chicago, on daylight time.
    const local = zone.atTimestamp(1721044800);
    try testing.expectEqual(@as(i32, 2024), local.year);
    try testing.expectEqual(Month.Jul, local.month);
    try testing.expectEqual(@as(u6, 15), local.day);
    try testing.expectEqual(@as(u5, 7), local.hour);
    try testing.expectEqual(@as(u6, 0), local.minute);
    try testing.expectEqual(@as(i32, -18000), local.offset);
    try testing.expectEqual(DayOfWeek.Mon, local.weekday);

    // Converting back to UTC undoes it exactly.
    try testing.expectEqual(@as(i64, 1721044800), zone.resolve(local).earliest());
}

test "an ordinary local reading names one instant" {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    const local: DateTime = .{ .year = 2024, .month = .Jul, .day = 15, .hour = 7 };
    switch (zone.resolve(local)) {
        .unique => |at| try testing.expectEqual(@as(i64, 1721044800), at),
        else => return error.TestUnexpectedResult,
    }
}

test "a local reading skipped by the spring forward" {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // Clocks went from 02:00 to 03:00 on 2024-03-10, so 02:30 never
    // happened that day.
    const local: DateTime = .{ .year = 2024, .month = .Mar, .day = 10, .hour = 2, .minute = 30 };
    switch (zone.resolve(local)) {
        .gap => |gap| {
            try testing.expectEqual(@as(i32, -21600), gap.before);
            try testing.expectEqual(@as(i32, -18000), gap.after);
            // Reading it with the old offset lands half an hour past the
            // switch, at 03:30 local.
            try testing.expectEqual(@as(i64, 1710059400), gap.at);
        },
        else => return error.TestUnexpectedResult,
    }

    // The minute before and the minute after the gap are ordinary.
    try testing.expect(zone.resolve(.{
        .year = 2024,
        .month = .Mar,
        .day = 10,
        .hour = 1,
        .minute = 59,
    }) == .unique);
    try testing.expect(zone.resolve(.{
        .year = 2024,
        .month = .Mar,
        .day = 10,
        .hour = 3,
    }) == .unique);
}

test "a local reading repeated by the fall back" {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // Clocks went from 02:00 back to 01:00 on 2024-11-03, so 01:30
    // happened twice, an hour apart.
    const local: DateTime = .{ .year = 2024, .month = .Nov, .day = 3, .hour = 1, .minute = 30 };
    switch (zone.resolve(local)) {
        .ambiguous => |both| {
            try testing.expectEqual(@as(i64, 1730615400), both.earlier);
            try testing.expectEqual(@as(i64, 1730619000), both.later);
            try testing.expectEqual(@as(i64, 3600), both.later - both.earlier);
        },
        else => return error.TestUnexpectedResult,
    }

    const resolved = zone.resolve(local);
    try testing.expectEqual(@as(i64, 1730615400), resolved.earliest());
    try testing.expectEqual(@as(i64, 1730619000), resolved.latest());
    // The two readings really do differ only in which side of the switch
    // they fall on.
    try testing.expect(zone.typeAt(resolved.earliest()).is_dst);
    try testing.expect(!zone.typeAt(resolved.latest()).is_dst);
}

test "a zone whose daylight saving time is half an hour" {
    var zone = try loadForTest("Australia/Lord_Howe");
    defer zone.deinit(testing.allocator);

    // Lord Howe moves its clocks by thirty minutes rather than an hour,
    // so its gap is half the usual width.
    const local: DateTime = .{ .year = 2024, .month = .Oct, .day = 6, .hour = 2, .minute = 15 };
    switch (zone.resolve(local)) {
        .gap => |gap| {
            try testing.expectEqual(@as(i32, 10 * std.time.s_per_hour + 1800), gap.before);
            try testing.expectEqual(@as(i32, 11 * std.time.s_per_hour), gap.after);
        },
        else => return error.TestUnexpectedResult,
    }

    // In January the island is on daylight time at +11.
    try testing.expectEqual(@as(i32, 39600), zone.offsetAt(1705320000));
}

test "a zone that has never had daylight saving time" {
    var zone = try loadForTest("Asia/Kolkata");
    defer zone.deinit(testing.allocator);

    // A fixed offset of five and a half hours, in both halves of the year
    // and beyond the last stored transition.
    for ([_]i64{ 1705320000, 1721044800, 4086590400 }) |at| {
        const local_type = zone.typeAt(at);
        try testing.expectEqual(@as(i32, 19800), local_type.offset);
        try testing.expect(!local_type.is_dst);
    }

    // With no switches, every local reading names exactly one instant.
    try testing.expect(zone.resolve(.{
        .year = 2024,
        .month = .Mar,
        .day = 10,
        .hour = 2,
        .minute = 30,
    }) == .unique);
}
