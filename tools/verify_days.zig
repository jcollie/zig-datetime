// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Checks `Date.fromDaysSinceStartOfEra` against Hinnant's
//! `civil_from_days` for every day number a `Date` can hold, from
//! `Date.min_days` to `Date.max_days`: about 1.57 trillion of them.
//!
//! The library converts a day number with Ben Joffe's fixed-point
//! algorithm, whose author established its range by testing rather than
//! proof. The tests and the fuzz targets compare it with Hinnant's on the
//! days most likely to go wrong; this compares it on all of them, so that
//! for the range this library uses the question is settled rather than
//! sampled. It takes about half an hour on a sixteen-thread machine, which
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

const DaysType = Date.DaysType;

/// Days per chunk. Large enough that taking the next one costs nothing
/// beside checking it, small enough that progress shows every second or
/// so and the processors finish close together.
const chunk_len: i64 = 1 << 28;

/// Returns the first day number in `[first, last]` on which the two
/// algorithms disagree, or null if they agree on all of it.
pub fn firstDisagreement(first: DaysType, last: DaysType) ?DaysType {
    var day = first;
    while (day <= last) : (day += 1) {
        const expected = hinnant.civilFromDays(day);
        const got = Date.fromDaysSinceStartOfEra(day);
        if (expected.year != got.year or
            expected.month != got.month.monthNumber() or
            expected.day != got.day) return day;
    }
    return null;
}

test firstDisagreement {
    try std.testing.expectEqual(@as(?DaysType, null), firstDisagreement(-100_000, 100_000));
    try std.testing.expectEqual(@as(?DaysType, null), firstDisagreement(Date.min_days, Date.min_days + 1000));
    try std.testing.expectEqual(@as(?DaysType, null), firstDisagreement(Date.max_days - 1000, Date.max_days));
}

/// What the tasks share: where the next chunk starts, how many are done,
/// and the earliest disagreement any of them has found.
const Shared = struct {
    next: std.atomic.Value(i64) = .init(Date.min_days),
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
        if (start > Date.max_days) return;
        const end = @min(start + chunk_len - 1, Date.max_days);

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

    const span: u64 = @intCast(@as(i64, Date.max_days) - Date.min_days + 1);
    var shared: Shared = .{
        .chunks = std.math.divCeil(u64, span, chunk_len) catch unreachable,
        .io = io,
        .started = .now(io, .awake),
    };

    const tasks = std.Thread.getCpuCount() catch 1;
    std.debug.print("checking {d} day numbers, {d} to {d}, on {d} tasks\n", .{
        span,
        Date.min_days,
        Date.max_days,
        tasks,
    });

    var group: Io.Group = .init;
    for (0..tasks) |_| try group.concurrent(io, worker, .{&shared});
    try group.await(io);

    const elapsed = shared.started.durationTo(.now(io, .awake));
    const seconds = @divTrunc(elapsed.nanoseconds, std.time.ns_per_s);

    const disagreement = shared.disagreement.load(.monotonic);
    if (disagreement != std.math.maxInt(i64)) {
        const day: DaysType = @intCast(disagreement);
        std.debug.print("day {d}: Hinnant {any}, Joffe {any}\n", .{
            day,
            hinnant.civilFromDays(day),
            Date.fromDaysSinceStartOfEra(day),
        });
        return error.Disagreement;
    }

    std.debug.print("all {d} day numbers agree, in {d}s\n", .{ span, seconds });
}
