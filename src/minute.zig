// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The minute within an hour.

const std = @import("std");

/// A minute within an hour, 0 through 59. Sized the same way as `Second`,
/// from a range of 0 to 60, so the two share a width.
pub const Minute = std.math.IntFittingRange(0, 60);
