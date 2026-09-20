#!/usr/bin/env bash
set -euo pipefail

tests_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$tests_dir/../.." && pwd)
widget="$repo_root/examples/widgets/tclock-weather"

# shellcheck source=/dev/null
source "$widget"

fail() { printf 'FAIL %s\n' "$1" >&2; return 1; }

assert_eq() {
  local actual=$1 expected=$2 label=$3
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
    return 1
  fi
}

assert_eq "$(wmo_label 0)" 'Clear' 'wmo 0'
assert_eq "$(wmo_label 2)" 'Partly cloudy' 'wmo 2'
assert_eq "$(wmo_label 61)" 'Rain' 'wmo 61'
assert_eq "$(wmo_label 71)" 'Snow' 'wmo 71'
assert_eq "$(wmo_label 95)" 'Thunderstorm' 'wmo 95'
assert_eq "$(wmo_label 123)" 'Unknown' 'wmo unknown'

assert_eq "$(weekday_from_iso 2026-09-21)" '2' 'weekday monday'
assert_eq "$(weekday_from_iso 2000-01-01)" '0' 'weekday saturday'
assert_eq "$(weekday_name 2)" 'Mon' 'weekday name mon'
assert_eq "$(weekday_name 0)" 'Sat' 'weekday name sat'

assert_eq "$(round_number 22.4)" '22' 'round down'
assert_eq "$(round_number 26.7)" '27' 'round up'
assert_eq "$(round_number -3.6)" '-4' 'round negative'
assert_eq "$(round_number 70)" '70' 'round integer'
assert_eq "$(round_number '')" '0' 'round empty'

assert_eq "$(urlencode 'Porto Alegre')" 'Porto+Alegre' 'urlencode space'
assert_eq "$(urlencode 'Curitiba')" 'Curitiba' 'urlencode token'

run_script() { "$widget" "$@" 2>&1; }

expect_fail() {
  local label=$1 expected=$2
  shift 2
  local out
  out=$(run_script "$@" || true)
  if run_script "$@" >/dev/null 2>&1; then
    fail "$label: expected non-zero exit"
    return 1
  fi
  if [[ "$out" != *"$expected"* ]]; then
    printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$out" >&2
    return 1
  fi
}

assert_eq "$(run_script --help)" "$(usage)" 'help text'
assert_eq "$(run_script -h)" "$(usage)" 'short help text'
expect_fail 'no location' 'no location' --city ''
expect_fail 'unknown option' "unknown option '--bogus'" --bogus
expect_fail 'bad days' "invalid --days 'abc'" --city Curitiba --days abc
expect_fail 'zero days' "invalid --days '0'" --city Curitiba --days 0
expect_fail 'lon only' 'both --lat and --lon' --lon 1
expect_fail 'bad units' "invalid --units 'kelvin'" --city Curitiba --units kelvin
expect_fail 'bad lat' "invalid --lat 'x'" --lat x --lon 1
expect_fail 'missing value' '--city requires a value' --city

printf 'weather widget scenarios passed\n'
