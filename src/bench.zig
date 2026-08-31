//! Benchmarks for the datetime library, run with `zig build bench`.
//!
//! Inputs cycle through a table of 1024 values and every result is folded
//! into an accumulator; both are needed to keep the optimizer from
//! constant-folding or dead-code-eliminating the work being measured.
//!
//! The timezone benchmarks need a copy of the IANA database. They use the
//! one embedded by -Dembed-tzdata if there is one and fall back to the
//! system's, and say so and skip if neither is present.

const std = @import("std");

const datetime = @import("datetime");
const Date = datetime.Date;
const DateTime = datetime.DateTime;
const Instant = datetime.Instant;
const TimeZone = datetime.TimeZone;
const iso8601 = datetime.iso8601;
const rfc822 = datetime.rfc822;
const tzdb = datetime.tzdb;

const N = 10_000_000;
const table_len = 1024;

fn report(name: []const u8, ns: u64) void {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
    const rate = 1e9 / per / 1e6;
    std.debug.print("{s:<26} {d:>8.2} ns/op {d:>8.2} Mop/s\n", .{ name, per, rate });
}

fn skip(name: []const u8, why: []const u8) void {
    std.debug.print("{s:<26} {s}\n", .{ name, why });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // Timestamps spread across 1970 to 2100, so the transition searches
    // land all over the table rather than on one cached spot.
    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    const rng = prng.random();

    var timestamps: [table_len]i64 = undefined;
    for (&timestamps) |*t| t.* = rng.intRangeAtMost(i64, 0, 4_102_444_800);

    var datetimes: [table_len]DateTime = undefined;
    for (&datetimes, timestamps) |*d, t| {
        d.* = Instant.fromNanoTimeStamp(@as(i128, t) * std.time.ns_per_s).asDateTime();
    }

    var dates: [table_len]Date = undefined;
    for (&dates, datetimes) |*d, dt| {
        d.* = .{ .year = dt.year, .month = dt.month, .day = dt.day };
    }

    var days: [table_len]Date.DaysType = undefined;
    for (&days, dates) |*d, date| d.* = date.toDaysSinceStartOfEra();

    // --- calendar arithmetic ------------------------------------------

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= dates[i & (table_len - 1)].toDaysSinceStartOfEra();
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("Date.toDays", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| {
            const date = Date.fromDaysSinceStartOfEra(days[i & (table_len - 1)]);
            acc +%= date.year + date.day;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("Date.fromDays", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| {
            const dt = Instant.fromNanoTimeStamp(
                @as(i128, timestamps[i & (table_len - 1)]) * std.time.ns_per_s,
            ).asDateTime();
            acc +%= dt.year + dt.hour;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("Instant.asDateTime", ns);
    }

    {
        var shifted: [table_len]DateTime = undefined;
        for (&shifted, datetimes) |*d, dt| {
            d.* = dt;
            d.offset = -5 * std.time.s_per_hour;
        }
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= shifted[i & (table_len - 1)].toUtc().hour;
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("DateTime.toUtc", ns);
    }

    // --- formatting ---------------------------------------------------

    {
        var buf: [64]u8 = undefined;
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: u8 = 0;
        for (0..N) |i| {
            var writer: std.Io.Writer = .fixed(&buf);
            try datetimes[i & (table_len - 1)].format("YYYY-MM-DDTHH:mm:ss", &writer);
            for (writer.buffered()) |c| acc +%= c;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("format YYYY-MM-DDTHH:mm:ss", ns);
    }

    // --- parsing ------------------------------------------------------

    var iso_texts: [table_len][32]u8 = undefined;
    var iso_lens: [table_len]usize = undefined;
    var rfc_texts: [table_len][40]u8 = undefined;
    var rfc_lens: [table_len]usize = undefined;
    for (datetimes, 0..) |dt, i| {
        var writer: std.Io.Writer = .fixed(&iso_texts[i]);
        try dt.format("YYYY-MM-DDTHH:mm:ssZ", &writer);
        iso_lens[i] = writer.buffered().len;

        var rfc_writer: std.Io.Writer = .fixed(&rfc_texts[i]);
        try dt.format("ddd, DD MMM YYYY HH:mm:ss ZZ", &rfc_writer);
        rfc_lens[i] = rfc_writer.buffered().len;
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| {
            const at = i & (table_len - 1);
            const parsed = try DateTime.parse("YYYY-MM-DDTHH:mm:ss", iso_texts[at][0..iso_lens[at]]);
            acc +%= parsed.value.year;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("DateTime.parse", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| {
            const at = i & (table_len - 1);
            const parsed = try iso8601.parse(iso_texts[at][0..iso_lens[at]]);
            acc +%= parsed.value.year;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("iso8601.parse", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| {
            const at = i & (table_len - 1);
            const parsed = try rfc822.parse(rfc_texts[at][0..rfc_lens[at]]);
            acc +%= parsed.value.year;
        }
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("rfc822.parse", ns);
    }

    // --- timezones ----------------------------------------------------

    var zone = (try loadZone(io, gpa, "America/Chicago")) orelse {
        skip("TimeZone.typeAt", "no timezone database available");
        return;
    };
    defer zone.deinit(gpa);

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= zone.offsetAt(timestamps[i & (table_len - 1)]);
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("TimeZone.offsetAt", ns);
    }

    {
        // Past the last stored transition, so every lookup runs the
        // zone's POSIX rule rather than searching the table.
        var future: [table_len]i64 = undefined;
        for (&future, timestamps) |*f, t| f.* = 4_200_000_000 + @rem(t, 1_000_000_000);
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= zone.offsetAt(future[i & (table_len - 1)]);
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("TimeZone.offsetAt (posix)", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= zone.resolve(datetimes[i & (table_len - 1)]).earliest();
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("TimeZone.resolve", ns);
    }

    {
        const t0: std.Io.Timestamp = .now(io, .awake);
        var acc: i64 = 0;
        for (0..N) |i| acc +%= zone.atTimestamp(timestamps[i & (table_len - 1)]).hour;
        const ns: u64 = @intCast(t0.durationTo(.now(io, .awake)).nanoseconds);
        std.mem.doNotOptimizeAway(acc);
        report("TimeZone.atTimestamp", ns);
    }
}

/// Returns a zone from whichever copy of the database is available, or
/// null when there is none.
fn loadZone(io: std.Io, gpa: std.mem.Allocator, name: []const u8) !?TimeZone {
    if (tzdb.embedded.available) {
        if (try tzdb.embedded.load(name)) |zone| return zone;
    }
    for (tzdb.system.search_directories) |directory| {
        return tzdb.system.load(io, gpa, directory, name) catch continue;
    }
    return null;
}
