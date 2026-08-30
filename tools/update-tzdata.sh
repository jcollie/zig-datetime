#!/usr/bin/env bash
#
# Updates the pinned IANA timezone database release.
#
# The version lives in three places that have to agree: the two dependency
# URLs and hashes in build.zig.zon, and the tz_release constant in
# build.zig that the generated data records as its own version. This
# rewrites all of them together, so they cannot drift apart.
#
# Prints the new version to stdout on success and leaves the working tree
# modified. Exits 0 with no output and no changes when already current.
#
# Usage: tools/update-tzdata.sh [version]
#
# With no argument the newest release IANA publishes is used. Pass a
# version such as 2026c to pin a specific one, which is also how this gets
# tested.

set -euo pipefail

readonly RELEASES="https://data.iana.org/time-zones/releases"
readonly VERSION_URL="https://data.iana.org/time-zones/tzdb/version"

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

die() { echo "update-tzdata: $*" >&2; exit 1; }
note() { echo "update-tzdata: $*" >&2; }

command -v zig >/dev/null || die "zig is not on PATH; it is needed to compute package hashes"
command -v curl >/dev/null || die "curl is not on PATH"

# --- which release do we want -------------------------------------------

if [ $# -gt 0 ]; then
    wanted="$1"
else
    # IANA publishes the current release here as a bare version string.
    wanted="$(curl --fail --silent --show-error --location "$VERSION_URL" | tr -d '[:space:]')"
fi

case "$wanted" in
    [0-9][0-9][0-9][0-9][a-z]) ;;
    *) die "'$wanted' does not look like a tzdb release (expected four digits and a letter, such as 2026c)" ;;
esac

current="$(sed -n 's/^const tz_release = "\(.*\)";$/\1/p' build.zig)"
[ -n "$current" ] || die "could not find the tz_release constant in build.zig"

if [ "$wanted" = "$current" ]; then
    note "already on $current"
    exit 0
fi

# Refuse to go backwards. The version endpoint has been known to move
# before the tarballs appear, and a rerun should never undo a newer pin.
if [ "$(printf '%s\n%s\n' "$current" "$wanted" | sort | head -1)" != "$current" ]; then
    die "$wanted is older than the pinned $current; refusing to downgrade"
fi

# The version endpoint can name a release whose tarballs are not published
# yet, so check before touching anything.
for archive in "tzcode$wanted" "tzdata$wanted"; do
    curl --fail --silent --head --location "$RELEASES/$archive.tar.gz" >/dev/null ||
        die "$archive.tar.gz is not published yet"
done

note "updating $current -> $wanted"

# --- fetch the new packages and record their hashes ----------------------

code_url="$RELEASES/tzcode$wanted.tar.gz"
data_url="$RELEASES/tzdata$wanted.tar.gz"

note "hashing $code_url"
code_hash="$(zig fetch "$code_url")"
note "hashing $data_url"
data_hash="$(zig fetch "$data_url")"

[ -n "$code_hash" ] && [ -n "$data_hash" ] || die "zig fetch produced no hash"

# --- rewrite the three places the version appears ------------------------

# awk rather than sed, because the hash lines are only distinguishable by
# which dependency block they sit in.
awk -v code_url="$code_url" -v code_hash="$code_hash" \
    -v data_url="$data_url" -v data_hash="$data_hash" '
    /^ *\.tzcode = \.\{/ { block = "code" }
    /^ *\.tzdata = \.\{/ { block = "data" }
    /^ *\},? *$/         { block = "" }
    block != "" && /^ *\.url = / {
        sub(/"[^"]*"/, "\"" (block == "code" ? code_url : data_url) "\"")
    }
    block != "" && /^ *\.hash = / {
        sub(/"[^"]*"/, "\"" (block == "code" ? code_hash : data_hash) "\"")
    }
    { print }
' build.zig.zon > build.zig.zon.new
mv build.zig.zon.new build.zig.zon

sed -i "s/^const tz_release = \"$current\";\$/const tz_release = \"$wanted\";/" build.zig

# --- check we actually rewrote what we meant to --------------------------

for expected in "tzcode$wanted.tar.gz" "tzdata$wanted.tar.gz" "$code_hash" "$data_hash"; do
    grep -qF -- "$expected" build.zig.zon || die "build.zig.zon is missing '$expected' after rewriting"
done
grep -qF "const tz_release = \"$wanted\";" build.zig || die "build.zig still names the old release"
if grep -qF "$current" build.zig.zon build.zig; then
    die "a reference to $current survived the rewrite"
fi

echo "$wanted"
