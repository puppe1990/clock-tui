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

printf 'weather widget scenarios passed\n'
