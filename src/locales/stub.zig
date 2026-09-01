// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Stands in for the generated locale data when the build did not ask for
//! it, which is the default. `-Dembed-locales` replaces this with the
//! real thing; see `build.zig` and `tools/gen_locales.js`.
//!
//! The shape is a tuple of anonymous struct literals rather than a named
//! type, so that neither this nor the generated file has to name anything
//! from the library. `locale.Entry` is what they are read back as.
//!
//! This sits in a directory of its own because a module takes its whole
//! containing directory with it. Left in src/ it would make a second
//! module out of every file here, which turns up in the generated
//! documentation as a duplicate of the entire library.

/// No locales, which is what a build without `-Dembed-locales` carries.
/// `locale.en` is built into the library itself and is here either way.
pub const entries = .{};

/// The moment.js release the data was generated from, empty when there is
/// none.
pub const moment_version = "";
