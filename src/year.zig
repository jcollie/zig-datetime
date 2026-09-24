// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The year of the proleptic Gregorian calendar.

/// A year of the proleptic Gregorian calendar. Signed, and numbered
/// astronomically rather than by era: year 0 is 1 BCE, year -1 is 2 BCE,
/// and so on, so that arithmetic on years never has to skip a gap.
///
/// That is ISO 8601's own numbering. ISO 8601-1:2019, 4.2.1, identifies
/// years "both before and after the introduction of the Gregorian
/// calendar", and 4.3.2 numbers them from `0000` for year zero; ISO
/// 8601-2:2019, 4.4.1.2, writes the year before it as `-0001`.
pub const Year = i32;
