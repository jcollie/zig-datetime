// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Checks `Date.fromDayNumber` against Hinnant's `civil_from_days` for
//! every day number a `Date` can hold, from `Date.min_day_number` to
//! `Date.max_day_number`: about 1.57 trillion of them, and checks that
//! `Date.toDayNumber` takes each date it gives back to the day number it
//! came from.
//!
//! The library converts in both directions with Ben Joffe's fixed-point
//! algorithms, whose author established their range by testing rather than
//! proof. The tests and the fuzz targets compare them with Hinnant's on the
//! days most likely to go wrong; this compares them on all of them, so that
//! for the range this library uses the question is settled rather than
//! sampled. Every date a `Date` can hold is the date of exactly one of these
//! day numbers, so the round trip checks the conversion back on every date
//! there is. It takes about forty minutes on a sixteen-thread machine, which
//! is why it is a build step of its own and not part of `zig build test`.
//!
//!     zig build verify-days
//!
//! The range is cut into chunks, and one task per processor takes the next
//! chunk until there are none left. The first disagreement stops every
//! task and is printed with both answers, and the program exits with an
//! error.
//!
//! This runs on the build host. See `build.zig`.

const std = @import("std");
const Io = std.Io;
const Date = @import("datetime").Date;
const hinnant = @import("hinnant");

const DayNumber = Date.DayNumber;

/// Days per chunk. Large enough that taking the next one costs nothing
/// beside checking it, small enough that progress shows every second or
/// so and the processors finish close together.
const chunk_len: i64 = 1 << 28;

/// Returns the first day number in `[first, last]` on which the two
/// algorithms disagree about the date, or whose date does not convert back
/// to it, or null if there is no such day number.
pub fn firstDisagreement(first: DayNumber, last: DayNumber) ?DayNumber {
    var day = first;
    while (day <= last) : (day += 1) {
        const expected = hinnant.civilFromDays(day);
        const got = Date.fromDayNumber(day);
        if (expected.year != got.year or
            expected.month != got.month.monthNumber() or
            expected.day != got.day or
            got.toDayNumber() != day) return day;
    }
    return null;
}

test firstDisagreement {
    try std.testing.expectEqual(@as(?DayNumber, null), firstDisagreement(-100_000, 100_000));
    try std.testing.expectEqual(@as(?DayNumber, null), firstDisagreement(Date.min_day_number, Date.min_day_number + 1000));
    try std.testing.expectEqual(@as(?DayNumber, null), firstDisagreement(Date.max_day_number - 1000, Date.max_day_number));
}

/// What the tasks share: where the next chunk starts, how many are done,
/// and the earliest disagreement any of them has found.
const Shared = struct {
    next: std.atomic.Value(i64) = .init(Date.min_day_number),
    done: std.atomic.Value(u64) = .init(0),
    /// `maxInt(i64)` until something disagrees.
    disagreement: std.atomic.Value(i64) = .init(std.math.maxInt(i64)),
    chunks: u64,
    io: Io,
    started: Io.Timestamp,
};

/// Takes chunks until there are none left or a disagreement turns up.
fn worker(shared: *Shared) void {
    while (shared.disagreement.load(.monotonic) == std.math.maxInt(i64)) {
        const start = shared.next.fetchAdd(chunk_len, .monotonic);
        if (start > Date.max_day_number) return;
        const end = @min(start + chunk_len - 1, Date.max_day_number);

        if (firstDisagreement(@intCast(start), @intCast(end))) |day| {
            _ = shared.disagreement.fetchMin(day, .monotonic);
            return;
        }

        const done = shared.done.fetchAdd(1, .monotonic) + 1;
        if (done % 64 == 0 or done == shared.chunks) {
            const elapsed = shared.started.durationTo(.now(shared.io, .awake));
            std.debug.print("{d}/{d} chunks, {d}s\n", .{
                done,
                shared.chunks,
                @divTrunc(elapsed.nanoseconds, std.time.ns_per_s),
            });
        }
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    _ = init;

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const span: u64 = @intCast(@as(i64, Date.max_day_number) - Date.min_day_number + 1);
    var shared: Shared = .{
        .chunks = std.math.divCeil(u64, span, chunk_len) catch unreachable,
        .io = io,
        .started = .now(io, .awake),
    };

    const tasks = std.Thread.getCpuCount() catch 1;
    std.debug.print("checking {d} day numbers, {d} to {d}, on {d} tasks\n", .{
        span,
        Date.min_day_number,
        Date.max_day_number,
        tasks,
    });

    var group: Io.Group = .init;
    for (0..tasks) |_| try group.concurrent(io, worker, .{&shared});
    try group.await(io);

    const elapsed = shared.started.durationTo(.now(io, .awake));
    const seconds = @divTrunc(elapsed.nanoseconds, std.time.ns_per_s);

    const disagreement = shared.disagreement.load(.monotonic);
    if (disagreement != std.math.maxInt(i64)) {
        const day: DayNumber = @intCast(disagreement);
        const got = Date.fromDayNumber(day);
        std.debug.print("day {d}: Hinnant {any}, Joffe {any}, back to {d}\n", .{
            day,
            hinnant.civilFromDays(day),
            got,
            got.toDayNumber(),
        });
        return error.Disagreement;
    }

    std.debug.print("all {d} day numbers agree, in {d}s\n", .{ span, seconds });
}
