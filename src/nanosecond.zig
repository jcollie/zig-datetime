// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The nanosecond within a second.

const std = @import("std");

/// A nanosecond within a second, 0 through 999999999. Sized to hold a
/// whole second's worth of them, which takes 30 bits.
pub const Nanosecond = std.math.IntFittingRange(0, std.time.ns_per_s);
