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
//! `zig build oracle-parse` does the same for parsing, against both of
//! moment's parsing modes at once. That one is a survey rather than a
//! gate: the two do not agree yet, so it reports and returns success, and
//! `test` does not depend on it.
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

    // The stub sits in a directory of its own because a module takes its
    // whole containing directory with it. Left in src/ it would make a
    // second module out of every file here, which turns up in the
    // generated documentation as a duplicate of the entire library.
    const tzdata_source = if (embed_tzdata)
        generateTzdata(b, tz_packing, tz_from)
    else
        b.path("src/tzdata/stub.zig");

    module.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });

    const options = b.addOptions();
    options.addOption(bool, "no_system_tzdata", no_system_tzdata);
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
        .root_source_file = b.path("src/datetime.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_datetime.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });
    bench_datetime.addImport("build_options", options.createModule());

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
                    .{ .name = "datetime", .module = module },
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

        // The same idea for parsing, which is a survey rather than a gate:
        // the two have not been made to agree yet, so this reports where
        // they stand instead of failing, and `test` does not depend on it.
        const parse_dump = b.addExecutable(.{
            .name = "oracle-parse-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/oracle_parse_dump.zig"),
                .target = b.graph.host,
                .imports = &.{
                    .{ .name = "datetime", .module = module },
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
            "Survey this library's parsing against moment.js",
        );
        parse_step.dependOn(&run_parse_oracle.step);
    }
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
