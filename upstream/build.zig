// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Everything that reads an upstream source: the two table generators and
//! the oracles.
//!
//! Its own project, because of what a declared dependency costs. moment and
//! the three CLDR packages are 143 MB, and `zon2nix` -- or anything else that
//! reads a manifest rather than running a build -- reads every entry in it
//! whether the build ever calls for that package or not. Guarding the
//! `b.lazyDependency` call is not enough; the entry has to be somewhere else.
//! Here is somewhere else.
//!
//! The library comes from the checkout this sits inside, by path, so the two
//! are always the same code.
//!
//!     zig build gen-cldr      regenerate ../src/cldrlocales/all.zig
//!     zig build gen-locales   regenerate ../src/locales/all.zig
//!     zig build test          every oracle
//!
//! An oracle checks this library's answers against the implementation they
//! were modelled on -- moment.js, Go's `time`, ICU, the C library -- rather
//! than against what somebody remembered of it.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.graph.host;

    // The library as it ships, and the library with each of the two
    // generated tables compiled in. The oracles that check a table ask for
    // it outright rather than depending on how this build was invoked: what
    // they compare is the committed table against its source, and that
    // answer does not change with anybody's `-Dembed-*`.
    const plain = b.dependency("datetime", .{ .target = host }).module("datetime");
    const with_locales = b.dependency("datetime", .{
        .target = host,
        .@"embed-locales" = true,
    }).module("datetime");
    const with_cldr = b.dependency("datetime", .{
        .target = host,
        .@"embed-cldr" = true,
    }).module("datetime");

    const test_step = b.step("test", "Run every oracle");

    // -- generating ----------------------------------------------------------
    //
    // Both tables are committed, so these are a maintainer's errand: run when
    // moment or CLDR makes a release, with the diff reviewed like any other.
    //
    // The generators write into the library's source tree, which is a
    // directory above this one, so they run with that as their working
    // directory and are given a path relative to it.
    const gen_locales_step = b.step(
        "gen-locales",
        "Regenerate ../src/locales/all.zig from moment.js's locale files",
    );
    if (b.lazyDependency("moment", .{})) |moment| {
        const run = b.addSystemCommand(&.{"node"});
        run.addFileArg(b.path("src/gen_locales.js"));
        run.addDirectoryArg(moment.path(""));
        run.addArg("src/locales/all.zig");
        run.setCwd(b.path(".."));
        run.stdio = .inherit;
        run.has_side_effects = true;
        gen_locales_step.dependOn(&run.step);
    }

    const gen_cldr_step = b.step(
        "gen-cldr",
        "Regenerate ../src/cldrlocales/all.zig from the Unicode CLDR",
    );
    if (b.lazyDependency("cldr_core", .{})) |core| {
        if (b.lazyDependency("cldr_dates", .{})) |dates| {
            if (b.lazyDependency("cldr_numbers", .{})) |numbers| {
                const run = b.addSystemCommand(&.{"node"});
                run.addFileArg(b.path("src/gen_cldr.js"));
                run.addDirectoryArg(core.path(""));
                run.addDirectoryArg(dates.path(""));
                run.addDirectoryArg(numbers.path(""));
                run.addArg("src/cldrlocales/all.zig");
                // Every locale: the table is generated once and committed,
                // so narrowing it here would narrow it for everybody.
                // `-Dcldr-locales` narrows what a build compiles instead.
                run.addArg("");
                run.setCwd(b.path(".."));
                run.stdio = .inherit;
                run.has_side_effects = true;
                gen_cldr_step.dependOn(&run.step);
            }
        }
    }

    // -- moment --------------------------------------------------------------

    const oracle_step = b.step(
        "oracle",
        "Check formatting against moment.js",
    );
    const parse_step = b.step(
        "oracle-parse",
        "Check parsing against moment.js, in both of its modes",
    );
    const locale_step = b.step(
        "oracle-locale",
        "Check the embedded locales against moment.js's own",
    );

    if (b.lazyDependency("moment", .{})) |moment| {
        // The format strings are modelled on moment.js, so moment is what
        // says whether they behave. `src/oracle_dump.zig` formats a corpus
        // and `src/oracle.js` asks moment the same questions and reports
        // every answer that differs.
        const dump = b.addExecutable(.{
            .name = "oracle-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/oracle_dump.zig"),
                // Built for the host: it runs here, now, as part of the
                // check, and never ships anywhere.
                .target = host,
                .imports = &.{.{ .name = "datetime", .module = plain }},
            }),
        });
        const run_dump = b.addRunArtifact(dump);

        const run_oracle = b.addSystemCommand(&.{"node"});
        run_oracle.addFileArg(b.path("src/oracle.js"));
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
        // divergences, documented in the script, and fails on anything else,
        // so it is a gate against regressions rather than a survey.
        const parse_dump = b.addExecutable(.{
            .name = "oracle-parse-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/oracle_parse_dump.zig"),
                .target = host,
                .imports = &.{.{ .name = "datetime", .module = plain }},
            }),
        });
        const run_parse_dump = b.addRunArtifact(parse_dump);

        const run_parse = b.addSystemCommand(&.{"node"});
        run_parse.addFileArg(b.path("src/oracle_parse.js"));
        run_parse.addFileArg(moment.path("moment.js"));
        run_parse.addFileArg(run_parse_dump.captureStdOut(.{ .basename = "parse.tsv" }));
        run_parse.stdio = .inherit;
        run_parse.setEnvironmentVariable("TZ", "UTC");
        parse_step.dependOn(&run_parse.step);
        test_step.dependOn(&run_parse.step);

        // And the locales themselves, which are moment's own data as
        // `src/gen_locales.js` read it out.
        const locale_dump = b.addExecutable(.{
            .name = "oracle-locale-dump",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/oracle_locale_dump.zig"),
                .target = host,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "datetime", .module = with_locales }},
            }),
        });
        const run_locale_dump = b.addRunArtifact(locale_dump);

        const run_locale = b.addSystemCommand(&.{"node"});
        run_locale.addFileArg(b.path("src/oracle_locale.js"));
        run_locale.addDirectoryArg(moment.path(""));
        run_locale.addFileArg(run_locale_dump.captureStdOut(.{ .basename = "locales.tsv" }));
        run_locale.stdio = .inherit;
        run_locale.setEnvironmentVariable("TZ", "UTC");
        locale_step.dependOn(&run_locale.step);
        test_step.dependOn(&run_locale.step);
    }

    // -- Go ------------------------------------------------------------------
    //
    // No pinned dependency here: the layouts are part of the standard library
    // rather than something to fetch, so the version is whichever `go` the
    // dev shell carries, and the oracle prints it.
    const go_dump = b.addExecutable(.{
        .name = "oracle-go-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle_go_dump.zig"),
            .target = host,
            .imports = &.{.{ .name = "datetime", .module = plain }},
        }),
    });
    const run_go_dump = b.addRunArtifact(go_dump);

    const run_go = b.addSystemCommand(&.{ "go", "run" });
    run_go.addFileArg(b.path("src/oracle_go.go"));
    run_go.addFileArg(run_go_dump.captureStdOut(.{ .basename = "go.tsv" }));
    run_go.stdio = .inherit;
    // `go run` writes its build cache somewhere, and refuses to run at all
    // without a writable one. The Zig cache directory is already the build's
    // scratch space, so it goes there rather than in $HOME.
    run_go.setEnvironmentVariable("GOCACHE", b.pathFromRoot(".zig-cache/go"));
    run_go.setEnvironmentVariable("GOFLAGS", "-mod=mod");
    run_go.setEnvironmentVariable("TZ", "UTC");

    const go_step = b.step("oracle-go", "Check the Go layouts against Go's time package");
    go_step.dependOn(&run_go.step);
    test_step.dependOn(&run_go.step);

    // -- ICU -----------------------------------------------------------------
    //
    // ICU is the reference implementation of UTS #35. No pinned dependency for
    // the oracle itself: ICU comes from the dev shell and the oracle prints
    // which release it was, the way the Go one prints its toolchain.
    //
    // The C++ is compiled by Zig rather than by a separate toolchain, so the
    // dev shell needs ICU and pkg-config and nothing more. Zig finds the
    // library through pkg-config, which is why `icu-i18n` is spelled the way
    // the `.pc` file names it rather than the way the linker does.
    const cldr_dump = b.addExecutable(.{
        .name = "oracle-cldr-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle_cldr_dump.zig"),
            .target = host,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "datetime", .module = with_cldr }},
        }),
    });

    const cldr_oracle_module = b.createModule(.{
        .target = host,
        .optimize = .ReleaseFast,
        .link_libcpp = true,
    });
    cldr_oracle_module.addCSourceFile(.{
        .file = b.path("src/oracle_cldr.cpp"),
        .language = .cpp,
        .flags = &.{"-std=c++17"},
    });
    cldr_oracle_module.linkSystemLibrary("icu-i18n", .{});
    cldr_oracle_module.linkSystemLibrary("icu-uc", .{});

    const cldr_oracle = b.addExecutable(.{
        .name = "oracle-cldr",
        .root_module = cldr_oracle_module,
    });

    const run_cldr_dump = b.addRunArtifact(cldr_dump);
    const run_cldr = b.addRunArtifact(cldr_oracle);
    run_cldr.addFileArg(run_cldr_dump.captureStdOut(.{ .basename = "cldr.tsv" }));
    run_cldr.stdio = .inherit;
    run_cldr.setEnvironmentVariable("TZ", "UTC");

    const cldr_step = b.step("oracle-cldr", "Check the CLDR patterns against ICU");
    cldr_step.dependOn(&run_cldr.step);
    test_step.dependOn(&run_cldr.step);

    // -- the C library -------------------------------------------------------
    //
    // Nothing is fetched and nothing is added to the dev shell: the oracle is
    // C, the C library is already there, and Zig compiles the one and links
    // the other.
    //
    // It runs only where there is a libc to ask. A Windows host has
    // `strftime` but no `strptime`, no `tm_gmtoff` and no `tm_zone`, so the
    // comparison there would be against a different function; the step is
    // declared everywhere and only joins `test` on a platform whose libc is
    // the one being followed.
    const strftime_dump = b.addExecutable(.{
        .name = "oracle-strftime-dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle_strftime_dump.zig"),
            .target = host,
            .imports = &.{.{ .name = "datetime", .module = plain }},
        }),
    });

    const strftime_oracle_module = b.createModule(.{
        .target = host,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    strftime_oracle_module.addCSourceFile(.{
        .file = b.path("src/oracle_strftime.c"),
        .language = .c,
        .flags = &.{"-std=c11"},
    });

    const strftime_oracle = b.addExecutable(.{
        .name = "oracle-strftime",
        .root_module = strftime_oracle_module,
    });

    const run_strftime_dump = b.addRunArtifact(strftime_dump);
    const run_strftime = b.addRunArtifact(strftime_oracle);
    run_strftime.addFileArg(run_strftime_dump.captureStdOut(.{ .basename = "strftime.tsv" }));
    run_strftime.stdio = .inherit;
    // `%s` and `%Z` are the two conversions that reach for the process's own
    // timezone in glibc, so the process is given one it cannot be surprised
    // by.
    run_strftime.setEnvironmentVariable("TZ", "UTC");

    const strftime_step = b.step(
        "oracle-strftime",
        "Check the strftime conversions against the C library",
    );
    strftime_step.dependOn(&run_strftime.step);
    if (host.result.os.tag != .windows) test_step.dependOn(&run_strftime.step);
}
