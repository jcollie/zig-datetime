// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Turns moment.js's locale files into src/locales/locales.zig, the table
// `locale.zig` reads when a build asks for -Dembed-locales.
//
// The data is moment's rather than a transcription of it, for the same
// reason the timezone database is IANA's own output: moment is what this
// library's formatting is checked against, so a locale that disagreed
// with moment's would be a divergence built in at the source. Bumping the
// pin in build.zig.zon and running this again is what keeps them in step.
//
// Two of a locale's pieces are functions in moment rather than data --
// the meridiem and the ordinal -- and both are enumerated here rather
// than reimplemented. Their domains are finite: twenty-four hours by the
// part of the hour, and the numbers a date sequence can write. What comes
// out is a table that answers the same questions.
//
// Usage: gen_locales.js <path to moment> <output file>

const fs = require('fs');
const path = require('path');

const momentPath = process.argv[2];
const outputPath = process.argv[3];
if (!momentPath || !outputPath) {
  console.error('usage: gen_locales.js <moment dir> <output file>');
  process.exit(2);
}

const moment = require(path.resolve(momentPath, 'moment.js'));
const version = require(path.resolve(momentPath, 'package.json')).version;

const localeDir = path.resolve(momentPath, 'locale');
const tags = fs
  .readdirSync(localeDir)
  .filter((f) => f.endsWith('.js'))
  .map((f) => f.slice(0, -3))
  .sort();

for (const tag of tags) require(path.join(localeDir, tag + '.js'));

// The sequences that write an ordinal, in the order locale.ordinal_tags
// holds their tables. moment names them by the letter it passes to the
// ordinal function, which is the sequence with its `o` taken off.
const ORDINAL_TOKENS = ['M', 'D', 'DDD', 'd', 'w', 'W'];

// Format strings to try when looking for a locale's declined names. Each
// is the shape one of moment's locales looks for; the day before the
// name is the common case, two locales want it after, and Czech allows a
// full stop between.
const MONTH_PROBES = ['D MMMM', 'D. MMMM', 'Do MMMM', 'MMMM D', 'MMMM Do'];

/// What each probe is called in `locale.DeclineShapes`.
const MONTH_PROBE_SHAPES = {
  'D MMMM': 'day_then_month',
  'D. MMMM': 'day_stop_month',
  'Do MMMM': 'ordinal_then_month',
  'MMMM D': 'month_then_day',
  'MMMM Do': 'month_then_ordinal',
};

// The same for weekdays, where what the patterns look for is bracketed
// text before the name.
const WEEKDAY_PROBES = ['[on] dddd', 'dddd HH:mm', 'D dddd'];

/// The same probe with its names one letter shorter, for the short
/// tables.
function shorten(probe) {
  return probe.replace(/MMMM|dddd/g, (found) => found.slice(1));
}

// The localized sequences, in the order locale.LongDateFormat holds the
// flags for them.
const LONG_DATE_KEYS = ['LT', 'LTS', 'L', 'LL', 'LLL', 'LLLL', 'l', 'll', 'lll', 'llll'];

// How many numbers an ordinal table distinguishes, matching
// locale.ordinal_slots. Under a hundred every number has its own slot,
// because a language may treat any of them specially; at a hundred and
// above the last two digits decide.
const ORDINAL_SLOTS = 200;

function ordinalSlot(n) {
  return n < 100 ? n : 100 + (n % 100);
}

/// The largest number each sequence can write, which is what has to be
/// covered. The day of the year is the only one that passes a hundred.
const ORDINAL_MAX = 400;

const warnings = [];

/// Splits what moment's ordinal returned into what goes before the number
/// and what goes after it.
function splitOrdinal(tag, token, n, written) {
  const text = String(written);
  const at = text.indexOf(String(n));
  if (at < 0) {
    warnings.push(
      `${tag}: ordinal(${n}, '${token}') is ${JSON.stringify(text)}, which does not contain the number`,
    );
    return ['', ''];
  }
  return [text.slice(0, at), text.slice(at + String(n).length)];
}

/// Zig string literal. The source is UTF-8 and so are these, so only the
/// two characters that end a literal need escaping, plus the control
/// characters that would not survive being written out.
function zigString(s) {
  let out = '"';
  for (const ch of String(s)) {
    const code = ch.codePointAt(0);
    if (ch === '"') out += '\\"';
    else if (ch === '\\') out += '\\\\';
    else if (code < 0x20 || code === 0x7f) out += '\\x' + code.toString(16).padStart(2, '0');
    else out += ch;
  }
  return out + '"';
}

function zigStrings(list) {
  return '.{ ' + list.map(zigString).join(', ') + ' }';
}

/// The same, with the type spelled out. The generated file cannot name a
/// type from the library, but the array types below are built into the
/// language, and giving the values a type is what lets them be copied
/// into a `locale.Entry` field by field.
function zigNames(list) {
  return `[${list.length}][]const u8{ ` + list.map(zigString).join(', ') + ' }';
}

/// A locale's names, in both the form it uses on their own and the form
/// it uses inside a date.
///
/// moment holds these three different ways -- a plain array, an object of
/// a standalone array and an in-format one, or a function that picks by a
/// regular expression over the format string -- so none of them is read
/// directly. Asking the accessor once per name, with and without a format
/// string that triggers the declined form, gets the same answer out of
/// all three.
///
/// The in-format array comes back null when it is the same as the other,
/// which is most languages.
function nameForms(accessor, data, count, probeFormats) {
  const at = (index) => {
    const day = moment.utc(Date.UTC(2024, 0, 1)).locale(data._abbr);
    // A month is picked by its number and a weekday by its date, which
    // for the first week of 2024 has the 7th as a Sunday.
    return count === 12 ? day.month(index) : day.date(7 + index);
  };

  const standalone = [];
  for (let index = 0; index < count; index++) {
    standalone.push(String(accessor.call(data, at(index), '')));
  }

  // More than one probe, because a locale's own pattern decides which
  // form comes back and the patterns disagree about what to look for:
  // most want the day before the name, two want it after, and one wants
  // a full stop between. The first probe that produces something
  // different from the standalone form is the declined one.
  const matched = [];
  let format = null;
  for (const probeFormat of probeFormats) {
    const found = [];
    for (let index = 0; index < count; index++) {
      found.push(String(accessor.call(data, at(index), probeFormat)));
    }
    if (found.some((name, i) => name !== standalone[i])) {
      matched.push(probeFormat);
      if (!format) format = found;
    }
  }

  return { standalone, format, matched };
}

const out = [];
// The header the generated file carries, which is moment's own licensing
// rather than this project's: the names in it are moment's data.
// REUSE-IgnoreStart
out.push('// SPDX-FileCopyrightText: © JS Foundation and other contributors');
out.push('// SPDX-License-Identifier: MIT');
// REUSE-IgnoreEnd
out.push('');
out.push("//! Generated by tools/gen_locales.js from moment.js's own locale");
out.push('//! files. Do not edit.');
out.push('//!');
out.push('//! One anonymous struct literal per locale, read back as');
out.push('//! `locale.Entry`. Nothing here names a type, because this is a');
out.push('//! module of its own and could not reach one in the library.');
out.push('');
out.push(`/// The moment.js release this data was generated from.`);
out.push(`pub const moment_version = ${zigString(version)};`);
out.push('');
out.push('/// Every locale moment ships, sorted by tag.');
out.push('pub const entries = .{');

let count = 0;
for (const tag of tags) {
  moment.locale(tag);
  const data = moment.localeData();
  if (!data || data._abbr !== tag) {
    warnings.push(`${tag}: moment did not register it under that name`);
    continue;
  }

  // `D MMMM` is what moment's own locales test for when they decline a
  // month name after a day number, and `[on] dddd` is the shape the ones
  // that decline a weekday look for.
  const months = nameForms(data.months, data, 12, MONTH_PROBES);
  const monthsShort = nameForms(data.monthsShort, data, 12, MONTH_PROBES.map(shorten));
  const weekdays = nameForms(data.weekdays, data, 7, WEEKDAY_PROBES);
  const weekdaysShort = nameForms(data.weekdaysShort, data, 7, WEEKDAY_PROBES.map(shorten));
  const weekdaysMin = nameForms(data.weekdaysMin, data, 7, WEEKDAY_PROBES.map(shorten));

  const lists = {
    months: months.standalone,
    months_short: monthsShort.standalone,
    weekdays: weekdays.standalone,
    weekdays_short: weekdaysShort.standalone,
    weekdays_min: weekdaysMin.standalone,
  };
  let usable = true;
  for (const [name, list] of Object.entries(lists)) {
    const wanted = name.startsWith('months') ? 12 : 7;
    if (!Array.isArray(list) || list.length !== wanted) {
      warnings.push(`${tag}: ${name} is not ${wanted} names, so the locale is left out`);
      usable = false;
    }
  }
  if (!usable) continue;

  if (weekdays.format) {
    // moment picks the declined weekday by a regular expression looking
    // for bracketed text before the sequence -- "[в] dddd" in Russian.
    // The tokenizer here does not say whether a literal came from
    // brackets, so there is nothing to key that on, and the standalone
    // form is what gets written. See tools/oracle_locale.js, which counts
    // what that costs.
    warnings.push(`${tag}: has in-format weekday names, which are not carried`);
  }
  if (data.postformat && data.postformat('12,3') !== '12,3') {
    warnings.push(`${tag}: rewrites digits or separators after formatting, which is not done here`);
  }

  const dow = data.firstDayOfWeek();
  const doy = data.firstDayOfYear();

  // The meridiem, by hour, by which part of the hour it is, by case.
  // Five of moment's locales change the word inside the hour, and none
  // of them anywhere but on the minute and the half hour.
  const meridiem = [];
  for (let hour = 0; hour < 24; hour++) {
    const parts = [];
    for (const minute of [0, 15, 45]) {
      // Lower case first, to match the order of `locale.Case`.
      parts.push([data.meridiem(hour, minute, true), data.meridiem(hour, minute, false)]);
    }
    meridiem.push(parts);
  }

  // The ordinal, as the distinct decorations it puts around a number and
  // which one each number takes.
  const forms = [];
  const formIndex = new Map();
  const tables = [];
  for (const token of ORDINAL_TOKENS) {
    const table = new Array(ORDINAL_SLOTS).fill(0);
    const seen = new Array(ORDINAL_SLOTS).fill(false);
    for (let n = 0; n <= ORDINAL_MAX; n++) {
      const slot = ordinalSlot(n);
      if (slot >= ORDINAL_SLOTS || seen[slot]) continue;
      const around = splitOrdinal(tag, token, n, data.ordinal(n, token));
      const key = JSON.stringify(around);
      if (!formIndex.has(key)) {
        formIndex.set(key, forms.length);
        forms.push(around);
      }
      table[slot] = formIndex.get(key);
      seen[slot] = true;
    }
    tables.push(table);
  }
  if (forms.length > 255) {
    warnings.push(`${tag}: ${forms.length} ordinal forms, more than an index byte holds`);
    continue;
  }

  out.push('    .{');
  out.push(`        .tag = ${zigString(tag)},`);
  out.push(`        .months = ${zigNames(months.standalone)},`);
  out.push(`        .months_short = ${zigNames(monthsShort.standalone)},`);
  out.push(
    `        .months_in_format = ${months.format ? zigNames(months.format) : 'null'},`,
  );
  out.push(
    `        .months_short_in_format = ${monthsShort.format ? zigNames(monthsShort.format) : 'null'},`,
  );
  out.push(`        .weekdays = ${zigNames(weekdays.standalone)},`);
  out.push(`        .weekdays_short = ${zigNames(weekdaysShort.standalone)},`);
  out.push(`        .weekdays_min = ${zigNames(weekdaysMin.standalone)},`);
  for (const key of ['LT', 'LTS', 'L', 'LL', 'LLL', 'LLLL']) {
    out.push(`        .${key} = ${zigString(data.longDateFormat(key))},`);
  }
  // A locale may name the lower case spellings rather than let moment
  // derive them, and eighteen of them do -- Chinese keeps the full
  // weekday name in `llll` where the derivation would shorten it. Asking
  // moment for the string is what gets the locale's own answer either
  // way; the null is for the ones it derived, so that a hand-written
  // locale does not have to write out what the rule already says.
  for (const key of ['l', 'll', 'lll', 'llll']) {
    const own = data._longDateFormat[key];
    out.push(`        .${key} = ${own ? zigString(own) : 'null'},`);
  }

  // Whether each of the ten uses the declined month name.
  //
  // Which one a locale reaches for is decided by a regular expression
  // over the format string, and every locale that has two forms writes
  // its own: some look for the day before the month, some for the month
  // before the day, some allow a full stop between and some do not.
  // There is no one rule to carry, so for the strings that are the
  // locale's own the answer is asked of the locale rather than worked
  // out. A format string the caller wrote falls back to the rule most of
  // moment's locales use; see `DateTime.DayState`.
  const declined = LONG_DATE_KEYS.map((key) => {
    if (!months.format) return false;
    const expanded = data.longDateFormat(key);
    const probe = moment.utc(Date.UTC(2024, 2, 5)).locale(tag);
    return data.months(probe, expanded) === months.format[2];
  });
  out.push(
    `        .months_declined = ${months.format ? `[10]bool{ ${declined.join(', ')} }` : 'null'},`,
  );

  // And which arrangements make it decline, for a format string this
  // library's caller wrote and that no flag above covers. Which probes
  // matched is the answer; see `locale.DeclineShapes`.
  const matched = new Set(months.matched ?? []);
  const shapes = MONTH_PROBES.map(
    (probe) => `.${MONTH_PROBE_SHAPES[probe]} = ${matched.has(probe)}`,
  );
  out.push(`        .months_decline = .{ ${shapes.join(', ')} },`);
  // moment's `dv` says `dow: 7` where it means Sunday, and every place
  // moment uses `dow` to pick a weekday reduces it mod 7 -- so the day
  // the week starts on is `dow % 7`. The anchoring day is not reduced,
  // because moment does not reduce it either: it computes `7 + dow - doy`
  // from the raw value, which for `dv` is the 2nd of January rather than
  // the 5th of the December before.
  out.push(`        .week_starts_on = ${dow % 7},`);
  out.push(`        .january_day_in_first_week = ${7 + dow - doy},`);
  out.push('        .meridiem = [24][3][2][]const u8{');
  for (const hour of meridiem) {
    out.push('            .{ ' + hour.map((p) => zigStrings(p)).join(', ') + ' },');
  }
  out.push('        },');
  out.push('        .ordinal_forms = &[_][2][]const u8{');
  for (const form of forms) out.push(`            ${zigStrings(form)},`);
  out.push('        },');
  out.push(`        .ordinal_index = &[_][${ORDINAL_SLOTS}]u8{`);
  for (const table of tables) out.push(`            .{ ${table.join(', ')} },`);
  out.push('        },');
  out.push('    },');
  count += 1;
}

out.push('};');
out.push('');

fs.writeFileSync(outputPath, out.join('\n'));

console.error(`gen_locales: ${count} locales from moment ${version}`);
for (const warning of warnings) console.error('gen_locales: ' + warning);
