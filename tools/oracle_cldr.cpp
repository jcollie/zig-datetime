// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's CLDR pattern support against ICU, which is the
// reference implementation of UTS #35 and the thing every other CLDR date
// formatter is checked against in turn.
//
// tools/oracle_cldr_dump.zig writes one record per line -- the locale,
// the instant in milliseconds, the offset it is read at in seconds, the
// pattern or the pair of lengths, and what this library made of it -- and
// this asks ICU the same question and reports every answer that differs.
//
// Three things are set up so that the two are answering the same
// question rather than nearly the same one:
//
//   The zone is a SimpleTimeZone carrying the offset and nothing else,
//   with no identifier ICU could find names under. That is exactly what a
//   DateTime is: a reading and an offset. It is also what makes the zone
//   fields take their documented fallback, the localized GMT format, on
//   both sides -- given a real zone identifier ICU would answer `z` with
//   a name that this library has no way to know.
//
//   The calendar is a GregorianCalendar whose changeover date has been
//   pushed before every date there is. ICU's Gregorian calendar is
//   Julian before October 1582 by default, and this library's is
//   proleptic Gregorian throughout, so without this every date before the
//   changeover would differ by ten days or more and say nothing about the
//   formatting.
//
//   The locale is asked for with @calendar=gregorian. Thai and Persian
//   and half a dozen others default to a calendar of their own, and a
//   Buddhist year is not a disagreement about the year field.
//
// Usage: oracle_cldr <path to the dump>

#include <unicode/calendar.h>
#include <unicode/datefmt.h>
#include <unicode/dtfmtsym.h>
#include <unicode/gregocal.h>
#include <unicode/locid.h>
#include <unicode/simpletz.h>
#include <unicode/smpdtfmt.h>
#include <unicode/unistr.h>
#include <unicode/uversion.h>

#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

using namespace icu;

namespace {

struct Mismatch {
  std::string locale;
  std::string what;
  std::string ours;
  std::string theirs;
  long long millis;
  int offset;
};

// Divergences this library knows about and does not intend to fix, with
// the reason. Anything else is a failure.
//
// Both are about a short date, and both are narrow enough to name the
// locale: keep this list short and keep every entry explained, because it
// is the difference between a documented limit and a bug nobody noticed.
//
// Returns the reason, or an empty string when the record is not one of
// them.
std::string excuse(const std::string &tag, bool shortDate) {
  if (!shortDate) return "";

  // Hawaiian writes the month of its short date in lowercase Roman
  // numerals, which CLDR says by hanging a numbering system on that one
  // field of the pattern. A numbering system here is ten digits, and
  // `romanlow` is an algorithm rather than ten digits, so the override is
  // dropped and the month is written in the locale's ordinary figures.
  // tools/gen_cldr.js reports every override it drops, and this is the
  // only one CLDR has.
  if (tag == "haw") return "a numbering system this does not carry";

  // French as written in Mali sets its own short pattern for joining a
  // date to a time, and then says that the same pattern for joining a
  // date to a time of day is inherited. CLDR's JSON distribution resolves
  // that inheritance sideways, to the locale's own general pattern, and
  // ICU resolves it upwards, to the pattern plain French uses. The two
  // disagree about whether there is a comma before the time. This carries
  // what the JSON says, because the JSON is where the data comes from.
  if (tag == "fr-ML") return "CLDR and ICU inherit this pattern differently";

  return "";
}

// The locales CLDR ships and this ICU does not, which are skipped and
// counted. Their data here is still CLDR's own -- the placeholder names
// are literally what CLDR ships for them -- but there is nothing to check
// it against, so saying how many went unchecked is the honest report.
std::vector<std::string> unknownLocales;

// How many records each excused divergence accounted for.
std::map<std::string, long long> excused;

std::string toUtf8(const UnicodeString &text) {
  std::string out;
  text.toUTF8String(out);
  return out;
}

// The locale ICU should answer in: the tag the dump named, with the
// Gregorian calendar asked for by name.
Locale localeFor(const std::string &tag) {
  return Locale::createCanonical((tag + "@calendar=gregorian").c_str());
}

// Whether this ICU actually ships the locale.
//
// CLDR ships a directory for every locale it has any data at all for,
// including the ones whose coverage is so thin that their month names are
// still the placeholders `M01` through `M12`; ICU leaves those out.
// Asking such a locale for a date does not fail -- ICU falls back, and not
// to root but to the default locale, so Afar comes back in English and
// every name in the corpus looks like a divergence.
//
// The available locale list is the only reliable test. Neither the status
// code nor the valid locale distinguishes the cases well enough:
// `U_USING_FALLBACK_WARNING` is also what a perfectly good locale returns
// when one of its tables is inherited from its parent.
bool known(const std::string &tag) {
  static std::set<std::string> available;
  static bool loaded = false;
  if (!loaded) {
    int32_t count = 0;
    const Locale *all = Locale::getAvailableLocales(count);
    for (int32_t index = 0; index < count; index += 1) available.insert(all[index].getName());
    loaded = true;
  }

  static std::map<std::string, bool> cache;
  auto found = cache.find(tag);
  if (found != cache.end()) return found->second;

  // ICU spells an identifier with underscores and an upper case variant,
  // so the tag is canonicalized before it is looked for: CLDR's
  // `ca-ES-valencia` is ICU's `ca_ES_VALENCIA`.
  bool answer = available.count(Locale::createCanonical(tag.c_str()).getName()) > 0;
  cache[tag] = answer;
  if (!answer) unknownLocales.push_back(tag);
  return answer;
}

// A calendar that is proleptic Gregorian and reads at `offset` seconds
// east of UTC.
Calendar *calendarFor(int offset, const Locale &locale, UErrorCode &status) {
  SimpleTimeZone zone(offset * 1000, UnicodeString("+"));
  GregorianCalendar *calendar = new GregorianCalendar(zone, locale, status);
  if (U_FAILURE(status)) return calendar;
  // Before every date a Year can hold, so that nothing in the corpus
  // falls on the Julian side of the change.
  calendar->setGregorianChange(-1e17, status);
  return calendar;
}

std::string formatPattern(const std::string &tag, const std::string &pattern, int offset,
                          double millis, bool &ok) {
  UErrorCode status = U_ZERO_ERROR;
  Locale locale = localeFor(tag);

  SimpleDateFormat formatter(UnicodeString::fromUTF8(pattern), locale, status);
  if (U_FAILURE(status)) {
    ok = false;
    return u_errorName(status);
  }

  Calendar *calendar = calendarFor(offset, locale, status);
  if (U_FAILURE(status)) {
    delete calendar;
    ok = false;
    return u_errorName(status);
  }
  formatter.adoptCalendar(calendar);

  SimpleTimeZone zone(offset * 1000, UnicodeString("+"));
  formatter.setTimeZone(zone);

  UnicodeString out;
  formatter.format(static_cast<UDate>(millis), out);
  ok = true;
  return toUtf8(out);
}

DateFormat::EStyle styleOf(int which) {
  switch (which) {
    case 0: return DateFormat::kFull;
    case 1: return DateFormat::kLong;
    case 2: return DateFormat::kMedium;
    default: return DateFormat::kShort;
  }
}

std::string formatStyled(const std::string &tag, int dateStyle, int timeStyle, int offset,
                         double millis, bool &ok) {
  UErrorCode status = U_ZERO_ERROR;
  Locale locale = localeFor(tag);

  std::unique_ptr<DateFormat> formatter;
  if (dateStyle < 0) {
    formatter.reset(DateFormat::createTimeInstance(styleOf(timeStyle), locale));
  } else if (timeStyle < 0) {
    formatter.reset(DateFormat::createDateInstance(styleOf(dateStyle), locale));
  } else {
    formatter.reset(
        DateFormat::createDateTimeInstance(styleOf(dateStyle), styleOf(timeStyle), locale));
  }
  if (!formatter) {
    ok = false;
    return "no formatter";
  }

  Calendar *calendar = calendarFor(offset, locale, status);
  if (U_FAILURE(status)) {
    delete calendar;
    ok = false;
    return u_errorName(status);
  }
  formatter->adoptCalendar(calendar);

  SimpleTimeZone zone(offset * 1000, UnicodeString("+"));
  formatter->setTimeZone(zone);

  UnicodeString out;
  formatter->format(static_cast<UDate>(millis), out);
  ok = true;
  return toUtf8(out);
}

std::vector<std::string> split(const std::string &line, char separator, size_t most) {
  std::vector<std::string> parts;
  size_t start = 0;
  while (parts.size() + 1 < most) {
    size_t at = line.find(separator, start);
    if (at == std::string::npos) break;
    parts.push_back(line.substr(start, at - start));
    start = at + 1;
  }
  parts.push_back(line.substr(start));
  return parts;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    std::fprintf(stderr, "usage: oracle_cldr <dump>\n");
    return 2;
  }

  std::ifstream file(argv[1]);
  if (!file) {
    std::fprintf(stderr, "oracle: cannot open %s\n", argv[1]);
    return 2;
  }

  std::vector<Mismatch> mismatches;
  long long checked = 0;
  std::string line;

  while (std::getline(file, line)) {
    if (line.empty()) continue;

    if (line[0] == 'P') {
      auto parts = split(line, '\t', 6);
      if (parts.size() != 6) {
        std::fprintf(stderr, "oracle: malformed P record: %s\n", line.c_str());
        return 2;
      }
      const std::string &tag = parts[1];
      if (!known(tag)) continue;

      double millis = std::strtod(parts[2].c_str(), nullptr);
      int offset = std::atoi(parts[3].c_str());
      const std::string &pattern = parts[4];
      const std::string &ours = parts[5];

      bool ok = false;
      std::string theirs = formatPattern(tag, pattern, offset, millis, ok);
      checked += 1;
      if (!ok || ours != theirs) {
        std::string reason = excuse(tag, false);
        if (!reason.empty()) {
          excused[tag + ": " + reason] += 1;
        } else {
          mismatches.push_back({tag, "\"" + pattern + "\"", ours, theirs,
                                static_cast<long long>(millis), offset});
        }
      }
    } else if (line[0] == 'S') {
      auto parts = split(line, '\t', 7);
      if (parts.size() != 7) {
        std::fprintf(stderr, "oracle: malformed S record: %s\n", line.c_str());
        return 2;
      }
      const std::string &tag = parts[1];
      if (!known(tag)) continue;

      double millis = std::strtod(parts[2].c_str(), nullptr);
      int offset = std::atoi(parts[3].c_str());
      int dateStyle = std::atoi(parts[4].c_str());
      int timeStyle = std::atoi(parts[5].c_str());
      const std::string &ours = parts[6];

      bool ok = false;
      std::string theirs = formatStyled(tag, dateStyle, timeStyle, offset, millis, ok);
      checked += 1;
      if (!ok || ours != theirs) {
        std::string reason = excuse(tag, dateStyle == 3);
        if (!reason.empty()) {
          excused[tag + ": " + reason] += 1;
        } else {
          static const char *names[] = {"full", "long", "medium", "short"};
          std::string what = "date=";
          what += dateStyle < 0 ? "none" : names[dateStyle];
          what += " time=";
          what += timeStyle < 0 ? "none" : names[timeStyle];
          mismatches.push_back(
              {tag, what, ours, theirs, static_cast<long long>(millis), offset});
        }
      }
    } else {
      std::fprintf(stderr, "oracle: unknown record kind in: %s\n", line.c_str());
      return 2;
    }
  }

  std::printf("oracle: %lld comparisons against ICU %s\n", checked, U_ICU_VERSION);

  if (!unknownLocales.empty()) {
    std::printf("oracle: %zu locales CLDR ships and ICU %s does not, unchecked\n",
                unknownLocales.size(), U_ICU_VERSION);
  }

  if (!excused.empty()) {
    long long total = 0;
    for (const auto &each : excused) total += each.second;
    std::printf("oracle: %lld known and documented:\n", total);
    for (const auto &each : excused) {
      std::printf("    %s (%lld)\n", each.first.c_str(), each.second);
    }
  }

  if (mismatches.empty()) {
    std::printf("oracle: no divergence%s\n", excused.empty() ? "" : " beyond those");
    return 0;
  }

  std::printf("oracle: %zu differ\n\n", mismatches.size());

  // Grouped by what was asked for, since a pattern that disagrees usually
  // does so for every instant and one line each would bury the shape of
  // it.
  std::map<std::string, std::vector<const Mismatch *>> grouped;
  std::vector<std::string> order;
  for (const auto &each : mismatches) {
    if (grouped.find(each.what) == grouped.end()) order.push_back(each.what);
    grouped[each.what].push_back(&each);
  }

  for (const auto &what : order) {
    const auto &group = grouped[what];
    std::printf("  %s (%zu)\n", what.c_str(), group.size());
    for (size_t index = 0; index < group.size() && index < 3; index += 1) {
      const Mismatch *each = group[index];
      std::printf("      %s @%lldms %+ds  ours \"%s\"  icu \"%s\"\n", each->locale.c_str(),
                  each->millis, each->offset, each->ours.c_str(), each->theirs.c_str());
    }
    if (group.size() > 3) std::printf("      ... and %zu more\n", group.size() - 3);
    std::printf("\n");
  }

  return 1;
}
