// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks posixtz.parseLenient against the C library's own reading of TZ.
//
// tools/oracle_tz_dump.zig writes, for each TZ value, the spans this
// library makes of it over a handful of years: where each starts and
// ends, its offset, whether it is daylight saving time, and what it is
// called. This sets TZ to the same value in a child process of its own
// -- glibc keeps what it last read in static storage, and a value that
// fails half way would otherwise inherit the previous one's leftovers --
// and asks localtime_r about every span at its two ends, either side of
// each, and every two hours in between.
//
// TZDIR is pointed at a directory with nothing in it, so that glibc
// cannot find a file named by the value and has to read it as a rule,
// and cannot find `posixrules` either. That is the case parseLenient
// models; a file is the caller's to look for first.
//
// Usage: oracle-tz <path to the dump> <empty directory>

#define _GNU_SOURCE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef __GLIBC__
#include <gnu/libc-version.h>
#endif

#define MAX_SPANS 4096

struct span {
    long long start;
    long long end;
    long offset;
    int isdst;
    char name[64];
};

static struct span spans[MAX_SPANS];
static int span_count = 0;

// Compares glibc's reading of one instant with the span it should fall
// in, printing the first disagreement. Returns nonzero on a mismatch.
static int check(const char *tz, const struct span *span, long long at) {
    time_t t = (time_t)at;
    struct tm tm;
    if (localtime_r(&t, &tm) == NULL) return 0;
    const char *zone = tm.tm_zone ? tm.tm_zone : "";
    if (tm.tm_gmtoff == span->offset && (tm.tm_isdst > 0) == span->isdst &&
        strcmp(zone, span->name) == 0)
        return 0;
    printf("  \"%s\" at %lld\n      ours %ld %s \"%s\"  glibc %ld %s \"%s\"\n", tz, at, span->offset,
           span->isdst ? "dst" : "std", span->name, (long)tm.tm_gmtoff,
           tm.tm_isdst > 0 ? "dst" : "std", zone);
    return 1;
}

// Checks every span of one TZ value, in the child process.
static int check_all(const char *tz) {
    setenv("TZ", tz, 1);
    tzset();

    for (int i = 0; i < span_count; i++) {
        const struct span *span = &spans[i];
        long long points[] = {span->start, span->start + 1, span->end - 1, span->end - 2};
        for (size_t p = 0; p < sizeof points / sizeof points[0]; p++) {
            if (points[p] < span->start || points[p] >= span->end) continue;
            if (check(tz, span, points[p])) return 1;
        }
        for (long long at = span->start; at < span->end; at += 7200) {
            if (check(tz, span, at)) return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: oracle-tz <dump> <empty directory>\n");
        return 2;
    }

    setenv("TZDIR", argv[2], 1);

    FILE *file = fopen(argv[1], "r");
    if (file == NULL) {
        perror(argv[1]);
        return 2;
    }

    char line[4096];
    char tz[1024] = "";
    int have = 0;
    long values = 0, failures = 0;

    // A value's spans run until the next value or the end of the file;
    // `flush` checks the ones gathered.
    for (;;) {
        char *got = fgets(line, sizeof line, file);
        if (got != NULL) {
            size_t length = strlen(line);
            if (length > 0 && line[length - 1] == '\n') line[length - 1] = '\0';
        }

        if (got == NULL || strncmp(line, "Z\t", 2) == 0) {
            if (have) {
                fflush(stdout);
                pid_t child = fork();
                if (child == 0) {
                    int failed = check_all(tz);
                    fflush(stdout);
                    _exit(failed);
                }
                int status = 0;
                waitpid(child, &status, 0);
                values++;
                if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) failures++;
            }
            if (got == NULL) break;
            snprintf(tz, sizeof tz, "%s", line + 2);
            span_count = 0;
            have = 1;
            continue;
        }

        if (strncmp(line, "S\t", 2) == 0) {
            if (span_count >= MAX_SPANS) {
                fprintf(stderr, "oracle: too many spans for \"%s\"\n", tz);
                return 2;
            }
            struct span *span = &spans[span_count];
            char *fields[6];
            int n = 0;
            for (char *at = line + 2, *start = at;; at++) {
                if (*at == '\t' || *at == '\0') {
                    int done = *at == '\0';
                    *at = '\0';
                    if (n < 6) fields[n++] = start;
                    start = at + 1;
                    if (done) break;
                }
            }
            if (n < 4) {
                fprintf(stderr, "oracle: malformed span for \"%s\"\n", tz);
                return 2;
            }
            span->start = atoll(fields[0]);
            span->end = atoll(fields[1]);
            span->offset = atol(fields[2]);
            span->isdst = atoi(fields[3]);
            snprintf(span->name, sizeof span->name, "%s", n > 4 ? fields[4] : "");
            span_count++;
            continue;
        }

        fprintf(stderr, "oracle: unknown record \"%s\"\n", line);
        return 2;
    }

    fclose(file);

#ifdef __GLIBC__
    printf("oracle: %ld TZ values against glibc %s\n", values, gnu_get_libc_version());
#else
    printf("oracle: %ld TZ values against the system C library\n", values);
#endif
    if (failures == 0) {
        printf("oracle: no divergence\n");
        return 0;
    }
    printf("oracle: %ld differ\n", failures);
    return 1;
}
