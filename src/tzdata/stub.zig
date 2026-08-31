// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Stands in for the generated timezone database when the build was
//! configured without embedded data. Building with `-Dembed-tzdata` swaps
//! this out for a module generated from the IANA sources; see `build.zig`.

/// The IANA release the data came from, empty when there is none.
pub const version = "";

/// The `zic -r` argument the data was trimmed to, empty when the full
/// history was kept.
pub const history_from = "";

/// The concatenated TZif files, empty when there is none.
pub const blob: []const u8 = "";

/// Where one zone's bytes sit inside `blob`.
pub const Entry = struct {
    name: []const u8,
    start: u32,
    len: u32,
};

/// The zones in the database, sorted by name.
pub const entries: []const Entry = &.{};
