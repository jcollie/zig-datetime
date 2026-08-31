// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The second within a minute.

/// A second within a minute, 0 through 59, widened to hold the leap
/// second values 60 and 61 that a minute may carry.
pub const Second = u6;
