<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-datetime

Dates, times, and timezones for Zig 0.16.

API documentation: <https://jeff.jcollie.page/zig-datetime/>, published from
main by `.forgejo/workflows/test.yaml`.

## Where this lives

The repository is hosted on Forgejo, which is where the issues, the
continuous integration and the published documentation are:

```sh
git clone https://git.jcollie.dev/jeff/zig-datetime.git
```

It is mirrored to GitHub, and that is the copy Zig fetches from, since a
`zig fetch` URL is read by whoever depends on this and GitHub is the more
reachable of the two:

```sh
git clone https://github.com/jcollie/zig-datetime.git
```

It is mirrored on Tangled at <https://tangled.org/jcollie.dev/zig-datetime>,
a forge built on the AT Protocol, where the repository is addressed by its
owner's identity rather than by a server name.

It is also published on [Radicle][radicle], a peer-to-peer code forge that
needs no account on anything. A Radicle repository is findable only by its
repository ID, so this is that ID:

```sh
rad clone rad:zrcUiTVhYvJSzwRyCBNmfM9oHkSo
```

`rad clone` finds seeds through your local node's routing table, so the node
has to be running first, and cloning seeds the repository in turn, which helps
keep it available:

```sh
rad node start
```

If you already have the repository and only want to help host it:

```sh
rad seed rad:zrcUiTVhYvJSzwRyCBNmfM9oHkSo
```

The Radicle copy is public, named `zig-datetime`, and its default branch is
`main` — the same name and branch as the others, so any of the four gives the
same history.

[radicle]: https://radicle.xyz

## Adding it to a project

```sh
zig fetch --save git+https://github.com/jcollie/zig-datetime
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
| `-Dembed-locales` | off | Compile moment.js's 137 locales into the library; see [Locales](#locales) |

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

There are four vocabularies a format string can be written in. The
moment.js sequences below are the general case; `golayout`, `cldr` and
`strftime` are the same job said the way Go, the Unicode Consortium and
the C library say it, and each has a section of its own further down.

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

### Locales

The default locale is `en`, and every entry point that does not take one
uses it, so nothing changes for a caller that never asks. To ask, pass one:

```zig
var zone_locale = datetime.locale.byName(header) orelse .en;

try dt.formatWith("dddd D MMMM YYYY", zone_locale, writer);   // mardi 5 mars 2024
const parsed = try datetime.DateTime.parseWith("dddd D MMMM YYYY", text, .{
    .locale = zone_locale,
});
```

A locale is runtime data rather than a comptime parameter. The format
string stays comptime, because it decides which code runs; the locale only
decides which bytes come out, so one can come from a request header or a
configuration file without a switch over everything you might have
compiled in.

It carries more than names. `Do` writes `1er` in French and `1.` in
German; `A` is `午後` in Japanese; `w` counts from Sunday with January 1st
in week one for `en` and by the ISO rule for most of Europe, and `e`
numbers the weekday from whichever day the week starts on, where `d` is
always Sunday-based and `E` always ISO. And the `L` family really is
localized — the same sequence is a different date order:

```zig
try dt.formatWith("L", .en, writer);      // 03/05/2024
try dt.formatWith("L", french, writer);   // 05/03/2024
```

That is the one piece a locale changes at run time rather than renames: it
stands for a whole format string, so the tokenizer runs over the locale's
expansion. Everything else is the comptime-unrolled walk it always was.

`-Dembed-locales` compiles in moment's other hundred and thirty-six, and
`locale.byName` finds one by tag. Without it there is only `en`, and
nothing is fetched:

```sh
zig build -Dembed-locales
```

The data is moment's own, read out of its locale files by
`upstream/src/gen_locales.js` — a locale transcribed by hand would be a
divergence built in at the source. The table it writes,
`src/locales/all.zig`, is committed, so `-Dembed-locales` compiles a file
that is already here and fetches nothing; `zig build gen-locales`
regenerates it when moment makes a release. The two pieces moment holds as functions rather than data, the
meridiem and the ordinal, are enumerated rather than reimplemented: their
domains are finite, so what comes out is a table that answers the same
questions.

You can also write one by hand; `Locale` is a plain struct, and only the
names and the `L` strings have no default.

#### Compatibility, checked

`zig build oracle-locale` formats a corpus in every embedded locale and
diffs it against moment in the same locale:

```
97818 comparisons across the locales of moment 2.30.1
10067 known and documented
no divergence beyond those
```

The documented ones are three, and each is a limit rather than a bug:

- **Twenty-three locales rewrite the digits after formatting**, and some
  the separators too — moment calls it `postformat`, and Arabic, Hindi and
  Bengali among others use it. This library writes ASCII digits. The
  oracle proves the difference is confined to that by running moment's own
  `postformat` over this library's answer and requiring the result to
  match exactly, so every name, meridiem and ordinal still has to agree.

- **moment writes `NaN` for the fortieth ordinal in Azerbaijani, Turkmen
  and Turkish**, where its suffix table has no entry. This library writes
  the number. Reproducing a NaN is not parity with anything.

- **Ukrainian declines the weekday name after a preposition**, which
  moment selects with a pattern looking for bracketed text before the
  sequence. The tokenizer here does not record whether a literal came from
  brackets, so the standalone form is written.

Beyond the oracle, every embedded locale is written and read back in a
test, so a name that cannot be parsed in the language it was written in is
a failure rather than something nobody tried.

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

### CLDR patterns

`cldr` is the third way of saying it, and the one the rest of the world
is speaking: the pattern vocabulary the Unicode Consortium defines in
[UTS #35](https://unicode.org/reports/tr35/tr35-dates.html), which ICU,
Java, .NET and every `Intl.DateTimeFormat` in a browser use underneath.

```zig
try datetime.cldr.format(value, "yyyy-MM-dd'T'HH:mm:ssXXX", .en, writer);
try datetime.cldr.format(value, "EEEE, d MMMM y", french, writer);
```

The letter says which field and how many of it says how that field is
written, so `M` is the month as a number, `MMM` abbreviates it, `MMMM`
spells it out and `MMMMM` reduces it to a letter. Text inside single
quotes is copied through, which is how a letter is written as itself, and
`''` is one apostrophe. Every ASCII letter is reserved whether or not it
names a field, so `hello` is a compile error rather than four fields and
an `o`; quote it.

Where it goes beyond the other two is that the locale carries its own
patterns. A caller that does not want to decide how a date is written
asks for a length instead:

```zig
try datetime.cldr.formatDateTime(value, .medium, .short, locale, writer);
```

which is `Mar 5, 2024, 2:30 PM` in English, `5 mars 2024, 14:30` in
French and `2024/03/05 14:30` in Japanese, because the arrangement is
data rather than something this library decided. `formatDate` and
`formatTime` ask for one half.

There are two entry points because CLDR patterns arrive both ways.
`format` takes the pattern at comptime, tokenizes it while the program is
compiled, and refuses one that is not a pattern with a compile error;
`formatRuntime` takes one that was not known until the program ran, which
is what the locale's own patterns are. Both walk the same field writer.

#### Locales

`-Dembed-cldr` compiles in CLDR's own seven hundred and sixty-six
locales, and `cldr.byName` finds one by tag. Without it there is only
`en`, and nothing is fetched:

```sh
zig build -Dembed-cldr
zig build -Dembed-cldr -Dcldr-locales=fr,de,ja   # or only the ones you want
```

A tag CLDR does not ship is retried with its last subtag dropped, so an
`Accept-Language` header works: `en-US` answers with `en`. That is not a
formality — CLDR ships no `pt-BR`, because Brazilian Portuguese is the
default content of `pt`.

The data is the Unicode Consortium's own, read out of its JSON
distribution by `upstream/src/gen_cldr.js`. The table it writes,
`src/cldrlocales/all.zig`, is committed and holds every locale CLDR ships,
so `-Dembed-cldr` compiles a file that is already here and fetches nothing,
and `-Dcldr-locales` narrows what that build compiles rather than what was
generated — an entry no locale is built from costs a binary nothing.
`zig build gen-cldr` regenerates the table when CLDR makes a release. It carries
what CLDR has and moment has no notion of: era names, quarter names, the
narrow width, the difference between the name inside a date and the name
standing alone, the flexible day periods that make `B` write "in the
morning", and the ten digits a locale writes its numbers with — a Bengali
date really is written in Bengali digits, rather than in ASCII ones
rewritten afterwards.

#### Compatibility, checked

ICU is the reference implementation of UTS #35, and `zig build
oracle-cldr` diffs against it: every field at every count, the shapes
callers write, the corners of the quoting, and then every embedded locale
against the patterns a locale can differ about, at seven instants and
three offsets each.

```
889650 comparisons against ICU 78.3
124 locales CLDR ships and ICU 78.3 does not, unchecked
105 known and documented
no divergence beyond those
```

The oracle gives ICU a zone that is nothing but an offset, because that
is what a `DateTime` is, and a Gregorian calendar whose changeover has
been pushed before every date there is, because ICU's is Julian before
1582 and this library's is proleptic Gregorian throughout.

Four things are deliberately not ICU's behaviour, and each is a limit
rather than a bug:

- **`V`, `VV` and `VVV` are refused**, along with the skeleton-only `j`,
  `J` and `C`. The first three name a zone — its short identifier, its
  long one, the city it is kept by — and a `DateTime` carries an offset
  rather than a zone; ICU, given a zone that is nothing but an offset,
  answers `unk` and `Unknown Location`. The last three ask for whichever
  clock the locale prefers and are resolved before formatting begins;
  ICU writes nothing for them. A field that silently vanishes is worse
  than one that will not compile. `VVVV` is allowed, because its
  fallback is something an offset can truthfully say.

- **A count a field has no meaning for is refused** rather than falling
  back. ICU writes `MMMMMM` as a six digit month number and `OO` as
  nothing at all.

- **Fractional seconds keep their precision.** ICU holds milliseconds and
  pads `SSSS` onwards with zeros; this holds nanoseconds and writes them.
  For any value ICU can represent the two agree, which is why the
  oracle's corpus stops at the millisecond. The same choice, for the same
  reason, as the moment sequences make.

- **Two locales are excused**, and the oracle counts them. Hawaiian
  writes the month of its short date in lowercase Roman numerals, which
  CLDR expresses by hanging a numbering system on one field of a pattern;
  a numbering system here is ten digits and `romanlow` is an algorithm.
  French as written in Mali has a joining pattern that CLDR's JSON and
  ICU inherit differently, and they disagree about a comma.

Beyond that, `z` and its neighbours take UTS #35's documented fallback:
given no zone to name, the localized GMT format, so `z` is `GMT-5` and
`zzzz` is `GMT-05:00`, in the locale's own spelling and digits. The
abbreviation a zone did supply is on the value instead, put there by the
zone that knew it:

```zig
const local = zone.atTimestamp(1720000000);
std.debug.print("{s}\n", .{local.designation.slice()});   // CDT
```

CLDR patterns are formatting only. Parsing them is a separate and much
less well specified problem — several fields are ambiguous or
unparseable by construction — and the moment sequences, Go's layouts,
the strftime conversions, `iso8601`, `rfc822` and `rfc5322` are all
still there to read text with.

### strftime conversions

`strftime` is the fourth way of saying it, and the one already written
down in most configuration files: a `%` followed by a letter, and
everything else copied through.

```zig
try datetime.strftime.format(value, "%Y-%m-%d %H:%M:%S", writer);
const value = try datetime.strftime.parseAll("%a, %d %b %Y %H:%M:%S %z", header);
```

Everything POSIX defines is here, along with the GNU extensions that
turn up beside it: `%P`, `%k`, `%l`, `%s`, `%e`, `%C`, `%D`, `%F`, `%G`,
`%g`, `%h`, `%r`, `%R`, `%T`, `%u` and `%V`. Between the `%` and the
letter go the GNU flags — `-` for no padding, `_` for spaces, `0` for
zeros, `^` for upper case and `#` for the opposite case — then a minimum
field width, then the `E` or `O` modifier, which is read and dropped
because no locale here has an alternative representation to offer:

```zig
try datetime.strftime.format(value, "%A, %-d %B %Y", writer);   // Friday, 5 January 2024
try datetime.strftime.format(value, "%^b %_3d", writer);        // JAN   5
```

Two conversions are `date(1)`'s rather than `strftime(3)`'s, and both
are here because without them something this library holds could not be
written at all. `%N` is the nanosecond, nine digits by default and as
many as a width asks for, so `%3N` is milliseconds. `%:z`, `%::z` and
`%:::z` are the offset with colons in it, which is what RFC 3339 wants
and what `%z` cannot spell.

A conversion the library does not know is a **compile error** naming it,
where the C library would copy it through as text. That is the one place
a comptime format string earns its keep: `%Q` is a typo, and a typo that
prints itself is one nobody finds.

Parsing is `strptime`'s shape rather than `strftime`'s: whitespace in the
format matches any run of it including none, a numeric field takes one
digit as readily as two, names are matched without regard to case, and
text after what the format asked for is left alone. `parse` returns what
it read in `Result.str`; `parseAll` requires the whole input.

#### Compatibility, checked

glibc's `C` locale is the specification and `zig build oracle-strftime`
diffs against it: every conversion on its own, every flag and width over
the conversions they say anything about, the shapes callers write, and
each one read straight back. The oracle is C, compiled by Zig and linked
against whatever libc the host has, so it needs nothing added to the dev
shell.

```
12496 comparisons against glibc 2.42, no divergence beyond 626 known and documented
```

Those are the deliberate differences, and the oracle carries the same
list so that anything else fails. Writing:

- **`%s` honours the offset.** glibc reaches a `struct tm` through
  `mktime`, so its count of seconds is the fields read against the
  process's timezone and `tm_gmtoff` is ignored. A `DateTime` carries the
  offset that says which instant it names, and uses it.
- **`%Z` writes nothing when the zone is not known**, which POSIX allows
  in so many words. glibc falls back to the running process's zone name,
  which would be a claim about where a reading was made that nothing here
  can support.

Reading, glibc's `strptime` is followed as far as it goes and then four
things are kept that it throws away or refuses: `%G` with `%V` resolves
an ISO week date, `%j` names a date without a year beside it, `%P` is
read as well as written, and a flag, a width or an `E`/`O` modifier is
ignored rather than refused — so that a format string which writes a date
can read one back, which in glibc it cannot. `%s` reads a negative count
too, which glibc writes and will not read.

The interchange formats have their own parsers, because the shape of
their input is not known ahead of reading it and a format string cannot
express that.

**RFC 822**, as used by email, HTTP, and RSS:

```zig
const result = try datetime.rfc822.parse("Fri, 21 Nov 1997 09:55:06 -0600");
const utc = result.value.toUtc();
```

It reads the syntax leniently, which is what a feed or a mailbox needs:
the day name, its comma and the seconds are all optional, two and three
digit years are windowed the way RFC 5322 section 4.3 says to, and the
alphabetic zones (`GMT`, `EST`, and the single letter military ones) are
accepted alongside `±hhmm`.

**RFC 5322**, the current syntax of a message `Date:` header, is the same
grammar read strictly:

```zig
const result = try datetime.rfc5322.parse("Fri, 21 Nov 1997 09:55:06 -0600");
```

Strictly means the obsolete forms above are refused — a four digit year,
a two digit hour, a numeric zone and the comma after the day name are all
required, so `20 Jun 82 12:34 EST` is `error.ParseError` here and a date
for `rfc822.parse`. The division is between forms that change what a date
*means* and forms that do not: a two digit year has to be guessed at a
century and an alphabetic zone is ambiguous between the handful RFC 822
named and the hundreds in use.

What it adds in exchange is the rest of RFC 5322, which `rfc822` does not
have:

```zig
// Comments stand wherever whitespace may, they nest, and `\` quotes the
// character after it. A header still folded across lines is read as it
// arrived. All of it is part of the date, so `result.str` covers it.
const commented = try datetime.rfc5322.parse(
    "Thu,\r\n 13 (the thirteenth) Feb 1969 23:32:54 -0330 (Newfoundland)",
);

// Section 3.3 gives `-0000` a meaning `+0000` does not: the time is UTC,
// but the sender would not say what zone it was in, so the date carries
// no zone information at all. Both leave `offset` zero, so the
// distinction is reported on its own.
const withheld = try datetime.rfc5322.parse("21 Nov 1997 09:55:06 -0000");
std.debug.print("{}\n", .{withheld.unknown_offset});   // true
```

Years past four digits are well formed — the grammar says `4*DIGIT` —
and a date must be semantically valid as well as well formed, so a day
name that disagrees with the date it precedes is an error in both
parsers.

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
by prior agreement, are not accepted. Durations and time intervals have
parsers of their own, below.

### Durations

`iso8601.parseDuration` reads the other half of the syntax, and
`Duration` is what it reads into:

```zig
const result = try datetime.iso8601.parseDuration("P3Y6M4DT12H30M5S");
const later = now.add(result.value);
```

A `Duration` keeps **months**, **days** and **everything below a day**
apart, and that separation is the whole design. A duration is not a fixed
number of nanoseconds, because a month is not a fixed number of days: one
month after the 31st of January is the 28th of February, and a type that
reduced the duration to a count would have no way to say so. `Instant` is
for a fixed span; `Duration` is for the calendar's own arithmetic. Years
fold into months and weeks into days, since within each pair the
conversion is exact.

`DateTime.add` applies one, in the order XML Schema's [*Adding durations
to dateTimes*](https://www.w3.org/TR/xmlschema-2/#adding-durations-to-dateTimes)
lays down: the sub-day part first, so that its whole days can be set
aside; then the months, with the day of the month **clamped** to the last
day of wherever it landed; then the days, as a day count. Doing the months
before the days is why adding a duration is neither commutative nor
associative — `P1M1D` from the 31st of January is the 1st of March, while
a day and then a month would be the 2nd — and why ISO 8601 writes the
components in that one order and no other.

Two things about a duration are worth knowing before relying on it.
`sign` answers `1`, `-1`, `0`, or **null** when the fields disagree.
`{ .months = 1, .days = -1 }` is a real length of time, but ISO 8601-1
has at most one sign, in front of everything, and cannot write it. ISO
8601-2's composite durations put a sign on each component instead, and
that is what `format` writes for such a duration: `P1M-1D`, or
`P-1Y-2M3D`. `parseDuration` reads both forms back, but not a sign in
both places at once, `-P1Y-2M`, which Part 2 forbids. An interval refuses
any negative component, because a mixed duration runs forwards from some
dates and backwards from others: `P1M-30D` is a day earlier from the 31st
of January and a day later from the 1st of March. And
`DurationParseResult.fractional` says which component carried a decimal
fraction, because a caller may allow fewer of them than ISO 8601 does —
XML Schema's `duration` allows one only on the seconds, so `P1.5D` is a
good ISO 8601 duration and not a valid `xs:duration`, and once the
fraction is folded into `nanoseconds` there is nothing left to tell from.

Fractions of a year, a month or a week are refused outright rather than
guessed at, since none of the three has a length in days to divide. The
alternative `P0003-06-04T12:30:05` spelling of a duration is not read.

### Intervals

`iso8601.parseInterval` reads a time interval in any of ISO 8601's three
forms, and `Interval` is what it reads into:

```zig
const a = try datetime.iso8601.parseInterval("2007-03-01T13:00:00Z/2008-05-11T15:30:00Z");
const b = try datetime.iso8601.parseInterval("2007-03-01T13:00:00Z/P1Y2M10DT2H30M");
const c = try datetime.iso8601.parseInterval("P1Y2M10DT2H30M/2008-05-11T15:30:00Z");

if (b.value.contains(datetime.Instant.now(io))) { ... }
```

An `Interval` is a tagged union that keeps the **form it was written in**,
for the reason `Duration` keeps its months apart: `2001-01-31/P1M` means a
month from the 31st of January, and the pair of endpoints it resolves to
would say only 28 days. `start` and `end` resolve whichever endpoint was
not written, by `DateTime.add` — or, for a duration and an end, by adding
the negated duration, since subtraction has no better definition once a
month has been clamped: `P1M/2001-02-28` could have started on any of four
days in January, and it answers the 28th, the latest of them.
`duration` answers only when one was written, because which calendar
duration lies between two dates has no single answer, and `length` is the
fixed span in nanoseconds, taken between the endpoints' instants.

`contains` and `overlaps` treat an interval as **half-open**, holding its
start and not its end. ISO 8601 leaves that to the application, and it is
the choice that lets intervals tile: `2024-03-15/2024-03-16` and
`2024-03-16/2024-03-17` share no instant and leave none out.

The parts are separated by a solidus, or by the `--` that ISO 8601 allows
where a solidus cannot go. An end with no zone of its own is in the
start's, whether or not it is abbreviated: ISO 8601-1:2019/Amd 1:2022 says
a time shift written before the separator applies after it, and makes
`2018-01-15T12:00:00+05:00/2018-02-20T12:00:00` end at `+05:00`. And the
end may leave out its higher-order components, which it takes from the
start:

| interval | ends at |
| --- | --- |
| `2007-12-14T13:30/15:30` | 15:30 the same day |
| `2008-02-15/03-14` | 2008-03-14 |
| `2008-02-15T09:00/16T17:00` | 17:00 the next day |
| `20071214T1330/1530` | 15:30 the same day |

The abbreviated end is read by laying it over the tail of the start's text
at each place one component ends and the next begins, and keeping the
splice that reads to the start's precision and consumes the most of the
end. Without separators there is nowhere to lay it, so a start in the
basic form can have its date left out and nothing finer. The result also
reports, for each endpoint that was a date, the `has_offset` and
`precision` that `parse` would have.

An interval has to run forwards — an end before its start is
`error.OutOfRange` — and a duration in one may not carry a sign. A
duration that would carry the other endpoint outside the years a `Year`
can hold is refused at parse time, which is what makes `start` and `end`
safe on anything the parser returns; `DateTime.addChecked` is the same
check for a duration from somewhere else. A bare duration is not read,
since ISO 8601 counts it as an interval placed by context and there is none
of that here.

`Interval.format` writes one back in its own form, each endpoint in full in
the extended form with `Z` for a zero offset. A `DateTime` cannot say it
was read without a zone, so a local endpoint comes back as `Z` — the
instant `length` and `contains` took it to be.

### Recurring intervals

`iso8601.parseRecurringInterval` reads a series of intervals, and
`RecurringInterval` is what it reads into: `R`, how many intervals, a
solidus, and an interval in any of the three forms above.

```zig
const result = try datetime.iso8601.parseRecurringInterval("R12/2024-01-31T09:00:00Z/P1M");
var occurrences = result.value.iterator();
while (try occurrences.next()) |occurrence| {
    // occurrence is an Interval: occurrence.start(), occurrence.end(), ...
}
```

ISO 8601-1:2019 defines one as a "series of consecutive time intervals of
identical duration", and the word *consecutive* decides the
arithmetic: each interval starts where the one before it ended, so the
series is built by adding the duration to each occurrence in turn, not by
multiplying it from the first. Once a month has been clamped the two
differ. `R/2024-01-31T00:00:00Z/P1M` runs to the 29th of February, then the
29th of March, and stays on the 29th, because that is where each interval
ended. RFC 5545's `RRULE` multiplies instead, and lands on the 31st where
there is one, but it describes a pattern of events, not a run of intervals
laid end to end. An interval written as two endpoints has no calendar
duration to repeat, so its series repeats its length on the timeline.

The count is the number of intervals, the first one included — the
standard reads its own `R15/…` as "fifteen recurrences" — and `R/` with no
count is unbounded. The form decides which occurrence the text names. A
start and an end, or a start and a duration, name the **first**, and the
series runs forwards. A duration and an end name the **last**:
`R/P1Y/1985-04-12T23:20:50Z` is an unbounded run of years that ended in
April 1985. `iterator` walks outward from the one named, and `isForwards`
says which way.

`R0` and `R-1` are refused. Neither ISO 8601-1:2019 nor ISO 8601-2:2019
defines them; an absent count is the only spelling of an unbounded series
either part gives. Accounts elsewhere say `R-1` means unbounded, and
disagree about whether `R0` is no intervals or one interval not repeated.
A count read the wrong way gives a series of the wrong length and nothing
to say so, so neither is guessed at. The repeat rule ISO 8601-2 adds after
the interval, as in `R12/20150929T140000/P1H30M0S/F2W`, is not read either:
it is left as trailing text.

Only the named occurrence is range-checked when the series is parsed,
because an unbounded series has no last occurrence to check. Walking one
into the edge of the years a `Year` can hold makes `next` return
`error.OutOfRange`. It does not return null there, because the series has
not ended; the next occurrence just cannot be represented.

## JSON

`Date`, `DateTime`, `Instant`, `Duration`, `Interval` and
`RecurringInterval` carry the hooks
`std.json` looks for, `jsonStringify`, `jsonParse` and `jsonParseFromValue`,
so they can be fields of anything you read or write with it:

```zig
const Event = struct {
    name: []const u8,
    at: datetime.DateTime,
    lasts: datetime.Duration,
};

const parsed = try std.json.parseFromSlice(Event, gpa,
    \\{"name":"standup","at":"2024-03-15T09:00:00-05:00","lasts":"PT15M"}
, .{});
defer parsed.deinit();

const text = try std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
```

Each is a JSON **string** holding its ISO 8601 spelling, not an object of
its fields, because that string is what every other JSON producer and
consumer of dates speaks — JavaScript's `Date.prototype.toJSON` writes one
— and this library reads it back:

| type | written as |
| --- | --- |
| `Date` | `"2024-03-15"` |
| `DateTime` | `"2024-03-15T14:30:00-05:00"`, with `Z` for a zero offset |
| `Instant` | `"2024-03-15T19:30:00Z"`, always in UTC |
| `Duration` | `"P1Y2M10DT2H30M"` |
| `Interval` | `"2024-03-15T09:00:00Z/P1D"`, in the form it was built in |
| `RecurringInterval` | `"R5/2024-03-15T09:00:00Z/P7D"` |

A fraction of a second is written only when there is one. Reading goes
through the ISO 8601 parsers above and has to consume the whole string, and
it is **strict**: it refuses anything it would otherwise have to complete
with something the text did not say.

- A `DateTime`, an `Instant`, and every endpoint an `Interval` or a
  `RecurringInterval` writes out have to be named to the second and carry
  an offset — the shape of RFC 3339's `date-time`, which is what JSON
  Schema's `date-time` format means. `"2024-03-15T14:30:00"` is refused
  rather than read as UTC, and `"2024-03-15T14:30Z"` rather than given a
  `:00`. An interval's end may still leave its zone to the start, since
  ISO 8601 says the start's zone applies to it.
- A `Date` refuses a time of day and a date that names no day, since it has
  nowhere to keep the one and nothing to hold for the other.

The parsers themselves stay lenient, and are the way to read a local or
reduced time on purpose: `iso8601.parse` reports `has_offset` and
`precision` beside the value, which a `DateTime` has no fields for.

A string that is not the representation is `error.InvalidCharacter`, and
one whose components are out of range — a month of 13, an interval that
runs backwards — is `error.Overflow`. Those are the errors `std.json`
gives for a malformed and an oversized number, so they sit in the error
sets it already has. Anything but a string is `error.UnexpectedToken`.

Three things do not survive the trip. A `DateTime`'s `designation` has
nowhere to go in ISO 8601 and comes back empty. An `Instant` is read by
removing the offset it was written with, and has nowhere to keep it, so a
field whose local offset matters — a forecast for a place — wants to be a
`DateTime`, which keeps it as written. And a `Duration` comes back
canonical, `P14M` as `P1Y2M`, the same length of time.

`iso8601.writeDateTime` and `iso8601.writeDate` are the writers the hooks
use, public for anyone who wants the same text without JSON around it.

## The calendar arithmetic

Turning a date into a day number and back is Howard Hinnant's, from
[*chrono-Compatible Low-Level Date
Algorithms*](https://howardhinnant.github.io/date_algorithms.html):
`days_from_civil`, `civil_from_days`, `weekday_from_days` and
`weekday_difference`, in `src/Date.zig` and `src/dayofweek.zig`, with the
derivations quoted in the doc comments there.

Two ideas do the work. The year is shifted to begin in March, which puts
the leap day at the end of it and leaves month lengths that a single
division inverts. And the calendar is cut into *eras* of 400 years, the
period after which the proleptic Gregorian calendar repeats exactly —
146097 days, every era — so a conversion factors the era out and then
works in a day-of-era and a year-of-era, which is why one era being right
means all of time is right. There is no table anywhere in it, and no
leap-year test in the round trip itself.

What that buys is a calendar exact in both directions for every year a
`Year` can hold, with no epoch-relative special cases and nothing that
degrades far from 1970. `Year` is an `i32`, numbered astronomically, so
there is a year 0 and negative years before it. What the paper does *not*
do is validity checking, deliberately, so `Date.isRegular` and the
assertions inside the conversions are this library's own. The paper's own
verification is kept, and runs: see `-Dbig-test-years` below.

Hinnant dedicates the algorithms to the public domain, so they are here
under the same MIT licence as the rest without any further condition.

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
zig build oracle-locale            # the embedded locales against moment.js
zig build oracle-cldr              # the CLDR patterns against ICU
zig build oracle-strftime          # the strftime conversions against the C library
zig build bench                    # always ReleaseFast, whatever -Doptimize says
```

Every oracle is part of `zig build test`, so an ordinary run needs `node`,
`go` and ICU, and fetches moment and CLDR the first time.

They live in `upstream/`, which is a Zig project of its own with a manifest
of its own, and the steps above run it from here. The reason is what a
declared dependency costs: moment and the three CLDR packages are 143 MB,
and anything that reads a manifest rather than running a build — `zon2nix`,
and every Nix expression generated from it — reads every entry whether the
build ever calls for that package or not. Guarding the `b.lazyDependency`
call stops the fetch and not the declaration, so the entry has to live
somewhere a consumer's tooling does not read. Each oracle can also be run
from inside that directory, which is the same thing without the hop.

moment and CLDR are pinned there, because each is the specification being
tested against and a floating version would move the target; Go and ICU are
not, because their behaviour is part of a toolchain rather than something to
fetch, and each oracle prints the version it ran against. `-Dcldr-locales`
narrows the embedded table, which is the quick way to iterate on one locale.

The C++ in `upstream/src/oracle_cldr.cpp` is compiled by Zig rather than by
a toolchain of its own, so the dev shell needs ICU and `pkg-config` and
nothing more. The C in `upstream/src/oracle_strftime.c` is compiled the same
way and needs nothing at all beyond a libc, which is also why that one
step is the only oracle that does not join `zig build test` on Windows:
`strptime`, `tm_gmtoff` and `tm_zone` are not there to compare against.

`src/fuzz.zig` holds a property per parser: nothing crashes on input
nobody chose, whatever comes back holds together, and anything with an
inverse survives the round trip. Each runs twice over, against a list of
seeds and against inputs built by mutating them, so an ordinary test run
does a small amount of fuzzing and `-Dfuzz-iterations=N` does as much as
you like:

```sh
zig build test -Dfuzz-iterations=500000 --seed 42
```

`-Dbig-test-years=N` sweeps every date from `-N-01-01` to `N-12-31`
through the day-number conversions and back, checking that the day number
advances by exactly one, that the round trip returns the date it started
from, and that the weekday advances by one. It is Hinnant's own test of
the algorithms `Date` and `DayOfWeek` are built on, and it defaults to
zero, which skips it:

```sh
zig build test -Dbig-test-years=2000                            # seconds
zig build test -Dbig-test-years=1000000 -Doptimize=ReleaseFast  # the paper's own
```

The second is the span the paper publishes, 730,485,366 dates, and the
test asserts that count too — so a disagreement about how many days two
million years hold is itself a failure. It takes about fifteen seconds,
against the seventeen the paper reports for the same sweep in C++ in
2013. In `Debug` it takes long enough to be worth not doing.

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

## References cited

The documents this library is written against. They are kept in a Zotero
collection called `zig-datetime`, with the full text of each RFC attached.

- **[POSIX]** The Open Group and IEEE, *The Open Group Base Specifications
  Issue 8*, IEEE Std 1003.1-2024,
  <https://pubs.opengroup.org/onlinepubs/9799919799/>. The `strftime` and
  `strptime` conversion specifications that `strftime` implements, and the
  `TZ` environment variable whose rule syntax `posixtz` reads.
- **[GLIBC]** Free Software Foundation, "Formatting Calendar Time", *The GNU
  C Library Reference Manual*,
  <https://www.gnu.org/software/libc/manual/html_node/Formatting-Calendar-Time.html>.
  The extensions POSIX does not have — `%P`, `%k`, `%l`, `%s`, the `-`, `_`,
  `0`, `^` and `#` flags and the field width — and, through
  `upstream/src/oracle_strftime.c`, the behaviour those are checked against.
- **[COREUTILS]** Free Software Foundation, "date invocation", *GNU Coreutils
  Manual*,
  <https://www.gnu.org/software/coreutils/manual/html_node/date-invocation.html>.
  `%N` and the `%:z` family, which are `date(1)`'s rather than
  `strftime(3)`'s and are the only way to write a nanosecond or an RFC 3339
  offset.
- **[ISO8601]** International Organization for Standardization, *Date and
  time — Representations for information interchange — Part 1: Basic rules*,
  ISO 8601-1:2019, <https://www.iso.org/standard/70907.html>. The calendar,
  ordinal and week date forms that `iso8601` reads, the duration syntax
  `Duration` holds, and the time interval forms `Interval` holds. Clause 5.6
  and definition 3.1.1.11 are what `RecurringInterval` follows: a series of
  *consecutive* intervals, the count read as the number of intervals, and
  the duration-and-end form naming the last one rather than the first.
- **[ISO8601-2]** International Organization for Standardization, *Date and
  time — Representations for information interchange — Part 2:
  Extensions*, ISO 8601-2:2019, <https://www.iso.org/standard/70908.html>.
  The repeat rules a recurring interval may carry in its clause 13, which
  `parseRecurringInterval` leaves unread, and, with Part 1, the evidence
  that the standard gives `R0` and `R-1` no meaning.
- **[ISO8601-1-AMD1]** International Organization for Standardization, *Date
  and time — Representations for information interchange — Part 1: Basic
  rules — Amendment 1: Technical corrections*, ISO 8601-1:2019/Amd 1:2022,
  <https://www.iso.org/standard/81801.html>. Its restated 5.5.1 is why an
  interval's end without a zone takes the start's, written out in full or
  not, and its 5.3.2 on the ending of the day is how `24:00` is read: the
  first instant of the next day.
- **[ISO8601-2-AMD1]** International Organization for Standardization, *Date
  and time — Representations for information interchange — Part 2:
  Extensions — Amendment 1: Canonical expressions, extensions to time scale
  components and date time arithmetic*, ISO 8601-2:2019/Amd 1:2025,
  <https://www.iso.org/standard/86124.html>. Which pairs of units convert
  exactly — years and months, weeks and days, as `Duration` folds them —
  and which do not.
- **[ISO8601-1-WD]** ISO/TC 154/WG 5, *Data elements and interchange formats
  — Information interchange — Representation of dates and times — Part 1:
  Basic rules*, ISO/WD 8601-1, working draft N0038, 16 February 2016,
  <https://www.loc.gov/standards/datetime/iso-tc154-wg5_n0038_iso_wd_8601-1_2016-02-16.pdf>.
  A draft of ISO 8601-1 that the Library of Congress made public, which is
  what `RecurringInterval` was first written from; the published text
  agrees with it on everything that type does.
- **[ISO8601-2-WD]** ISO/TC 154/WG 5, *Data elements and interchange formats
  — Information interchange — Representation of dates and times — Part 2:
  Extensions*, ISO/WD 8601-2, working draft N0039, 16 February 2016,
  <https://www.loc.gov/standards/datetime/iso-tc154-wg5_n0039_iso_wd_8601-2_2016-02-16.pdf>.
  The draft of Part 2, public in the same place. Its repeat rules are
  spelled differently from the published ones, `FREQ=` where 2019 has `F`.
- **[UTS35]** Unicode Consortium, *Unicode Locale Data Markup Language (LDML)
  Part 4: Dates*, UTS #35,
  <https://unicode.org/reports/tr35/tr35-dates.html>. The pattern vocabulary
  `cldr` speaks, field by field and count by count.
- **[CLDR]** Unicode Consortium, *Unicode CLDR Project*,
  <https://cldr.unicode.org/>. The locale data `-Dembed-cldr` compiles in,
  and `windowsZones.xml`, which `src/windowszones.zig` is generated from.
- **[ICU]** Unicode Consortium, "Formatting Dates and Times", *ICU
  Documentation*,
  <https://unicode-org.github.io/icu/userguide/format_parse/datetime/>. The
  reference implementation of UTS #35, and what `zig build oracle-cldr`
  diffs against.
- **[MOMENT]** *Moment.js Documentation*, <https://momentjs.com/docs/>. The
  format-string sequences `DateTime.format` uses, the two parsing modes, and
  the locale data `-Dembed-locales` compiles in.
- **[GO]** *time package*, Go Packages, <https://pkg.go.dev/time>. The
  reference-time layouts `golayout` implements, and what `zig build
  oracle-go` diffs against.
- **[TZDB]** Internet Assigned Numbers Authority, *Time Zone Database*,
  <https://www.iana.org/time-zones>. The zone data itself, and `zic`, the
  reference compiler `-Dembed-tzdata` builds and runs.
- **[HINNANT]** Hinnant, H., *chrono-Compatible Low-Level Date Algorithms*,
  <https://howardhinnant.github.io/date_algorithms.html>. `days_from_civil`
  and `civil_from_days`, which `Date` is built on, and the sweep over every
  date in a span of years that `-Dbig-test-years` runs.
- **[RFC822]** Crocker, D., *Standard for the Format of ARPA Internet Text
  Messages*, RFC 822, August 1982,
  <https://www.rfc-editor.org/info/rfc822>. The date syntax `rfc822` reads
  leniently, including the alphabetic and military zones.
- **[RFC1123]** Braden, R., Ed., *Requirements for Internet Hosts —
  Application and Support*, RFC 1123, October 1989,
  <https://www.rfc-editor.org/info/rfc1123>. The four digit year that
  amended RFC 822, and the layout Go names `RFC1123`.
- **[RFC2822]** Resnick, P., Ed., *Internet Message Format*, RFC 2822, April
  2001, <https://www.rfc-editor.org/info/rfc2822>. The revision of RFC 822
  that RFC 5322 in turn obsoletes.
- **[RFC3339]** Klyne, G. and C. Newman, *Date and Time on the Internet:
  Timestamps*, RFC 3339, July 2002,
  <https://www.rfc-editor.org/info/rfc3339>. The ISO 8601 profile most
  internet protocols mean, which `iso8601` accepts and which
  `strftime.pattern.rfc_3339` writes.
- **[RFC5322]** Resnick, P., Ed., *Internet Message Format*, RFC 5322,
  October 2008, <https://www.rfc-editor.org/info/rfc5322>. The current
  `date-time` grammar `rfc5322` reads strictly: comments, folding, and the
  meaning section 3.3 gives `-0000`.
- **[RFC8536]** Olson, A., Eggert, P. and K. Murchison, *The Time Zone
  Information Format (TZif)*, RFC 8536, February 2019,
  <https://www.rfc-editor.org/info/rfc8536>. The binary format `tzif` reads,
  all three versions of it.
