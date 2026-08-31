// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

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

/// One local time type: an offset from UTC, whether it is a daylight
/// saving one, and the abbreviation shown for it. Re-exported from `tzif`
/// so that callers of a zone need not reach into the file format.
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

/// What building a zone can fail with: anything wrong with the TZif bytes,
/// or with the POSIX rule in their footer.
pub const Error = tzif.ParseError || posixtz.ParseError;

/// Builds a zone from TZif bytes that the caller continues to own. Use
/// this for data embedded with `@embedFile`, which needs no allocator.
pub fn fromBytes(name: []const u8, bytes: []const u8) Error!TimeZone {
    return init(name, bytes, false);
}

test fromBytes {
    // The zone borrows the bytes, so nothing is allocated and nothing has
    // to be freed. This is the shape `tzdb.embedded` uses, where the data
    // is already in the binary.
    const bytes = try bytesForTest("America/Chicago");
    defer testing.allocator.free(bytes);

    const zone = try fromBytes("America/Chicago", bytes);
    try testing.expectEqualStrings("America/Chicago", zone.name);
    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), zone.offsetAt(0));
}

/// Builds a zone that takes ownership of `bytes`, which `deinit` frees.
pub fn fromOwnedBytes(name: []const u8, bytes: []const u8) Error!TimeZone {
    return init(name, bytes, true);
}

test fromOwnedBytes {
    // The zone takes the bytes over, so `deinit` is what frees them. This
    // is the shape `tzdb.system` uses, having just read a file.
    //
    // The bytes are taken first because `bytesForTest` skips the test on
    // a machine with no database, and anything allocated ahead of that
    // would be lost when the skip propagates out.
    const bytes = try bytesForTest("America/Chicago");
    errdefer testing.allocator.free(bytes);

    const name = try testing.allocator.dupe(u8, "America/Chicago");
    errdefer testing.allocator.free(name);

    var zone = try fromOwnedBytes(name, bytes);
    defer zone.deinit(testing.allocator);

    try testing.expectEqualStrings("America/Chicago", zone.name);
}

/// Parses `bytes` into a zone. The footer is parsed here rather than on
/// demand so that a malformed rule is reported when the zone is built,
/// not later at some lookup that happens to fall past the transitions.
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

test init {
    const bytes = try bytesForTest("America/Chicago");
    defer testing.allocator.free(bytes);

    // The footer is parsed here and not on demand, so a zone that builds
    // at all has a usable rule for the times past its last transition.
    const zone = try init("America/Chicago", bytes, false);
    try testing.expect(zone.rule != null);
    try testing.expect(!zone.owned);

    // Bad bytes fail here rather than at some later lookup.
    try testing.expectError(error.BadMagic, init("x", "XZif" ++ ("\x00" ** 40), false));
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

test deinit {
    // An owned zone frees its bytes and its name; the testing allocator
    // is what checks that this happened.
    var owned = try loadForTest("America/Chicago");
    owned.deinit(testing.allocator);

    // A borrowed one frees nothing, so its bytes outlive it.
    const bytes = try bytesForTest("America/Chicago");
    defer testing.allocator.free(bytes);

    var borrowed = try fromBytes("America/Chicago", bytes);
    borrowed.deinit(testing.allocator);
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

test typeAt {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // Midwinter and midsummer 2024, either side of the switch.
    const winter = zone.typeAt(1704067200);
    try testing.expectEqualStrings("CST", winter.designation);
    try testing.expect(!winter.is_dst);

    const summer = zone.typeAt(1720000000);
    try testing.expectEqualStrings("CDT", summer.designation);
    try testing.expect(summer.is_dst);

    // Far past the last stored transition the footer's rule answers, so
    // a slim file keeps working rather than running out.
    const distant = zone.typeAt(4102444800);
    try testing.expect(distant.designation.len > 0);
}

/// Returns the offset from UTC in seconds in effect at `timestamp`.
pub fn offsetAt(self: TimeZone, timestamp: i64) i32 {
    return self.typeAt(timestamp).offset;
}

test offsetAt {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), zone.offsetAt(1704067200));
    try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), zone.offsetAt(1720000000));
}

/// A stretch of time over which one local time type applies.
pub const Span = struct {
    local_type: Type,
    /// Inclusive.
    start: i64,
    /// Exclusive.
    end: i64,
};

/// Returns the span around `timestamp`.
///
/// This costs a little more than `typeAt` does, since the rule in a
/// footer has to work out the switches either side rather than just
/// which side of them it is on. It is worth it wherever the bounds save
/// a second lookup, which is what `resolve` uses them for.
pub fn spanAt(self: TimeZone, timestamp: i64) Span {
    if (self.data.spanAtTimestamp(timestamp)) |span| return .{
        .local_type = span.local_type,
        .start = span.start,
        .end = span.end,
    };

    // Past the last stored transition the footer takes over, and it does
    // not govern anything before that, so a span it reports cannot reach
    // back past the handover.
    const count = self.data.transitionCount();
    const takeover: i64 = if (count == 0)
        std.math.minInt(i64)
    else
        self.data.transitionAt(count - 1);

    if (self.rule) |rule| {
        const span = rule.spanAt(timestamp);
        return .{
            .local_type = span.local_type,
            .start = @max(span.start, takeover),
            .end = span.end,
        };
    }

    return .{
        .local_type = self.data.lastType(),
        .start = takeover,
        .end = std.math.maxInt(i64),
    };
}

/// Converts an instant to the local wall-clock time in this zone, with
/// `DateTime.offset` set to the offset that was in effect.
pub fn atInstant(self: TimeZone, instant: Instant) DateTime {
    const seconds: i64 = @intCast(@divFloor(instant.timestamp, std.time.ns_per_s));
    const local_type = self.typeAt(seconds);

    const shifted: Instant = .{
        .timestamp = instant.timestamp + @as(i128, local_type.offset) * std.time.ns_per_s,
    };
    var datetime = shifted.asDateTime();
    datetime.offset = local_type.offset;
    return datetime;
}

test atInstant {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // 2024-07-03T09:46:40Z, in the middle of daylight saving time, reads
    // five hours earlier on a Chicago clock.
    const local = zone.atInstant(.fromNanoTimeStamp(1720000000 * @as(i128, std.time.ns_per_s)));
    try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), local.offset);
    try testing.expectEqual(Month.Jul, local.month);
    try testing.expectEqual(@as(u5, 4), local.hour);
    try testing.expectEqual(@as(u6, 46), local.minute);

    // The offset comes back on the value, so the reading can be turned
    // round again without the zone.
    try testing.expectEqual(@as(u5, 9), local.toUtc().hour);
}

/// Converts a Unix timestamp in seconds to local wall-clock time.
pub fn atTimestamp(self: TimeZone, timestamp: i64) DateTime {
    return self.atInstant(.fromNanoTimeStamp(@as(i128, timestamp) * std.time.ns_per_s));
}

test atTimestamp {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // The same as `atInstant`, for callers holding whole seconds.
    const local = zone.atTimestamp(1720000000);
    try testing.expectEqual(@as(u5, 4), local.hour);
    try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), local.offset);
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

    test earliest {
        try testing.expectEqual(@as(i64, 100), (Resolved{ .unique = 100 }).earliest());

        // For a repeated reading this is the first of the two instants,
        // the one before the clocks went back.
        const twice: Resolved = .{ .ambiguous = .{ .earlier = 100, .later = 3700 } };
        try testing.expectEqual(@as(i64, 100), twice.earliest());

        // A skipped reading names one instant either way.
        const skipped: Resolved = .{ .gap = .{ .at = 100, .before = 0, .after = 3600 } };
        try testing.expectEqual(@as(i64, 100), skipped.earliest());
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

    test latest {
        try testing.expectEqual(@as(i64, 100), (Resolved{ .unique = 100 }).latest());

        // The second of the two instants a repeated reading names.
        const twice: Resolved = .{ .ambiguous = .{ .earlier = 100, .later = 3700 } };
        try testing.expectEqual(@as(i64, 3700), twice.latest());
    }
};

/// Resolves a local wall-clock reading to UTC. The `offset` field of
/// `local` is ignored; the zone decides it.
pub fn resolve(self: TimeZone, local: DateTime) Resolved {
    const reading = localSeconds(local);

    // A span running from `start` to `end` with offset `o` covers local
    // readings from `start + o` to `end + o`, so it holds a match for
    // this reading exactly when the reading falls in that range, and the
    // match is `reading - o`. The span's own bounds settle that, which is
    // why this walks spans rather than probing instants and then looking
    // each one up again to see whether it stuck.
    //
    // An offset is less than a day, so only the spans covering the day
    // either side of the reading can hold a match. Usually that is one
    // span and one lookup; a reading near a switch takes two.
    const window = std.time.s_per_day;
    const last = reading +| window;

    var candidates: [2]i64 = undefined;
    var count: usize = 0;
    var before: i32 = 0;
    var after: i32 = 0;

    var probe = reading -| window;
    var first = true;
    while (true) {
        const span = self.spanAt(probe);
        if (first) {
            before = span.local_type.offset;
            first = false;
        }
        after = span.local_type.offset;

        const at = reading - span.local_type.offset;
        if (at >= span.start and at < span.end and (count == 0 or candidates[0] != at)) {
            candidates[count] = at;
            count += 1;
            if (count == candidates.len) break;
        }

        // `end` is exclusive and above `probe`, so this always advances.
        if (span.end > last) break;
        probe = span.end;
    }

    switch (count) {
        1 => return .{ .unique = candidates[0] },
        2 => return .{ .ambiguous = .{
            .earlier = @min(candidates[0], candidates[1]),
            .later = @max(candidates[0], candidates[1]),
        } },
        else => {
            // Nothing matched, so the reading is inside a gap. Report the
            // transition that skipped it, which is where a clock set to
            // this reading would land.
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

test localSeconds {
    // The reading is counted as though it were UTC, which is what makes
    // it comparable against a span's bounds shifted by that span's
    // offset. The `offset` field is deliberately not applied here.
    try testing.expectEqual(
        @as(i64, 0),
        localSeconds(.{ .year = 1970, .month = .Jan, .day = 1 }),
    );
    try testing.expectEqual(
        @as(i64, 3600),
        localSeconds(.{ .year = 1970, .month = .Jan, .day = 1, .hour = 1 }),
    );
    try testing.expectEqual(
        localSeconds(.{ .year = 2024, .month = .Mar, .day = 15 }),
        localSeconds(.{ .year = 2024, .month = .Mar, .day = 15, .offset = -5 * std.time.s_per_hour }),
    );
}

const testing = std.testing;

/// Directories that different systems keep the TZif tree in, or nothing
/// at all when the build asked for `-Dno-system-tzdata`.
///
/// Emptying the list is what makes a machine that has a database behave
/// like one that has not: `bytesForTest` finds nothing and skips, which is
/// the path a mistake can otherwise hide in. See `build.zig`.
const test_directories: []const []const u8 = if (@import("build_options").no_system_tzdata)
    &.{}
else
    &.{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    };

/// Reads the TZif bytes of a named zone from whichever copy of the
/// database this machine has, or skips the test when it has none. The
/// caller owns the bytes.
fn bytesForTest(name: []const u8) ![]u8 {
    for (test_directories) |directory| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, name });
        defer testing.allocator.free(path);

        return std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            path,
            testing.allocator,
            .limited(1 << 20),
        ) catch continue;
    }
    return error.SkipZigTest;
}

/// Loads a zone for a test from whichever copy of the database this
/// machine has, or skips the test when it has none.
fn loadForTest(name: []const u8) !TimeZone {
    const bytes = try bytesForTest(name);
    errdefer testing.allocator.free(bytes);

    const owned_name = try testing.allocator.dupe(u8, name);
    errdefer testing.allocator.free(owned_name);

    return fromOwnedBytes(owned_name, bytes);
}

test spanAt {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // Midsummer 2024 sits inside daylight saving time, bounded by the
    // March and November switches.
    const summer = zone.spanAt(1720000000);
    try testing.expectEqualStrings("CDT", summer.local_type.designation);
    try testing.expectEqual(@as(i64, 1710057600), summer.start);
    try testing.expectEqual(@as(i64, 1730617200), summer.end);

    // The bounds are what save a second lookup: any instant inside them
    // is governed by the same type.
    try testing.expectEqual(
        summer.local_type.offset,
        zone.typeAt(summer.end - 1).offset,
    );

    // Past the last stored transition the footer's rule answers, and it
    // cannot report a span reaching back before the handover.
    const distant = zone.spanAt(4102444800);
    try testing.expect(distant.start > 0);
}

test resolve {
    var zone = try loadForTest("America/Chicago");
    defer zone.deinit(testing.allocator);

    // An ordinary reading names exactly one instant. The `offset` field
    // of the input is ignored; the zone is what decides it.
    const ordinary = zone.resolve(.{ .year = 2024, .month = .Jul, .day = 3, .hour = 12 });
    try testing.expectEqual(@as(i64, 1720026000), ordinary.unique);

    // The hour the clocks skip forward over never happens, so there is no
    // reading to name. `at` is where it would have fallen, between the
    // offsets either side of the switch.
    const skipped = zone.resolve(.{ .year = 2024, .month = .Mar, .day = 10, .hour = 2, .minute = 30 });
    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), skipped.gap.before);
    try testing.expectEqual(@as(i32, -5 * std.time.s_per_hour), skipped.gap.after);

    // The hour the clocks repeat happens twice, an hour apart.
    const repeated = zone.resolve(.{ .year = 2024, .month = .Nov, .day = 3, .hour = 1, .minute = 30 });
    try testing.expectEqual(
        @as(i64, std.time.s_per_hour),
        repeated.ambiguous.later - repeated.ambiguous.earlier,
    );

    // `earliest` and `latest` pick one without the caller switching on
    // which case it was.
    try testing.expectEqual(repeated.ambiguous.earlier, repeated.earliest());
    try testing.expectEqual(repeated.ambiguous.later, repeated.latest());
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
