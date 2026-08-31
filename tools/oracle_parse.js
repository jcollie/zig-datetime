// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's parsing against moment.js.
//
// `tools/oracle_parse_dump.zig` writes one record per line -- the format
// string, the input, whether this library parsed it, and either what it
// parsed to or why it refused -- and this asks moment the same question.
//
// This library has the same two parsing modes moment does, so each record
// says which mode it was read in and is held to the matching mode of
// moment. A divergence is a divergence now rather than a survey finding.
//
// Usage: node oracle_parse.js <path to moment.js> <path to the dump>
//
// `moment.parseZone` rather than `moment.utc`, because it keeps the offset
// the input carried instead of converting away from it, which is what this
// library does. moment's `now` is pinned to the reference instant the Zig
// side defaults from, since both fill in unmentioned fields from it and a
// floating reference would make the comparison depend on the clock.
//
// `parseZone` reads a moment with no offset in it as local, so the date it
// defaults from is the reference in the machine's own zone. build.zig runs
// this with TZ=UTC for that reason; without it the survey would report a
// day's difference on every input that names no date, and the difference
// would be the runner's timezone rather than anything about the library.

'use strict';

const fs = require('fs');

const [momentPath, dumpPath] = process.argv.slice(2);
if (!momentPath || !dumpPath) {
    console.error('usage: oracle_parse.js <moment.js> <dump>');
    process.exit(2);
}

const moment = require(momentPath);

// 2001-09-09T01:46:40Z, the same instant `reference` names in the dumper.
const REFERENCE = 1000000000000;
moment.now = () => REFERENCE;

const CANONICAL = 'YYYY-MM-DDTHH:mm:ss.SSSZ';

/** What moment made of one case, in the shape the dump reports. */
function ask(input, format, strict) {
    const m = moment.parseZone(input, format, strict);
    if (!m.isValid()) return { ok: false };

    // How much of the input moment actually used, so that a parse which
    // stopped early can be told from one that consumed everything.
    const leftOver = m.parsingFlags().unusedInput.join('').length;
    return { ok: true, consumed: input.length - leftOver, value: m.format(CANONICAL) };
}

/** Whether our record and moment's answer say the same thing. */
function agrees(ours, theirs) {
    if (ours.ok !== theirs.ok) return false;
    if (!ours.ok) return true;
    return ours.value === theirs.value && ours.consumed === theirs.consumed;
}

const lines = fs.readFileSync(dumpPath, 'utf8').split('\n').filter((l) => l.length > 0);

const rows = [];
for (const line of lines) {
    const parts = [];
    let at = 0;
    for (let i = 0; i < 4; i++) {
        const next = line.indexOf('\t', at);
        if (next < 0) {
            console.error(`oracle: malformed record: ${JSON.stringify(line)}`);
            process.exit(2);
        }
        parts.push(line.slice(at, next));
        at = next + 1;
    }
    const [format, input, mode, status] = parts;
    const detail = line.slice(at);

    let ours;
    if (status === 'ok') {
        const space = detail.indexOf(' ');
        ours = { ok: true, consumed: Number(detail.slice(0, space)), value: detail.slice(space + 1) };
    } else {
        ours = { ok: false, error: detail };
    }

    rows.push({ format, input, mode, ours, theirs: ask(input, format, mode === 'strict') });
}

const show = (r) => (r.ok ? `${r.value} (${r.consumed} used)` : `refused${r.error ? ' ' + r.error : ''}`);

// The one thing lenient parsing does not follow moment on.
//
// moment's lenient mode does not read a format string left to right
// against the input: for each sequence it searches the rest of the input
// for something that sequence's pattern matches, skips whatever came
// before, and skips the sequence entirely when nothing matches. So a
// separator that does not match is stepped over, and an input that runs
// out is padded with whatever the sequences would have defaulted to.
//
// This library reads left to right in both modes and refuses instead.
// These are the cases in the corpus where that shows. Anything else is a
// regression, and fails the build.
const KNOWN = [
    ['YYYY-MM-DD', '2024/03/15', 'lenient'],
    ['YYYY-MM-DD', '2024-03', 'lenient'],
    ['HH:mm', '14', 'lenient'],
];

const isKnown = (r) => KNOWN.some(([f, i, m]) => r.format === f && r.input === i && r.mode === m);

const disputed = rows.filter((r) => !agrees(r.ours, r.theirs) && !isKnown(r));

const knownSeen = rows.filter((r) => isKnown(r) && !agrees(r.ours, r.theirs)).length;
if (knownSeen !== KNOWN.length) {
    console.log(
        `oracle: ${knownSeen} of ${KNOWN.length} known divergences still diverge` +
            ' -- if one was fixed, take it out of KNOWN'
    );
}

console.log(`oracle: ${rows.length} parses against moment ${moment.version}, in both modes`);

if (disputed.length === 0) {
    console.log(`oracle: no divergence beyond the ${KNOWN.length} known and documented`);
    process.exit(0);
}

console.log(`oracle: ${disputed.length} differ\n`);

// Group by format string and mode, since a disagreement usually holds for
// every instant a round trip walks.
const groups = new Map();
for (const r of disputed) {
    const key = `${r.format}\u0000${r.mode}`;
    if (!groups.has(key)) groups.set(key, { format: r.format, mode: r.mode, cases: [] });
    groups.get(key).cases.push(r);
}

for (const g of groups.values()) {
    console.log(`  ${JSON.stringify(g.format)} ${g.mode} (${g.cases.length})`);
    const seen = new Set();
    for (const r of g.cases) {
        const signature = `${show(r.ours)}|${show(r.theirs)}`.replace(/\d/g, '#');
        if (seen.has(signature)) continue;
        seen.add(signature);
        if (seen.size > 3) break;
        console.log(`      ${JSON.stringify(r.input)}`);
        console.log(`          ours   ${show(r.ours)}`);
        console.log(`          moment ${show(r.theirs)}`);
    }
    console.log();
}

process.exit(1);
