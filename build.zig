// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Build script for the datetime library.
//!
//! The library itself needs nothing beyond the standard library. What this
//! script mostly does is the optional `-Dembed-tzdata` path, which turns
//! the IANA sources into a module compiled into the binary: it fetches the
//! sources and tzcode as lazy dependencies, builds `zic` with the C
//! compiler Zig ships, runs it to compile the sources into a TZif tree,
//! and then runs `tools/tzpack.zig` over that tree to produce the blob and
//! index that `src/tzdb.zig` reads. Nothing on the host is used, so the
//! result is the same whatever timezone data the machine happens to have.
//!
//! Without that option the `tzdata` module resolves to `src/tzdata/stub.zig`
//! instead, which has the same shape and no data.
//!
//! `zig build oracle` checks the format strings against moment.js, which
//! they are modelled on, by running both over the same corpus and diffing.
//! moment is pinned in `build.zig.zon` and fetched lazily, and the runner
//! is the `node` named in `flake.nix`. It is part of `zig build test`,
//! because the two agree.
//!
//! `zig build oracle-go` checks `golayout` against Go's own `time`
//! package, the same way and for the same reason. Go comes from the dev
//! shell rather than from a pin, because the layouts are part of its
//! standard library; the oracle prints the version it ran against.
//!
//! `zig build oracle-strftime` does the same for `strftime`, against the
//! C library that defines those conversions. The oracle is C, compiled by
//! Zig and linked against whatever libc the host has, so it costs no
//! dependency and nothing in the dev shell.
//!
//! `zig build oracle-parse` does the same for parsing. `DateTime.Mode` has
//! the same two settings moment's strict flag chooses between, and each is
//! held to the matching mode of moment. It carries a short list of known
//! divergences and fails on anything else, and is part of `test` too.
//!
//! `zig build windowszones` regenerates `src/windowszones.zig`, the table
//! that gets from a Windows zone name to an IANA one. Unlike the timezone
//! database that table is checked into the tree, so that the Windows path
//! costs no dependency and no network; this step is only for refreshing it
//! when CLDR publishes a new release.
//!
//! `-Dno-system-tzdata` is a testing knob rather than a build variant. The
//! tests that read the operating system's copy of the database skip when
//! there is none, and those skips are where a mistake can hide on a
//! machine that has one; the option empties the directories the tests look
//! in so that both halves are reachable from either kind of machine.

const std = @import("std");

/// The IANA release that `build.zig.zon` pins. Kept here so the generated
/// data can record which release it came from.
const tz_release = "2026d";

/// The CLDR release `src/windowszones.zig` was generated from, recorded in
/// the generated file and reported as `tzdb.windows.cldr_version`. The file
/// to feed `zig build windowszones` is:
///
///   https://raw.githubusercontent.com/unicode-org/cldr/release-48-2/common/supplemental/windowsZones.xml
const cldr_release = "release-48-2";

/// How zic should pack the embedded data.
const Packing = enum { slim, fat };

/// The data files that make up the database. `backward` carries the links
/// from old zone names to current ones, so leaving it out would drop names
/// like "US/Central" that plenty of systems still hand out.
const tz_sources = [_][]const u8{
    "africa",  "antarctica",   "asia",         "australasia",
    "europe",  "northamerica", "southamerica", "etcetera",
    "factory", "backward",
};

/// Declares the library module, the tests, the benchmarks, the generated
/// documentation, and the optional embedded timezone database.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_filter = b.option([]const u8, "test-filter", "Filter for test") orelse "";

    const embed_tzdata = b.option(
        bool,
        "embed-tzdata",
        "Compile the IANA timezone database into the library. Fetches the " ++
            "IANA sources and builds zic with the C compiler Zig ships, so " ++
            "it needs no timezone data or tools on the host (default: false)",
    ) orelse false;

    const tz_packing = b.option(
        Packing,
        "tzdata-packing",
        "How zic should pack the embedded data. slim leans on each zone's " ++
            "POSIX rule for repeating years and is roughly half the size; " ++
            "fat writes every transition out (default: slim)",
    ) orelse .slim;

    const tz_from = b.option(
        []const u8,
        "tzdata-from",
        "Drop embedded transitions before this time, as a zic -r argument " ++
            "such as @0 for the Unix epoch (default: keep all history)",
    );

    const fuzz_iterations = b.option(
        usize,
        "fuzz-iterations",
        "How many mutated inputs each fuzz target tries. The default keeps " ++
            "`zig build test` quick; raise it for a longer hunt (default: 2000)",
    ) orelse 2000;

    const big_test_years = b.option(
        u32,
        "big-test-years",
        "Sweep every date from -N-01-01 to N-12-31 through the day-number " ++
            "conversions and back, checking the three properties Hinnant's " ++
            "paper checks. Zero, the default, skips it. The paper's own " ++
            "figure is 1000000, which is 730,485,366 dates and wants " ++
            "-Doptimize=ReleaseFast (default: 0)",
    ) orelse 0;

    const embed_locales = b.option(
        bool,
        "embed-locales",
        "Compile moment.js's locales into the library, so that a locale " ++
            "can be chosen by name at run time. English is built in either " ++
            "way; this adds the other hundred and thirty-six (default: false)",
    ) orelse false;

    const embed_cldr = b.option(
        bool,
        "embed-cldr",
        "Compile the Unicode CLDR's locales into the library, so that a " ++
            "CLDR date pattern can be written in any of them at run time. " ++
            "English is built in either way; this adds the other seven " ++
            "hundred and sixty-five (default: false)",
    ) orelse false;

    const cldr_locales = b.option(
        []const u8,
        "cldr-locales",
        "Restrict the CLDR locale table to these identifiers, comma " ++
            "separated, so that a program needing a handful does not pay " ++
            "for all of them: -Dcldr-locales=fr,de,ja. Narrows what " ++
            "`zig build oracle-cldr` checks as well, which is the quick " ++
            "way to iterate on one locale. Empty, the default, means every " ++
            "locale CLDR ships",
    ) orelse "";

    const no_system_tzdata = b.option(
        bool,
        "no-system-tzdata",
        "Run the tests as though the machine had no system timezone " ++
            "database, so that the paths taken when there is none are " ++
            "exercised on a machine that has one. Affects the tests only; " ++
            "the library behaves the same either way (default: false)",
    ) orelse false;

    // `src/root.zig` and not `src/datetime.zig`, which is what it was called
    // until it turned out that the two conventions this library follows --
    // a namespace file named in lower case, a type file named for its type --
    // collide when the namespace and the type share a name. `datetime.zig`
    // and `DateTime.zig` are one file on a case-insensitive filesystem, so
    // Zig's package manager could not unpack this package on Windows or
    // macOS at all: `unable to create file 'src/datetime.zig':
    // PathAlreadyExists`, before a line of it was ever compiled.
    const module = b.addModule(
        "datetime",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    // Both tables are generated and committed, so asking for them costs a
    // build nothing but the compiling: no fetch, no node, no network. What
    // regenerates them is `zig build gen-locales` and `zig build gen-cldr`,
    // which run in `upstream/` where the sources they read are declared.
    const locales_source = if (embed_locales)
        b.path("src/locales/all.zig")
    else
        b.path("src/locales/stub.zig");

    const cldr_locales_source = if (embed_cldr)
        b.path("src/cldrlocales/all.zig")
    else
        b.path("src/cldrlocales/stub.zig");

    // `-Dcldr-locales` used to narrow what was generated. The table is the
    // same 766 locales for everybody now, so the narrowing happens here
    // instead: the library reads this at comptime and builds its lookup out
    // of the entries named, and an entry nothing refers to costs a binary
    // nothing. Empty, the default, means all of them.
    const cldr_options = b.addOptions();
    cldr_options.addOption([]const u8, "locales", cldr_locales);
    module.addImport("cldr_options", cldr_options.createModule());

    // The stub sits in a directory of its own because a module takes its
    // whole containing directory with it. Left in src/ it would make a
    // second module out of every file here, which turns up in the
    // generated documentation as a duplicate of the entire library.
    const tzdata_source = if (embed_tzdata)
        generateTzdata(b, tz_packing, tz_from)
    else
        b.path("src/tzdata/stub.zig");

    module.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });
    module.addAnonymousImport("locales", .{ .root_source_file = locales_source });
    module.addAnonymousImport("cldrlocales", .{ .root_source_file = cldr_locales_source });

    // Windows has no zoneinfo tree, so `tzdb.windows` asks it which zone
    // the machine is set to instead. Lazy, and only for that target, so a
    // build for anything else neither fetches nor compiles the bindings.
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
            module.addImport("win32", zigwin32.module("win32"));
        }
    }

    const options = b.addOptions();
    options.addOption(bool, "no_system_tzdata", no_system_tzdata);
    options.addOption(usize, "fuzz_iterations", fuzz_iterations);
    options.addOption(u32, "big_test_years", big_test_years);
    module.addImport("build_options", options.createModule());

    const tests = b.addTest(.{
        .root_module = module,
        .filters = &.{test_filter},
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // Zig emits the API documentation as a side effect of compiling, so
    // this builds the library purely to get at it. The result is a static
    // site: index.html, the viewer's wasm and javascript, and the sources
    // it reads from.
    const docs_library = b.addLibrary(.{
        .name = "datetime",
        .root_module = module,
    });

    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Build the API documentation into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    // The generated viewer fetches `sources.tar` and `main.wasm` at runtime,
    // which a browser refuses to do from a `file://` page, so reading the docs
    // locally means serving them. This is the same reason `zig std` runs a
    // server rather than just opening a file.
    const docs_port = b.option(u16, "docs-port", "Port for `zig build docs-serve` (default 8000)") orelse 8000;

    const docs_server = b.addExecutable(.{
        .name = "docs-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/docs_server.zig"),
            // Always built for the machine running the build, never for
            // whatever `-Dtarget` the library is being built for.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run_docs_server = b.addRunArtifact(docs_server);
    run_docs_server.step.dependOn(&install_docs.step);
    run_docs_server.addArg(b.getInstallPath(.prefix, "docs"));
    run_docs_server.addArg(b.fmt("{d}", .{docs_port}));
    // The server runs until interrupted, so its output has to reach the
    // terminal rather than being captured by the build runner.
    run_docs_server.stdio = .inherit;

    const docs_serve_step = b.step("docs-serve", "Serve the API documentation over HTTP");
    docs_serve_step.dependOn(&run_docs_server.step);

    // The server has tests of its own; without this they would never run.
    const docs_server_tests = b.addTest(.{ .root_module = docs_server.root_module });
    test_step.dependOn(&b.addRunArtifact(docs_server_tests).step);

    // The benchmarks always build ReleaseFast, independent of -Doptimize,
    // so they need their own instance of the module built the same way.
    const bench_datetime = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_datetime.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });
    bench_datetime.addAnonymousImport("locales", .{ .root_source_file = locales_source });
    bench_datetime.addImport("build_options", options.createModule());
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
            bench_datetime.addImport("win32", zigwin32.module("win32"));
        }
    }

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{
                    .name = "datetime",
                    .module = bench_datetime,
                },
            },
        }),
    });

    const run_bench = b.addRunArtifact(bench_exe);

    const bench_step = b.step("bench", "Run the benchmarks");
    bench_step.dependOn(&run_bench.step);

    // CLDR's table of Windows zone names against IANA ones, which is what
    // `tzdb.windows` reads. It is checked into the tree rather than
    // generated on every build: it is a few kilobytes of names that change
    // about once a year, and fetching it would put a dependency and a
    // network round trip in front of every Windows build for that.
    //
    // Refreshing it is therefore a deliberate step rather than something
    // the build does on its own, and it takes the file rather than
    // downloading it, because a build step that reaches the network is not
    // reproducible:
    //
    //     curl -O https://raw.githubusercontent.com/unicode-org/cldr/\
    //         release-48-2/common/supplemental/windowsZones.xml
    //     zig build windowszones -Dwindowszones-xml=windowsZones.xml
    //
    // Then update `cldr_release` above to match what was downloaded.
    const gen_windowszones = b.addExecutable(.{
        .name = "gen-windowszones",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_windowszones.zig"),
            // Built for the machine running the build: it runs here, now,
            // and never ships anywhere.
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    // The generator has tests of its own; without this they would never run.
    test_step.dependOn(&b.addRunArtifact(
        b.addTest(.{ .root_module = gen_windowszones.root_module }),
    ).step);

    const windowszones_step = b.step(
        "windowszones",
        "Regenerate src/windowszones.zig from CLDR's windowsZones.xml",
    );

    if (b.option(
        []const u8,
        "windowszones-xml",
        "Path to CLDR's windowsZones.xml, for `zig build windowszones`",
    )) |xml_path| {
        const run_gen = b.addRunArtifact(gen_windowszones);
        run_gen.addFileArg(.{ .cwd_relative = xml_path });
        const generated_table = run_gen.addOutputFileArg("windowszones.zig");
        run_gen.addArg(cldr_release);

        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(generated_table, "src/windowszones.zig");
        windowszones_step.dependOn(&update.step);
    } else {
        windowszones_step.dependOn(&b.addFail(
            "windowszones needs the CLDR file: -Dwindowszones-xml=path/to/windowsZones.xml",
        ).step);
    }

    // Everything from here down runs `upstream/`, and belongs to whoever is
    // working on this library rather than to anybody depending on it.
    //
    // `b.pkg_hash` is empty for the package the build was invoked on and
    // holds the package hash for anything reached as a dependency, which is
    // exactly the distinction wanted: a dependent's build does not so much as
    // declare these steps, and never has to have the directory they name.
    if (b.pkg_hash.len != 0) return;

    // The oracles live in `upstream/`, a project of its own, because of what
    // a declared dependency costs: moment and the three CLDR packages are
    // 143 MB, and anything that reads a manifest rather than running a build
    // -- `zon2nix`, and every Nix expression generated from it -- reads every
    // entry whether the build ever calls for that package or not. Guarding
    // the `b.lazyDependency` call stops the fetch and not the declaration.
    //
    // These three steps run it from here, so that the commands are the same
    // ones they always were.
    // Part of `zig build test`, as they were when they lived here: a
    // divergence from any of the four is a regression rather than a known
    // gap.
    const run_oracles = shellOut(b, "test", null);
    const oracles_step = b.step("oracles", "Check this library against moment, Go, ICU and libc, in upstream/");
    oracles_step.dependOn(&run_oracles.step);
    test_step.dependOn(&run_oracles.step);

    // Each on its own as well, because iterating on one is what a person
    // actually does with them, and because the README has always named them.
    for ([_]struct { name: []const u8, help: []const u8 }{
        .{ .name = "oracle", .help = "Check formatting against moment.js, in upstream/" },
        .{ .name = "oracle-parse", .help = "Check parsing against moment.js, in upstream/" },
        .{ .name = "oracle-locale", .help = "Check the embedded locales against moment.js, in upstream/" },
        .{ .name = "oracle-go", .help = "Check the Go layouts against Go's time package, in upstream/" },
        .{ .name = "oracle-cldr", .help = "Check the CLDR patterns against ICU, in upstream/" },
        .{ .name = "oracle-strftime", .help = "Check the strftime conversions against the C library, in upstream/" },
    }) |each| {
        b.step(each.name, each.help).dependOn(&shellOut(b, each.name, null).step);
    }

    const gen_locales_step = b.step("gen-locales", "Regenerate src/locales/all.zig, in upstream/");
    gen_locales_step.dependOn(&shellOut(b, "gen-locales", null).step);

    const gen_cldr_step = b.step("gen-cldr", "Regenerate src/cldrlocales/all.zig, in upstream/");
    gen_cldr_step.dependOn(&shellOut(b, "gen-cldr", null).step);
}

/// Runs one of `upstream/`'s steps, forwarding whatever followed `--`.
fn shellOut(b: *std.Build, step: []const u8, extra: ?[]const []const u8) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", step });
    run.setCwd(b.path("upstream"));
    run.stdio = .inherit;
    // Its inputs are packages in a cache and tools in another directory
    // rather than anything this build declares, so there is nothing here for
    // the build runner to decide it is up to date against.
    run.has_side_effects = true;
    if (extra) |args| run.addArgs(args);
    if (b.args) |args| run.addArgs(args);
    return run;
}

/// Builds the embedded timezone database and returns the path of the
/// generated Zig source that indexes it.
///
/// The IANA database ships as zic source rather than as compiled TZif, so
/// something has to compile it. Rather than reimplement zic, this builds
/// the real one from the C sources that IANA publishes alongside the data,
/// using the C compiler that Zig already carries. The result is the
/// reference implementation's own output, and the whole thing is hermetic:
/// no zic, no timezone data and no C toolchain need exist on the host.
fn generateTzdata(
    b: *std.Build,
    packing: Packing,
    from: ?[]const u8,
) std.Build.LazyPath {
    const tzcode = b.lazyDependency("tzcode", .{}) orelse return b.path("src/tzdata/stub.zig");
    const tzdata = b.lazyDependency("tzdata", .{}) orelse return b.path("src/tzdata/stub.zig");

    // zic.c includes two headers that the tz Makefile generates rather
    // than ships. Both are a handful of #defines, so they are written out
    // here instead of running make.
    const headers = b.addWriteFiles();
    _ = headers.add("version.h", b.fmt(
        \\static char const PKGVERSION[]="(tzcode) ";
        \\static char const TZVERSION[]="{s}";
        \\static char const REPORT_BUGS_TO[]="tz@iana.org";
        \\
    , .{tz_release}));
    _ = headers.add("tzdir.h",
        \\#ifndef TZDEFAULT
        \\# define TZDEFAULT "/etc/localtime"
        \\#endif
        \\#ifndef TZDIR
        \\# define TZDIR "/usr/share/zoneinfo"
        \\#endif
        \\
    );

    // zic runs during the build, so it is built for the host rather than
    // for whatever the library is being cross-compiled to.
    const zic_module = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    zic_module.addCSourceFile(.{
        .file = tzcode.path("zic.c"),
        .flags = &.{"-std=c99"},
    });
    zic_module.addIncludePath(tzcode.path(""));
    zic_module.addIncludePath(headers.getDirectory());

    const zic = b.addExecutable(.{
        .name = "zic",
        .root_module = zic_module,
    });

    const run_zic = b.addRunArtifact(zic);
    run_zic.addArg("-b");
    run_zic.addArg(@tagName(packing));
    if (from) |lo| {
        run_zic.addArg("-r");
        run_zic.addArg(lo);
    }
    run_zic.addArg("-d");
    const zoneinfo = run_zic.addOutputDirectoryArg("zoneinfo");
    for (tz_sources) |source| run_zic.addFileArg(tzdata.path(source));

    // Fold the tree of TZif files into one blob plus an index.
    const packer = b.addExecutable(.{
        .name = "tzpack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tzpack.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    const run_packer = b.addRunArtifact(packer);
    run_packer.addDirectoryArg(zoneinfo);
    const generated = run_packer.addOutputDirectoryArg("tzdb");
    run_packer.addArg(tz_release);
    run_packer.addArg(from orelse "");

    return generated.path(b, "tzdata.zig");
}
