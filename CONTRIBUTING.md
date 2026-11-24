<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# Contributing to zig-datetime

This covers what you need to know before changing zig-datetime: how to build
and test it, where things live, which files are generated, and the rules the
code is held to. The [README](README.md) explains what the library does, and
[GLOSSARY.md](GLOSSARY.md) defines the terms the code and its comments use.

## Reporting issues and sending changes

Report issues and open pull requests on the Tangled mirror:
<https://tangled.org/jcollie.dev/zig-datetime>.

A good bug report includes three things: the input, what came back, and what
you expected. If you expected another implementation's behavior (moment.js,
ICU, glibc, Go, .NET or git), name that implementation and its version.

## Setting up

Everything builds inside the Nix dev shell. The shell provides the Zig
toolchain (0.17), ICU, Go, node, PowerShell, git, `reuse` and `zon2nix`, and
the oracles need all of them:

```sh
nix develop
zig build test
```

The first run fetches moment.js and the CLDR data, about 143 MB in all.

A second shell adds Wine, for running the test suite as a Windows binary:

```sh
WINEPREFIX=$PWD/.wine nix develop .#windows -c \
  zig build test -Dtarget=x86_64-windows -Dembed-tzdata -fwine
```

Set `WINEPREFIX` as shown. Wine builds a prefix for the first architecture it
sees and then refuses the other, so a leftover 32-bit `~/.wine` stops the run.
`.wine/` is in `.gitignore`.

## Layout

- `src/`: the library. `root.zig` is the module root, and each format has a
  file of its own (`cldr.zig`, `strftime.zig`, `golayout.zig`, `dotnet.zig`,
  `gitdate.zig`, `iso8601.zig`, and so on).
- `src/fuzz.zig`: one fuzz property per parser.
- `tools/`: the documentation server, the tzdata updater, the Windows zone
  table generator and the day-number verifier.
- `upstream/`: a separate Zig project holding the oracles and the generators.
  It has its own manifest so that the large reference packages (moment and
  CLDR) never appear in the manifest a consumer reads. The top-level build
  runs its steps for you, so `zig build oracle-cldr` works from the root.

## Before sending a change

CI runs all of these, so run them locally first:

```sh
zig fmt --exclude zig-pkg --exclude upstream/zig-pkg --check .
reuse lint
zig build test
zig build test -Dno-system-tzdata
zig build test -Dembed-locales
zig build test -Dembed-tzdata
```

`zig build test` runs every oracle as well as the unit tests. The README's
[Testing](README.md#testing) section explains the remaining options: fuzzing,
`-Dbig-test-years` and `verify-days`.

Run the Windows command from [Setting up](#setting-up) as well if your change
touches anything platform-specific, such as the timezone loaders or file
access.

## Oracles

Wherever this library claims compatibility with another implementation, that
implementation is the test. There is an oracle for each one:
- moment.js: formatting, parsing and locales;
- Go: `time` layouts;
- ICU: CLDR patterns and skeletons;
- glibc: `strftime`, `strptime` and `TZ`;
- .NET and PowerShell: format strings;
- git: date parsers.

Each oracle runs the real implementation and this library over the same
inputs and compares the results. Prefer extending an oracle's corpus to
writing expected values by hand: hand-written expectations encode what
someone believed the reference does, and the oracle checks what it actually
does.

Each oracle fails on any divergence it has not been told about. Some
divergences are deliberate. Others are differences the library cannot close,
such as data it does not carry or a limit in the reference. Each of those goes
on an explicit list in the oracle's source, with the reason, and the oracle
prints a count for each reason. When you add one, add it to the README's
"Compatibility, checked" section for that format too.

Do not loosen a comparison, or excuse a whole locale or format, to make a
failure go away. Narrow the excuse to the cases that actually differ.

moment.js and CLDR are pinned in `upstream/build.zig.zon`, because each is
the specification under test. Go, ICU, glibc, .NET and git come from the dev
shell, and each oracle prints the version it ran against.

## Rules the code follows

- **Compatibility means parity.** A format string from moment.js, `strftime`,
  Go, .NET or ICU means what it means there, for parsing as well as
  formatting. Do not add a sequence of your own that shadows one of theirs.
  Where the reference offers a choice, such as moment's strict and lenient
  parsing, expose the choice rather than picking one. The one exception is
  precision: where the library holds more than the reference (nanoseconds
  rather than milliseconds), it writes the real digits.
- **Readers refuse what they cannot represent.** A reader that would have to
  invent or drop part of its input returns an error instead. For example, it
  must not treat a time with no zone as UTC. A reader may instead report what
  it dropped alongside the value, the way `iso8601.parse` reports `has_offset`
  and `precision`. Documenting a lossy default is not enough.
- **Narrow after validating.** `@intCast` into a small integer panics when the
  value does not fit, so check the range before casting. A parser that casts
  `99` into a month field must reject it, not crash.
- **Doc comments explain the mechanism.** Say how a function decides what it
  does, not only what it is for. Writing the decision procedure out is often
  what exposes a mistake in it. Cite the clause of the standard you are
  implementing, as the existing comments cite ISO 8601 clauses.
- **Every function gets a doctest**, including private helpers. A doctest is a
  `test` named by the bare identifier of the declaration it exercises, such as
  `test bestPattern { ... }`. Keep it short and about that one function. Zig
  does not analyze a function nothing calls, so a doctest is also what proves
  the function compiles. Larger table-driven tests keep string names.
- **American spelling** in code, comments and documentation, except in
  quotations and proper nouns.

## Generated files

Do not edit these by hand. Regenerate them, and commit the generator change
and its output together.

| File | Regenerate with |
| --- | --- |
| `src/locales/all.zig` | `zig build gen-locales` (from moment.js) |
| `src/cldrlocales/all.zig` | `zig build gen-cldr` (from CLDR) |
| `src/windowszones.zig` | `zig build windowszones` (from CLDR's `windowsZones.xml`) |
| `build.zig.zon.nix` | `zon2nix --17 --nix=build.zig.zon.nix build.zig.zon upstream/build.zig.zon` |

Regenerate `build.zig.zon.nix` whenever either manifest's dependencies change.
CI builds with `--system`, which forbids Zig from fetching anything, so a
package missing from this file fails CI.

## Dependencies and tzdata

- **IANA timezone database:** `tools/update-tzdata.sh` moves the pin. It
  rewrites both hashes in `build.zig.zon` and `tz_release` in `build.zig`,
  then regenerates `build.zig.zon.nix`. A scheduled workflow
  (`.forgejo/workflows/tzdata.yml`) runs it daily and opens a pull request
  once the suite passes against the new release.
- **moment.js or CLDR:** after bumping either in `upstream/build.zig.zon`,
  rerun its generator. Expect the oracles to find differences, and either fix
  them or document them.

## References

If a change relies on a specification, a standard, or another
implementation's source, add it to the README's
[References cited](README.md#references-cited) section and cite it from the
code that depends on it.

## Licensing

The project is MIT licensed and follows [REUSE](https://reuse.software/).
Every new file starts with an SPDX header:

```zig
// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT
```

Files that cannot hold a comment are annotated in `REUSE.toml` instead.
Generated data keeps the copyright and license of its source. For example,
the moment.js locale table is MIT under the JS Foundation, and the Windows
zone table is Unicode-3.0. `reuse lint` must pass.

## Commits

Start the subject with the area the change touches when there is one, for
example `cldr: port ICU's DateTimePatternGenerator for skeletons` or
`posixtz: read TZ the way glibc does`. Write the subject as a summary of what
the change does. Use the body to explain why. A version bump is a commit of
its own, `Bump the version to 0.0.N`, and gets a signed `v0.0.N` tag.
