// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Turns the Unicode CLDR's JSON distribution into cldrlocales.zig, the
// table `cldrlocale.zig` reads when a build asks for -Dembed-cldr.
//
// The data is the Unicode Consortium's own rather than a transcription of
// it, for the same reason the timezone database is IANA's own output and
// the moment.js locales are moment's: CLDR is what this library's pattern
// formatting is checked against, so a locale that disagreed with CLDR's
// would be a divergence built in at the source. Bumping the pins in
// build.zig.zon and running this again is what keeps them in step.
//
// CLDR is split across three packages by what the data is about, and a
// locale needs all three:
//
//   cldr-dates-full    the calendar itself -- month, day, quarter, era
//                      and day period names, and the locale's own date
//                      and time patterns -- plus the formats a timezone
//                      offset is written in.
//   cldr-core          the supplemental data, which is keyed by region or
//                      by language rather than by locale: which day the
//                      week starts on, when each flexible day period
//                      runs, and the digits of every numbering system.
//   cldr-numbers-full  which numbering system a locale writes numbers in,
//                      which is the difference between 2024 and ২০২৪.
//
// Usage: gen_cldr.js <core dir> <dates dir> <numbers dir> <output file> [locales]
//
// `locales` is a comma separated list from -Dcldr-locales that narrows
// the table to those identifiers; empty means every locale CLDR ships.
//
// One thing CLDR says that this does not carry: a pattern may name a
// numbering system for one of its fields rather than for all of them, and
// the systems it names that way are algorithmic -- Hawaiian's short date
// writes its month in lowercase Roman numerals. A numbering system in
// this library is ten digits, so those overrides are dropped and the
// field is written in the locale's ordinary digits. Every one that is
// dropped is reported when this runs.

const fs = require('fs');
const path = require('path');

const corePath = process.argv[2];
const datesPath = process.argv[3];
const numbersPath = process.argv[4];
const outputPath = process.argv[5];
const subset = (process.argv[6] || '').trim();

if (!corePath || !datesPath || !numbersPath || !outputPath) {
  console.error('usage: gen_cldr.js <core dir> <dates dir> <numbers dir> <output file> [locales]');
  process.exit(2);
}

const read = (...parts) => JSON.parse(fs.readFileSync(path.resolve(...parts), 'utf8'));

const version = read(corePath, 'package.json').version;

const weekData = read(corePath, 'supplemental', 'weekData.json').supplemental.weekData;
const likelySubtags = read(corePath, 'supplemental', 'likelySubtags.json').supplemental.likelySubtags;
const dayPeriodRuleSets = read(corePath, 'supplemental', 'dayPeriods.json').supplemental.dayPeriodRuleSet;
const numberingSystems = read(corePath, 'supplemental', 'numberingSystems.json').supplemental.numberingSystems;

// ---------------------------------------------------------------------
// The shapes the Zig side expects, in the order it reads them.

// `cldrlocale.Width`: wide, abbreviated, narrow.
const WIDTHS = ['wide', 'abbreviated', 'narrow'];
// `cldrlocale.WeekdayWidth`, which has one more.
const WEEKDAY_WIDTHS = ['wide', 'abbreviated', 'short', 'narrow'];
// `cldrlocale.Context`, in CLDR's own spelling of the second one.
const CONTEXTS = ['format', 'stand-alone'];
// `cldrlocale.Length`.
const LENGTHS = ['full', 'long', 'medium', 'short'];
// `DayOfWeek`, which numbers Sunday zero, in CLDR's spelling.
const WEEKDAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
// `cldrlocale.DayPeriod`, in its own order rather than CLDR's.
const DAY_PERIOD_KEYS = [
  'midnight', 'am', 'noon', 'pm',
  'morning1', 'morning2',
  'afternoon1', 'afternoon2',
  'evening1', 'evening2',
  'night1', 'night2',
];

// ---------------------------------------------------------------------
// Writing Zig.

// The characters that have to be escaped to survive a Zig string literal,
// plus the ones that would survive but should not be written raw: CLDR
// puts bidirectional formatting marks inside several locales' timezone
// formats, and a source file with invisible characters in it is a source
// file nobody can edit.
const INVISIBLE = new Set([
  0x00a0, 0x061c, 0x200b, 0x200c, 0x200d, 0x200e, 0x200f,
  0x2028, 0x2029, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
  0x2060, 0x2066, 0x2067, 0x2068, 0x2069, 0xfeff,
]);

function zigString(text) {
  let out = '"';
  for (const character of text) {
    const code = character.codePointAt(0);
    if (character === '"') out += '\\"';
    else if (character === '\\') out += '\\\\';
    else if (code < 0x20 || code === 0x7f || INVISIBLE.has(code)) {
      out += '\\u{' + code.toString(16) + '}';
    } else out += character;
  }
  return out + '"';
}

// A list of strings on one line, which is how every name table is
// written: the tables are wide and there are hundreds of them, so one
// name per line would make a file too large to open.
const zigStrings = (list) => '.{ ' + list.map(zigString).join(', ') + ' }';

// The same list behind an explicit array type, which is how a row that is
// not nested inside one is written: an anonymous initializer has no type
// to infer from a struct field whose type the generated file cannot name.
const zigArray = (type, list) => type + '{ ' + list.map(zigString).join(', ') + ' }';

// ---------------------------------------------------------------------
// Reading CLDR.

// Returns the names of one context at every width.
//
// A name a locale does not define at some width is filled in from
// another, which is CLDR's own fallback and is done name by name rather
// than table by table: a locale may define every month at every width and
// still name only one of the flexible day periods, and taking the whole
// table from elsewhere because one entry was missing would replace names
// it did define. What is left empty after that is a name the locale
// really does not have, which only happens to the flexible day periods
// and which `cldr.zig` answers by falling back to the meridiem.
function widths(names, order, keys, fallbackOrder) {
  return order.map((width) =>
    keys.map((key) => {
      for (const candidate of [width, ...fallbackOrder]) {
        const value = names && names[candidate] && names[candidate][key];
        if (typeof value === 'string' && value.length > 0) return value;
      }
      return '';
    }),
  );
}

// The pattern a length stands for.
//
// Usually a string. A locale may instead give an object carrying the
// pattern under `_value` and a `_numbers` override beside it, which says
// that one field of that pattern is written in a different numbering
// system from the rest: Hawaiian writes the month of its short date in
// lowercase Roman numerals. Those systems are algorithmic rather than a
// table of ten digits, so the override is dropped and the pattern taken,
// which is written down at the top of the file and reported here so that
// a new one cannot appear unnoticed.
function patternOf(value, tag, which, length) {
  if (typeof value === 'string') return value;
  if (value && typeof value._value === 'string') {
    if (value._numbers) {
      overrides.push(`${tag}: the ${which} ${length} pattern asks for ${value._numbers}, which is not written`);
    }
    return value._value;
  }
  return undefined;
}

const overrides = [];

const MONTH_KEYS = Array.from({ length: 12 }, (_, index) => String(index + 1));
const QUARTER_KEYS = ['1', '2', '3', '4'];

// The two halves of a name table: what a locale writes inside a date, and
// what it writes on its own. The second is emitted as null when it is the
// same as the first, which is most languages and which halves the size of
// the table.
function contexts(root, order, keys, fallbackOrder) {
  const format = widths(root && root[CONTEXTS[0]], order, keys, fallbackOrder);
  const standalone = widths(root && root[CONTEXTS[1]], order, keys, fallbackOrder);
  const same = JSON.stringify(format) === JSON.stringify(standalone);
  return { format, standalone: same ? null : standalone };
}

// Which region's week rule a locale follows.
//
// CLDR keys its week data by region and a locale need not name one, so
// `en` has to be resolved to `en-Latn-US` before the table can be asked.
// That is what likelySubtags is for, and it is the same lookup ICU makes.
function regionOf(tag) {
  const explicit = tag.split('-').find((part) => /^[A-Z]{2}$/.test(part) || /^[0-9]{3}$/.test(part));
  if (explicit) return explicit;

  for (const candidate of [tag, tag.split('-')[0]]) {
    const likely = likelySubtags[candidate];
    if (!likely) continue;
    const region = likely.split('-').find((part) => /^[A-Z]{2}$/.test(part) || /^[0-9]{3}$/.test(part));
    if (region) return region;
  }
  return '001';
}

// The rules saying when each flexible day period runs.
//
// Keyed by language rather than by locale, with a few entries naming a
// region as well, so the full tag is tried before the language it belongs
// to. A language CLDR has no rules for gets none, and `B` then falls back
// to writing the meridiem.
function dayPeriodRules(tag) {
  const language = tag.split('-')[0];
  const set = dayPeriodRuleSets[tag] || dayPeriodRuleSets[language];
  if (!set) return [];

  const minutes = (text) => {
    const [hours, mins] = text.split(':').map(Number);
    return hours * 60 + mins;
  };

  const rules = [];
  for (const [name, rule] of Object.entries(set)) {
    const period = DAY_PERIOD_KEYS.indexOf(name);
    if (period < 0) continue;
    if (rule._at !== undefined) {
      rules.push([period, minutes(rule._at), minutes(rule._at), 1]);
    } else if (rule._from !== undefined && rule._before !== undefined) {
      rules.push([period, minutes(rule._from), minutes(rule._before), 0]);
    }
  }

  // The instants first, so that `Locale.dayPeriodAt` can try them without
  // sorting: noon is inside the afternoon's span in every locale that has
  // both, and the more specific answer is the right one.
  rules.sort((a, b) => b[3] - a[3]);
  return rules;
}

// The ten digits a locale writes numbers with, or null for the Western
// ones.
//
// CLDR treats this as part of the locale rather than as something done to
// the output afterwards, which is the difference between this and the
// `postformat` step moment.js bolts on: a Bengali date really is written
// in Bengali digits by the formatter.
function digitsOf(tag) {
  let numbers;
  try {
    numbers = read(numbersPath, 'main', tag, 'numbers.json').main[tag].numbers;
  } catch {
    return null;
  }
  const system = numbers.defaultNumberingSystem;
  if (!system || system === 'latn') return null;

  const definition = numberingSystems[system];
  if (!definition || definition._type !== 'numeric' || !definition._digits) return null;
  return Array.from(definition._digits);
}

// ---------------------------------------------------------------------

const mainDir = path.resolve(datesPath, 'main');
let tags = fs
  .readdirSync(mainDir)
  .filter((tag) => fs.existsSync(path.join(mainDir, tag, 'ca-gregorian.json')))
  .filter((tag) => fs.existsSync(path.join(mainDir, tag, 'timeZoneNames.json')));

if (subset.length > 0) {
  const wanted = new Set(subset.split(',').map((each) => each.trim().toLowerCase()).filter(Boolean));
  const found = new Set();
  tags = tags.filter((tag) => {
    if (!wanted.has(tag.toLowerCase())) return false;
    found.add(tag.toLowerCase());
    return true;
  });
  for (const each of wanted) {
    if (!found.has(each)) console.error(`gen_cldr: -Dcldr-locales names ${each}, which CLDR does not ship`);
  }
}

// Sorted the way `cldrlocale.orderIgnoreCase` compares, because that is
// what `byName` binary searches with: by ASCII code point with case
// folded away, and a shorter tag before a longer one it is a prefix of.
tags.sort((a, b) => {
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  const shortest = Math.min(left.length, right.length);
  for (let index = 0; index < shortest; index += 1) {
    if (left.charCodeAt(index) !== right.charCodeAt(index)) {
      return left.charCodeAt(index) < right.charCodeAt(index) ? -1 : 1;
    }
  }
  return a.length - b.length;
});

const out = [];
// The header the generated file carries, which is the Unicode
// Consortium's licensing rather than this project's: everything in the
// table is CLDR's data. The same header src/windowszones.zig carries, and
// for the same reason.
// REUSE-IgnoreStart
out.push('// SPDX-FileCopyrightText: © 1991-2026 Unicode, Inc.');
out.push('// SPDX-License-Identifier: Unicode-3.0');
// REUSE-IgnoreEnd
out.push('');
out.push('//! Generated by tools/gen_cldr.js from the Unicode CLDR. Do not edit.');
out.push('//!');
out.push('//! The shape is a tuple of anonymous struct literals rather than a named');
out.push('//! type, so that this does not have to name anything from the library;');
out.push('//! `cldrlocale.fromEntry` is what reads them back. See');
out.push('//! src/cldrlocales/stub.zig, which stands in for this when a build does');
out.push('//! not ask for -Dembed-cldr.');
out.push('');
out.push('pub const entries = .{');

let count = 0;
const warnings = [];

for (const tag of tags) {
  const gregorian = read(datesPath, 'main', tag, 'ca-gregorian.json').main[tag].dates.calendars.gregorian;
  const zoneNames = read(datesPath, 'main', tag, 'timeZoneNames.json').main[tag].dates.timeZoneNames;

  const months = contexts(gregorian.months, WIDTHS, MONTH_KEYS, ['wide', 'abbreviated']);
  const weekdays = contexts(gregorian.days, WEEKDAY_WIDTHS, WEEKDAY_KEYS, ['abbreviated', 'wide']);
  const quarters = contexts(gregorian.quarters, WIDTHS, QUARTER_KEYS, ['wide', 'abbreviated']);
  const periods = contexts(gregorian.dayPeriods, WIDTHS, DAY_PERIOD_KEYS, ['abbreviated', 'wide']);

  // The eras have widths but no contexts, and CLDR names the three
  // widths rather than numbering them. The `-alt-variant` entries beside
  // them are the common-era spellings, which are a different era name
  // rather than a different width, so they are left alone.
  const eras = [
    [gregorian.eras.eraNames['0'], gregorian.eras.eraNames['1']],
    [gregorian.eras.eraAbbr['0'], gregorian.eras.eraAbbr['1']],
    [gregorian.eras.eraNarrow['0'], gregorian.eras.eraNarrow['1']],
  ].map((pair, index) =>
    pair.map((name, side) => name || eras_fallback(gregorian, index, side)),
  );

  // The `-alt-ascii` variants beside the time patterns are the same
  // pattern with a plain space or a plain colon, offered for a
  // destination that cannot carry the real ones; the plain key is the
  // locale's own answer and is the one to take.
  const dateFormats = LENGTHS.map((length) => patternOf(gregorian.dateFormats[length], tag, 'date', length));
  const timeFormats = LENGTHS.map((length) => patternOf(gregorian.timeFormats[length], tag, 'time', length));
  const dateTimeFormats = LENGTHS.map((length) =>
    patternOf(gregorian.dateTimeFormats[length], tag, 'date-time', length),
  );

  // The glue for a date joined to a particular time of day, which is the
  // one ICU uses and so the one `cldr.formatDateTime` uses: English says
  // "at" and Afrikaans "om" where the general form above has a comma.
  // CLDR nests them under a usage, of which `standard` is the only one it
  // ships; a locale without them falls back to the general form.
  const atTime = (gregorian['dateTimeFormats-atTime'] || {}).standard || gregorian.dateTimeFormats;
  const dateTimeAtTimeFormats = LENGTHS.map(
    (length) => patternOf(atTime[length], tag, 'date-time at-time', length) || dateTimeFormats[LENGTHS.indexOf(length)],
  );

  const hourFormat = (zoneNames.hourFormat || '+HH:mm;-HH:mm').split(';');
  const region = regionOf(tag);
  const firstDay = (weekData.firstDay && (weekData.firstDay[region] || weekData.firstDay['001'])) || 'sun';
  const minDays = Number((weekData.minDays && (weekData.minDays[region] || weekData.minDays['001'])) || 1);

  const rules = dayPeriodRules(tag);
  const digits = digitsOf(tag);

  if (!dateFormats.every(Boolean) || !timeFormats.every(Boolean) || !dateTimeFormats.every(Boolean) ||
      !dateTimeAtTimeFormats.every(Boolean)) {
    warnings.push(`${tag}: a date or time pattern is missing and was skipped`);
    continue;
  }

  out.push('    .{');
  out.push(`        .tag = ${zigString(tag)},`);

  out.push('        .months = [3][12][]const u8{');
  for (const row of months.format) out.push(`            ${zigStrings(row)},`);
  out.push('        },');
  if (months.standalone === null) {
    out.push('        .months_stand_alone = null,');
  } else {
    out.push('        .months_stand_alone = [3][12][]const u8{');
    for (const row of months.standalone) out.push(`            ${zigStrings(row)},`);
    out.push('        },');
  }

  out.push('        .weekdays = [4][7][]const u8{');
  for (const row of weekdays.format) out.push(`            ${zigStrings(row)},`);
  out.push('        },');
  if (weekdays.standalone === null) {
    out.push('        .weekdays_stand_alone = null,');
  } else {
    out.push('        .weekdays_stand_alone = [4][7][]const u8{');
    for (const row of weekdays.standalone) out.push(`            ${zigStrings(row)},`);
    out.push('        },');
  }

  out.push('        .quarters = [3][4][]const u8{');
  for (const row of quarters.format) out.push(`            ${zigStrings(row)},`);
  out.push('        },');
  if (quarters.standalone === null) {
    out.push('        .quarters_stand_alone = null,');
  } else {
    out.push('        .quarters_stand_alone = [3][4][]const u8{');
    for (const row of quarters.standalone) out.push(`            ${zigStrings(row)},`);
    out.push('        },');
  }

  out.push('        .day_periods = [3][12][]const u8{');
  for (const row of periods.format) out.push(`            ${zigStrings(row)},`);
  out.push('        },');
  if (periods.standalone === null) {
    out.push('        .day_periods_stand_alone = null,');
  } else {
    out.push('        .day_periods_stand_alone = [3][12][]const u8{');
    for (const row of periods.standalone) out.push(`            ${zigStrings(row)},`);
    out.push('        },');
  }

  out.push('        .eras = [3][2][]const u8{');
  for (const row of eras) out.push(`            ${zigStrings(row)},`);
  out.push('        },');

  out.push(`        .date_formats = ${zigArray('[4][]const u8', dateFormats)},`);
  out.push(`        .time_formats = ${zigArray('[4][]const u8', timeFormats)},`);
  out.push(`        .date_time_formats = ${zigArray('[4][]const u8', dateTimeFormats)},`);
  out.push(`        .date_time_at_time_formats = ${zigArray('[4][]const u8', dateTimeAtTimeFormats)},`);

  out.push(`        .gmt_format = ${zigString(zoneNames.gmtFormat || 'GMT{0}')},`);
  out.push(`        .gmt_zero_format = ${zigString(zoneNames.gmtZeroFormat || 'GMT')},`);
  out.push(`        .hour_format_positive = ${zigString(hourFormat[0])},`);
  out.push(`        .hour_format_negative = ${zigString(hourFormat[1] || hourFormat[0])},`);

  out.push(`        .first_day = ${WEEKDAY_KEYS.indexOf(firstDay)},`);
  out.push(`        .min_days_in_first_week = ${minDays},`);

  if (rules.length === 0) {
    out.push('        .day_period_rules = &[_][4]u16{},');
  } else {
    out.push('        .day_period_rules = &[_][4]u16{');
    for (const rule of rules) out.push(`            .{ ${rule.join(', ')} },`);
    out.push('        },');
  }

  out.push(
    digits === null
      ? '        .digits = null,'
      : `        .digits = ${zigArray('[10][]const u8', digits)},`,
  );

  out.push('    },');
  count += 1;
}

// An era name a locale leaves out, which a handful do for the narrow
// width: the next width up rather than nothing, since an empty era would
// simply vanish out of a formatted date.
function eras_fallback(gregorian, width, side) {
  const order = ['eraAbbr', 'eraNames', 'eraNarrow'];
  for (const key of order) {
    const found = gregorian.eras[key] && gregorian.eras[key][String(side)];
    if (found) return found;
  }
  return side === 0 ? 'BCE' : 'CE';
}

out.push('};');
out.push('');
out.push('/// The CLDR release this was generated from.');
out.push(`pub const cldr_version = ${zigString(version)};`);
out.push('');

fs.writeFileSync(outputPath, out.join('\n'));

console.error(`gen_cldr: ${count} locales from CLDR ${version}`);
for (const warning of warnings) console.error('gen_cldr: ' + warning);
for (const override of overrides) console.error('gen_cldr: ' + override);
