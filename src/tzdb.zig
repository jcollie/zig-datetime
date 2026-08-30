//! Sources of timezone data.
//!
//! `system` reads the operating system's copy of the IANA database, the
//! TZif tree that lives under `/usr/share/zoneinfo` on most systems.
//! `embedded` reads a copy compiled into the binary at build time, which
//! needs no filesystem and no allocator but has to be asked for with
//! `-Dembed-tzdata`. See `build.zig`.

const std = @import("std");

const TimeZone = @import("TimeZone.zig");
const generated = @import("tzdata");

pub const InvalidNameError = error{InvalidZoneName};

/// Checks that `name` is a plausible IANA zone name before it is used to
/// build a path. Zone names reach this code from configuration and from
/// the `TZ` environment variable, so a name that walks out of the zone
/// directory has to be refused rather than opened.
pub fn validateName(name: []const u8) InvalidNameError!void {
    if (name.len == 0 or name.len > 256) return error.InvalidZoneName;
    if (name[0] == '/' or name[0] == '.') return error.InvalidZoneName;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidZoneName;

    for (name) |char| switch (char) {
        'A'...'Z', 'a'...'z', '0'...'9', '/', '_', '-', '+' => {},
        else => return error.InvalidZoneName,
    };
}

/// The operating system's copy of the IANA database.
///
/// Which directory holds that copy, and which zone the user wants, are
/// both answered by environment variables. This library does not read
/// them: in Zig 0.16 a program receives its environment through the
/// `std.process.Init` passed to `main`, and a library that went looking
/// for it behind the caller's back would have to reach for globals. So
/// the caller reads the environment and passes the answer in.
///
/// The two variables are `TZDIR`, the directory, and `TZ`, the zone:
///
/// ```zig
/// pub fn main(init: std.process.Init) !void {
///     const directory = init.environ_map.get("TZDIR") orelse
///         datetime.tzdb.system.default_directory;
///
///     var zone = try datetime.tzdb.system.load(
///         init.io,
///         init.gpa,
///         directory,
///         "America/Chicago",
///     );
///     defer zone.deinit(init.gpa);
/// }
/// ```
///
/// See `resolveTz` for what the `TZ` variable can hold, and `load` and
/// `loadLocal` for the two ways in.
pub const system = struct {
    /// Where the TZif tree lives on most Unix systems, used when `TZDIR`
    /// is unset. Some systems put it elsewhere: NixOS uses
    /// `/etc/zoneinfo`, and a few older Unixes use `/usr/lib/zoneinfo` or
    /// `/usr/share/lib/zoneinfo`. A program that wants to work on all of
    /// them should read `TZDIR` first and fall back to trying these in
    /// turn, as `search_directories` lists them.
    pub const default_directory = "/usr/share/zoneinfo";

    /// The places a TZif tree is commonly found, in the order worth
    /// trying when `TZDIR` is unset and the first guess misses.
    pub const search_directories = [_][]const u8{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    };

    /// Where the symlink or copy naming the machine's own zone lives,
    /// used by `loadLocal` when `TZ` is unset.
    pub const default_localtime = "/etc/localtime";

    /// What a `TZ` environment variable is asking for.
    pub const Tz = union(enum) {
        /// `TZ` was unset: use the machine's own zone, which is what
        /// `loadLocal` reads out of `/etc/localtime`.
        local,
        /// `TZ` was set but empty, which POSIX defines as UTC.
        utc,
        /// Something that can name a zone under `TZDIR`, such as
        /// "America/Chicago". Pass it to `load`.
        ///
        /// If no such file exists, this may instead be a POSIX rule that
        /// happens to look like a name, so fall back to `posixtz.parse`
        /// rather than treating the missing file as fatal. See
        /// `resolveTz` for why the two cannot always be told apart.
        name: []const u8,
        /// An absolute path to a TZif file, which bypasses `TZDIR`
        /// entirely. Pass it to `loadLocal`, which takes a path.
        path: []const u8,
        /// A POSIX rule, such as "CST6CDT,M3.2.0,M11.1.0". No zone is
        /// named like this, so there is no file to look for: hand it
        /// straight to `posixtz.parse`.
        rule: []const u8,
    };

    /// Works out what a `TZ` value is asking for, without touching the
    /// filesystem. Pass `null` when the variable is unset.
    ///
    /// `TZ` is not simply a zone name. It may also be an absolute path to
    /// a TZif file, or a complete POSIX rule such as
    /// "CST6CDT,M3.2.0,M11.1.0" that names no file at all; and by a
    /// convention going back to the original tzcode, a leading colon
    /// introduces something implementation-defined, which in practice
    /// means a name or a path.
    ///
    /// The value is classified by these steps, in order:
    ///
    /// 1. No value at all is `.local`, meaning the machine's own zone.
    /// 2. An empty value is `.utc`, which is what POSIX says it means.
    /// 3. A leading colon is stripped and ignored. It only ever says
    ///    "this is not a rule", which the remaining steps work out
    ///    anyway, and a value of just ":" is treated as empty.
    /// 4. A value starting with "/" is a `.path`. A zone name is always
    ///    relative to `TZDIR`, so a leading slash can only be a file.
    /// 5. A value containing "," or starting with "<" is a `.rule`.
    ///    These are the two things a rule can contain that a zone name
    ///    never does: the comma before its switch dates, and the angle
    ///    brackets around a numeric abbreviation like "<+0530>".
    /// 6. Anything else is a `.name`.
    ///
    /// Step 6 is deliberately generous, because a rule and a name cannot
    /// always be told apart by looking. "EST5EDT", "MST7MDT", "GMT0" and
    /// every "Etc/GMT+5" are real zone names, and each is also a
    /// well-formed POSIX rule meaning about the same thing. Guessing from
    /// the shape of the text gets all forty of them wrong, so this does
    /// what glibc and musl do instead: assume a name, and leave the
    /// caller to fall back to `posixtz.parse` when no such file turns up.
    /// That resolves the ambiguity with the only evidence that settles
    /// it, which is whether the file exists.
    ///
    /// ```zig
    /// const zone = switch (system.resolveTz(init.environ_map.get("TZ"))) {
    ///     .local => try system.loadLocal(io, gpa, null),
    ///     .path => |path| try system.loadLocal(io, gpa, path),
    ///     .name => |name| system.load(io, gpa, directory, name) catch |err| switch (err) {
    ///         // Not a zone after all, so try it as a rule.
    ///         error.FileNotFound => return parseAsRule(name),
    ///         else => return err,
    ///     },
    ///     .rule => |rule| return parseAsRule(rule),
    ///     .utc => ...,
    /// };
    /// ```
    pub fn resolveTz(value: ?[]const u8) Tz {
        const text = value orelse return .local;
        if (text.len == 0) return .utc;

        const body = if (text[0] == ':') text[1..] else text;
        if (body.len == 0) return .utc;

        if (body[0] == '/') return .{ .path = body };

        // The only two marks a POSIX rule carries that no zone name does.
        if (body[0] == '<') return .{ .rule = body };
        if (std.mem.indexOfScalar(u8, body, ',') != null) return .{ .rule = body };

        return .{ .name = body };
    }

    /// A TZif file for a single zone is a few kilobytes at most; the
    /// largest in the 2026c release is well under 32 KiB.
    const size_limit: std.Io.Limit = .limited(1 << 20);

    /// Returns the release the tree in `directory` was compiled from,
    /// such as "2026c", or null when the tree does not record one. The
    /// caller owns the returned slice.
    ///
    /// A TZif file carries no version at all, so the only thing in a
    /// zoneinfo tree that names the release is the first line of
    /// `tzdata.zi`, the single file form of zic's own input, which most
    /// distributions ship alongside the compiled zones. Systems that
    /// leave it out cannot be asked.
    pub fn version(
        io: std.Io,
        gpa: std.mem.Allocator,
        directory: []const u8,
    ) (std.mem.Allocator.Error || error{})!?[]const u8 {
        const path = try std.fs.path.join(gpa, &.{ directory, "tzdata.zi" });
        defer gpa.free(path);

        // The whole file is read for the sake of its first line, which is
        // wasteful but keeps this to one call; it is a hundred kilobytes
        // or so and this is not on any hot path.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 24)) catch return null;
        defer gpa.free(bytes);

        const line = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len];
        const prefix = "# version ";
        if (!std.mem.startsWith(u8, line, prefix)) return null;

        const found = std.mem.trim(u8, line[prefix.len..], " \t\r");
        if (found.len == 0) return null;
        return try gpa.dupe(u8, found);
    }

    pub const LoadError = InvalidNameError ||
        std.Io.Dir.ReadFileAllocError ||
        TimeZone.Error ||
        std.mem.Allocator.Error;

    /// Loads the named zone, such as "America/Chicago", from `directory`.
    ///
    /// `directory` is the TZif tree: pass the `TZDIR` environment
    /// variable if it is set, and `default_directory` otherwise. See the
    /// `system` namespace for the whole pattern.
    ///
    /// `name` is validated before it is joined onto `directory`, so a
    /// value taken straight from `TZ` cannot walk out of the tree.
    ///
    /// The returned zone owns its data and must be released with
    /// `TimeZone.deinit`.
    pub fn load(
        io: std.Io,
        gpa: std.mem.Allocator,
        directory: []const u8,
        name: []const u8,
    ) LoadError!TimeZone {
        try validateName(name);

        const path = try std.fs.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, size_limit);
        errdefer gpa.free(bytes);

        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);

        return TimeZone.fromOwnedBytes(owned_name, bytes);
    }

    /// Loads a zone from a TZif file directly, rather than by name.
    ///
    /// With `path` null this reads `/etc/localtime`, which is the
    /// machine's own zone and the right answer when `TZ` is unset. It
    /// also takes the absolute path out of a `TZ` value that holds one.
    ///
    /// The zone is called "localtime" whatever the path, because a TZif
    /// file does not record which zone it is a copy of. A caller that
    /// needs the real name has to get it from `TZ`, or by reading where
    /// `/etc/localtime` points.
    pub fn loadLocal(
        io: std.Io,
        gpa: std.mem.Allocator,
        path: ?[]const u8,
    ) LoadError!TimeZone {
        const from = path orelse default_localtime;

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, from, gpa, size_limit);
        errdefer gpa.free(bytes);

        const owned_name = try gpa.dupe(u8, "localtime");
        errdefer gpa.free(owned_name);

        return TimeZone.fromOwnedBytes(owned_name, bytes);
    }
};

/// The copy of the database compiled into this binary.
pub const embedded = struct {
    /// The IANA release the embedded data was generated from, such as
    /// "2026c". Empty when the build did not embed any.
    pub const version = generated.version;

    /// Whether this build has embedded data at all.
    pub const available = generated.entries.len > 0;

    /// The `zic -r` argument the data was trimmed to with
    /// `-Dtzdata-from`, empty when the full history was kept. Instants
    /// before this point are not described by the embedded data.
    pub const history_from = generated.history_from;

    /// The names of every embedded zone, sorted.
    pub fn names(buffer: []([]const u8)) [][]const u8 {
        const wanted = @min(buffer.len, generated.entries.len);
        for (generated.entries[0..wanted], buffer[0..wanted]) |entry, *slot| {
            slot.* = entry.name;
        }
        return buffer[0..wanted];
    }

    /// The number of embedded zones.
    pub fn count() usize {
        return generated.entries.len;
    }

    /// Looks up a zone by name. Needs no allocator, because the data is
    /// already in the binary and the zone borrows it. Returns null if the
    /// build has no embedded data or does not include this zone.
    pub fn load(name: []const u8) TimeZone.Error!?TimeZone {
        const entry = find(name) orelse return null;
        return try TimeZone.fromBytes(
            entry.name,
            generated.blob[entry.start..][0..entry.len],
        );
    }

    fn find(name: []const u8) ?generated.Entry {
        var low: usize = 0;
        var high: usize = generated.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, generated.entries[mid].name, name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return generated.entries[mid],
            }
        }
        return null;
    }
};

const testing = std.testing;

test "zone names are checked before they become paths" {
    for ([_][]const u8{
        "UTC",
        "America/Chicago",
        "America/North_Dakota/Center",
        "Etc/GMT+5",
        "US/Central",
    }) |name| {
        try validateName(name);
    }

    for ([_][]const u8{
        "",
        // A name that walks out of the zone directory.
        "../../etc/passwd",
        "America/../../etc/passwd",
        "..",
        // An absolute path, which would ignore the directory entirely.
        "/etc/passwd",
        // A leading dot, which is how the traversal above starts.
        ".hidden",
        // Characters that have no business in a zone name.
        "America/Chicago\x00",
        "America/Chi cago",
        "America/Chicago;rm",
    }) |name| {
        try testing.expectError(error.InvalidZoneName, validateName(name));
    }
}

test "the system database loads a zone" {
    const directories = [_][]const u8{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    };

    for (directories) |directory| {
        var zone = system.load(testing.io, testing.allocator, directory, "America/Chicago") catch continue;
        defer zone.deinit(testing.allocator);

        try testing.expectEqualStrings("America/Chicago", zone.name);
        try testing.expectEqual(@as(i32, -21600), zone.offsetAt(1705320000));
        try testing.expectEqual(@as(i32, -18000), zone.offsetAt(1721044800));

        // A name that escapes the directory is refused before any file is
        // opened, whatever the directory happens to be.
        try testing.expectError(
            error.InvalidZoneName,
            system.load(testing.io, testing.allocator, directory, "../../etc/passwd"),
        );
        return;
    }
    return error.SkipZigTest;
}

test "the embedded database loads a zone" {
    // Only built with -Dembed-tzdata; without it there is nothing to test.
    if (!embedded.available) return error.SkipZigTest;

    try testing.expect(embedded.count() > 300);
    try testing.expect(embedded.version.len > 0);

    var zone = (try embedded.load("America/Chicago")).?;
    // No allocator was involved, because the data is already in the
    // binary and the zone borrows it.
    defer zone.deinit(testing.allocator);

    try testing.expectEqualStrings("America/Chicago", zone.name);
    try testing.expectEqual(@as(i32, -21600), zone.offsetAt(1705320000));
    try testing.expectEqual(@as(i32, -18000), zone.offsetAt(1721044800));
    // Beyond the last stored transition, which slim packing leaves to the
    // POSIX rule in the footer.
    try testing.expectEqual(@as(i32, -18000), zone.offsetAt(4086590400));

    // Links from retired names resolve too, because the `backward` file
    // is compiled in along with the rest.
    var link = (try embedded.load("US/Central")).?;
    defer link.deinit(testing.allocator);
    try testing.expectEqual(zone.offsetAt(1721044800), link.offsetAt(1721044800));

    try testing.expectEqual(@as(?TimeZone, null), try embedded.load("Mars/Olympus_Mons"));
}

test "the embedded and system databases agree" {
    if (!embedded.available) return error.SkipZigTest;

    const directories = [_][]const u8{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    };

    // Only worth comparing when both sides are the same release. The two
    // legitimately disagree otherwise, which is the normal state of
    // affairs while a tzdata update is being prepared: the embedded copy
    // is the new release and the machine's is whatever it had.
    const matching = matching: {
        for (directories) |directory| {
            const found = (try system.version(testing.io, testing.allocator, directory)) orelse continue;
            defer testing.allocator.free(found);
            if (std.mem.eql(u8, found, embedded.version)) break :matching true;
        }
        break :matching false;
    };
    if (!matching) return error.SkipZigTest;

    const names = [_][]const u8{
        "America/Chicago",
        "Europe/Berlin",
        "Asia/Kolkata",
        "Australia/Lord_Howe",
        "Pacific/Chatham",
        "America/Sao_Paulo",
    };

    // A build may have been asked to drop early history, in which case
    // the two databases are meant to disagree before the cutoff.
    const cutoff: i64 = if (embedded.history_from.len == 0)
        std.math.minInt(i64)
    else if (embedded.history_from[0] == '@')
        std.fmt.parseInt(i64, embedded.history_from[1..], 10) catch return error.SkipZigTest
    else
        return error.SkipZigTest;

    // Sampled across a century, which reaches from local mean time to
    // well past the last stored transition.
    var probes: [140]i64 = undefined;
    for (&probes, 0..) |*probe, index| {
        probe.* = -2208988800 + @as(i64, @intCast(index)) * (2 * std.time.s_per_day * 365);
    }

    for (directories) |directory| {
        var compared: usize = 0;
        for (names) |name| {
            var from_system = system.load(testing.io, testing.allocator, directory, name) catch continue;
            defer from_system.deinit(testing.allocator);

            var from_binary = (try embedded.load(name)) orelse continue;
            defer from_binary.deinit(testing.allocator);

            for (probes) |at| {
                if (at < cutoff) continue;
                try testing.expectEqual(from_system.offsetAt(at), from_binary.offsetAt(at));
                try testing.expectEqualStrings(
                    from_system.typeAt(at).designation,
                    from_binary.typeAt(at).designation,
                );
                compared += 1;
            }
        }
        if (compared > 0) return;
    }
    return error.SkipZigTest;
}

test "TZ values are sorted into what they ask for" {
    const Tz = system.Tz;

    // Unset means the machine's own zone.
    try testing.expectEqual(Tz.local, system.resolveTz(null));
    // Set but empty means UTC, as does a bare colon.
    try testing.expectEqual(Tz.utc, system.resolveTz(""));
    try testing.expectEqual(Tz.utc, system.resolveTz(":"));

    // Zone names, with and without the conventional leading colon.
    try testing.expectEqualStrings("America/Chicago", system.resolveTz("America/Chicago").name);
    try testing.expectEqualStrings("America/Chicago", system.resolveTz(":America/Chicago").name);
    try testing.expectEqualStrings("UTC", system.resolveTz("UTC").name);
    try testing.expectEqualStrings("US/Central", system.resolveTz("US/Central").name);

    // Absolute paths bypass TZDIR.
    try testing.expectEqualStrings("/etc/localtime", system.resolveTz("/etc/localtime").path);
    try testing.expectEqualStrings(
        "/usr/share/zoneinfo/America/Chicago",
        system.resolveTz(":/usr/share/zoneinfo/America/Chicago").path,
    );

    // Rules, recognised by the comma before their switch dates or by the
    // angle brackets around a numeric abbreviation.
    try testing.expectEqualStrings("CST6CDT,M3.2.0,M11.1.0", system.resolveTz("CST6CDT,M3.2.0,M11.1.0").rule);
    try testing.expectEqualStrings("EST5EDT,M3.2.0/2,M11.1.0/2", system.resolveTz("EST5EDT,M3.2.0/2,M11.1.0/2").rule);
    try testing.expectEqualStrings(
        "<+1030>-10:30<+11>-11,M10.1.0,M4.1.0",
        system.resolveTz("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0").rule,
    );
    try testing.expectEqualStrings("<-03>3", system.resolveTz("<-03>3").rule);

    // These are all real zone names, and all of them are also well formed
    // POSIX rules. They come back as names so that the file on disk gets
    // the first say, which is the only thing that can settle it.
    for ([_][]const u8{
        "Etc/GMT+5",
        "Etc/GMT-14",
        "Etc/GMT0",
        "GMT0",
        "GMT+0",
        "CST6CDT",
        "EST5EDT",
        "MST7MDT",
        "PST8PDT",
    }) |ambiguous| {
        try testing.expectEqualStrings(ambiguous, system.resolveTz(ambiguous).name);
        // And each really is a name this library would accept.
        try validateName(system.resolveTz(ambiguous).name);
    }

    // A rule that looks like a name is reported as a name, and only turns
    // out to be a rule when no such file exists. "EST5" names no zone.
    try testing.expectEqualStrings("EST5", system.resolveTz("EST5").name);

    // A definite rule really parses, and a name really validates.
    try posixtzTest(system.resolveTz("CST6CDT,M3.2.0,M11.1.0").rule);
    try validateName(system.resolveTz("America/Chicago").name);
}

fn posixtzTest(rule: []const u8) !void {
    const parsed = try @import("posixtz.zig").parse(rule);
    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), parsed.std_offset);
}

test "the system database reports which release it was built from" {
    const directories = [_][]const u8{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    };

    for (directories) |directory| {
        const found = (try system.version(testing.io, testing.allocator, directory)) orelse continue;
        defer testing.allocator.free(found);

        // A release is four digits and a lower case letter, as in 2026c.
        try testing.expectEqual(@as(usize, 5), found.len);
        for (found[0..4]) |char| try testing.expect(std.ascii.isDigit(char));
        try testing.expect(std.ascii.isLower(found[4]));
        return;
    }
    // No tree on this machine records one, which is allowed.
    return error.SkipZigTest;
}
