#!/bin/sh
set -eu

solver=${1:-./build/wave_solver}

expect_failure() {
    description=$1
    shift
    if "$solver" "$@" >/dev/null 2>&1; then
        echo "$description unexpectedly succeeded" >&2
        exit 1
    fi
}

require_nonnegative_finite() {
    key=$1
    value=$(printf '%s\n' "$output" | awk -F= -v key="$key" '$1 == key { print $2 }')
    if ! awk -v value="$value" 'BEGIN {
        number = "^[+]?[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$"
        exit !(value ~ number && value + 0 >= 0)
    }'; then
        echo "$key is missing or is not a finite nonnegative number: $value" >&2
        exit 1
    fi
}

output=$("$solver" --n 4 --lx 1 --ly 1.5 --lz 2 --time 0.05 --steps 2 --threads 2)
require_nonnegative_finite solve_wall_seconds
require_nonnegative_finite max_absolute_error

expect_failure "unstable CLI configuration" \
    --n 4 --lx 1 --ly 1 --lz 1 --time 1 --steps 1 --threads 1
expect_failure "missing required CLI option" \
    --n 4 --lx 1 --ly 1 --lz 1 --time 0.01 --steps 2
expect_failure "unknown CLI option" --unknown 1
expect_failure "duplicate CLI option" \
    --n 4 --n 5 --lx 1 --ly 1 --lz 1 --time 0.01 --steps 2 --threads 1
expect_failure "NaN domain length" \
    --n 4 --lx nan --ly 1 --lz 1 --time 0.01 --steps 2 --threads 1
expect_failure "infinite physical time" \
    --n 4 --lx 1 --ly 1 --lz 1 --time inf --steps 2 --threads 1

"$solver" --help >/dev/null
echo "All CLI tests passed."
