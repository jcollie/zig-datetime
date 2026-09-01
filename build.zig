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
const tz_release = "2026c";

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

    const embed_locales = b.option(
        bool,
        "embed-locales",
        "Compile moment.js's locales into the library, so that a locale " ++
            "can be chosen by name at run time. English is built in either " ++
            "way; this adds the other hundred and thirty-six (default: false)",
    ) orelse false;

    const no_system_tzdata = b.option(
        bool,
        "no-system-tzdata",
        "Run the tests as though the machine had no system timezone " ++
            "database, so that the paths taken when there is none are " ++
            "exercised on a machine that has one. Affects the tests only; " ++
            "the library behaves the same either way (default: false)",
    ) orelse false;

    const module = b.addModule(
        "datetime",
        .{
            .root_source_file = b.path("src/datetime.zig"),
            .target = target,
            .optimize = optimize,
        },
    );

    const locales_source = if (embed_locales)
        generateLocales(b)
    else
        b.path("src/locales/stub.zig");

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
    module.addImport("build_options", options.createModule());

    // The oracles below run on the machine doing the build, so they need
    // an instance of the library built for it: a cross-compiled one
    // cannot be linked into a host executable, and `zig build test
    // -Dtarget=...` would then fail on the oracle steps rather than on
    // anything to do with what is being tested. What they check --
    // formatting, parsing, the layouts -- is the same whatever the target,
    // so checking the host build is checking the same code.
    const host_module = if (target.query.isNative()) module else host: {
        const copy = b.createModule(.{
            .root_source_file = b.path("src/datetime.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        copy.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });
        copy.addAnonymousImport("locales", .{ .root_source_file = locales_source });
        copy.addImport("build_options", options.createModule());
        if (b.graph.host.result.os.tag == .windows) {
            if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
                copy.addImport("win32", zigwin32.module("win32"));
            }
        }
        break :host copy;
    };

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
        .root_source_file = b.path("src/datetime.zig"),
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

    // The format strings are modelled on moment.js, so moment is what
    // says whether they behave. `tools/oracle_dump.zig` formats a corpus
    // and `tools/oracle.js` asks moment the same questions and reports
    // every answer that differs.
    //
    // Part of `zig build test`, now that the two agree on every sequence:
    // a divergence from here on is a regression rather than a known gap.
    // It costs a fetch of moment the first time and a second of node
    // after that.
    const oracle_step = b.step(
        "oracle",
        "Check formatting against moment.js (needs the network on first run)",
    );

    if (b.lazyDependency("moment", .{})) |moment| {
        const oracle_dump = b.addExecutable(.{
            .name = "oracle-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/oracle_dump.zig"),
                // Built for the host: it runs here, now, as part of the
                // check, and never ships anywhere.
                .target = b.graph.host,
                .imports = &.{
                    .{ .name = "datetime", .module = host_module },
                },
            }),
        });

        const run_dump = b.addRunArtifact(oracle_dump);

        const run_oracle = b.addSystemCommand(&.{"node"});
        run_oracle.addFileArg(b.path("tools/oracle.js"));
        run_oracle.addFileArg(moment.path("moment.js"));
        run_oracle.addFileArg(run_dump.captureStdOut(.{ .basename = "corpus.tsv" }));

        // The report is the point of running this, so it goes to the
        // terminal rather than into the build runner's capture. Inheriting
        // stdio settles the exit code check too, which is why there is no
        // `expectExitCode` here: the two are mutually exclusive, and a
        // non-zero exit still fails the step.
        run_oracle.stdio = .inherit;

        // moment reads the machine's zone for anything it treats as local,
        // so the runner's own timezone would otherwise leak into the
        // comparison and make it depend on where it ran.
        run_oracle.setEnvironmentVariable("TZ", "UTC");

        oracle_step.dependOn(&run_oracle.step);
        test_step.dependOn(&run_oracle.step);

        // The same idea for parsing. It carries a short list of known
        // divergences, documented in the script, and fails on anything
        // else, so it is a gate against regressions rather than a survey.
        const parse_dump = b.addExecutable(.{
            .name = "oracle-parse-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/oracle_parse_dump.zig"),
                .target = b.graph.host,
                .imports = &.{
                    .{ .name = "datetime", .module = host_module },
                },
            }),
        });

        const run_parse_dump = b.addRunArtifact(parse_dump);

        const run_parse_oracle = b.addSystemCommand(&.{"node"});
        run_parse_oracle.addFileArg(b.path("tools/oracle_parse.js"));
        run_parse_oracle.addFileArg(moment.path("moment.js"));
        run_parse_oracle.addFileArg(run_parse_dump.captureStdOut(.{ .basename = "parse.tsv" }));
        run_parse_oracle.stdio = .inherit;
        run_parse_oracle.setEnvironmentVariable("TZ", "UTC");

        const parse_step = b.step(
            "oracle-parse",
            "Check parsing against moment.js, in both of its modes",
        );
        parse_step.dependOn(&run_parse_oracle.step);
        test_step.dependOn(&run_parse_oracle.step);

        // And the locales themselves, which are moment's own data read
        // out by `tools/gen_locales.js`. Only worth running when they
        // are there to check, so this asks for them rather than
        // depending on how the rest of the build was invoked: what it
        // compares is the table against its source, and that answer does
        // not change with `-Dembed-locales`.
        const locales_module = b.createModule(.{
            .root_source_file = b.path("src/datetime.zig"),
            .target = b.graph.host,
        });
        locales_module.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });
        locales_module.addAnonymousImport("locales", .{ .root_source_file = generateLocales(b) });
        locales_module.addImport("build_options", options.createModule());

        const locale_dump = b.addExecutable(.{
            .name = "oracle-locale-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/oracle_locale_dump.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "datetime", .module = locales_module },
                },
            }),
        });

        const run_locale_dump = b.addRunArtifact(locale_dump);

        const run_locale_oracle = b.addSystemCommand(&.{"node"});
        run_locale_oracle.addFileArg(b.path("tools/oracle_locale.js"));
        run_locale_oracle.addDirectoryArg(moment.path(""));
        run_locale_oracle.addFileArg(run_locale_dump.captureStdOut(.{ .basename = "locales.tsv" }));
        run_locale_oracle.stdio = .inherit;
        run_locale_oracle.setEnvironmentVariable("TZ", "UTC");

        const locale_step = b.step(
            "oracle-locale",
            "Check the embedded locales against moment.js's own",
        );
        locale_step.dependOn(&run_locale_oracle.step);
        test_step.dependOn(&run_locale_oracle.step);
    }

    // And the same again for Go's time layouts, against Go's own package.
    // No pinned dependency here: the layouts are part of the standard
    // library rather than something to fetch, so the version is whichever
    // `go` the dev shell carries, and the oracle prints it.
    const go_dump = b.addExecutable(.{
        .name = "oracle-go-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/oracle_go_dump.zig"),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "datetime", .module = host_module },
            },
        }),
    });

    const run_go_dump = b.addRunArtifact(go_dump);

    const run_go_oracle = b.addSystemCommand(&.{ "go", "run" });
    run_go_oracle.addFileArg(b.path("tools/oracle_go.go"));
    run_go_oracle.addFileArg(run_go_dump.captureStdOut(.{ .basename = "go.tsv" }));
    run_go_oracle.stdio = .inherit;

    // `go run` writes its build cache somewhere, and refuses to run at all
    // without a writable one. The Zig cache directory is already the
    // build's scratch space, so it goes there rather than in $HOME.
    run_go_oracle.setEnvironmentVariable("GOCACHE", b.pathFromRoot(".zig-cache/go"));
    run_go_oracle.setEnvironmentVariable("GOFLAGS", "-mod=mod");
    run_go_oracle.setEnvironmentVariable("TZ", "UTC");

    const go_step = b.step("oracle-go", "Check the Go layouts against Go's time package");
    go_step.dependOn(&run_go_oracle.step);
    test_step.dependOn(&run_go_oracle.step);
}

/// Builds the embedded locale table and returns the path of the generated
/// Zig source holding it.
///
/// The data is moment.js's own, read out of the locale files in the
/// package `build.zig.zon` pins, because moment is what this library's
/// formatting is checked against: a locale transcribed by hand would be a
/// divergence built in at the source. `tools/gen_locales.js` is where the
/// reading happens, and it needs the `node` the dev shell carries.
///
/// Nothing is fetched or run without `-Dembed-locales`, and `locale.en`
/// is built into the library rather than generated, so an ordinary build
/// neither needs moment nor node.
fn generateLocales(b: *std.Build) std.Build.LazyPath {
    const moment = b.lazyDependency("moment", .{}) orelse return b.path("src/locales/stub.zig");

    const run = b.addSystemCommand(&.{"node"});
    run.addFileArg(b.path("tools/gen_locales.js"));
    run.addDirectoryArg(moment.path(""));
    const generated = run.addOutputFileArg("locales.zig");

    return generated;
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
