// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Reader for the Time Zone Information Format (TZif) defined by RFC 8536,
//! the binary format that the IANA timezone database is compiled into and
//! that operating systems keep under `/usr/share/zoneinfo`.
//!
//! The reader is zero-copy: it borrows the file bytes and decodes the
//! big-endian fields on access rather than building parallel arrays. That
//! keeps it usable without an allocator, which matters for timezone data
//! embedded in the binary with `@embedFile`.

const std = @import("std");

/// What `parse` can fail with.
pub const ParseError = error{
    BadMagic,
    BadHeader,
    BadFooter,
    UnsupportedVersion,
    Truncated,
};

/// The file's version, taken from the byte after the magic. Versions 2 and
/// later store the whole file twice: a version 1 block for readers that
/// predate them, then a second block with 64-bit transition times and a
/// POSIX rule in its footer. See `parse`, which reads the second block
/// whenever there is one.
pub const Version = enum(u8) {
    /// The original 32-bit format, which has no 64-bit block and no footer.
    v1 = 0,
    v2 = '2',
    v3 = '3',
    v4 = '4',
};

/// One local time type: what the clock reads and what it is called during
/// some span of the zone's history.
pub const Type = struct {
    /// Seconds east of UTC, so -18000 for -05:00.
    offset: i32,
    /// Whether this type is a daylight saving time.
    is_dst: bool,
    /// The abbreviation shown for this type, such as "CST" or "-04".
    designation: []const u8,
};

const magic = "TZif";
const header_len = 44;
const type_record_len = 6;

/// The counts from a TZif header, which give the sizes of every field in
/// the data block that follows it.
const Counts = struct {
    version: Version,
    isutcnt: u32,
    isstdcnt: u32,
    leapcnt: u32,
    timecnt: u32,
    typecnt: u32,
    charcnt: u32,

    /// The length of the data block described by these counts, where each
    /// transition time and leap second occurrence takes `time_size` bytes.
    fn blockLength(self: Counts, time_size: u32) u64 {
        return @as(u64, self.timecnt) * (time_size + 1) +
            @as(u64, self.typecnt) * type_record_len +
            @as(u64, self.charcnt) +
            @as(u64, self.leapcnt) * (time_size + 4) +
            @as(u64, self.isstdcnt) +
            @as(u64, self.isutcnt);
    }

    test blockLength {
        // Two transitions, two types, "CST\0CDT\0", no leap seconds and
        // no indicators, at the 4-byte time width of a version 1 block:
        // 2*(4+1) + 2*6 + 8 = 30.
        const counts: Counts = .{
            .version = .v2,
            .isutcnt = 0,
            .isstdcnt = 0,
            .leapcnt = 0,
            .timecnt = 2,
            .typecnt = 2,
            .charcnt = 8,
        };
        try testing.expectEqual(@as(u64, 30), counts.blockLength(4));

        // The same counts at the 8-byte width of the second block, where
        // each transition costs four bytes more: 2*(8+1) + 12 + 8 = 38.
        try testing.expectEqual(@as(u64, 38), counts.blockLength(8));
    }
};

/// A parsed TZif file, as slices into the bytes it was parsed from.
///
/// Parsing only finds where each of the file's arrays begins and ends. The
/// arrays themselves are left in the file's own layout, and the accessors
/// below decode one record out of them per call, which is what keeps the
/// type free of an allocator at the cost of decoding a record again each
/// time it is read.
pub const Tzif = struct {
    version: Version,
    /// The width in bytes of each transition time, 4 for a version 1 file
    /// and 8 for the 64-bit block of any later version.
    time_size: u8,
    /// Transition times, big-endian, `time_size` bytes each.
    transition_times: []const u8,
    /// For each transition, the index of the local time type it switches to.
    transition_types: []const u8,
    /// The local time type records, six bytes each.
    type_records: []const u8,
    /// The NUL-separated designation strings that type records index into.
    designations: []const u8,
    /// The POSIX TZ string describing times after the last transition, or
    /// empty for a version 1 file. See `posixtz`.
    footer: []const u8,

    /// The number of transitions in the file.
    pub fn transitionCount(self: Tzif) usize {
        return self.transition_times.len / self.time_size;
    }

    test transitionCount {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        try testing.expectEqual(@as(usize, 2), file.transitionCount());
    }

    /// Returns the `index`th transition as a Unix timestamp in seconds.
    pub fn transitionAt(self: Tzif, index: usize) i64 {
        const at = index * self.time_size;
        return switch (self.time_size) {
            4 => std.mem.readInt(i32, self.transition_times[at..][0..4], .big),
            8 => std.mem.readInt(i64, self.transition_times[at..][0..8], .big),
            else => unreachable,
        };
    }

    test transitionAt {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        // Decoded from the file's own big-endian bytes on each call,
        // which is why nothing here needs an allocator.
        try testing.expectEqual(@as(i64, 1710057600), file.transitionAt(0));
        try testing.expectEqual(@as(i64, 1730617200), file.transitionAt(1));
    }

    /// The number of local time types in the file. Always at least one.
    pub fn typeCount(self: Tzif) usize {
        return self.type_records.len / type_record_len;
    }

    test typeCount {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        // The file is built with a standard type and a daylight one.
        try testing.expectEqual(@as(usize, 2), file.typeCount());
    }

    /// Returns the `index`th local time type.
    pub fn typeAt(self: Tzif, index: usize) Type {
        const record = self.type_records[index * type_record_len ..][0..type_record_len];
        const designation_index = record[5];
        const rest = self.designations[designation_index..];
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
        return .{
            .offset = std.mem.readInt(i32, record[0..4], .big),
            .is_dst = record[4] != 0,
            .designation = rest[0..end],
        };
    }

    test typeAt {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        const standard = file.typeAt(0);
        try testing.expectEqualStrings("CST", standard.designation);
        try testing.expectEqual(@as(i32, -6 * std.time.s_per_hour), standard.offset);
        try testing.expect(!standard.is_dst);

        const daylight = file.typeAt(1);
        try testing.expectEqualStrings("CDT", daylight.designation);
        try testing.expect(daylight.is_dst);
    }

    /// Returns the type that applies before the first transition. RFC 8536
    /// specifies the first type that is not a daylight saving time, falling
    /// back to the first type of all.
    pub fn defaultType(self: Tzif) Type {
        for (0..self.typeCount()) |index| {
            const local_type = self.typeAt(index);
            if (!local_type.is_dst) return local_type;
        }
        return self.typeAt(0);
    }

    test defaultType {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        // The first type that is not a daylight saving one, which here
        // is the standard type rather than the one at index 0 by luck.
        try testing.expectEqualStrings("CST", file.defaultType().designation);
    }

    /// A stretch of time over which one local time type applies, and that
    /// type. The bounds let a caller tell whether some other instant is
    /// still governed by the same type without searching again.
    pub const Span = struct {
        local_type: Type,
        /// Inclusive. `minInt` when nothing precedes this type.
        start: i64,
        /// Exclusive.
        end: i64,
    };

    /// Returns the span around `timestamp`, a Unix time in seconds, or
    /// null if `timestamp` falls at or after the last transition. In that
    /// case the caller must consult `footer`, because a file compiled
    /// with `zic -b slim` relies on it for all future times.
    pub fn spanAtTimestamp(self: Tzif, timestamp: i64) ?Span {
        const count = self.transitionCount();
        if (count == 0) return null;
        if (timestamp < self.transitionAt(0)) return .{
            .local_type = self.defaultType(),
            .start = std.math.minInt(i64),
            .end = self.transitionAt(0),
        };
        if (timestamp >= self.transitionAt(count - 1)) return null;

        // The index of the last transition that is not after `timestamp`.
        var low: usize = 0;
        var high: usize = count - 1;
        while (low < high) {
            const mid = low + (high - low + 1) / 2;
            if (self.transitionAt(mid) <= timestamp) low = mid else high = mid - 1;
        }
        return .{
            .local_type = self.typeAt(self.transition_types[low]),
            .start = self.transitionAt(low),
            .end = self.transitionAt(low + 1),
        };
    }

    test spanAtTimestamp {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        // Between the two transitions, bounded by both of them.
        const summer = file.spanAtTimestamp(1720000000).?;
        try testing.expectEqualStrings("CDT", summer.local_type.designation);
        try testing.expectEqual(@as(i64, 1710057600), summer.start);
        try testing.expectEqual(@as(i64, 1730617200), summer.end);

        // Before the first transition there is no lower bound.
        const before = file.spanAtTimestamp(0).?;
        try testing.expectEqualStrings("CST", before.local_type.designation);
        try testing.expectEqual(@as(i64, std.math.minInt(i64)), before.start);

        // At or after the last transition the file has nothing more to
        // say and the footer takes over.
        try testing.expectEqual(@as(?Span, null), file.spanAtTimestamp(1730617200));
    }

    /// Returns the local time type in effect at `timestamp`, or null under
    /// the same condition as `spanAtTimestamp`.
    ///
    /// This repeats that function's search rather than calling it and
    /// taking the type, because it is the hot path: reading the upper
    /// bound costs another decode of a big-endian field, and returning
    /// the wider value costs again, for something callers here discard.
    pub fn typeAtTimestamp(self: Tzif, timestamp: i64) ?Type {
        const count = self.transitionCount();
        if (count == 0) return null;
        if (timestamp < self.transitionAt(0)) return self.defaultType();
        if (timestamp >= self.transitionAt(count - 1)) return null;

        var low: usize = 0;
        var high: usize = count - 1;
        while (low < high) {
            const mid = low + (high - low + 1) / 2;
            if (self.transitionAt(mid) <= timestamp) low = mid else high = mid - 1;
        }
        return self.typeAt(self.transition_types[low]);
    }

    test typeAtTimestamp {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        try testing.expectEqualStrings("CST", file.typeAtTimestamp(0).?.designation);
        try testing.expectEqualStrings("CDT", file.typeAtTimestamp(1710057600).?.designation);

        // Null once past the last stored transition; see `posixtz`.
        try testing.expectEqual(@as(?Type, null), file.typeAtTimestamp(1730617200));
    }

    /// Returns the type in effect at or after the last transition, which is
    /// what the footer's rules must agree with at the moment they take over.
    pub fn lastType(self: Tzif) Type {
        const count = self.transitionCount();
        if (count == 0) return self.defaultType();
        return self.typeAt(self.transition_types[count - 1]);
    }

    test lastType {
        const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
        defer testing.allocator.free(bytes);
        const file = try parse(bytes);

        // The November transition returns the zone to standard time, so
        // that is what the footer's rules have to agree with.
        try testing.expectEqualStrings("CST", file.lastType().designation);
    }
};

/// Parses the TZif file in `bytes`. The returned value borrows `bytes`,
/// which must outlive it.
///
/// For a version 2 or later file the 32-bit block is skipped entirely and
/// the 64-bit block is used, which is what the format intends: the first
/// block exists only so that readers predating version 2 see something
/// sensible.
pub fn parse(bytes: []const u8) ParseError!Tzif {
    const first = try parseHeader(bytes);

    if (first.version == .v1) {
        var tzif = try parseBlock(bytes[header_len..], first, 4);
        tzif.version = .v1;
        tzif.footer = "";
        return tzif;
    }

    const skip = std.math.cast(usize, first.blockLength(4)) orelse return error.Truncated;
    if (bytes.len < header_len + skip) return error.Truncated;
    const rest = bytes[header_len + skip ..];

    const second = try parseHeader(rest);
    var tzif = try parseBlock(rest[header_len..], second, 8);
    tzif.version = first.version;

    const block_len = std.math.cast(usize, second.blockLength(8)) orelse return error.Truncated;
    const footer_area = rest[header_len + block_len ..];
    if (footer_area.len < 2 or footer_area[0] != '\n') return error.BadFooter;
    const end = std.mem.indexOfScalar(u8, footer_area[1..], '\n') orelse return error.BadFooter;
    tzif.footer = footer_area[1..][0..end];

    return tzif;
}

/// Reads the 44 byte header at the start of `bytes`.
fn parseHeader(bytes: []const u8) ParseError!Counts {
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;

    const version = std.enums.fromInt(Version, bytes[4]) orelse return error.UnsupportedVersion;

    const counts: Counts = .{
        .version = version,
        .isutcnt = std.mem.readInt(u32, bytes[20..24], .big),
        .isstdcnt = std.mem.readInt(u32, bytes[24..28], .big),
        .leapcnt = std.mem.readInt(u32, bytes[28..32], .big),
        .timecnt = std.mem.readInt(u32, bytes[32..36], .big),
        .typecnt = std.mem.readInt(u32, bytes[36..40], .big),
        .charcnt = std.mem.readInt(u32, bytes[40..44], .big),
    };

    // RFC 8536 section 3.1: there must be at least one local time type and
    // one designation, and the indicator counts must either be zero or
    // match the type count.
    if (counts.typecnt == 0 or counts.charcnt == 0) return error.BadHeader;
    if (counts.isutcnt != 0 and counts.isutcnt != counts.typecnt) return error.BadHeader;
    if (counts.isstdcnt != 0 and counts.isstdcnt != counts.typecnt) return error.BadHeader;

    return counts;
}

test parseHeader {
    const bytes = try buildFile(&.{1710057600}, &.{1}, "CST6CDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(bytes);

    // This reads the first header. In a version 2 file that describes the
    // placeholder 32-bit block, which carries the types and designations
    // but no transitions; `parse` steps over it to reach the real one.
    const counts = try parseHeader(bytes);
    try testing.expectEqual(Version.v2, counts.version);
    try testing.expectEqual(@as(u32, 0), counts.timecnt);
    try testing.expectEqual(@as(u32, 2), counts.typecnt);

    // The magic is checked before anything is read out of the header.
    try testing.expectError(error.BadMagic, parseHeader("XZif" ++ ("\x00" ** 40)));
    try testing.expectError(error.Truncated, parseHeader("TZif"));

    // RFC 8536 requires at least one local time type and one designation.
    var no_types = try testing.allocator.dupe(u8, bytes[0..header_len]);
    defer testing.allocator.free(no_types);
    std.mem.writeInt(u32, no_types[36..40], 0, .big);
    try testing.expectError(error.BadHeader, parseHeader(no_types));
}

/// Carves the data block at the start of `bytes` into its fields.
fn parseBlock(bytes: []const u8, counts: Counts, time_size: u8) ParseError!Tzif {
    var rest = bytes;

    const transition_times = try take(&rest, @as(u64, counts.timecnt) * time_size);
    const transition_types = try take(&rest, counts.timecnt);
    const type_records = try take(&rest, @as(u64, counts.typecnt) * type_record_len);
    const designations = try take(&rest, counts.charcnt);

    // The leap second records and the standard/wall and UT/local
    // indicators are read past but not retained: the indicators only
    // matter to zic when recompiling, and leap seconds are not applied
    // here because Unix time is defined to ignore them.
    _ = try take(&rest, @as(u64, counts.leapcnt) * (@as(u64, time_size) + 4));
    _ = try take(&rest, counts.isstdcnt);
    _ = try take(&rest, counts.isutcnt);

    // Every transition must name a type that exists.
    for (transition_types) |index| {
        if (index >= counts.typecnt) return error.BadHeader;
    }
    // Every type must name a designation that starts inside the block.
    var index: usize = 0;
    while (index < counts.typecnt) : (index += 1) {
        if (type_records[index * type_record_len + 5] >= counts.charcnt) return error.BadHeader;
    }

    return .{
        .version = .v1,
        .time_size = time_size,
        .transition_times = transition_times,
        .transition_types = transition_types,
        .type_records = type_records,
        .designations = designations,
        .footer = "",
    };
}

/// Splits `len` bytes off the front of `rest` and returns them.
fn take(rest: *[]const u8, len: u64) ParseError![]const u8 {
    const n = std.math.cast(usize, len) orelse return error.Truncated;
    if (rest.len < n) return error.Truncated;
    defer rest.* = rest.*[n..];
    return rest.*[0..n];
}

test take {
    // Each call hands back the next `len` bytes and advances `rest`, so
    // the block's fields can be sliced off one after another.
    var rest: []const u8 = "CST\x00CDT\x00";
    try testing.expectEqualStrings("CST", try take(&rest, 3));
    try testing.expectEqualStrings("\x00", try take(&rest, 1));
    try testing.expectEqualStrings("CDT\x00", try take(&rest, 4));
    try testing.expectEqual(@as(usize, 0), rest.len);

    // Asking for more than is there is what makes a short file an error
    // rather than an out-of-bounds read.
    var short: []const u8 = "CS";
    try testing.expectError(error.Truncated, take(&short, 3));

    // A length too large to be a slice at all is caught the same way.
    var any: []const u8 = "CST";
    try testing.expectError(error.Truncated, take(&any, std.math.maxInt(u64)));
}

const testing = std.testing;

/// Appends `value` to `list` as `T` in big-endian order.
fn appendInt(list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var buffer: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buffer, value, .big);
    try list.appendSlice(testing.allocator, &buffer);
}

/// Appends a 44-byte TZif header: the magic, the version byte, the fifteen
/// reserved bytes, and the six counts.
fn appendHeader(list: *std.ArrayList(u8), version: u8, counts: Counts) !void {
    try list.appendSlice(testing.allocator, magic);
    try list.append(testing.allocator, version);
    try list.appendNTimes(testing.allocator, 0, 15);
    try appendInt(list, u32, counts.isutcnt);
    try appendInt(list, u32, counts.isstdcnt);
    try appendInt(list, u32, counts.leapcnt);
    try appendInt(list, u32, counts.timecnt);
    try appendInt(list, u32, counts.typecnt);
    try appendInt(list, u32, counts.charcnt);
}

/// Builds a two-type file with the given transitions, as a version 1 file
/// when `footer` is null and a version 2 file otherwise. The designations
/// are always "CST" and "CDT".
fn buildFile(transitions: []const i64, indices: []const u8, footer: ?[]const u8) ![]u8 {
    const designations = "CST\x00CDT\x00";
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(testing.allocator);

    const write = struct {
        /// Appends the two type records the test files are built from,
        /// standard CST at -06:00 and daylight CDT at -05:00.
        fn types(l: *std.ArrayList(u8)) !void {
            // CST, standard, designation at offset 0.
            try appendInt(l, i32, -6 * 3600);
            try l.appendSlice(testing.allocator, &.{ 0, 0 });
            // CDT, daylight, designation at offset 4.
            try appendInt(l, i32, -5 * 3600);
            try l.appendSlice(testing.allocator, &.{ 1, 4 });
        }
    };

    const counts: Counts = .{
        .version = .v1,
        .isutcnt = 0,
        .isstdcnt = 0,
        .leapcnt = 0,
        .timecnt = @intCast(transitions.len),
        .typecnt = 2,
        .charcnt = designations.len,
    };

    if (footer == null) {
        try appendHeader(&list, 0, counts);
        for (transitions) |at| try appendInt(&list, i32, @intCast(at));
        try list.appendSlice(testing.allocator, indices);
        try write.types(&list);
        try list.appendSlice(testing.allocator, designations);
        return list.toOwnedSlice(testing.allocator);
    }

    // A version 2 file carries a 32-bit block first, for readers that
    // predate the version. An empty one is enough to be well formed.
    const empty: Counts = .{
        .version = .v2,
        .isutcnt = 0,
        .isstdcnt = 0,
        .leapcnt = 0,
        .timecnt = 0,
        .typecnt = 2,
        .charcnt = designations.len,
    };
    try appendHeader(&list, '2', empty);
    try write.types(&list);
    try list.appendSlice(testing.allocator, designations);

    try appendHeader(&list, '2', counts);
    for (transitions) |at| try appendInt(&list, i64, at);
    try list.appendSlice(testing.allocator, indices);
    try write.types(&list);
    try list.appendSlice(testing.allocator, designations);

    try list.append(testing.allocator, '\n');
    try list.appendSlice(testing.allocator, footer.?);
    try list.append(testing.allocator, '\n');

    return list.toOwnedSlice(testing.allocator);
}

test parse {
    const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(bytes);

    const file = try parse(bytes);
    try testing.expectEqual(Version.v2, file.version);

    // The 32-bit block is stepped over, so the transitions come from the
    // 64-bit one and the footer is there to govern times past them.
    try testing.expectEqual(@as(u8, 8), file.time_size);
    try testing.expectEqual(@as(usize, 2), file.transitionCount());
    try testing.expectEqualStrings("CST6CDT,M3.2.0,M11.1.0", file.footer);

    // The result borrows `bytes` rather than copying, so it must not
    // outlive them, and no allocator was needed to build it.
    try testing.expectEqualStrings("CDT", file.typeAtTimestamp(1720000000).?.designation);

    try testing.expectError(error.BadMagic, parse("XZif" ++ ("\x00" ** 40)));
}

test parseBlock {
    // The block is everything after a header, and the header's counts are
    // what say how long each of its arrays is. A version 1 file is one
    // header and one block, so this is what `parse` does for that case.
    const bytes = try buildFile(&.{1710057600}, &.{1}, null);
    defer testing.allocator.free(bytes);

    const counts = try parseHeader(bytes);
    const file = try parseBlock(bytes[header_len..], counts, 4);

    try testing.expectEqual(@as(usize, 1), file.transitionCount());
    try testing.expectEqual(@as(i64, 1710057600), file.transitionAt(0));
    try testing.expectEqual(@as(usize, 2), file.typeCount());

    // Cutting the block short is caught rather than read past.
    try testing.expectError(
        error.Truncated,
        parseBlock(bytes[header_len .. header_len + 2], counts, 4),
    );
}

test "parse a version 1 file" {
    const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, null);
    defer testing.allocator.free(bytes);

    const file = try parse(bytes);
    try testing.expectEqual(Version.v1, file.version);
    try testing.expectEqual(@as(u8, 4), file.time_size);
    try testing.expectEqual(@as(usize, 2), file.transitionCount());
    try testing.expectEqual(@as(usize, 2), file.typeCount());
    try testing.expectEqualStrings("", file.footer);

    try testing.expectEqual(@as(i64, 1710057600), file.transitionAt(0));
    try testing.expectEqual(@as(i64, 1730617200), file.transitionAt(1));

    try testing.expectEqualStrings("CST", file.typeAt(0).designation);
    try testing.expectEqualStrings("CDT", file.typeAt(1).designation);
    try testing.expect(!file.typeAt(0).is_dst);
    try testing.expect(file.typeAt(1).is_dst);
}

test "parse a version 2 file and use its 64 bit block" {
    const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(bytes);

    const file = try parse(bytes);
    try testing.expectEqual(Version.v2, file.version);
    try testing.expectEqual(@as(u8, 8), file.time_size);
    try testing.expectEqual(@as(usize, 2), file.transitionCount());
    try testing.expectEqualStrings("CST6CDT,M3.2.0,M11.1.0", file.footer);
    try testing.expectEqual(@as(i64, 1710057600), file.transitionAt(0));
}

test "look up the type in effect at an instant" {
    const bytes = try buildFile(&.{ 1710057600, 1730617200 }, &.{ 1, 0 }, "CST6CDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(bytes);

    const file = try parse(bytes);

    // Before the first transition the first standard type applies.
    try testing.expectEqualStrings("CST", file.typeAtTimestamp(0).?.designation);
    try testing.expectEqualStrings("CST", file.typeAtTimestamp(1710057599).?.designation);
    // Between the two transitions, the daylight type.
    try testing.expectEqualStrings("CDT", file.typeAtTimestamp(1710057600).?.designation);
    try testing.expectEqualStrings("CDT", file.typeAtTimestamp(1730617199).?.designation);
    // At or after the last transition the footer takes over, so the file
    // itself has nothing more to say.
    try testing.expectEqual(@as(?Type, null), file.typeAtTimestamp(1730617200));
    try testing.expectEqual(@as(?Type, null), file.typeAtTimestamp(4070952000));

    try testing.expectEqualStrings("CST", file.defaultType().designation);
    try testing.expectEqualStrings("CST", file.lastType().designation);
}

test "the binary search lands on the right transition" {
    // Ten transitions alternating between the two types.
    var transitions: [10]i64 = undefined;
    var indices: [10]u8 = undefined;
    for (0..10) |i| {
        transitions[i] = @as(i64, @intCast(i)) * 1000;
        indices[i] = @intCast(i % 2);
    }

    const bytes = try buildFile(&transitions, &indices, null);
    defer testing.allocator.free(bytes);
    const file = try parse(bytes);

    // Every instant from just before the first transition to just after
    // the last one resolves to the transition that precedes it.
    var at: i64 = -1;
    while (at < 9000) : (at += 1) {
        const found = file.typeAtTimestamp(at) orelse continue;
        const expected: usize = if (at < 0) 0 else @intCast(@mod(@divFloor(at, 1000), 2));
        try testing.expectEqual(expected == 1, found.is_dst);
    }
}

test "parse rejects malformed files" {
    try testing.expectError(error.Truncated, parse(""));
    try testing.expectError(error.Truncated, parse("TZif"));

    const good = try buildFile(&.{1710057600}, &.{1}, "CST6CDT,M3.2.0,M11.1.0");
    defer testing.allocator.free(good);

    // A file that does not start with the magic.
    const wrong_magic = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(wrong_magic);
    wrong_magic[0] = 'X';
    try testing.expectError(error.BadMagic, parse(wrong_magic));

    // A version byte that is not one this reader knows.
    const wrong_version = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(wrong_version);
    wrong_version[4] = '9';
    try testing.expectError(error.UnsupportedVersion, parse(wrong_version));

    // A file cut short partway through its data block.
    try testing.expectError(error.Truncated, parse(good[0 .. good.len - 40]));

    // A header claiming no local time types at all.
    const no_types = try testing.allocator.dupe(u8, good);
    defer testing.allocator.free(no_types);
    std.mem.writeInt(u32, no_types[36..40], 0, .big);
    try testing.expectError(error.BadHeader, parse(no_types));
}
