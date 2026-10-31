// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Checks `gitdate` against git itself.
//!
//! git's date parsing is documented by example and defined by what git
//! does, so git is the specification. Its two parsers can each be asked a
//! question without a commit in sight:
//!
//!   * `git rev-parse --since=TEXT` prints `--max-age=SECONDS`, which is
//!     the approximate parser's answer. Any number of `--since` can go in
//!     one call, so the whole corpus costs one process per zone and time.
//!   * `git var GIT_COMMITTER_IDENT`, with `GIT_COMMITTER_DATE=TEXT`,
//!     prints the identity git would put in a commit, ending in the
//!     timestamp and offset the strict parser read, or fails with
//!     `invalid date format`. That is one process per question.
//!   * `git rev-parse HEAD@{TEXT}` fails with `unknown revision` when the
//!     approximate parser understood nothing in `TEXT`, which is what
//!     `Approximate.failed` reports. It wants a repository with a
//!     commit, which is made in the directory given as the one argument.
//!     A text of digits alone is a reflog index there rather than a date,
//!     and one starting with `-` is `@{-N}`, so those are not asked.
//!
//! `GIT_TEST_DATE_NOW` sets git's idea of the current time, and `TZ` and
//! `TZDIR` its zone, so every question is asked at each of a handful of
//! instants either side of daylight saving changes, in zones either side
//! of UTC, in both hemispheres, at a half and a three-quarter hour, and
//! as bare POSIX rules.
//!
//! Every disagreement is printed. Those in `known` are expected and say
//! why; anything else fails the run.

const std = @import("std");
const Io = std.Io;

const datetime = @import("datetime");
const gitdate = datetime.gitdate;
const TimeZone = datetime.TimeZone;
const tzdb = datetime.tzdb;

/// The zones every question is asked in, as `TZ` values.
const zones = [_][]const u8{
    "UTC",
    "America/New_York",
    "Europe/Berlin",
    "Australia/Sydney",
    "Asia/Kolkata",
    "Pacific/Chatham",
    "America/Sao_Paulo",
    "CET-1CEST,M3.5.0,M10.5.0/3",
    "<+0330>-3:30",
    "EST5EDT,M3.2.0/2,M11.1.0/2",
    "",
};

/// The instants every question is asked at.
const nows = [_]i64{
    1790000000, // Monday 2026-09-21 14:13:20 UTC
    1773550800, // Sunday 2026-03-15, a week after the US springs forward
    1773558000, // two hours later
    1774738800, // Sunday 2026-03-29, as Europe springs forward
    1791511200, // Friday 2026-10-09
    1775368800, // Sunday 2026-04-05, as Sydney falls back
};

/// Questions for the approximate parser. Most of these are also strict
/// dates, which it answers first.
const approximate = [_][]const u8{
    // What zig-git asks.
    "yesterday",
    "2 weeks ago",
    "1 month ago",
    "3 years ago",
    "noon",
    "midnight",
    "tea",
    "last friday",
    "6 months ago",
    "2026-03-08",
    "2026-03-08 02:30:00",
    "2026-11-01 01:30:00",
    "2026-10-25 02:30",
    "2026-04-05 02:30",
    "Mar 29 2026 2:30am",
    "01/02/2026",
    "2026.03.29",
    "20260308T023000",
    "@1790000000 +0130",
    "Tue, 1 Sep 2026 12:00:00 -0700",
    "now",
    "today",
    "five hours ago",
    "never",
    "10 pm yesterday",
    "noon last monday",
    "nonsense",
    "2026-09-21 14:16 +0000",
    "50 minutes ago",

    // Relative words, and how they combine.
    "3 days ago",
    "3 days",
    "3 Days Ago",
    "1 week 2 days ago",
    "3 days and 2 hours ago",
    "1.week.ago",
    "1_week_ago",
    "last week",
    "last month",
    "last year",
    "one week ago",
    "ten days ago",
    "eleven days ago",
    "a week ago",
    "days ago",
    "ago",
    "3 sec ago",
    "3 mins ago",
    "3 dayss ago",
    "24 hours ago",
    "4380 hours ago",
    "182 days ago",
    "3 days ago 3 days ago",
    "yesterday noon",
    "noon yesterday",
    "yesterday today",
    "today yesterday",
    "now yesterday",
    "never yesterday",
    "never 3pm",
    "midnight 3 days ago",
    "3 days ago midnight",
    "last friday noon",
    "today 3pm",

    // Weekdays.
    "friday",
    "last monday",
    "last tuesday",
    "last sunday",
    "last fri",
    "last fr",
    "3 mon ago",
    "5 last friday",
    "Jan 5 friday",
    "Jan 5 last friday",
    "last friday Jan 5",
    "yesterday last friday",

    // Times of day.
    "3pm",
    "3 pm",
    "12am",
    "12pm",
    "13pm",
    "am",
    "pm",
    "11:30pm",
    "15:00",
    "15:00:07",
    "3:00",
    "10:30:15.123",
    "Jan 5 24:00",
    "Jan 5 25:00",
    "Jan 5 12:60",
    "Jan 5 12:30:60",
    "Jan 5 9:5",

    // Months, days and years by name and number.
    "Oct 5",
    "Sep 25",
    "Sep 20",
    "Dec 1",
    "december",
    "Jan",
    "Jan 2025",
    "Jan 1 2025",
    "1 Jan 2025",
    "2025 Jan 1",
    "5 Jan",
    "Feb 30",
    "Feb 29 2025",
    "Sept 5",
    "Septe 5",
    "Septemberx 5",
    "Se 5",
    "last fridayx",
    "last fridays",
    "last frid",
    "2026-09-10 yesterday",
    "2026-09-10 last friday",
    "Jan 5 noon",
    "Sep 21 tea",
    "yesterday tea",
    "tea yesterday",
    "noon 2 days ago",
    "last mondays",
    "01/02/1969",
    "1969-01-02",
    "noon today",
    "Jan noon",
    "Jul 5 today",
    "1 hour ago today",
    "today 1 hour ago",
    "14:13:20 today",
    "11:00 today",
    "noon today",
    "3pm today",
    "1999 today",
    "Jan 1 1970",
    "Jul 15 1970 noon",
    "Jan 1 1",
    "Jan 1 37",
    "Jan 1 38",
    "Jan 1 69",
    "Jan 1 1969",
    "Jan 1 2099",
    "Jan 1 2100",
    "Jan 5 3 days ago",
    "3 days ago Jan 5",
    "yesterday Jan 5",
    "Jan 5 yesterday",
    "Jan 5 today",
    "last Jan",
    "last 5",
    "last 3 days",
    "1",
    "5",
    "31",
    "32",
    "69",
    "70",
    "99",
    "1999",
    "2026",
    "2100",
    "5 6",
    "5 25",
    "25 5",
    "40 5",
    "5 6 2025",
    "Jan 5 6",

    // Numeric dates, and the guess between the day and the month.
    "01/02",
    "13/02",
    "10/05",
    "10/05/2026",
    "10/05/2027",
    "10/05/27",
    "10/01",
    "10/02",
    "09/22",
    "05.10",
    "05.10.2026",
    "05.10.2027",
    "11.12.2026",
    "12.30",
    "30.12",
    "1.13",
    "13.13",
    "1.5 days ago",
    "5/6/7",
    "01/02/26",
    "01/02/30",
    "01/02/37",
    "01/02/70",
    "01/02/99",
    "26-01-02",
    "70-01-02",
    "32-01-02",
    "001-01-02",
    "2026-13-01",
    "2026-01-32",
    "2026-02-31",
    "2027-10-30",

    // Timestamps.
    "179000000",
    "100000000",
    "99999999",
    "179000000 Jan",
    "Jan 179000000",

    // Found by feeding git random strings of these words and numbers.
    "1 now at",
    "12:00 at now one",
    "13/02 now Dec",
    "3 today sat",
    "2025 ten Jan 25",
    "1999 2026 junk one",
    "2026 month",
    "+0100 Jan month Oct",
    "1 tea years months",
    "31 three noon 32 tea",
    "monday 32 ten ago",
    "never 10/05 2",
    "tea years 3 +0100 last",
    "70 midnight today",
    "12:00 tea now 2025",
    "three one",
    "last midnight friday",
    "1 three",
    "one yesterday am pm",
    "05.10 15 now",
    "+0100 years 15 3",
    "2025 -0500 minutes",
    "-0500 month Mar",
    "32 now noon",
    "15 12:00 13 10/05",
    "3:30 10/05 Jan",
    "05.10 24:00 10/05 Oct",
    "05.10 am tea 1 2025",
    "10/05 EST hours",
    "0 15 at monday 10/05",
    "10/05 one 12:00",
    "05.10 13/02",
    "Dec -0500 tea now 02:30:00",
    "99 years 9 32 15:00",
    "5 years 3:30 sat",
    "3/4 three",
    "12:00 3/4 minutes Mar one",
    "seven and 7.4.26",
    "2025-02-29 1345 years 11 tuesday",
    "1345 years 11 tuesday",
    "2025-03-01 1 year 1 tuesday",
    "Jan 5 1 month last monday",
    "1:02:03.456 years 23:59:59",
    "+05:30 ten",
    "-12 Sept Mon",
    "+1345 month",
    "0500 month",
    "now month 30 never PM",
    "1/13, 1, never, Weeks, and",
    "9:05 pm 01/02/70 am",
    "tea now",
    "now tea",
    "tea 21",
    "tea 3pm",
    "tea Aug",
    "tea now 21",
    "now 5 Jan",
};

/// Questions for the strict parser.
const strict = [_][]const u8{
    "2026-01-15 12:00",
    "2026-01-15T12:00",
    "2026-01-15T12:00:00Z",
    "2026-01-15T12:00:00-05:00",
    "2026-01-15 12:00:00.5",
    "2026-01-15 12:00:60",
    "2026-01-15 12:00:61",
    "2026-01-15 24:00",
    "2026-01-32 12:00",
    "2026-02-30 12:00",
    "2026-13-01 12:00",
    "2026/01/15 12:00",
    "15.01.2026 12:00",
    "01.02.2026 12:00",
    "01-02-2026 12:00",
    "01/02/26 12:00",
    "26-01-15 12:00",
    "1969-12-31 12:00",
    "1970-01-01 00:00",
    "2099-12-31 12:00",
    "2100-01-01 12:00",
    "0001-01-01 12:00",
    "20260115T120000",
    "20260115 120000",
    "20260115T1200",
    "2026-01-15 120000",
    "2026-01-15 1200",
    "2026-01-15",
    "2026-03-08 02:30",
    "2026-03-29 02:30",
    "2026-10-25 02:30",
    "2026-11-01 01:30",
    "2026-04-05 02:30",
    "2026-10-04 02:30",
    "Mar 8 2026 2:30am",
    "Mar 8 2:30am",
    "Jan 15 12:00 2026",
    "12:00 Jan 15 2026",
    "Jan 15 2026 12:00 pm",
    "Jan 15 2026 1:00 pm",
    "Jan 15 2026 12:00 am",
    "Jan 15 2026 13:00 am",
    "Jan 15 2026 0:00 pm",
    "Jan 15 2026 pm 1:00",
    "10/02/2026 12:00",
    "10/05/2027 12:00",
    "05.10.2026 12:00",
    "01/02/27 12:00",
    "01/02/37 12:00",
    "01/02/38 12:00",
    "01/02/70 12:00",
    "01/02/71 12:00",
    "Jan 15 99 12:00",
    "Jan 15 70 12:00",
    "Jan 15 1 12:00",
    "Jan 15 2026 12:00 1999",
    "2026 2027 Jan 15 12:00",
    "179000000 Jan",
    "Jan 179000000",
    "179000000 12:00",
    "179000000 Jan 12:00 +0100",
    "Septe 15 2026 12:00",
    "Septemberx 15 2026 12:00",
    "2026-01-15 12:00 10.30",
    "2026-01-15 12:00 12:60",
    "1.13 2026-01-15 12:00",
    "01 02 70 12:00",
    "01/02 70 12:00",
    "Jan 2 70 12:00",
    "Jan 1 2026 12:00 1950",
    "Jan 1 2026 12:00 1900",
    "Jan 1 2026 12:00 01/02/1969",
    "Jan 1 2026 12:00 15/13/2000",
    "Jan 1 2026 12:00 2100-01-02",
    "Jan 1 2026 12:00 99-01-02",
    "Jan 1 2026 12:00 2025-13-13",
    "Jan 1 2026 12:00 2025-06",
    "2026-01-15 12:00 5-01",
    "Jan 15 2026 noon",
    "junk 2026-01-15 12:00 yesterday",
    "Thu Jan 15 12:00:00 2026",
    "Thu Jan 15 12:00:00 2026 -0500",
    "Thu, 15 Jan 2026 12:00:00 +0000",
    "15 Jan 2026 12:00 GMT",
    "15 Jan 2026 12:00 EST",
    "15 Jan 2026 12:00 cet",
    "15 Jan 2026 12:00 CES",
    "15 Jan 2026 12:00 IDL",
    "15 Jan 2026 12:00 NT",
    "15 Jan 2026 12:00 UT",
    "15 Jan 2026 12:00 -05",
    "15 Jan 2026 12:00 -5",
    "15 Jan 2026 12:00 +1430",
    "15 Jan 2026 12:00 +2359",
    "15 Jan 2026 12:00 +2400",
    "15 Jan 2026 12:00 +0099",
    "Jan 15 26 12:00",
    "1790000000",
    "1790000000 -0500",
    "1790000000 +0130",
    "@1790000000",
    "@1790000000 +0000",
    "@0 +0000",
    "@100",
    "123456789 +0000",
    "12345678 +0000",
    "4102444799 +0000",
    "4102444800 +0000",
    "yesterday",

    // Found by feeding git random strings of these words and numbers.
    "25:00 0:00 Feb",
    "NOON hours 0:00 2024 and Jan",
    "Jan 2026 12:00",
    "Feb 25 00 12:00",
    "Feb 25 01 12:00",
    "Feb 25 10 12:00",
    "14 00:30 2019 12",
    "2019 12 14 00:30",
    "12:00 2026-01-15 +0100 EST",
    "12:00 2026-01-15 EST +0100",
    "12:00 2026-01-15 EST CET",
    "2026-01-15 12:00 0500",
    "2026-01-15 12:00 0099",
    "2026-01-15 12:00 1399",
    "2026-01-15 12:00 1401",
    "120000 2026-01-15",
    "235960 2026-01-15",
    "pm T1200 2026-01-15",
    "am T1200 2026-01-15",
    "2026-01-15 t1200",
    "1790000000, @, Tuesday, Thu, 15 Jan 2026, T1200",
    "Jan 15 2026 24:00 pm",
    "Jan 15 2026 24:00 am",
};

/// Disagreements that are expected, and why. Each is matched on the
/// parser and the text, in every zone and at every time.
const known = [_]struct { parser: Parser, text: []const u8, why: []const u8 }{};

const Parser = enum { approximate, strict, failed };

const Oracle = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    repository: []const u8,
    /// The questions for each parser: the corpora above, or the lines of
    /// a file named on the command line.
    approximate: []const []const u8 = &approximate,
    strict: []const []const u8 = &strict,
    tzdir: []const u8,
    comparisons: usize = 0,
    known_seen: usize = 0,
    divergences: usize = 0,
    /// What stopped a task, if anything did.
    failure: ?anyerror = null,

    fn run(self: *Oracle, argv: []const []const u8, tz: []const u8, now: i64, extra: ?[2][]const u8) !std.process.RunResult {
        var env = try self.environ.clone(self.gpa);
        defer env.deinit();
        try env.put("TZ", tz);
        try env.put("TZDIR", self.tzdir);
        var now_text: [32]u8 = undefined;
        try env.put("GIT_TEST_DATE_NOW", try std.fmt.bufPrint(&now_text, "{d}", .{now}));
        try env.put("GIT_COMMITTER_NAME", "oracle");
        try env.put("GIT_COMMITTER_EMAIL", "oracle@example.invalid");
        if (extra) |pair| try env.put(pair[0], pair[1]);
        return std.process.run(self.gpa, self.io, .{
            .argv = argv,
            .cwd = .{ .path = self.repository },
            .environ_map = &env,
        });
    }

    fn report(self: *Oracle, parser: Parser, text: []const u8, tz: []const u8, now: i64, expected: []const u8, got: []const u8) void {
        for (known) |entry| {
            if (entry.parser == parser and std.mem.eql(u8, entry.text, text)) {
                self.known_seen += 1;
                return;
            }
        }
        self.divergences += 1;
        std.debug.print("{t:<11} TZ={s:<28} now={d} {s:<34} git={s} gitdate={s}\n", .{
            parser, tz, now, text, expected, got,
        });
    }

    fn zone(self: *Oracle, tz: []const u8) !TimeZone {
        return switch (tzdb.system.resolveTz(tz)) {
            .local, .utc => TimeZone.utc,
            .rule => |rule| TimeZone.fromRule(rule) catch TimeZone.utc,
            .path => |path| tzdb.system.loadLocal(self.io, self.gpa, path),
            .name => |name| tzdb.system.load(self.io, self.gpa, self.tzdir, name) catch
                TimeZone.fromRule(name) catch TimeZone.utc,
        };
    }

    fn checkApproximate(self: *Oracle, tz: []const u8, zone_value: *const TimeZone, now: i64) !void {
        // One process per question: within one, glibc's `mktime` starts
        // each conversion from the offset the last one found, so an
        // answer can depend on the questions asked before it.
        for (self.approximate) |text| {
            const arg = try std.fmt.allocPrint(self.gpa, "--since={s}", .{text});
            defer self.gpa.free(arg);
            const result = try self.run(&.{ "git", "rev-parse", arg }, tz, now, null);
            defer self.gpa.free(result.stdout);
            defer self.gpa.free(result.stderr);
            if (!result.term.success()) return error.GitFailed;

            // git prints the timestamp unsigned, so one before 1970
            // comes out as a very large number.
            const line = std.mem.trimEnd(u8, result.stdout, "\n");
            const unsigned = try std.fmt.parseInt(u64, std.mem.trimStart(u8, line, "--max-age="), 10);
            const expected: i64 = @bitCast(unsigned);

            const got = gitdate.approximate(text, .{ .now = now, .zone = zone_value });
            self.comparisons += 1;
            if (expected != got.timestamp) {
                var expected_text: [32]u8 = undefined;
                var got_text: [32]u8 = undefined;
                self.report(
                    .approximate,
                    text,
                    tz,
                    now,
                    try std.fmt.bufPrint(&expected_text, "{d}", .{expected}),
                    try std.fmt.bufPrint(&got_text, "{d}", .{got.timestamp}),
                );
            }
        }
    }

    fn checkStrict(self: *Oracle, tz: []const u8, zone_value: *const TimeZone, now: i64) !void {
        for (self.strict) |text| {
            const result = try self.run(&.{ "git", "var", "GIT_COMMITTER_IDENT" }, tz, now, .{ "GIT_COMMITTER_DATE", text });
            defer self.gpa.free(result.stdout);
            defer self.gpa.free(result.stderr);

            const expected = if (result.term.success()) blk: {
                // "oracle <oracle@example.invalid> 1790000000 +0130"
                const line = std.mem.trimEnd(u8, result.stdout, "\n");
                const close = std.mem.findScalarLast(u8, line, '>') orelse return error.BadIdent;
                break :blk std.mem.trim(u8, line[close + 1 ..], " ");
            } else if (std.mem.find(u8, result.stderr, "invalid date format") != null)
                "invalid"
            else
                return error.GitFailed;

            var got_text: [64]u8 = undefined;
            const got = if (gitdate.strict(text, zone_value)) |exact| blk: {
                const minutes = @divTrunc(exact.offset, 60);
                const magnitude: u32 = @abs(minutes);
                break :blk try std.fmt.bufPrint(&got_text, "{d} {c}{d:0>2}{d:0>2}", .{
                    exact.timestamp,
                    @as(u8, if (minutes < 0) '-' else '+'),
                    magnitude / 60,
                    magnitude % 60,
                });
            } else |_| "invalid";

            self.comparisons += 1;
            if (!std.mem.eql(u8, expected, got)) self.report(.strict, text, tz, now, expected, got);
        }
    }

    fn checkFailed(self: *Oracle, now: i64) !void {
        const zone_value = TimeZone.utc;
        for (self.approximate) |text| {
            // Digits alone are a reflog index, and a leading `-` is
            // `@{-N}`, the branch checked out N switches ago.
            if (std.mem.indexOfNone(u8, text, "0123456789") == null) continue;
            if (text[0] == '-') continue;
            const ref = try std.fmt.allocPrint(self.gpa, "HEAD@{{{s}}}", .{text});
            defer self.gpa.free(ref);
            const result = try self.run(&.{ "git", "rev-parse", ref }, "UTC", now, null);
            defer self.gpa.free(result.stdout);
            defer self.gpa.free(result.stderr);

            const expected = std.mem.find(u8, result.stderr, "unknown revision") != null;
            const got = gitdate.approximate(text, .{ .now = now, .zone = &zone_value }).failed;
            self.comparisons += 1;
            if (expected != got) self.report(.failed, text, "UTC", now, if (expected) "failed" else "ok", if (got) "failed" else "ok");
        }
    }
};

/// Asks every question in one zone at every time, on a copy of the
/// oracle that keeps its own count.
fn checkZone(oracle: *Oracle, tz: []const u8) void {
    var zone_value = oracle.zone(tz) catch |err| {
        oracle.failure = err;
        return;
    };
    defer zone_value.deinit(oracle.gpa);
    for (nows) |now| {
        oracle.checkApproximate(tz, &zone_value, now) catch |err| {
            oracle.failure = err;
            return;
        };
        oracle.checkStrict(tz, &zone_value, now) catch |err| {
            oracle.failure = err;
            return;
        };
    }
}

/// Asks whether each text fails, at every time.
fn checkAllFailed(oracle: *Oracle) void {
    for (nows) |now| oracle.checkFailed(now) catch |err| {
        oracle.failure = err;
        return;
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const repository = args.next() orelse return error.MissingRepository;

    const tzdir = init.environ_map.get("TZDIR") orelse "/usr/share/zoneinfo";

    // A file of further questions, one to a line, asked of both parsers
    // in place of the corpora: for exploring, rather than for the build.
    var extra: std.ArrayList([]const u8) = .empty;
    defer extra.deinit(gpa);
    var extra_bytes: []u8 = &.{};
    defer gpa.free(extra_bytes);
    if (args.next()) |path| {
        extra_bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24));
        var lines = std.mem.splitScalar(u8, extra_bytes, '\n');
        while (lines.next()) |line| if (line.len > 0) try extra.append(gpa, line);
    }

    var oracle: Oracle = .{
        .gpa = gpa,
        .io = io,
        .environ = init.environ_map,
        .repository = repository,
        .tzdir = tzdir,
    };
    if (extra.items.len > 0) {
        oracle.approximate = extra.items;
        oracle.strict = extra.items;
    }

    // A repository with one commit, for `HEAD@{...}` to look in.
    for ([_][]const []const u8{
        &.{ "git", "init", "-q", "." },
        &.{ "git", "-c", "user.name=oracle", "-c", "user.email=oracle@example.invalid", "commit", "-q", "--allow-empty", "-m", "oracle" },
    }) |argv| {
        const result = try oracle.run(argv, "UTC", nows[0], .{ "GIT_AUTHOR_DATE", "1700000000 +0000" });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!result.term.success()) {
            std.debug.print("{s}", .{result.stderr});
            return error.GitFailed;
        }
    }

    const version = try oracle.run(&.{ "git", "--version" }, "UTC", nows[0], null);
    defer gpa.free(version.stdout);
    defer gpa.free(version.stderr);

    // Each zone is checked on a task of its own, since nearly all the
    // time goes in waiting for git, one process at a time.
    var tallies: [zones.len + 1]Oracle = @splat(oracle);
    var group: Io.Group = .init;
    for (zones, tallies[0..zones.len]) |tz, *tally| {
        group.concurrent(io, checkZone, .{ tally, tz }) catch checkZone(tally, tz);
    }
    group.concurrent(io, checkAllFailed, .{&tallies[zones.len]}) catch checkAllFailed(&tallies[zones.len]);
    try group.await(io);

    for (tallies) |tally| {
        if (tally.failure) |err| return err;
        oracle.comparisons += tally.comparisons;
        oracle.known_seen += tally.known_seen;
        oracle.divergences += tally.divergences;
    }

    std.debug.print("oracle: {d} comparisons against {s}", .{ oracle.comparisons, version.stdout });
    if (known.len > 0) {
        std.debug.print("oracle: {d} known and documented:\n", .{oracle.known_seen});
        for (known) |entry| std.debug.print("    {t} \"{s}\": {s}\n", .{ entry.parser, entry.text, entry.why });
    }
    if (oracle.divergences > 0) {
        std.debug.print("oracle: {d} divergences\n", .{oracle.divergences});
        std.process.exit(1);
    }
    std.debug.print("oracle: no divergence{s}\n", .{if (known.len > 0) " beyond those" else ""});
}
