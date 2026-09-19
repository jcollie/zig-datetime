// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's strftime support against the C library's own.
//
// tools/oracle_strftime_dump.zig writes one record per line -- the
// instant in milliseconds, the offset it is read at in minutes, the zone
// name, the format string, and what this library made of it -- and this
// asks the C library the same question and reports every answer that
// differs.
//
// The `C` locale is set explicitly rather than inherited, because that is
// the locale whose month names, meridiem and %c arrangement this library
// implements; a machine with LC_TIME set to something else would
// otherwise be comparing against a different specification.
//
// The broken-down time is built with gmtime_r on the instant already
// shifted by the offset, which is exactly what the Zig side does to get
// its wall-clock fields, and then tm_gmtoff and tm_zone are filled in by
// hand so that %z and %Z have something true to say. glibc reads both.
//
// Usage: oracle-strftime <path to the dump>

#define _GNU_SOURCE

#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __GLIBC__
#include <gnu/libc-version.h>
#endif

#define MAX_MISMATCHES 64

struct mismatch {
    char format[64];
    char detail[256];
};

static struct mismatch mismatches[MAX_MISMATCHES];
static int mismatch_count = 0;
static int overflowed = 0;

// The known divergences, counted by the reason each one was allowed, so
// that the summary says what was skipped rather than only how much.
#define MAX_REASONS 16
static struct {
    const char *why;
    long count;
} reasons[MAX_REASONS];
static int reason_count = 0;

static void allow(const char *why) {
    for (int i = 0; i < reason_count; i++) {
        if (strcmp(reasons[i].why, why) == 0) {
            reasons[i].count++;
            return;
        }
    }
    if (reason_count < MAX_REASONS) {
        reasons[reason_count].why = why;
        reasons[reason_count].count = 1;
        reason_count++;
    }
}

static void record(const char *format, const char *detail) {
    if (mismatch_count >= MAX_MISMATCHES) {
        overflowed = 1;
        return;
    }
    snprintf(mismatches[mismatch_count].format, sizeof mismatches[0].format, "%s", format);
    snprintf(mismatches[mismatch_count].detail, sizeof mismatches[0].detail, "%s", detail);
    mismatch_count++;
}

// The two places this library deliberately answers something else than
// glibc does. Both are cases where glibc has nowhere to put an answer and
// falls back to the running process's timezone, which a DateTime -- a
// wall-clock reading that carries its own offset -- has no business
// consulting.
//
// %s: glibc reaches a struct tm through mktime, so its seconds-since-the-
// epoch are the fields read against TZ and tm_gmtoff is ignored. Here the
// offset on the reading is what says which instant it names. At a zero
// offset the two questions coincide, which is where they are compared.
//
// %G, %g and %V on the way back in: glibc's strptime reads an ISO week
// date and throws it away, where this resolves it into a date, because
// Date.fromWeek exists and a format string that round trips is worth
// more than bug-for-bug agreement.
// Whether `format` asks for the conversion `letter`, whatever flags,
// width or modifier were written in between. A plain strstr would miss
// the letter in "%-V" and find it in the "%s" of a "%Es", which is the
// difference between a known divergence and a silent gap in the check.
static int has_conversion(const char *format, char letter) {
    for (const char *at = format; *at != '\0'; at++) {
        if (*at != '%') continue;
        at++;
        while (*at != '\0' && strchr("-_0^#", *at) != NULL) at++;
        while (*at >= '0' && *at <= '9') at++;
        if (*at == 'E' || *at == 'O') at++;
        while (*at == ':') at++;
        if (*at == '\0') break;
        if (*at == letter) return 1;
        if (*at == '%') continue;
    }
    return 0;
}

// Whether `format` carries a flag, a width or an E/O modifier anywhere.
static int decorated(const char *format) {
    for (const char *at = format; *at != '\0'; at++) {
        if (*at != '%') continue;
        at++;
        if (*at == '\0') break;
        if (strchr("-_0^#", *at) != NULL) return 1;
        if (*at >= '1' && *at <= '9') return 1;
        if (*at == 'E' || *at == 'O') return 1;
    }
    return 0;
}

static const char *known_format_divergence(const char *format, long minutes) {
    if (has_conversion(format, 's') && minutes != 0)
        return "%s: glibc ignores tm_gmtoff and reads the fields against TZ";
    return NULL;
}

static const char *known_parse_divergence(const char *format, const char *input) {
    // glibc's strftime writes a negative count of seconds for a time
    // before the epoch and its strptime then reads no sign, so what it
    // wrote it cannot read. This reads one.
    if (has_conversion(format, 's') && input[0] == '-')
        return "%s before the epoch: glibc's strptime reads no sign";

    if (has_conversion(format, 'G') || has_conversion(format, 'V') ||
        has_conversion(format, 'g'))
        return "%G/%g/%V: glibc reads an ISO week date and drops it";

    if (has_conversion(format, 'P'))
        return "%P: a formatting extension glibc's strptime does not read";

    // glibc turns a day of the year into a month and a day only when the
    // format also named a year, because %Y is what sets its want_xday.
    if (has_conversion(format, 'j') && !has_conversion(format, 'Y') &&
        !has_conversion(format, 'F') && !has_conversion(format, 'D') &&
        !has_conversion(format, 'x') && !has_conversion(format, 'c'))
        return "%j alone: glibc keeps the day of the year without resolving it";

    // glibc's strptime takes no flags and no widths, and takes E and O
    // only for the handful of conversions its locale data covers. Here
    // they are read and ignored, so that a format string that writes a
    // date can read one back.
    if (decorated(format))
        return "a flag, a width or an E/O modifier, which glibc's strptime refuses";

    return NULL;
}

// Splits a tab separated line in place, returning how many fields were
// found. Trailing empty fields count, which is what lets a refusal be
// written as empty columns.
static int split(char *line, char *fields[], int max) {
    int count = 0;
    char *start = line;

    for (char *at = line;; at++) {
        if (*at == '\t' || *at == '\0') {
            int done = (*at == '\0');
            if (count < max) {
                *at = '\0';
                fields[count++] = start;
            }
            start = at + 1;
            if (done) break;
        }
    }

    return count;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: oracle-strftime <dump>\n");
        return 2;
    }

    if (setlocale(LC_ALL, "C") == NULL) {
        fprintf(stderr, "oracle: cannot set the C locale\n");
        return 2;
    }

    FILE *file = fopen(argv[1], "r");
    if (file == NULL) {
        perror(argv[1]);
        return 2;
    }

    char line[4096];
    long checked = 0;
    long known = 0;

    while (fgets(line, sizeof line, file) != NULL) {
        size_t length = strlen(line);
        if (length > 0 && line[length - 1] == '\n') line[length - 1] = '\0';
        if (line[0] == '\0') continue;

        char *fields[12];
        int count = split(line, fields, 12);

        if (strcmp(fields[0], "F") == 0) {
            if (count != 6) {
                fprintf(stderr, "oracle: malformed F record\n");
                return 2;
            }

            long long at = atoll(fields[1]);
            long minutes = atol(fields[2]);
            const char *name = fields[3];
            const char *format = fields[4];
            const char *ours = fields[5];

            // The wall-clock fields the Zig side has: the instant moved by
            // the offset and then read as if it were UTC.
            time_t shifted = (time_t)(at / 1000) + minutes * 60;
            if (at < 0 && at % 1000 != 0) shifted -= 1;

            struct tm tm;
            if (gmtime_r(&shifted, &tm) == NULL) {
                fprintf(stderr, "oracle: gmtime_r refused %lld\n", at);
                return 2;
            }
            tm.tm_gmtoff = minutes * 60;
            tm.tm_zone = name;
            tm.tm_isdst = 0;

            char theirs[512];
            size_t written = strftime(theirs, sizeof theirs, format, &tm);
            theirs[written] = '\0';

            checked++;
            if (strcmp(ours, theirs) != 0) {
                const char *why = known_format_divergence(format, minutes);
                if (why != NULL) {
                    known++;
                    allow(why);
                } else {
                    char detail[256];
                    snprintf(detail, sizeof detail, "%lld @%ld  ours \"%s\"  glibc \"%s\"",
                             at, minutes, ours, theirs);
                    record(format, detail);
                }
            }
        } else if (strcmp(fields[0], "P") == 0) {
            if (count != 10) {
                fprintf(stderr, "oracle: malformed P record\n");
                return 2;
            }

            const char *format = fields[1];
            const char *input = fields[2];
            const char *status = fields[3];

            // The same reference this library parses from, so that the
            // fields a format string does not mention agree by
            // construction rather than by accident: the Unix epoch.
            struct tm tm;
            memset(&tm, 0, sizeof tm);
            tm.tm_year = 70;
            tm.tm_mday = 1;
            tm.tm_wday = 4;
            tm.tm_isdst = 0;

            char *rest = strptime(input, format, &tm);

            char ours[128];
            char theirs[128];

            if (strcmp(status, "err") == 0) {
                snprintf(ours, sizeof ours, "REFUSED");
            } else {
                snprintf(ours, sizeof ours, "%s %s-%s-%s %s:%s:%s",
                         fields[3], fields[4], fields[5], fields[6],
                         fields[7], fields[8], fields[9]);
            }

            if (rest == NULL) {
                snprintf(theirs, sizeof theirs, "REFUSED");
            } else {
                snprintf(theirs, sizeof theirs, "%zu %d-%d-%d %d:%d:%d",
                         (size_t)(rest - input), tm.tm_year + 1900, tm.tm_mon + 1,
                         tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
            }

            checked++;
            if (strcmp(ours, theirs) != 0) {
                const char *why = known_parse_divergence(format, input);
                if (why != NULL) {
                    known++;
                    allow(why);
                } else {
                    char detail[256];
                    snprintf(detail, sizeof detail, "\"%s\"  ours [%s]  glibc [%s]",
                             input, ours, theirs);
                    record(format, detail);
                }
            }
        } else {
            fprintf(stderr, "oracle: unknown record kind \"%s\"\n", fields[0]);
            return 2;
        }
    }

    fclose(file);

#ifdef __GLIBC__
    printf("oracle: %ld comparisons against glibc %s\n", checked, gnu_get_libc_version());
#else
    printf("oracle: %ld comparisons against the system C library\n", checked);
#endif

    if (known > 0) {
        printf("oracle: %ld known and documented:\n", known);
        for (int i = 0; i < reason_count; i++)
            printf("    %s (%ld)\n", reasons[i].why, reasons[i].count);
    }

    if (mismatch_count == 0) {
        printf("oracle: no divergence%s\n", known > 0 ? " beyond those" : "");
        return 0;
    }

    printf("oracle: %d differ%s\n\n", mismatch_count, overflowed ? " (and more, not listed)" : "");
    for (int i = 0; i < mismatch_count; i++) {
        printf("  \"%s\"\n      %s\n", mismatches[i].format, mismatches[i].detail);
    }

    return 1;
}
