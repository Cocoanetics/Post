#!/bin/sh
# Reads `swift --version` output on stdin, echoes it, and exits non-zero unless
# the compiler's major/minor version is exactly the expected one (default 6.4).
# Handles both "Apple Swift version 6.4 (...)" and "Swift version 6.4.2 (...)".
expected="${1:-6.4}"
output=$(cat)
printf '%s\n' "$output"

version=$(printf '%s\n' "$output" | sed -n 's/^.*[Ss]wift version \([0-9][0-9]*\.[0-9][0-9]*\)\([. (-].*\)\{0,1\}$/\1/p' | head -n 1)

if [ -z "$version" ]; then
    echo "error: could not parse a Swift version from the output above" >&2
    exit 1
fi
if [ "$version" != "$expected" ]; then
    echo "error: expected Swift $expected, found $version" >&2
    exit 1
fi
