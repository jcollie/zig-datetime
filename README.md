<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-datetime

Dates, times, and timezones for Zig 0.16.

API documentation: <https://jeff.ocj.page/zig-datetime/>, published from
main by `.forgejo/workflows/test.yaml`.

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
scratch container, a cross-compiled binary — or if you are targeting
Windows, which has none of the kind this reads, build with
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

### Windows

Windows has no zoneinfo tree. It keeps its own zone data in the registry,
under its own names — `Central Standard Time` rather than
`America/Chicago` — in its own format, with none of the history IANA
carries. So `tzdb.system` cannot work there at all, and says so:
`tzdb.system.available` is false, `search_directories` is empty, and
`load` and `loadLocal` fail with `error.NoSystemDatabase` rather than
opening a Unix path that was never going to exist.

What does work is `tzdb.windows`, which asks Windows which zone the
machine is set to and translates the name:

```zig
// Needs -Dembed-tzdata: the name comes from Windows, the data does not.
var zone = try datetime.tzdb.windows.loadLocal();
```

That is three steps, and each is available on its own.
`windows.localKeyName` calls `GetDynamicTimeZoneInformation` and returns
its `TimeZoneKeyName`, which is the registry key the setting came from and
is the same string in every locale, unlike the display names beside it.
`windows.ianaName` looks that up in CLDR's table — the only published
correspondence between the two sets of names — and is a plain table lookup
that works on any target. `tzdb.embedded.load` then supplies the data,
which is why `-Dembed-tzdata` is not optional here.

A Windows zone usually covers several IANA ones: `Central Standard Time`
is Chicago in the United States, Winnipeg in Canada and Mexico City in
Mexico. The table takes CLDR's world-wide default, the answer that does
not need to know where the machine is, which is the same choice ICU makes
for a bare Windows name.

The registry is never read. Windows' own zone data would be a second
binary format to parse, for less history than the copy already in the
binary, and the two would disagree about the past.

Code written to work on both looks like this:

```zig
var zone = if (datetime.tzdb.system.available)
    try datetime.tzdb.system.loadLocal(io, gpa, null)
else
    try datetime.tzdb.windows.loadLocal();
```

The Win32 call comes from [zigwin32], fetched lazily and only when the
target is Windows, so builds for anything else neither fetch nor compile
it. The name table is checked into the tree as `src/windowszones.zig`
rather than fetched, so the Windows path costs no network and no second
dependency; `zig build windowszones -Dwindowszones-xml=…` regenerates it
when CLDR publishes a new release.

The Windows path is not left to be right by inspection: CI cross-compiles
the test suite to Windows and runs it under Wine, which is where
`localKeyName` actually calls into Win32 and the name it returns is
actually looked up. To do the same locally:

```sh
nix develop .#windows -c zig build test \
    -Dtarget=x86_64-windows -Dembed-tzdata -fwine
```

[zigwin32]: https://github.com/marlersoft/zigwin32

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

Format strings are sequences of tags taken from moment.js, tokenized at
compile time:

```zig
const text = try instant.asDateTime().formatAlloc(gpa, "YYYY-MM-DDTHH:mm:ssZ");
const parsed = try datetime.DateTime.parse("YYYY-MM-DD HH:mm:ss", "2024-07-15 07:00:00");
```

Anything that is not a sequence is copied through, so `YYYY/MM/DD` means
what it looks like. Square brackets make a literal of text that would
otherwise be read as sequences, and a backslash does the same for whatever
follows it: `GGGG-[W]WW-E` writes an ISO week date.

Parsing has moment's two modes. `parse` is the lenient one and `parseWith`
takes both the mode and the reference the unnamed fields come from:

```zig
// Lenient: a padded sequence takes one digit as well as two, a name
// sequence takes any of its lengths, and trailing text is left alone.
const loose = try datetime.DateTime.parse("MMM D YYYY", "March 5 2024 (approx)");

// Strict: exact widths, and the whole input has to be used.
const tight = try datetime.DateTime.parseStrict("MMM D YYYY", "Mar 05 2024");

const relative = try datetime.DateTime.parseWith("MMM D", "Mar 15", .{
    .relative_to = base,
    .mode = .strict,
});
```

`ParseResult.str` is the prefix that was consumed, so a caller can carry
on from `value[str.len..]`; `skipped` says how much inside it was stepped
over rather than read, which only lenient parsing does.

### Compatibility with moment.js

The vocabulary is moment's, and that is checked rather than claimed.
`zig build oracle` runs moment itself over the same corpus and diffs every
answer: every sequence on its own, the shapes callers actually write,
escaping and its corners, and a day-by-day sweep from 2015 to 2032 read at
five offsets including a quarter-hour one.

```
796200 comparisons against moment 2.30.1, no divergence
```

`zig build oracle-parse` does the same for parsing, in both modes, holding
each to the matching mode of moment. moment is pinned in `build.zig.zon`
and fetched lazily, the way tzcode and tzdata are, because it is the
specification being tested against and a floating version would move the
target. Both run as part of `zig build test`.

Following moment means following it where it is surprising. Leniently a
sequence is searched for rather than required where it stands, so
`2024/03/15` reads against `YYYY-MM-DD` and `14` against `HH:mm` is two
o'clock; `w` is the week starting Sunday that holds January 1st while `W`
is the ISO week, and each has its own week-numbering year in `gg` and
`GG`; `YY` of `70` is 1970 and of `68` is 2068; `Hmm` is one sequence and
not an hour beside a minute; and `YYY` is `YY` followed by `Y`.

Two places it does not follow moment, both deliberate:

- **Fractional seconds keep their precision.** moment holds milliseconds
  and pads `SSSS` onwards with zeros. This holds nanoseconds and prints
  them, so `SSSS` of `.123456789` is `1234` rather than `1230`. For any
  input moment can represent the two agree; beyond that the library is
  not going to lie about a value it has.

- **`z` and `zz` are constant**, `UTC` and `Coordinated Universal Time`,
  whatever the offset. That is moment's own behaviour rather than a gap:
  it has no zone names at all, and real abbreviations come from
  moment-timezone, a separate package. The real one is on the value
  instead, put there by the zone that knows it:

  ```zig
  const local = zone.atTimestamp(1720000000);
  std.debug.print("{s}\n", .{local.designation.slice()});   // CDT
  ```

  It is six bytes stored in the `DateTime` rather than a slice into the
  zone, so the reading does not depend on the zone outliving it. Empty
  means not known, which is what a parsed date or `Instant.asDateTime`
  gives you: neither has a zone to ask.

The locale is `en`, which is moment's default and the only one here, so
the localized sequences `L`, `LL`, `LT` and the rest expand to their
English forms.

### Go's time layouts

`golayout` is the other way of saying it, taken from Go, where the format
string is one particular time written the way you want yours written:

```zig
const text = try std.fmt.allocPrint(...);  // or straight to a writer
try datetime.golayout.format(value, "2006-01-02T15:04:05Z07:00", writer);

const value = try datetime.golayout.parse("Jan _2 3:04PM", "Mar 15 2:30PM");
```

Go picked `Mon Jan 2 15:04:05 MST 2006` as that time, so that every
component has a different number: month 1, day 2, hour 3 on the twelve
hour clock and 15 on the twenty-four hour one, minute 4, second 5, year 6,
and a zone seven hours west. Nothing is a code to look up; the layout is
an example. The layouts Go's own package names are here under the names it
gives them, so `golayout.layout.rfc3339` and `golayout.layout.kitchen`
mean what they do there.

Go's behaviour is the specification and `zig build oracle-go` checks it
against Go's own `time` package, formatting and parsing both. That
includes following Go where it is unhelpful: `2006` writes a year before
the common era with a leading minus and then will not read one back, and
`MST` writes a numeric offset when a reading has no zone name and then
will not read that back either, because Go takes the digits after a sign
as one number of hours and `+0545` is not a count of hours. Both are
Go's, and a layout that means one thing there should not mean another
here.

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

## Keeping tzdata current

The IANA database is re-cut several times a year, usually because a
country has changed its rules at short notice, so the pin in
`build.zig.zon` goes stale on its own schedule rather than yours.

`tools/update-tzdata.sh` moves it. With no argument it takes the newest
release IANA publishes; pass a version to pin a particular one:

```sh
tools/update-tzdata.sh          # newest published
tools/update-tzdata.sh 2026c    # a specific release
```

The version lives in three places that have to agree — both dependency
hashes in `build.zig.zon` and the `tz_release` constant in `build.zig`,
which the generated data records as its own version — so the script
rewrites all three together and verifies afterwards that no reference to
the old release survived. It refuses to move backwards, and checks that
both tarballs are actually published before touching anything, since
IANA's version endpoint has been known to move first.

`.forgejo/workflows/tzdata.yml` runs that daily. When a new release
appears it rebuilds `zic` from the new sources, regenerates the embedded
database, runs the suite against it, and only then opens a pull request.

Each release gets its own branch, `tzdata-update-<version>`. If that
branch already exists the release has been dealt with and the run stops
before building anything, so a pull request left open for review is never
disturbed. When a newer release turns up it arrives as its own branch and
its own pull request, and the earlier one is closed as superseded with a
comment pointing at its replacement. Nothing is force-pushed and no
branch is reused, so a review stays attached to the release it was
written about. Superseded branches are left in place as a record; only
their pull requests are closed.

See the comments at the top of the workflow for the runner and token it
needs.

## Testing

```sh
zig build test                     # system data only; embedded tests skip
zig build test -Dembed-tzdata      # everything, including embedded-vs-system agreement
zig build test -Dno-system-tzdata  # as though the machine had no database
zig build oracle                   # formatting against moment.js
zig build oracle-parse             # parsing against moment.js, in both modes
zig build oracle-go                # Go's time layouts against Go itself
zig build bench                    # always ReleaseFast, whatever -Doptimize says
```

All three oracles are part of `zig build test`, so an ordinary run needs
`node` and `go`, and fetches moment the first time. moment is pinned in
`build.zig.zon`; Go is not, because the layouts are part of its standard
library rather than something to fetch, and the oracle prints the version
it ran against.

`src/fuzz.zig` holds a property per parser: nothing crashes on input
nobody chose, whatever comes back holds together, and anything with an
inverse survives the round trip. Each runs twice over, against a list of
seeds and against inputs built by mutating them, so an ordinary test run
does a small amount of fuzzing and `-Dfuzz-iterations=N` does as much as
you like:

```sh
zig build test -Dfuzz-iterations=500000 --seed 42
```

The seed is the test runner's, so a failure replays exactly. There are
`std.testing.fuzz` targets beside the mutation ones for when
`zig build --fuzz` works: on Zig 0.16.0 it does not compile, on any
project, in the compiler's own test runner.

`-Dno-system-tzdata` empties the directories the tests look in, which
makes a machine that has a timezone database behave like one that has
not. The tests that read it skip either way; the option is what makes the
skipped half reachable from either kind of machine, and it is a testing
knob rather than a build variant — the library behaves the same with and
without it.

## Reading the docs locally

```sh
zig build docs-serve            # http://127.0.0.1:8000, -Ddocs-port=N to change
```

A server rather than opening `zig-out/docs/index.html`, because the
viewer fetches `sources.tar` and `main.wasm` at runtime and a browser
refuses those from a `file://` page.
