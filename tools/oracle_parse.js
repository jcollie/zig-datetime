// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's parsing against moment.js.
//
// `tools/oracle_parse_dump.zig` writes one record per line -- the format
// string, the input, whether this library parsed it, and either what it
// parsed to or why it refused -- and this asks moment the same question.
//
// moment parses in two modes and they disagree about most of the awkward
// cases, so every record is checked against both rather than one being
// picked in advance. That is the point of running this now: the report
// says which mode this library resembles, case by case, which is the thing
// worth knowing before deciding which to match.
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
    const first = line.indexOf('\t');
    const second = line.indexOf('\t', first + 1);
    const third = line.indexOf('\t', second + 1);
    if (first < 0 || second < 0 || third < 0) {
        console.error(`oracle: malformed record: ${JSON.stringify(line)}`);
        process.exit(2);
    }

    const format = line.slice(0, first);
    const input = line.slice(first + 1, second);
    const status = line.slice(second + 1, third);
    const detail = line.slice(third + 1);

    let ours;
    if (status === 'ok') {
        const space = detail.indexOf(' ');
        ours = { ok: true, consumed: Number(detail.slice(0, space)), value: detail.slice(space + 1) };
    } else {
        ours = { ok: false, error: detail };
    }

    rows.push({
        format,
        input,
        ours,
        lenient: ask(input, format, false),
        strict: ask(input, format, true),
    });
}

const tally = { both: 0, lenientOnly: 0, strictOnly: 0, neither: 0 };
for (const r of rows) {
    const l = agrees(r.ours, r.lenient);
    const s = agrees(r.ours, r.strict);
    if (l && s) tally.both += 1;
    else if (l) tally.lenientOnly += 1;
    else if (s) tally.strictOnly += 1;
    else tally.neither += 1;
}

const show = (r) => (r.ok ? `${r.value} (${r.consumed} used)` : `refused${r.error ? ' ' + r.error : ''}`);

console.log(`oracle: ${rows.length} parses against moment ${moment.version}`);
console.log(`  agree with both modes        ${tally.both}`);
console.log(`  agree with lenient only      ${tally.lenientOnly}`);
console.log(`  agree with strict only       ${tally.strictOnly}`);
console.log(`  agree with neither           ${tally.neither}`);

const disputed = rows.filter((r) => !agrees(r.ours, r.lenient) || !agrees(r.ours, r.strict));
if (disputed.length === 0) {
    console.log('oracle: no divergence in either mode');
    process.exit(0);
}

console.log(`\noracle: ${disputed.length} cases where the three do not all agree\n`);

// Group by the format string and by which modes agreed, so that a
// disagreement that holds for every instant is reported once with a count
// rather than once per instant.
const groups = new Map();
for (const r of disputed) {
    const shape = `${agrees(r.ours, r.lenient) ? 'L' : '-'}${agrees(r.ours, r.strict) ? 'S' : '-'}`;
    const key = `${r.format}\u0000${shape}`;
    if (!groups.has(key)) groups.set(key, { format: r.format, shape, cases: [] });
    groups.get(key).cases.push(r);
}

const label = { '--': 'we match neither mode', 'L-': 'we match lenient only', '-S': 'we match strict only' };

for (const g of groups.values()) {
    console.log(`  ${JSON.stringify(g.format)} -- ${label[g.shape]} (${g.cases.length} case${g.cases.length === 1 ? '' : 's'})`);
    const seen = new Set();
    for (const r of g.cases) {
        // One example per distinct disagreement, since the round trip
        // repeats the same shape across every instant it walks.
        const signature = `${show(r.ours)}|${show(r.lenient)}|${show(r.strict)}`.replace(/\d/g, '#');
        if (seen.has(signature)) continue;
        seen.add(signature);
        if (seen.size > 3) break;

        console.log(`      ${JSON.stringify(r.input)}`);
        console.log(`          ours    ${show(r.ours)}`);
        console.log(`          lenient ${show(r.lenient)}`);
        console.log(`          strict  ${show(r.strict)}`);
    }
    console.log();
}

// Reporting is the job for now: this is a survey of where the two stand,
// not a gate, so a divergence is not yet a failure. `zig build test` does
// not depend on this step.
process.exit(0);
