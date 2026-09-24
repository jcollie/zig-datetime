// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The second within a minute.

/// A second within a minute, 0 through 59, widened to hold the leap
/// second values 60 and 61 that a minute may carry.
///
/// ISO 8601-1:2019, 4.3.10, allows a second up to `60`, for a positive leap
/// second, and no further; `iso8601.parse` holds to that. `61` is C89's
/// "double leap second", which never happened but which glibc's `strptime`
/// still reads, and `strftime.parse` reads it to match.
pub const Second = u6;
