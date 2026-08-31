// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Nanosecond = std.math.IntFittingRange(0, std.time.ns_per_s);
