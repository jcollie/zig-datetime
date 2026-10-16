<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-datetime

Calendar dates, times of day, instants and time zones, and the text formats
they are read from and written to.

## Language

### Calendar

**Epoch**:
The day 1970-01-01 in the proleptic Gregorian calendar, from which day
numbers are counted.
_Avoid_: era, start of era

**Day number**:
A signed count of days from the epoch to a date; negative before it.
_Avoid_: days since start of era, Rata Die (which counts from a different day)

**Era**:
One 400-year cycle of the proleptic Gregorian calendar, always 146097 days
long, after which the calendar repeats exactly.
_Avoid_: epoch

### Clock

**Second of day**:
The number of seconds elapsed since midnight, 0 through 86399. A leap
second, the 61st second of its minute, is not a second of day.
_Avoid_: remainder, time (on its own)
