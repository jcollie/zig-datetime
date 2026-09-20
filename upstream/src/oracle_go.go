// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

// Checks this library's Go layout support against Go's own time package.
//
// tools/oracle_go_dump.zig writes one record per line -- the instant in
// milliseconds, the offset it is read at in minutes, the layout, and what
// this library made of it -- and this asks Go the same question and
// reports every answer that differs.
//
// The zone is built with time.FixedZone so that the offset is the one the
// record names rather than whatever the machine is set to, and so that a
// layout containing MST has a name to write. Go writes the numeric offset
// there when a zone has no name, which is what a DateTime that never went
// through a TimeZone also does, so the empty name is passed through as
// such rather than being made up.
//
// Usage: go run oracle_go.go <path to the dump>

package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// How a parsed result is written for comparison, matching the constant of
// the same name in tools/oracle_go_dump.zig.
const canonical = "2006-01-02T15:04:05.000000000-07:00:00"

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: oracle_go.go <dump>")
		os.Exit(2)
	}

	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	defer file.Close()

	type mismatch struct {
		at, minutes          int64
		layout, ours, theirs string
	}

	var mismatches []mismatch
	checked := 0

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if len(line) == 0 {
			continue
		}

		kind, body, found := strings.Cut(line, "\t")
		if !found {
			fmt.Fprintf(os.Stderr, "oracle: malformed record: %q\n", line)
			os.Exit(2)
		}

		switch kind {
		case "F":
			parts := strings.SplitN(body, "\t", 5)
			if len(parts) != 5 {
				fmt.Fprintf(os.Stderr, "oracle: malformed F record: %q\n", line)
				os.Exit(2)
			}

			at, _ := strconv.ParseInt(parts[0], 10, 64)
			minutes, _ := strconv.ParseInt(parts[1], 10, 64)
			name, layout, ours := parts[2], parts[3], parts[4]

			zone := time.FixedZone(name, int(minutes)*60)
			theirs := time.UnixMilli(at).In(zone).Format(layout)

			checked++
			if ours != theirs {
				mismatches = append(mismatches, mismatch{at, minutes, layout, ours, theirs})
			}

		case "P":
			parts := strings.SplitN(body, "\t", 4)
			if len(parts) != 4 {
				fmt.Fprintf(os.Stderr, "oracle: malformed P record: %q\n", line)
				os.Exit(2)
			}

			layout, input, status, ours := parts[0], parts[1], parts[2], parts[3]
			if status == "err" {
				ours = "REFUSED"
			}

			// Go's Parse keeps whatever offset the text carried, and
			// gives UTC when it carried none, which is what this side
			// does with a DateTime that was never told one.
			theirs := "REFUSED"
			if t, err := time.Parse(layout, input); err == nil {
				theirs = t.Format(canonical)
			}

			checked++
			if ours != theirs {
				mismatches = append(mismatches, mismatch{0, 0, layout + "  <- " + strconv.Quote(input), ours, theirs})
			}

		default:
			fmt.Fprintf(os.Stderr, "oracle: unknown record kind %q\n", kind)
			os.Exit(2)
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}

	fmt.Printf("oracle: %d comparisons against %s\n", checked, runtime.Version())

	if len(mismatches) == 0 {
		fmt.Println("oracle: no divergence")
		return
	}

	fmt.Printf("oracle: %d differ\n\n", len(mismatches))

	// Grouped by layout, since a layout that disagrees usually does so for
	// every instant and one line each would bury the shape of it.
	byLayout := map[string][]mismatch{}
	order := []string{}
	for _, m := range mismatches {
		if _, seen := byLayout[m.layout]; !seen {
			order = append(order, m.layout)
		}
		byLayout[m.layout] = append(byLayout[m.layout], m)
	}

	for _, l := range order {
		group := byLayout[l]
		fmt.Printf("  %q (%d)\n", l, len(group))
		for i, m := range group {
			if i >= 3 {
				fmt.Printf("      ... and %d more\n", len(group)-3)
				break
			}
			when := time.UnixMilli(m.at).UTC().Format(time.RFC3339Nano)
			fmt.Printf("      %s @%d  ours %q  go %q\n", when, m.minutes, m.ours, m.theirs)
		}
		fmt.Println()
	}

	os.Exit(1)
}
