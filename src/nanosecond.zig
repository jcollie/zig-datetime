const std = @import("std");

pub const Nanosecond = std.math.IntFittingRange(0, std.time.ns_per_s);
