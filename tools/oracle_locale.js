// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's locales against moment.js's own.
//
// tools/oracle_locale_dump.zig writes one record per line -- the locale's
// tag, the instant in milliseconds, the format string, and what this
// library made of it -- and this asks moment the same question in the same
// locale and reports every answer that differs.
//
// Everything is read in UTC, because a locale decides the words and not
// the offset, and the runner's own zone would otherwise leak into the
// comparison.
//
// Usage: oracle_locale.js <path to moment> <path to the dump>

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const momentPath = process.argv[2];
const dumpPath = process.argv[3];
if (!momentPath || !dumpPath) {
  console.error('usage: oracle_locale.js <moment dir> <dump>');
  process.exit(2);
}

const moment = require(path.resolve(momentPath, 'moment.js'));
const version = require(path.resolve(momentPath, 'package.json')).version;

const localeDir = path.resolve(momentPath, 'locale');
for (const file of fs.readdirSync(localeDir)) {
  if (file.endsWith('.js')) require(path.join(localeDir, file));
}

// Divergences this library knows about and does not intend to fix, with
// the reason. Anything else is a failure.
//
// Keyed by locale tag, each a predicate on the record. Keep this list
// short and keep every entry explained: it is the difference between a
// documented limit and a bug nobody noticed.
const KNOWN = {
  // moment's Turkic ordinals index a table of suffixes that has no entry
  // for every number, and produce the string "NaN" where it does not.
  // This library writes the number. Reproducing a NaN is not parity with
  // anything.
  nan: new Set(['az', 'tk', 'tr']),

  // Ukrainian declines the weekday name after a preposition, which
  // moment selects with a regular expression looking for bracketed text
  // before the sequence. The tokenizer here does not say whether a
  // literal came from brackets, so there is nothing to key that on and
  // the standalone form is written. Belarusian, Georgian, Lithuanian and
  // Russian have the same two forms and look for a particular word in
  // their own alphabet, which no format string written here contains, so
  // they agree either way.
  weekdayInFormat: new Set(['uk']),
};

const mismatches = [];
const excused = new Map();
let checked = 0;

const input = readline.createInterface({
  input: fs.createReadStream(dumpPath),
  crlfDelay: Infinity,
});

input.on('line', (line) => {
  if (line.length === 0) return;

  const parts = line.split('\t');
  if (parts.length !== 4) {
    console.error(`oracle: malformed record: ${JSON.stringify(line)}`);
    process.exit(2);
  }

  const [tag, at, format, ours] = parts;

  moment.locale(tag);
  const theirs = moment.utc(Number(at)).locale(tag).format(format);

  checked += 1;
  if (ours === theirs) return;

  // Seventeen locales rewrite the digits, and some the separators, after
  // formatting -- moment calls it `postformat`, and this library does
  // not do it. Running moment's own over this library's answer is what
  // says the difference is confined to that: everything else, the names
  // and the meridiem and the ordinals, still has to match exactly.
  const data = moment.localeData(tag);
  const postformatted = data.postformat ? data.postformat(ours) : ours;

  let reason = null;
  if (postformatted === theirs) reason = 'postformat';
  else if (KNOWN.nan.has(tag) && theirs.includes('NaN')) reason = 'NaN from moment';
  else if (KNOWN.weekdayInFormat.has(tag) && /d{3,4}/.test(format)) reason = 'in-format weekday';

  if (reason) {
    const key = `${tag}: ${reason}`;
    excused.set(key, (excused.get(key) ?? 0) + 1);
    return;
  }

  mismatches.push({ tag, at, format, ours, theirs });
});

input.on('close', () => {
  console.log(`oracle: ${checked} comparisons across the locales of moment ${version}`);

  if (excused.size > 0) {
    const total = [...excused.values()].reduce((a, b) => a + b, 0);
    console.log(`oracle: ${total} known and documented:`);
    for (const [key, count] of [...excused].sort()) {
      console.log(`    ${key} (${count})`);
    }
  }

  if (mismatches.length === 0) {
    console.log('oracle: no divergence beyond those');
    return;
  }

  console.log(`\noracle: ${mismatches.length} differ\n`);

  // Grouped by locale and format, since one wrong name shows up in every
  // instant and one line each would bury the shape of it.
  const groups = new Map();
  for (const m of mismatches) {
    const key = `${m.tag}  ${JSON.stringify(m.format)}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(m);
  }

  for (const [key, group] of groups) {
    console.log(`  ${key} (${group.length})`);
    for (const m of group.slice(0, 3)) {
      const when = moment.utc(Number(m.at)).format('YYYY-MM-DD HH:mm');
      console.log(`      ${when}  ours ${JSON.stringify(m.ours)}  moment ${JSON.stringify(m.theirs)}`);
    }
    if (group.length > 3) console.log(`      ... and ${group.length - 3} more`);
    console.log();
  }

  process.exit(1);
});
