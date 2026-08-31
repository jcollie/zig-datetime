// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's formatting against moment.js, which is the thing
// its format strings are modelled on.
//
// `tools/oracle_dump.zig` writes one record per line -- the instant in
// milliseconds, the offset to read it at in minutes, the format string,
// and what this library produced -- and this asks moment the same question
// and reports every answer that differs. It exits non-zero when any do, so `zig build oracle` fails on
// a divergence rather than printing one and passing.
//
// Usage: node oracle.js <path to moment.js> <path to the dump>
//
// moment is read from a path rather than from node_modules because it is
// pinned in build.zig.zon and unpacked by the Zig package manager; see
// build.zig.
//
// The offset is applied with `utcOffset`, which moves the reading without
// moving the instant. That keeps the moment in UTC mode, which is the
// case every DateTime corresponds to: one carrying an explicit offset is
// still `_isUTC` as far as moment is concerned, which is why `z` says
// "UTC" whatever the offset.

'use strict';

const fs = require('fs');

const [momentPath, dumpPath] = process.argv.slice(2);
if (!momentPath || !dumpPath) {
    console.error('usage: oracle.js <moment.js> <dump>');
    process.exit(2);
}

const moment = require(momentPath);

const lines = fs.readFileSync(dumpPath, 'utf8').split('\n').filter((l) => l.length > 0);

const mismatches = [];
let checked = 0;

for (const line of lines) {
    // Only the first three tabs separate fields; a formatted result may
    // legitimately contain one, though nothing in the corpus does.
    const first = line.indexOf('\t');
    const second = line.indexOf('\t', first + 1);
    const third = line.indexOf('\t', second + 1);
    if (first < 0 || second < 0 || third < 0) {
        console.error(`oracle: malformed record: ${JSON.stringify(line)}`);
        process.exit(2);
    }

    const at = Number(line.slice(0, first));
    const minutes = Number(line.slice(first + 1, second));
    const format = line.slice(second + 1, third);
    const ours = line.slice(third + 1);

    const theirs = moment.utc(at).utcOffset(minutes).format(format);
    checked += 1;

    if (ours !== theirs) {
        mismatches.push({ at, minutes, format, ours, theirs });
    }
}

// Group by format string, since a sequence that disagrees usually does so
// for every instant and one line per date would bury the shape of it.
const byFormat = new Map();
for (const m of mismatches) {
    if (!byFormat.has(m.format)) byFormat.set(m.format, []);
    byFormat.get(m.format).push(m);
}

console.log(`oracle: ${checked} comparisons against moment ${moment.version}`);

if (mismatches.length === 0) {
    console.log('oracle: no divergence');
    process.exit(0);
}

console.log(`oracle: ${mismatches.length} differ, across ${byFormat.size} format strings\n`);

for (const [format, group] of byFormat) {
    console.log(`  ${JSON.stringify(format)} (${group.length} of ${lines.length / byFormat.size | 0})`);
    for (const m of group.slice(0, 4)) {
        const when = moment.utc(m.at).toISOString();
        console.log(
            `      ${when} @${m.minutes}  ours ${JSON.stringify(m.ours)}  moment ${JSON.stringify(m.theirs)}`
        );
    }
    if (group.length > 4) console.log(`      ... and ${group.length - 4} more`);
}

process.exit(1);
