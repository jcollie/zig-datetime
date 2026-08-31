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

    // The benchmarks always build ReleaseFast, independent of -Doptimize,
    // so they need their own instance of the module built the same way.
    const bench_datetime = b.createModule(.{
        .root_source_file = b.path("src/datetime.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_datetime.addAnonymousImport("tzdata", .{ .root_source_file = tzdata_source });

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
