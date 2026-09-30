# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# Checks this library's .NET and PowerShell format strings against .NET and
# Get-Date themselves.
#
# src/oracle_powershell_dump.zig writes one record per line, of three kinds
# described there: F, what `dotnet.formatIn` wrote; P, what `dotnet.parseIn`
# read; and G, what `powershell.format` and `powershell.uformat` wrote. This
# asks .NET, or Get-Date, the same question and reports every answer that
# differs.
#
# .NET has two types a format string is applied to. The library follows
# DateTimeOffset, the one that carries an offset, so F records are checked
# against DateTimeOffset.ToString -- except `U`, which DateTimeOffset
# refuses and which is checked against a UTC DateTime. P records are
# checked against DateTime.ParseExact with AdjustToUniversal, which reports
# an offset by converting to UTC and its absence by leaving the kind
# Unspecified; the offset itself comes from DateTimeOffset.ParseExact where
# that reads the text too. `u` is read with DateTimeOffset alone, because
# DateTime.ParseExact ignores the `Z` it quotes; `o` and `r` are read with
# no styles, because only then does .NET use the code of its own it reads
# them with.
#
# Get-Date formats a local DateTime, so each G record is run with TZ set to
# the zone the record names. .NET on Linux reads TZ, and forgets what it
# read when TimeZoneInfo.ClearCachedData is called.
#
# Usage: pwsh -NoProfile -File oracle_powershell.ps1 <path to the dump>

param([Parameter(Mandatory = $true)][string]$Dump)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

public static class Oracle
{
    public static long Comparisons;
    // One example of each kind of divergence, keyed by what was being done
    // and to which format string, so that a single cause does not fill the
    // report with copies of itself.
    public static readonly List<string> Mismatches = new List<string>();
    static readonly Dictionary<string, int> seen = new Dictionary<string, int>();
    public static long Divergences;
    public static readonly SortedDictionary<string, long> Known = new SortedDictionary<string, long>();

    public static string Unescape(string text)
    {
        var result = new StringBuilder();
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '\\' && i + 1 < text.Length)
            {
                i++;
                result.Append(text[i] switch { 't' => '\t', 'n' => '\n', _ => text[i] });
            }
            else
            {
                result.Append(text[i]);
            }
        }
        return result.ToString();
    }

    public static string Escape(string text) =>
        text.Replace("\\", "\\\\").Replace("\t", "\\t").Replace("\n", "\\n");

    static CultureInfo CultureOf(string name) =>
        name == "en-US" ? new CultureInfo("en-US") : CultureInfo.InvariantCulture;

    static string Show(DateTime value) =>
        $"{value.Year}-{value.Month}-{value.Day}T{value.Hour}:{value.Minute}:{value.Second}.{value.Ticks % TimeSpan.TicksPerSecond:D7}";

    public static void Allow(string why)
    {
        Known.TryGetValue(why, out long count);
        Known[why] = count + 1;
    }

    public static void Differ(string key, string detail)
    {
        Divergences++;
        if (seen.ContainsKey(key)) return;
        seen[key] = Mismatches.Count;
        if (Mismatches.Count < 64) Mismatches.Add(detail);
    }

    public static void CheckFormat(string[] field)
    {
        string culture = field[1];
        long at = long.Parse(field[2]);
        int minutes = int.Parse(field[3]);
        string format = Unescape(field[4]);
        string ours = Unescape(field[5]);

        var instant = DateTimeOffset.FromUnixTimeMilliseconds(at);
        string theirs;
        try
        {
            theirs = format == "U"
                ? instant.UtcDateTime.ToString(format, CultureOf(culture))
                : instant.ToOffset(TimeSpan.FromMinutes(minutes)).ToString(format, CultureOf(culture));
        }
        catch (Exception e)
        {
            theirs = "!" + e.GetType().Name;
        }

        Comparisons++;
        if (theirs != ours)
        {
            Differ($"F {culture} {format}", $"format [{culture}] {at}ms at {minutes}min '{Escape(format)}': ours '{Escape(ours)}', .NET '{Escape(theirs)}'");
        }
    }

    public static void CheckParse(string[] field)
    {
        string culture = field[1];
        string format = Unescape(field[2]);
        string text = Unescape(field[3]);
        string ours = string.Join("\t", field, 4, field.Length - 4);

        string theirs;
        var info = CultureOf(culture);
        try
        {
            if (format == "o" || format == "O" || format == "r" || format == "R")
            {
                // .NET reads these two with code of their own, but only when
                // it is given no styles at all; any style sends them through
                // their patterns instead, which read differently. So they
                // are asked with none. DateTime says whether there was an
                // offset, by the kind it gives back; DateTimeOffset says
                // what it was, and in a process whose zone is UTC it
                // assumes zero when there was not one.
                var kind = DateTime.ParseExact(text, format, info).Kind;
                var read = DateTimeOffset.ParseExact(text, format, info);
                bool zoned = kind != DateTimeKind.Unspecified || format == "r" || format == "R";
                theirs = zoned
                    ? $"1\t{Show(read.UtcDateTime)}\t{(int)read.Offset.TotalMinutes}"
                    : $"0\t{Show(read.DateTime)}\t0";
            }
            else if (format == "u")
            {
                var read = DateTimeOffset.ParseExact(text, format, info, DateTimeStyles.AssumeUniversal);
                theirs = $"1\t{Show(read.UtcDateTime)}\t{(int)read.Offset.TotalMinutes}";
            }
            else
            {
                var read = DateTime.ParseExact(text, format, info, DateTimeStyles.AdjustToUniversal);
                if (read.Kind == DateTimeKind.Utc)
                {
                    // DateTimeOffset refuses some texts DateTime reads, a
                    // month and day with an offset and no year among them,
                    // so the offset is compared only when it has one.
                    string offset = "?";
                    try
                    {
                        offset = ((int)DateTimeOffset.ParseExact(text, format, info, DateTimeStyles.AssumeUniversal).Offset.TotalMinutes).ToString();
                    }
                    catch (FormatException)
                    {
                    }
                    theirs = $"1\t{Show(read)}\t{offset}";
                }
                else
                {
                    theirs = $"0\t{Show(read)}\t0";
                }
            }
        }
        catch (FormatException)
        {
            theirs = "err";
        }

        Comparisons++;
        if (theirs == ours) return;

        if (theirs.EndsWith("\t?") && ours.StartsWith(theirs.Substring(0, theirs.Length - 1))) return;

        // The two places the library reads differently, both documented on
        // `dotnet.parseIn`.
        if (theirs == "err" && ours != "err")
        {
            string year = ours.Split('\t')[1].Split('-')[0];
            if (int.Parse(year) < 1 || int.Parse(year) > 9999)
            {
                Allow("a year .NET cannot hold, read because a DateTime here can");
                return;
            }
        }
        if (ours == "err" && (format == "o" || format == "O") && text.Length >= 3 &&
            int.TryParse(text.Substring(text.Length - 2), out int offsetMinutes) && offsetMinutes >= 60 &&
            text[text.Length - 3] == ':')
        {
            Allow("o: .NET reads an offset's minutes without checking them");
            return;
        }

        Differ($"P {culture} {format} {(theirs == "err")} {(ours == "err")}", $"parse [{culture}] '{Escape(format)}' of '{Escape(text)}': ours '{Escape(ours)}', .NET '{Escape(theirs)}'");
    }
}
'@

# Get-Date formats with the session's culture, which on a CI runner is
# whatever LANG says. The library's default is the invariant culture, so
# that is what Get-Date is given.
[System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

$records = [System.IO.File]::ReadAllLines($Dump, [System.Text.Encoding]::UTF8)

# F and P records first, in UTC, which is where the dump's reference date
# for a text with no date in it came from.
$env:TZ = 'UTC'
[TimeZoneInfo]::ClearCachedData()

$byZone = @{}
foreach ($line in $records) {
    $field = $line.Split("`t")
    switch ($field[0]) {
        'F' { [Oracle]::CheckFormat($field) }
        'P' { [Oracle]::CheckParse($field) }
        'G' {
            if (-not $byZone.ContainsKey($field[1])) { $byZone[$field[1]] = [System.Collections.Generic.List[object]]::new() }
            $byZone[$field[1]].Add($field)
        }
    }
}

foreach ($zone in $byZone.Keys) {
    $env:TZ = $zone
    [TimeZoneInfo]::ClearCachedData()

    foreach ($field in $byZone[$zone]) {
        $minutes = [int]$field[2]
        $at = [long]$field[3]
        $parameter = $field[4]
        $format = [Oracle]::Unescape($field[5])
        $ours = [Oracle]::Unescape($field[6])

        $local = [DateTimeOffset]::FromUnixTimeMilliseconds($at).LocalDateTime
        $actual = [TimeZoneInfo]::Local.GetUtcOffset($local).TotalMinutes
        if ($actual -ne $minutes) {
            [Oracle]::Differ("zone ${zone}", "zone ${zone} is ${actual}min at ${at}ms, not ${minutes}min: the dump and the zone database disagree")
            continue
        }

        $theirs = if ($parameter -eq 'UFormat') {
            Get-Date -Date $local -UFormat $format
        } else {
            Get-Date -Date $local -Format $format
        }

        [Oracle]::Comparisons++
        if ($theirs -ceq $ours) { continue }

        # Get-Date hands .NET a local DateTime, and .NET writes `u` and `R`
        # of one without converting it, so their Z and GMT are false away
        # from UTC. The library converts, as DateTimeOffset does.
        if ($parameter -eq 'Format' -and $format -cin @('u', 'r', 'R') -and $minutes -ne 0) {
            [Oracle]::Allow('u and R: Get-Date writes a local time and calls it UTC')
            continue
        }

        [Oracle]::Differ("G ${parameter} ${format}", "Get-Date in ${zone} ${at}ms -${parameter} '$([Oracle]::Escape($format))': ours '$([Oracle]::Escape($ours))', PowerShell '$([Oracle]::Escape($theirs))'")
    }
}

$version = "PowerShell $($PSVersionTable.PSVersion) on $([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
Write-Output "oracle: $([Oracle]::Comparisons) comparisons against $version"

if ([Oracle]::Known.Count -gt 0) {
    $total = ([Oracle]::Known.Values | Measure-Object -Sum).Sum
    Write-Output "oracle: $total known and documented:"
    foreach ($reason in [Oracle]::Known.Keys) {
        Write-Output "    ${reason} ($([Oracle]::Known[$reason]))"
    }
}

if ([Oracle]::Divergences -eq 0) {
    Write-Output 'oracle: no divergence beyond those'
    exit 0
}

Write-Output "oracle: $([Oracle]::Divergences) divergences, of $([Oracle]::Mismatches.Count) kinds; one of each:"
foreach ($mismatch in [Oracle]::Mismatches) {
    Write-Output "    $mismatch"
}
exit 1
