// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Sources of timezone data.
//!
//! `system` reads the operating system's copy of the IANA database, the
//! TZif tree that lives under `/usr/share/zoneinfo` on most systems.
//! `embedded` reads a copy compiled into the binary at build time, which
//! needs no filesystem and no allocator but has to be asked for with
//! `-Dembed-tzdata`. See `build.zig`.
//!
//! Windows has no such tree, and `system.available` says so. It keeps its
//! own zones under its own names, so `windows` asks it which one the
//! machine is set to and translates the answer to an IANA name; the data
//! itself still has to come from `embedded`.

const builtin = @import("builtin");
const std = @import("std");

const TimeZone = @import("TimeZone.zig");
const generated = @import("tzdata");
const windowszones = @import("windowszones.zig");

/// What `validateName` rejects a zone name with.
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

test validateName {
    // Ordinary IANA names, including the `Etc/GMT+5` family and the
    // legacy `US/Central` spellings, all pass.
    try validateName("UTC");
    try validateName("America/Chicago");
    try validateName("Etc/GMT+5");
    try validateName("US/Central");

    // A name arriving from `TZ` must not be able to walk out of the zone
    // directory or name an absolute path, since it becomes one.
    try std.testing.expectError(error.InvalidZoneName, validateName("../../etc/passwd"));
    try std.testing.expectError(error.InvalidZoneName, validateName("/etc/passwd"));
    try std.testing.expectError(error.InvalidZoneName, validateName(".hidden"));
    try std.testing.expectError(error.InvalidZoneName, validateName(""));
    try std.testing.expectError(error.InvalidZoneName, validateName("America/Chicago\x00"));
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
    /// Whether this target keeps a TZif tree at all.
    ///
    /// False on Windows, which has no such tree: it holds its own zone
    /// data in the registry, in its own format, under its own names. Every
    /// path named here is a Unix one, so on Windows there is nothing for
    /// them to point at, `search_directories` is empty, and `load`,
    /// `loadLocal` and `version` refuse rather than opening a path that
    /// cannot exist.
    ///
    /// A program that has to work on both branches at comptime rather
    /// than finding out at run time:
    ///
    /// ```zig
    /// var zone = if (datetime.tzdb.system.available)
    ///     try datetime.tzdb.system.loadLocal(io, gpa, null)
    /// else
    ///     try datetime.tzdb.windows.loadLocal();
    /// ```
    ///
    /// See `windows` for the other half of that, and note that it needs
    /// `-Dembed-tzdata`, since the data has to come from somewhere.
    pub const available = builtin.os.tag != .windows;

    /// Where the TZif tree lives on most Unix systems, used when `TZDIR`
    /// is unset. Some systems put it elsewhere: NixOS uses
    /// `/etc/zoneinfo`, and a few older Unixes use `/usr/lib/zoneinfo` or
    /// `/usr/share/lib/zoneinfo`. A program that wants to work on all of
    /// them should read `TZDIR` first and fall back to trying these in
    /// turn, as `search_directories` lists them.
    ///
    /// Named on every target, so that a program can print what it would
    /// have looked for; it is only somewhere to look when `available`.
    pub const default_directory = "/usr/share/zoneinfo";

    /// The places a TZif tree is commonly found, in the order worth
    /// trying when `TZDIR` is unset and the first guess misses.
    ///
    /// Empty where `available` is false, so that a program written as a
    /// loop over this list does nothing at all rather than failing four
    /// times over on paths that no target of that kind has.
    pub const search_directories: []const []const u8 = if (available) &.{
        "/usr/share/zoneinfo",
        "/etc/zoneinfo",
        "/usr/lib/zoneinfo",
        "/usr/share/lib/zoneinfo",
    } else &.{};

    /// Where the symlink or copy naming the machine's own zone lives,
    /// used by `loadLocal` when `TZ` is unset. As with
    /// `default_directory`, it is only a real path when `available`.
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

    test resolveTz {
        // Unset means the machine's own zone; set but empty means UTC.
        try std.testing.expectEqual(Tz.local, resolveTz(null));
        try std.testing.expectEqual(Tz.utc, resolveTz(""));

        // A leading colon is the tzcode convention for "implementation
        // defined", and is dropped before the rest is classified.
        try std.testing.expectEqualStrings("America/Chicago", resolveTz("America/Chicago").name);
        try std.testing.expectEqualStrings("America/Chicago", resolveTz(":America/Chicago").name);

        // An absolute path bypasses TZDIR entirely.
        try std.testing.expectEqualStrings("/etc/localtime", resolveTz("/etc/localtime").path);

        // A rule names no file, so there is nothing to look for. Note
        // that `Etc/GMT+5` is a zone name and not a rule, which is what
        // makes this more than a look at the first character.
        try std.testing.expectEqualStrings("CST6CDT,M3.2.0,M11.1.0", resolveTz("CST6CDT,M3.2.0,M11.1.0").rule);
        try std.testing.expectEqualStrings("Etc/GMT+5", resolveTz("Etc/GMT+5").name);
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
    /// leave it out cannot be asked, and neither can a target with no
    /// tree at all, so both answer null.
    pub fn version(
        io: std.Io,
        gpa: std.mem.Allocator,
        directory: []const u8,
    ) (std.mem.Allocator.Error || error{})!?[]const u8 {
        if (!available) return null;

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

    test version {
        // Read from the first line of `tzdata.zi`, which not every
        // system ships, so null is an ordinary answer rather than an
        // error. The caller owns the string when there is one.
        for (test_directories) |directory| {
            const found = (try version(testing.io, testing.allocator, directory)) orelse continue;
            defer testing.allocator.free(found);

            // A release is a year and a letter, such as "2026c".
            try testing.expect(found.len >= 5);
            try testing.expect(std.ascii.isDigit(found[0]));
            return;
        }
        return error.SkipZigTest;
    }

    /// Returned by `load` and `loadLocal` on a target where `available`
    /// is false, in place of the file-not-found that opening a Unix path
    /// on Windows would otherwise produce. The failure is the platform
    /// rather than the request, and it says so.
    pub const UnavailableError = error{NoSystemDatabase};

    /// What `load` can fail with: a target with no database at all, a
    /// name that does not validate, anything that goes wrong reading the
    /// file, anything wrong with its contents, or a failed allocation.
    pub const LoadError = UnavailableError ||
        InvalidNameError ||
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
    /// Fails with `error.NoSystemDatabase` where `system.available` is
    /// false, without touching the filesystem.
    ///
    /// The returned zone owns its data and must be released with
    /// `TimeZone.deinit`.
    pub fn load(
        io: std.Io,
        gpa: std.mem.Allocator,
        directory: []const u8,
        name: []const u8,
    ) LoadError!TimeZone {
        if (!available) return error.NoSystemDatabase;

        try validateName(name);

        const path = try std.fs.path.join(gpa, &.{ directory, name });
        defer gpa.free(path);

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, size_limit);
        errdefer gpa.free(bytes);

        const owned_name = try gpa.dupe(u8, name);
        errdefer gpa.free(owned_name);

        return TimeZone.fromOwnedBytes(owned_name, bytes);
    }

    test load {
        for (test_directories) |directory| {
            var zone = load(testing.io, testing.allocator, directory, "America/Chicago") catch continue;
            defer zone.deinit(testing.allocator);

            try testing.expectEqualStrings("America/Chicago", zone.name);
            try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), zone.offsetAt(1705320000));

            // The name is validated before it is joined onto the
            // directory, so a value taken straight from `TZ` cannot walk
            // out of the tree.
            try testing.expectError(
                error.InvalidZoneName,
                load(testing.io, testing.allocator, directory, "../../etc/passwd"),
            );
            return;
        }
        return error.SkipZigTest;
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
    ///
    /// Fails with `error.NoSystemDatabase` where `system.available` is
    /// false; `windows.loadLocal` is what asks the same question there.
    pub fn loadLocal(
        io: std.Io,
        gpa: std.mem.Allocator,
        path: ?[]const u8,
    ) LoadError!TimeZone {
        if (!available) return error.NoSystemDatabase;

        const from = path orelse default_localtime;

        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, from, gpa, size_limit);
        errdefer gpa.free(bytes);

        const owned_name = try gpa.dupe(u8, "localtime");
        errdefer gpa.free(owned_name);

        return TimeZone.fromOwnedBytes(owned_name, bytes);
    }

    test loadLocal {
        // Passing null reads the machine's own zone from
        // `/etc/localtime`, which is a path rather than a name and so
        // needs no TZDIR. Under `-Dno-system-tzdata` there is nothing to
        // read, which a path that cannot exist stands in for, so the skip
        // happens through the same failure as on a machine without one.
        const path: ?[]const u8 = if (@import("build_options").no_system_tzdata)
            "/nonexistent/localtime"
        else
            null;

        var zone = loadLocal(testing.io, testing.allocator, path) catch return error.SkipZigTest;
        defer zone.deinit(testing.allocator);

        // The zone it names is not knowable here, but it is a real one.
        try testing.expectEqualStrings("localtime", zone.name);
        _ = zone.offsetAt(0);
    }
};

/// The machine's own zone on Windows.
///
/// Windows does not use the IANA database. It keeps its own zone data in
/// the registry, under its own names -- "Central Standard Time" rather
/// than "America/Chicago" -- and in its own binary format, with none of
/// the history IANA carries. So this is a name lookup rather than a data
/// source: it asks Windows which zone the machine is set to, translates
/// that name to an IANA one, and hands it to `embedded.load`.
///
/// Three pieces have to line up, and each can be used on its own:
///
/// 1. `localKeyName` calls `GetDynamicTimeZoneInformation` and returns
///    the `TimeZoneKeyName` it fills in, which is the registry key under
///    `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Time Zones`
///    and is the same string in every locale, unlike the display names
///    beside it.
/// 2. `ianaName` looks that up in CLDR's table, the only published
///    correspondence between the two sets of names.
/// 3. `embedded.load` supplies the data, which means a build without
///    `-Dembed-tzdata` gets as far as the name and no further. There is
///    nothing else to fall back on: `system` cannot work here.
///
/// ```zig
/// var zone = try datetime.tzdb.windows.loadLocal();
/// ```
///
/// The registry is never read. Windows' own zone data would be a second
/// format to parse for less history than the IANA copy already in the
/// binary, and the two would disagree about the past.
pub const windows = struct {
    /// Whether this target can be asked. True only on Windows; every
    /// function here fails with `error.NotWindows` elsewhere, except
    /// `ianaName`, which is a table lookup and works anywhere.
    pub const available = builtin.os.tag == .windows;

    /// Win32 bindings, imported only on the target that has them, so that
    /// a build for anything else neither fetches nor compiles them.
    const win32 = if (available) @import("win32").everything else struct {};

    /// The CLDR release the name table was generated from.
    pub const cldr_version = windowszones.cldr_version;

    /// Enough room for any name `localKeyName` can return.
    ///
    /// `TimeZoneKeyName` is 128 UTF-16 code units including its
    /// terminator, and a code unit outside a surrogate pair becomes at
    /// most three bytes of UTF-8. Real names are ASCII and under forty
    /// bytes, but the buffer is sized for what the field can hold rather
    /// than for what has been seen in it.
    pub const key_name_max = 127 * 3;

    /// What the name lookups can fail with.
    pub const NameError = error{
        /// Not Windows, so there is nothing to ask.
        NotWindows,
        /// Windows would not say which zone it is set to. It reports this
        /// as `TIME_ZONE_ID_INVALID`, or by leaving the key name empty,
        /// which is what a machine whose settings do not correspond to
        /// any registry zone does.
        NoTimeZone,
        /// Windows named a zone that CLDR's table does not map. A zone
        /// added to Windows since the table was generated looks like
        /// this; see `cldr_version` for which release that was.
        UnknownWindowsZone,
    };

    /// What `loadLocal` can fail with, which is the above plus the data
    /// not being there.
    pub const LoadError = NameError || TimeZone.Error || error{
        /// The zone was named, but this build has no copy of it. Only
        /// `-Dembed-tzdata` puts one in reach here, since `system` cannot
        /// work on Windows.
        ZoneNotEmbedded,
    };

    /// Reads the machine's own Windows zone name, such as
    /// "Central Standard Time", into `buffer`.
    ///
    /// This is `TimeZoneKeyName` from `GetDynamicTimeZoneInformation`,
    /// which names the registry key the setting came from. It is the
    /// invariant name: `StandardName` beside it is translated for the
    /// machine's locale and so cannot be looked up in any table.
    ///
    /// The name comes back as UTF-16 and is converted in place, which is
    /// the only reason a buffer is needed.
    pub fn localKeyName(buffer: *[key_name_max]u8) NameError![]const u8 {
        if (!available) return error.NotWindows;

        var info: win32.DYNAMIC_TIME_ZONE_INFORMATION = undefined;
        if (win32.GetDynamicTimeZoneInformation(&info) == win32.TIME_ZONE_ID_INVALID) {
            return error.NoTimeZone;
        }

        const name = std.mem.sliceTo(&info.TimeZoneKeyName, 0);
        if (name.len == 0) return error.NoTimeZone;

        // Ill-formed UTF-16 in a registry-backed field would mean
        // something is badly wrong, and it is not a different problem
        // from the field being empty: either way there is no name here.
        const len = std.unicode.utf16LeToUtf8(buffer, name) catch return error.NoTimeZone;
        return buffer[0..len];
    }

    /// Returns the IANA zone CLDR calls the world-wide default for the
    /// Windows zone `key_name`, or null when it maps none.
    ///
    /// A Windows zone usually covers several IANA ones -- "Central
    /// Standard Time" is Chicago in the United States, Winnipeg in Canada
    /// and Mexico City in Mexico -- and CLDR lists a mapping per
    /// territory. This is the `001` row, the answer that does not need to
    /// know where the machine is. It is the same choice ICU makes for a
    /// bare Windows name, and the offsets agree; the differences are in
    /// history and in the names the zones print.
    ///
    /// The table is sorted by Windows name, so this is a binary search
    /// over it. It works on every target, since it is only a table.
    pub fn ianaName(key_name: []const u8) ?[]const u8 {
        var low: usize = 0;
        var high: usize = windowszones.entries.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, windowszones.entries[mid].windows, key_name)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return windowszones.entries[mid].iana,
            }
        }
        return null;
    }

    test ianaName {
        // The name Windows reports for the United States central zone,
        // and the IANA zone CLDR calls its default.
        try std.testing.expectEqualStrings("America/Chicago", ianaName("Central Standard Time").?);
        try std.testing.expectEqualStrings("Europe/Berlin", ianaName("W. Europe Standard Time").?);
        try std.testing.expectEqualStrings("Asia/Calcutta", ianaName("India Standard Time").?);

        // Windows has a name for UTC itself.
        try std.testing.expectEqualStrings("Etc/UTC", ianaName("UTC").?);

        // The match is exact: this is a key name, not a display name, and
        // nothing here guesses at a near miss.
        try std.testing.expectEqual(@as(?[]const u8, null), ianaName("Central Standard Time (Mexico) "));
        try std.testing.expectEqual(@as(?[]const u8, null), ianaName("America/Chicago"));
        try std.testing.expectEqual(@as(?[]const u8, null), ianaName(""));
    }

    test localKeyName {
        var buffer: [key_name_max]u8 = undefined;

        // There is nothing to ask anywhere else, and saying so is the
        // point: the answer is a refusal rather than a zone that happens
        // to be wrong.
        if (!available) {
            try std.testing.expectError(error.NotWindows, localKeyName(&buffer));
            return error.SkipZigTest;
        }

        const name = try localKeyName(&buffer);

        // A registry key name, such as "Central Standard Time". Printable
        // ASCII throughout, which is what makes it a key rather than a
        // display name.
        try std.testing.expect(name.len > 0);
        for (name) |char| try std.testing.expect(char >= ' ' and char < 0x7f);
    }

    /// Returns the IANA name of the machine's own zone.
    ///
    /// `localKeyName` and `ianaName` in one step. The result is a string
    /// from the table rather than from the buffer, so it outlives the
    /// call and there is nothing to keep.
    pub fn localName() NameError![]const u8 {
        var buffer: [key_name_max]u8 = undefined;
        return ianaName(try localKeyName(&buffer)) orelse error.UnknownWindowsZone;
    }

    test localName {
        if (!available) {
            try std.testing.expectError(error.NotWindows, localName());
            return error.SkipZigTest;
        }

        // Whatever the machine is set to, the answer is an IANA name this
        // library would accept, and it outlives the buffer it was read
        // through because it comes from the table.
        const name = try localName();
        try validateName(name);
    }

    /// Loads the machine's own zone, from the copy of the database
    /// compiled into this binary.
    ///
    /// Needs `-Dembed-tzdata`, and fails with `error.ZoneNotEmbedded`
    /// without it, because `system` cannot work on Windows and so there
    /// is nowhere else for the data to come from. The zone borrows the
    /// blob that is already in the binary, so no allocator is involved.
    pub fn loadLocal() LoadError!TimeZone {
        const name = try localName();
        return (try embedded.load(name)) orelse error.ZoneNotEmbedded;
    }

    test loadLocal {
        if (!available) {
            try std.testing.expectError(error.NotWindows, loadLocal());
            return error.SkipZigTest;
        }

        // The name is only half of it: without `-Dembed-tzdata` there is
        // no copy of the database to read, and that is a different failure
        // from not knowing which zone to look for.
        if (!embedded.available) {
            try std.testing.expectError(error.ZoneNotEmbedded, loadLocal());
            return error.SkipZigTest;
        }

        var zone = try loadLocal();
        // The zone borrows the blob already in the binary, so no allocator
        // was involved and there is nothing to free.
        defer zone.deinit(std.testing.allocator);

        try std.testing.expectEqualStrings(try localName(), zone.name);
        _ = zone.offsetAt(0);
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

    test names {
        // The buffer bounds how many are written, so a caller can ask for
        // however many it has room for; `count` says how many there are.
        var buffer: [8][]const u8 = undefined;
        const found = names(&buffer);

        try std.testing.expectEqual(@min(buffer.len, count()), found.len);

        // They come back sorted, which is what makes `load` a binary
        // search rather than a scan.
        for (found, 0..) |name, i| {
            if (i == 0) continue;
            try std.testing.expect(std.mem.lessThan(u8, found[i - 1], name));
        }
    }

    /// The number of embedded zones.
    pub fn count() usize {
        return generated.entries.len;
    }

    test count {
        // Zero unless the build asked for the data with `-Dembed-tzdata`,
        // which is what `available` reports.
        try std.testing.expectEqual(available, count() > 0);
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

    test load {
        // Null when this build embedded no data, which is the default.
        if (!available) {
            try std.testing.expectEqual(@as(?TimeZone, null), try load("America/Chicago"));
            return error.SkipZigTest;
        }

        // The zone borrows the blob that is already in the binary, so no
        // allocator is involved and there is nothing to free.
        const zone = (try load("America/Chicago")).?;
        try std.testing.expectEqualStrings("America/Chicago", zone.name);
        try std.testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), zone.offsetAt(1705320000));

        try std.testing.expectEqual(@as(?TimeZone, null), try load("Nowhere/Nothing"));
    }

    /// Looks `name` up in the index. The generated entries are sorted by
    /// name, so this is a binary search over them.
    fn find(name: []const u8) ?generated.Entry {
        // With no embedded data `entries` is comptime-empty, and the
        // search below will not compile against it: indexing a slice
        // whose length is known to be zero is an error however
        // unreachable the index is. Returning early at comptime keeps the
        // rest from being analyzed, which is what lets a caller name
        // `embedded.load` in a build that did not ask for the data.
        if (comptime generated.entries.len == 0) return null;

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

    test find {
        if (!available) return error.SkipZigTest;

        // The entries are sorted by name, so every one of them is
        // findable and nothing else is.
        var buffer: [4][]const u8 = undefined;
        for (names(&buffer)) |name| {
            try std.testing.expect(find(name) != null);
        }
        try std.testing.expectEqual(@as(?generated.Entry, null), find("Nowhere/Nothing"));
    }
};

const testing = std.testing;

/// The directories the tests look in, which is `system.search_directories`
/// unless the build asked for `-Dno-system-tzdata`, in which case it is
/// nothing at all.
///
/// Emptying the list is what makes a machine that has a database behave
/// like one that has not, so that the tests which skip when there is none
/// are reachable from either. See `build.zig`.
const test_directories: []const []const u8 = if (@import("build_options").no_system_tzdata)
    &.{}
else
    system.search_directories;

test "the Windows name table is a table this library can use" {
    // Sorted and without repeats, which is what makes `ianaName` a binary
    // search, and what a regenerated table has to stay.
    for (windowszones.entries[1..], windowszones.entries[0 .. windowszones.entries.len - 1]) |entry, previous| {
        try testing.expect(std.mem.lessThan(u8, previous.windows, entry.windows));
    }

    // Every Windows name it holds is findable, and every IANA name it
    // gives back is one `load` would accept rather than refuse.
    for (windowszones.entries) |entry| {
        try testing.expectEqualStrings(entry.iana, windows.ianaName(entry.windows).?);
        try validateName(entry.iana);
    }

    // And, when there is a database to check against, every one of them
    // names a zone that is really in it. CLDR mapped these against the
    // 2021a release, so this is what would notice a name that has since
    // been dropped -- which would leave `windows.loadLocal` failing for
    // whoever is in that zone.
    if (!embedded.available) return error.SkipZigTest;
    for (windowszones.entries) |entry| {
        var zone = (try embedded.load(entry.iana)) orelse {
            std.debug.print("no embedded zone for {s} -> {s}\n", .{ entry.windows, entry.iana });
            return error.MissingZone;
        };
        zone.deinit(testing.allocator);
    }
}

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
    for (test_directories) |directory| {
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

    // Only worth comparing when both sides are the same release. The two
    // legitimately disagree otherwise, which is the normal state of
    // affairs while a tzdata update is being prepared: the embedded copy
    // is the new release and the machine's is whatever it had.
    const matching = matching: {
        for (test_directories) |directory| {
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

    for (test_directories) |directory| {
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

/// Asserts that `rule` parses as a POSIX `TZ` string and gives the -06:00
/// standard offset that the test's inputs all describe.
fn posixtzTest(rule: []const u8) !void {
    const parsed = try @import("posixtz.zig").parse(rule);
    try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), parsed.std_offset);
}

test "the system database reports which release it was built from" {
    for (test_directories) |directory| {
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
