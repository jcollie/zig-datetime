// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The year of the proleptic Gregorian calendar.

/// A year of the proleptic Gregorian calendar. Signed, and numbered
/// astronomically rather than by era: year 0 is 1 BCE, year -1 is 2 BCE,
/// and so on, so that arithmetic on years never has to skip a gap.
pub const Year = i32;
