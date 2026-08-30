# zig-datetime

Dates, times, and timezones for Zig 0.16.

## Adding it to a project

```sh
zig fetch --save git+https://github.com/jeffollie/zig-datetime
```

```zig
const datetime = b.dependency("datetime", .{
    .target = target,
    .optimize = optimize,
});
your_module.addImport("datetime", datetime.module("datetime"));
```

## Timezones

A `TimeZone` says what a clock in some place reads at a given instant. The
rules come from the IANA timezone database, which this library reads in its
compiled form, TZif (RFC 8536). There are two places to get that data from:
the copy the operating system already has, or a copy compiled into your
binary.

### Using the system's copy

This is the usual choice on Linux, macOS, and the BSDs. It needs no build
options, stays current when the system updates its data, and adds nothing
to your binary.

Two environment variables decide where the data is and which zone the user
wants: **`TZDIR`** names the directory holding the TZif tree, and **`TZ`**
names the zone.

**This library does not read either of them for you.** In Zig 0.16 a
program receives its environment through the `std.process.Init` passed to
`main`, so a library that went looking for it would have to reach for
globals behind your back. Instead you read the environment and pass the
answer in, which also means tests and sandboxes can point the library
somewhere else without touching the real one.

The short version, when you know which zone you want:

```zig
const std = @import("std");
const datetime = @import("datetime");

pub fn main(init: std.process.Init) !void {
    // TZDIR names the directory; fall back to the usual location.
    const directory = init.environ_map.get("TZDIR") orelse
        datetime.tzdb.system.default_directory;

    var zone = try datetime.tzdb.system.load(
        init.io,
        init.gpa,
        directory,
        "America/Chicago",
    );
    defer zone.deinit(init.gpa);

    // 2024-07-15 12:00 UTC, in Chicago.
    const local = zone.atTimestamp(1721044800);
    std.debug.print("{d}:{d:0>2} {s}\n", .{
        local.hour,
        local.minute,
        zone.typeAt(1721044800).designation,
    }); // 7:00 CDT
}
```

`default_directory` is `/usr/share/zoneinfo`, which is right on most
systems but not all: NixOS uses `/etc/zoneinfo`, and some older Unixes use
`/usr/lib/zoneinfo` or `/usr/share/lib/zoneinfo`. If you want to work
everywhere without requiring `TZDIR` to be set, try each in turn —
`tzdb.system.search_directories` lists them in a sensible order:

```zig
fn openZone(io: std.Io, gpa: std.mem.Allocator, environ: *std.process.Environ.Map, name: []const u8) !datetime.TimeZone {
    if (environ.get("TZDIR")) |dir| {
        return datetime.tzdb.system.load(io, gpa, dir, name);
    }
    for (datetime.tzdb.system.search_directories) |dir| {
        return datetime.tzdb.system.load(io, gpa, dir, name) catch continue;
    }
    return error.NoTimezoneDatabase;
}
```

### Honouring the user's `TZ`

`TZ` is not simply a zone name. It may be an absolute path to a TZif file,
or a complete POSIX rule that names no file at all, and by long convention
a leading colon introduces a name or a path.
`tzdb.system.resolveTz` sorts those cases apart without touching the
filesystem:

```zig
const zone = switch (datetime.tzdb.system.resolveTz(init.environ_map.get("TZ"))) {
    // TZ unset: the machine's own zone, which /etc/localtime is a copy of.
    .local => try datetime.tzdb.system.loadLocal(init.io, init.gpa, null),

    // TZ=/etc/localtime, or TZ=:/usr/share/zoneinfo/America/Chicago
    .path => |path| try datetime.tzdb.system.loadLocal(init.io, init.gpa, path),

    // TZ=America/Chicago, TZ=:America/Chicago, TZ=Etc/GMT+5
    .name => |name| datetime.tzdb.system.load(init.io, init.gpa, directory, name) catch |err| switch (err) {
        // Not a zone after all, so it must have been a rule. See below.
        error.FileNotFound => return parseAsRule(name),
        else => return err,
    },

    // TZ=CST6CDT,M3.2.0,M11.1.0 — a rule, with no file behind it.
    .rule => |rule| return parseAsRule(rule),

    // TZ="" is UTC.
    .utc => ...,
};
```

That `.name` case really does need the fallback, because a rule and a zone
name cannot always be told apart by looking at them. `EST5EDT`, `MST7MDT`,
`GMT0` and every `Etc/GMT+5` are real zone names *and* well-formed POSIX
rules meaning roughly the same thing. Guessing from the shape of the text
gets all forty of them wrong, so `resolveTz` assumes a name and lets the
filesystem settle it — the same thing glibc and musl do. Only a value
containing a comma, or starting with `<`, is reported as a definite
`.rule`, since no zone name contains either.

Zone names taken from `TZ` are attacker-controlled in some deployments, so
`load` validates them before joining them onto the directory. A name like
`../../etc/passwd` is refused rather than opened.

### Embedding the database instead

If you would rather not depend on the host having timezone data — a
scratch container, a cross-compiled binary, Windows — build with
`-Dembed-tzdata` and the database goes into the binary:

```sh
zig build -Dembed-tzdata
```

```zig
// No allocator and no filesystem: the data is already in the binary and
// the zone borrows it.
var zone = (try datetime.tzdb.embedded.load("America/Chicago")).?;
```

This fetches the IANA sources and builds `zic`, the reference compiler,
from the C sources IANA publishes alongside the data, using the C compiler
Zig already ships. Nothing needs to exist on the host: no `zic`, no
timezone data, no C toolchain. The output is byte-for-byte what the
reference implementation produces.

| Option | Default | Effect |
| --- | --- | --- |
| `-Dembed-tzdata` | off | Compile the database into the binary |
| `-Dtzdata-packing=slim\|fat` | `slim` | `slim` leans on each zone's POSIX rule for repeating years (~347 KB); `fat` writes every transition out (~702 KB) |
| `-Dtzdata-from=@0` | keep all | Drop transitions before this point; `@0` keeps 1970 onwards (~255 KB) |

Without `-Dembed-tzdata` nothing is fetched and no C is compiled, so an
ordinary build stays fast and offline. `tzdb.embedded.available` tells you
at comptime whether a build has data.

### Local times that are ambiguous or do not exist

Converting an instant to a wall clock reading always works. Going the
other way does not: when clocks spring forward a range of readings never
happens, and when they fall back a range happens twice. `resolve` reports
which case you are in rather than quietly picking one:

```zig
// 02:30 on the day the clocks went forward — a reading that never happened.
switch (zone.resolve(.{ .year = 2024, .month = .Mar, .day = 10, .hour = 2, .minute = 30 })) {
    .unique => |at| ...,
    .gap => |gap| ...,        // gap.before, gap.after, gap.at
    .ambiguous => |both| ..., // both.earlier, both.later
}
```

`resolved.earliest()` and `resolved.latest()` pick a side when you do not
care which.

## Formatting and parsing

Format strings are sequences of tags in the style of moment.js, checked at
compile time:

```zig
const text = try instant.asDateTime().formatAlloc(gpa, "YYYY-MM-DDTHH:mm:ssZ");
const parsed = try datetime.DateTime.parse("YYYY-MM-DD HH:mm:ss", "2024-07-15 07:00:00");
```

Two interchange formats have their own parsers, because the shape of
their input is not known ahead of reading it and a format string cannot
express that.

**RFC 822**, as used by email, HTTP, and RSS:

```zig
const result = try datetime.rfc822.parse("Fri, 21 Nov 1997 09:55:06 -0600");
const utc = result.value.toUtc();
```

**ISO 8601**, including the RFC 3339 subset that most internet protocols
mean when they say ISO 8601:

```zig
const result = try datetime.iso8601.parse("2024-03-15T14:30:00.5+05:30");
```

It reads all three date forms, in the extended spelling with separators
and the basic one without, at whatever precision the input stops at:

| | extended | basic |
| --- | --- | --- |
| calendar | `2024-03-15`, `2024-03`, `2024` | `20240315` |
| ordinal | `2024-075` | `2024075` |
| week | `2024-W11-5`, `2024-W11` | `2024W115` |

Times may stop at the hour, minute, or second, and any of those may carry
a decimal fraction with either separator, so `T14.5` is half past two.
`24:00` is the end of its date and comes back as midnight on the next
one. Zones are `Z`, `±hh`, `±hh:mm`, or `±hhmm`.

Two fields on the result carry what the string itself said. `has_offset`
distinguishes a local time that named no zone from one that ended in `Z`,
which `offset` alone cannot: both leave it zero. `precision` says which
component the input stopped at, so a caller can tell `2024-03` from
`2024-03-01`.

ISO 8601 forbids mixing the basic and extended forms, and so does this:
`2024-03-15T143000` is `error.MixedFormats`. The zone is the one
deliberate exception, since `+0530` after an extended time is common in
real data. Expanded years such as `+002024`, which ISO 8601 permits only
by prior agreement, are not accepted, and neither are intervals or
durations.

## A note on offsets

`DateTime.offset` is in **seconds** east of UTC, not minutes. Historical
offsets are not whole minutes: America/Chicago's local mean time, which
applies to any timestamp before 1883, is `-5:50:36`.

## Testing

```sh
zig build test                  # system data only; embedded tests skip
zig build test -Dembed-tzdata   # everything, including embedded-vs-system agreement
```
