# tclock-weather Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a bundled, TDD-tested `examples/widgets/tclock-weather` bash script that renders current conditions plus an N-day Open-Meteo forecast for clock-mode widgets.

**Architecture:** A single self-contained bash 3.2-compatible script with a sourceable function library (guarded `main`), deterministic JSON accessors (`jq` when present, pure-bash fallback otherwise), a normalized internal JSON shape shared by rendering and the cache, and a fake-`curl` fixture harness run from Rust so `cargo test` covers it.

**Tech Stack:** Bash 3.2 (macOS default), curl, jq (optional), Open-Meteo REST API, Rust test wrapper (`clock-tui/tests/`), GitHub Actions release packaging.

---

## File structure

- Create: `examples/widgets/tclock-weather` — the widget (single file, executable).
- Create: `clock-tui/tests/weather-widget.sh` — bash scenario harness.
- Create: `clock-tui/tests/weather_widget.rs` — Rust wrapper so `cargo test` runs the harness.
- Create: `clock-tui/tests/fixtures/weather/{geocode-ok,geocode-empty,forecast-metric,forecast-imperial,malformed}.json`
- Modify: `README.md` (add bundled weather section, retarget the `wttr.in` recipe)
- Modify: `.github/workflows/release.yml` (tarball + install line + manual install snippet)
- Modify: `packaging/aur/PKGBUILD-bin` (install `tclock-weather`, add optdepends)
- Modify: `AGENTS.md` (mention the bundled widget)
- Reference style: `clock-tui/tests/system-health-widget.sh`, `clock-tui/tests/system_health_widget.rs`
- Existing spec: `docs/superpowers/specs/2026-09-20-tclock-weather-widget-design.md`

All commands run from the repo root. Test commands are run per task; the harness is the fast feedback loop.

---

## Task 1: Script skeleton and pure helpers

**Files:**
- Create: `examples/widgets/tclock-weather`
- Create: `clock-tui/tests/weather-widget.sh`

- [ ] **Step 1: Write the failing test harness**

Create `clock-tui/tests/weather-widget.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: FAIL — `examples/widgets/tclock-weather: No such file or directory`

- [ ] **Step 3: Create the script skeleton and pure helpers**

Create `examples/widgets/tclock-weather` (executable):

```bash
#!/usr/bin/env bash
# tclock-weather — Open-Meteo weather widget for tclock.
#
#   [[clock.widgets]]
#   title = "Weather"
#   command = ["tclock-weather", "--city", "Curitiba"]
#   refresh_secs = 900
#
# Location: --city NAME (geocoded) or --lat/--lon. Units: --units metric|imperial.
# Theme: --theme / TCLOCK_WIDGET_THEME (default|evangelion|nerv). Cache on by
# default; disable with --no-cache or --cache-secs 0.
set -euo pipefail

GEOCODE_URL="https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL="https://api.open-meteo.com/v1/forecast"
DEFAULT_DAYS=3
DEFAULT_UNITS=metric
DEFAULT_TIMEOUT=10
DEFAULT_CACHE_SECS=900
DEFAULT_THEME=default
MAX_DAYS=16

CITY=""
LAT=""
LON=""
DAYS=""
UNITS=""
THEME=""
OUTPUT_JSON=0
CACHE_SECS=""
NO_CACHE=0
TIMEOUT=""
NO_COLOR_FLAG=0
CURRENT_ONLY=0
NORMALIZED=""
FORECAST_JSON=""
LOC_NAME=""
LOC_LAT=""
LOC_LON=""

die() {
  printf 'tclock-weather: %s\n' "$1" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
tclock-weather — Open-Meteo weather widget for tclock

Usage:
  tclock-weather --city NAME [--days N] [--units metric|imperial] [--current-only]
  tclock-weather --lat F --lon F [options]

Options:
  --city NAME          City to geocode (or TCLOCK_WEATHER_CITY)
  --lat F --lon F      Explicit coordinates (skips geocoding)
  --days N             Forecast days, 1-16 (default 3)
  --current-only       Print only current conditions
  --units UNIT         metric (default) or imperial
  --theme NAME         default|evangelion|nerv (or TCLOCK_WIDGET_THEME)
  --json               Print normalized JSON instead of a text block
  --cache-secs N       Cache TTL in seconds (default 900; 0 disables)
  --no-cache           Ignore and do not write the cache
  --no-color           Do not emit ANSI color (NO_COLOR is also honored)
  --timeout N          Network timeout in seconds (default 10)
  -h, --help           Show this help
USAGE
}

urlencode() {
  local s=$1 out='' c h i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      ' ') out+='+' ;;
      *) printf -v h '%%%02X' "'$c"; out+=$h ;;
    esac
  done
  printf '%s' "$out"
}

wmo_label() {
  case "$1" in
    0) printf 'Clear' ;;
    1) printf 'Mostly clear' ;;
    2) printf 'Partly cloudy' ;;
    3) printf 'Overcast' ;;
    45 | 48) printf 'Fog' ;;
    51 | 53 | 55) printf 'Drizzle' ;;
    56 | 57) printf 'Freezing drizzle' ;;
    61 | 63 | 65) printf 'Rain' ;;
    66 | 67) printf 'Freezing rain' ;;
    71 | 73 | 75) printf 'Snow' ;;
    77) printf 'Snow grains' ;;
    80 | 81 | 82) printf 'Rain showers' ;;
    85 | 86) printf 'Snow showers' ;;
    95) printf 'Thunderstorm' ;;
    96 | 99) printf 'Thunderstorm with hail' ;;
    *) printf 'Unknown' ;;
  esac
}

wmo_glyph() {
  case "$1" in
    0) printf '☀' ;;
    1) printf '🌤' ;;
    2) printf '⛅' ;;
    3) printf '☁' ;;
    45 | 48) printf '🌫' ;;
    51 | 53 | 55 | 56 | 57) printf '🌦' ;;
    61 | 63 | 65 | 66 | 67 | 80 | 81 | 82) printf '🌧' ;;
    71 | 73 | 75 | 77 | 85 | 86) printf '❄' ;;
    95 | 96 | 99) printf '⛈' ;;
    *) printf '·' ;;
  esac
}

# Zeller's congruence; prints 0=Sat, 1=Sun, 2=Mon, 3=Tue, 4=Wed, 5=Thu, 6=Fri.
weekday_from_iso() {
  local rest=${1%-*}
  local y
  y=$((10#${rest%-*}))
  local m
  m=$((10#${rest##*-}))
  local d
  d=$((10#${1##*-}))
  case "$m" in
    1 | 2)
      m=$((m + 12))
      y=$((y - 1))
      ;;
  esac
  local k=$((y % 100)) j=$((y / 100))
  printf '%s' "$(((d + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7))"
}

weekday_name() {
  case "$1" in
    0) printf 'Sat' ;;
    1) printf 'Sun' ;;
    2) printf 'Mon' ;;
    3) printf 'Tue' ;;
    4) printf 'Wed' ;;
    5) printf 'Thu' ;;
    6) printf 'Fri' ;;
  esac
}

# Locale-independent rounding of an API decimal string (drops the fraction).
round_number() {
  local v=$1 sign='' int='' frac='' d
  if [ -z "$v" ]; then
    printf '0'
    return 0
  fi
  case "$v" in -*) sign='-' v=${v#-} ;; esac
  int=${v%%.*}
  case "$v" in
    *.*) frac=${v#*.} ;;
  esac
  if [ -z "$int" ]; then int=0; fi
  if [ -n "$frac" ]; then
    d=${frac:0:1}
    if [[ "$d" =~ [0-9] ]] && [ "$d" -ge 5 ]; then int=$((int + 1)); fi
  fi
  printf '%s%s' "$sign" "$int"
}

# read_lines NAME "$newline_separated" -> fills global array NAME (bash 3.2 safe)
read_lines() {
  local name=$1 line i=0
  eval "$name=()"
  while IFS= read -r line; do
    eval "$name[$i]=\$line"
    i=$((i + 1))
  done <<<"$2"
}

main() {
  :
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed`

- [ ] **Step 5: Make executable and commit**

```bash
chmod +x examples/widgets/tclock-weather
git add examples/widgets/tclock-weather clock-tui/tests/weather-widget.sh
git commit -m "feat(weather): add tclock-weather skeleton and pure helpers"
```

---

## Task 2: Argument parsing and validation

**Files:**
- Modify: `examples/widgets/tclock-weather`
- Modify: `clock-tui/tests/weather-widget.sh`

- [ ] **Step 1: Write the failing tests**

In `clock-tui/tests/weather-widget.sh`, insert this block right before the final `printf 'weather widget scenarios passed\n'`:

```bash
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: FAIL — `--help` produces no output yet.

- [ ] **Step 3: Implement `parse_args` and `validate`**

In `examples/widgets/tclock-weather`, replace the `main() { :; }` stub with:

```bash
parse_args() {
  CITY="${TCLOCK_WEATHER_CITY:-}"
  UNITS="${TCLOCK_WEATHER_UNITS:-$DEFAULT_UNITS}"
  THEME="${TCLOCK_WIDGET_THEME:-$DEFAULT_THEME}"
  DAYS=$DEFAULT_DAYS
  TIMEOUT=$DEFAULT_TIMEOUT
  CACHE_SECS=$DEFAULT_CACHE_SECS
  if [ -n "${NO_COLOR:-}" ]; then NO_COLOR_FLAG=1; fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --city)
        if [ $# -lt 2 ]; then die "--city requires a value"; fi
        CITY=$2
        shift 2
        ;;
      --lat)
        if [ $# -lt 2 ]; then die "--lat requires a value"; fi
        LAT=$2
        shift 2
        ;;
      --lon)
        if [ $# -lt 2 ]; then die "--lon requires a value"; fi
        LON=$2
        shift 2
        ;;
      --days)
        if [ $# -lt 2 ]; then die "--days requires a value"; fi
        DAYS=$2
        shift 2
        ;;
      --units)
        if [ $# -lt 2 ]; then die "--units requires a value"; fi
        UNITS=$2
        shift 2
        ;;
      --theme)
        if [ $# -lt 2 ]; then die "--theme requires a value"; fi
        THEME=$2
        shift 2
        ;;
      --cache-secs)
        if [ $# -lt 2 ]; then die "--cache-secs requires a value"; fi
        CACHE_SECS=$2
        shift 2
        ;;
      --timeout)
        if [ $# -lt 2 ]; then die "--timeout requires a value"; fi
        TIMEOUT=$2
        shift 2
        ;;
      --current-only)
        CURRENT_ONLY=1
        shift
        ;;
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --no-cache)
        NO_CACHE=1
        shift
        ;;
      --no-color)
        NO_COLOR_FLAG=1
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        die "unknown option '$1' (see --help)"
        ;;
      *)
        if [ -n "$CITY" ]; then die "unexpected argument '$1'"; fi
        CITY=$1
        shift
        ;;
    esac
  done
  validate
}

validate() {
  if ! [[ "$DAYS" =~ ^[0-9]+$ ]] || [ "$DAYS" -lt 1 ] || [ "$DAYS" -gt "$MAX_DAYS" ]; then
    die "invalid --days '$DAYS': expected an integer from 1 to $MAX_DAYS"
  fi
  if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -lt 1 ]; then
    die "invalid --timeout '$TIMEOUT': expected a positive integer"
  fi
  if ! [[ "$CACHE_SECS" =~ ^[0-9]+$ ]]; then
    die "invalid --cache-secs '$CACHE_SECS': expected a non-negative integer"
  fi
  case "$UNITS" in
    metric | imperial) ;;
    *) die "invalid --units '$UNITS': expected metric or imperial" ;;
  esac
  if [ -n "$LAT" ] || [ -n "$LON" ]; then
    if [ -z "$LAT" ] || [ -z "$LON" ]; then die "both --lat and --lon are required"; fi
    if ! [[ "$LAT" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then die "invalid --lat '$LAT': expected a number"; fi
    if ! [[ "$LON" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then die "invalid --lon '$LON': expected a number"; fi
  fi
  if [ -z "$CITY" ] && { [ -z "$LAT" ] || [ -z "$LON" ]; }; then
    die "no location: pass --city NAME or --lat/--lon"
  fi
}

main() {
  parse_args "$@"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed`

- [ ] **Step 5: Commit**

```bash
git add examples/widgets/tclock-weather clock-tui/tests/weather-widget.sh
git commit -m "feat(weather): parse and validate CLI arguments"
```

---

## Task 3: JSON accessors, location resolution, fetch, normalized JSON

**Files:**
- Create: `clock-tui/tests/fixtures/weather/*.json`
- Modify: `examples/widgets/tclock-weather`
- Modify: `clock-tui/tests/weather-widget.sh`

- [ ] **Step 1: Create fixtures**

`clock-tui/tests/fixtures/weather/geocode-ok.json`:

```json
{"results":[{"id":1,"name":"Curitiba","latitude":-25.42,"longitude":-49.27,"country_code":"BR"}],"generationtime_ms":0.1}
```

`clock-tui/tests/fixtures/weather/geocode-empty.json`:

```json
{"generationtime_ms":0.05}
```

`clock-tui/tests/fixtures/weather/forecast-metric.json`:

```json
{"latitude":-25.42,"longitude":-49.27,"timezone":"America/Sao_Paulo","current_units":{"temperature_2m":"°C","apparent_temperature":"°C","relative_humidity_2m":"%","weather_code":"wmo code","wind_speed_10m":"km/h"},"current":{"time":"2026-09-20T10:00","temperature_2m":22.4,"apparent_temperature":23.1,"relative_humidity_2m":70,"weather_code":2,"wind_speed_10m":12.3},"daily_units":{"weather_code":"wmo code","temperature_2m_max":"°C","temperature_2m_min":"°C"},"daily":{"time":["2026-09-20","2026-09-21","2026-09-22"],"weather_code":[2,0,61],"temperature_2m_max":[24.1,26.7,21.2],"temperature_2m_min":[17.2,18.1,15.4]}}
```

`clock-tui/tests/fixtures/weather/malformed.json`:

```json
{"current": {"temperature_2m":
```

- [ ] **Step 2: Write the failing integration tests**

In `clock-tui/tests/weather-widget.sh`, insert this block right before the final `printf 'weather widget scenarios passed\n'`:

```bash
fixtures="$tests_dir/fixtures/weather"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

cat >"$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
url=""
for a in "$@"; do url=$a; done
log=${WEATHER_CALL_LOG:?WEATHER_CALL_LOG not set}
printf '%s\n' "$url" >>"$log"
if [ "${WEATHER_FAIL_CURL:-0}" = 1 ]; then exit 7; fi
case "$url" in
  *geocoding-api.open-meteo.com*)
    case "${WEATHER_GEOCODE:-ok}" in
      empty) cat "$WEATHER_FIXTURES/geocode-empty.json" ;;
      malformed) cat "$WEATHER_FIXTURES/malformed.json" ;;
      *) cat "$WEATHER_FIXTURES/geocode-ok.json" ;;
    esac
    ;;
  *api.open-meteo.com*)
    case "${WEATHER_FORECAST:-ok}" in
      malformed) cat "$WEATHER_FIXTURES/malformed.json" ;;
      imperial) cat "$WEATHER_FIXTURES/forecast-imperial.json" ;;
      *) cat "$WEATHER_FIXTURES/forecast-metric.json" ;;
    esac
    ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$mock_bin/curl"
export WEATHER_FIXTURES="$fixtures"

run_widget() {
  WEATHER_CALL_LOG="${WEATHER_CALL_LOG_OVERRIDE:-$test_tmp/calls.log}" \
    XDG_CACHE_HOME="$test_tmp/cache" \
    PATH="$mock_bin:$PATH" \
    "$widget" "$@"
}

plain() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }

json_out=$(run_widget --json --city Curitiba)
if [[ "$json_out" != *'"name": "Curitiba"'* ]]; then fail "json city: $json_out"; fi
if [[ "$json_out" != *'"temperature_2m": 22.4'* ]]; then fail "json temp: $json_out"; fi
if [[ "$json_out" != *'"weekday": ["Today", "Mon", "Tue"]'* ]]; then fail "json weekday: $json_out"; fi

calls="$test_tmp/lonely.log"
: >"$calls"
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --json --lat -25.42 --lon -49.27 >/dev/null
assert_eq "$(wc -l <"$calls" | tr -d ' ')" '1' 'lat/lon skips geocoding'

geocode_empty=$(WEATHER_GEOCODE=empty run_widget --no-cache --json --city Nowhere 2>&1 || true)
if [[ "$geocode_empty" != *'not found'* ]]; then fail "geocode empty: $geocode_empty"; fi

net_fail=$(WEATHER_FAIL_CURL=1 run_widget --no-cache --json --city Curitiba 2>&1 || true)
if [[ "$net_fail" != *'could not reach Open-Meteo geocoding'* ]]; then fail "network: $net_fail"; fi

bad=$(WEATHER_FORECAST=malformed run_widget --no-cache --json --city Curitiba 2>&1 || true)
if [[ "$bad" != *'unexpected response from Open-Meteo'* ]]; then fail "malformed: $bad"; fi
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: FAIL — `--json` prints nothing (main only parses args).

- [ ] **Step 4: Implement accessors, resolution, fetch, normalization**

In `examples/widgets/tclock-weather`, add these functions before `main`:

```bash
have_jq() { command -v jq >/dev/null 2>&1; }

json_object() {
  local out
  out=$(printf '%s' "$1" | tr -d '\n' |
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\{[^}]*\}" | head -n1 |
    sed -E 's/^[^{]*\{//; s/\}[^{}]*$//') || true
  printf '%s' "$out"
}

json_field_from() {
  local out
  out=$(printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" | head -n1 |
    sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]*$//') || true
  printf '%s' "$out"
}

json_array_from() {
  local out
  out=$(printf '%s' "$1" | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*\[[^]]*\]" | head -n1 |
    sed -E 's/^[^[]*\[//; s/\][^]]*$//' | tr ',' '\n' |
    sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//') || true
  printf '%s' "$out"
}

json_first_result_field() {
  local out
  out=$(printf '%s' "$1" | tr -d '\n' |
    sed -E 's/.*"results"[[:space:]]*:[[:space:]]*\[//' |
    grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" | head -n1 |
    sed -E 's/^[^:]*:[[:space:]]*//; s/^"//; s/"[[:space:]]*$//; s/[[:space:]]*$//') || true
  printf '%s' "$out"
}

extract_geocode_field() {
  if have_jq; then
    printf '%s' "$1" | jq -r ".results[0].$2 // empty"
  else
    json_first_result_field "$1" "$2"
  fi
}

get_current_field() {
  if have_jq; then
    printf '%s' "$1" | jq -r ".current.$2 // empty"
  else
    json_field_from "$(json_object "$1" current)" "$2"
  fi
}

get_daily_array() {
  if have_jq; then
    printf '%s' "$1" | jq -r ".daily.$2[]? | tostring"
  else
    json_array_from "$(json_object "$1" daily)" "$2"
  fi
}

get_location_field() {
  if have_jq; then
    printf '%s' "$1" | jq -r ".location.$2 // empty"
  else
    json_field_from "$(json_object "$1" location)" "$2"
  fi
}

json_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

http_get() {
  curl --fail --silent --show-error --max-time "$TIMEOUT" "$1"
}

resolve_location() {
  if [ -n "$LAT" ] && [ -n "$LON" ]; then
    LOC_LAT=$LAT
    LOC_LON=$LON
    if [ -n "$CITY" ]; then LOC_NAME=$CITY; else LOC_NAME="$LAT,$LON"; fi
    return 0
  fi
  local url response name lat lon
  url="$GEOCODE_URL?name=$(urlencode "$CITY")&count=1&language=en&format=json"
  response=$(http_get "$url") || die "could not reach Open-Meteo geocoding (timeout ${TIMEOUT}s); check your network"
  name=$(extract_geocode_field "$response" name)
  lat=$(extract_geocode_field "$response" latitude)
  lon=$(extract_geocode_field "$response" longitude)
  if [ -z "$lat" ] || [ -z "$lon" ]; then
    die "city '$CITY' not found; check the spelling or pass --lat/--lon"
  fi
  LOC_NAME=${name:-$CITY}
  LOC_LAT=$lat
  LOC_LON=$lon
}

fetch_forecast() {
  local params
  params="latitude=$LOC_LAT&longitude=$LOC_LON&timezone=auto"
  params="$params&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
  if [ "$CURRENT_ONLY" -eq 0 ]; then
    params="$params&daily=weather_code,temperature_2m_max,temperature_2m_min&forecast_days=$DAYS"
  fi
  if [ "$UNITS" = imperial ]; then
    params="$params&temperature_unit=fahrenheit&wind_speed_unit=mph"
  else
    params="$params&temperature_unit=celsius&wind_speed_unit=kmh"
  fi
  FORECAST_JSON=$(http_get "$FORECAST_URL?$params") || die "could not reach Open-Meteo forecast (timeout ${TIMEOUT}s); check your network"
}

build_daily_json() {
  local dates codes maxs mins
  dates=$(get_daily_array "$FORECAST_JSON" time)
  codes=$(get_daily_array "$FORECAST_JSON" weather_code)
  maxs=$(get_daily_array "$FORECAST_JSON" temperature_2m_max)
  mins=$(get_daily_array "$FORECAST_JSON" temperature_2m_min)
  [ -n "$dates" ] || die "unexpected response from Open-Meteo (no daily forecast); check the service or retry"
  local D C X N i n wd
  read_lines D "$dates"
  read_lines C "$codes"
  read_lines X "$maxs"
  read_lines N "$mins"
  n=${#D[@]}
  local out_t='' out_w='' out_c='' out_x='' out_n=''
  for ((i = 0; i < n; i++)); do
    if [ "$i" -eq 0 ]; then wd=Today; else wd=$(weekday_name "$(weekday_from_iso "${D[$i]}")"); fi
    if [ "$i" -gt 0 ]; then
      out_t+=', '; out_w+=', '; out_c+=', '; out_x+=', '; out_n+=', '
    fi
    out_t+="$(json_quote "${D[$i]}")"
    out_w+="$(json_quote "$wd")"
    out_c+="${C[$i]:-0}"
    out_x+="${X[$i]:-0}"
    out_n+="${N[$i]:-0}"
  done
  printf '{"time": [%s], "weekday": [%s], "weather_code": [%s], "temperature_2m_max": [%s], "temperature_2m_min": [%s]}' \
    "$out_t" "$out_w" "$out_c" "$out_x" "$out_n"
}

build_normalized() {
  local temp app hum code wind
  temp=$(get_current_field "$FORECAST_JSON" temperature_2m)
  app=$(get_current_field "$FORECAST_JSON" apparent_temperature)
  hum=$(get_current_field "$FORECAST_JSON" relative_humidity_2m)
  code=$(get_current_field "$FORECAST_JSON" weather_code)
  wind=$(get_current_field "$FORECAST_JSON" wind_speed_10m)
  if [ -z "$temp" ] || [ -z "$code" ]; then
    die "unexpected response from Open-Meteo; check the service or retry"
  fi
  local daily='{"time": [], "weekday": [], "weather_code": [], "temperature_2m_max": [], "temperature_2m_min": []}'
  if [ "$CURRENT_ONLY" -eq 0 ]; then
    daily=$(build_daily_json)
  fi
  printf '{\n'
  printf '  "location": {"name": %s, "latitude": %s, "longitude": %s},\n' \
    "$(json_quote "$LOC_NAME")" "$LOC_LAT" "$LOC_LON"
  printf '  "current": {"temperature_2m": %s, "apparent_temperature": %s, "relative_humidity_2m": %s, "weather_code": %s, "wind_speed_10m": %s},\n' \
    "$temp" "$app" "$hum" "$code" "$wind"
  printf '  "daily": %s\n' "$daily"
  printf '}\n'
}

render() { printf '%s\n' "$NORMALIZED"; }

main() {
  parse_args "$@"
  resolve_location
  fetch_forecast
  NORMALIZED=$(build_normalized)
  if [ "$OUTPUT_JSON" -eq 1 ]; then
    printf '%s\n' "$NORMALIZED"
  else
    render
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed`

- [ ] **Step 6: Verify the pure-bash fallback path**

Run: `PATH="$(dirname "$(command -v curl)"):/usr/bin:/bin" bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed` (hides `jq`, exercising the pure-bash parser).

- [ ] **Step 7: Commit**

```bash
git add examples/widgets/tclock-weather clock-tui/tests/weather-widget.sh clock-tui/tests/fixtures/weather
git commit -m "feat(weather): resolve location and normalize Open-Meteo data"
```

---

## Task 4: Rendering, units, themes, no-color

**Files:**
- Create: `clock-tui/tests/fixtures/weather/forecast-imperial.json`
- Modify: `examples/widgets/tclock-weather`
- Modify: `clock-tui/tests/weather-widget.sh`

- [ ] **Step 1: Create the imperial fixture**

`clock-tui/tests/fixtures/weather/forecast-imperial.json`:

```json
{"latitude":40.71,"longitude":-74.0,"timezone":"America/New_York","current_units":{"temperature_2m":"°F","apparent_temperature":"°F","relative_humidity_2m":"%","weather_code":"wmo code","wind_speed_10m":"mph"},"current":{"time":"2026-09-20T10:00","temperature_2m":72.3,"apparent_temperature":76.4,"relative_humidity_2m":55,"weather_code":0,"wind_speed_10m":8.2},"daily_units":{"weather_code":"wmo code","temperature_2m_max":"°F","temperature_2m_min":"°F"},"daily":{"time":["2026-09-20","2026-09-21","2026-09-22"],"weather_code":[0,3,95],"temperature_2m_max":[80.4,78.2,75.0],"temperature_2m_min":[60.1,58.6,55.3]}}
```

- [ ] **Step 2: Write the failing tests**

In `clock-tui/tests/weather-widget.sh`, insert this block right before the final `printf 'weather widget scenarios passed\n'`:

```bash
metric=$(run_widget --city Curitiba | plain)
[[ "$metric" == *'22°C'* ]] || fail "metric temp: $metric"
[[ "$metric" == *'feels 23°C · Partly cloudy'* ]] || fail "metric feels: $metric"
[[ "$metric" == *'Partly cloudy'* ]] || fail "metric cond: $metric"
[[ "$metric" == *'Humidity 70%'* ]] || fail "metric humidity: $metric"
[[ "$metric" == *'Wind 12 km/h'* ]] || fail "metric wind: $metric"
[[ "$metric" == *'Today'* ]] || fail "metric today: $metric"
[[ "$metric" == *'24°/17°'* ]] || fail "metric daily: $metric"

imperial=$(WEATHER_FORECAST=imperial run_widget --city Curitiba --units imperial | plain)
[[ "$imperial" == *'72°F'* ]] || fail "imperial temp: $imperial"
[[ "$imperial" == *'Wind 8 mph'* ]] || fail "imperial wind: $imperial"

current_only=$(run_widget --city Curitiba --current-only | plain)
[[ "$current_only" != *'Today'* ]] || fail "current-only leaked daily: $current_only"
[[ "$current_only" == *'22°C'* ]] || fail "current-only temp: $current_only"

default_raw=$(run_widget --city Curitiba)
[[ "$default_raw" == *$'\033[1;36m'* ]] || fail "default theme title code missing"
nerv_raw=$(TCLOCK_WIDGET_THEME=nerv run_widget --city Curitiba)
[[ "$nerv_raw" == *$'\033[1;31m'* ]] || fail "nerv theme title code missing"
unknown_raw=$(TCLOCK_WIDGET_THEME=whatever run_widget --city Curitiba)
[[ "$unknown_raw" == *$'\033[1;36m'* ]] || fail "unknown theme should fall back to default"
no_color_raw=$(run_widget --city Curitiba --no-color)
[[ "$no_color_raw" != *$'\033['* ]] || fail "no-color still emitted escapes"
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: FAIL — render prints normalized JSON, so `22°C` is absent.

- [ ] **Step 4: Implement theme codes and `render`**

In `examples/widgets/tclock-weather`, replace the `render() { ... }` stub with:

```bash
theme_code() {
  case "$1:$2" in
    evangelion:title) printf '\033[1;35m' ;;
    evangelion:accent) printf '\033[38;5;150m' ;;
    nerv:title) printf '\033[1;31m' ;;
    nerv:accent) printf '\033[32m' ;;
    *:title) printf '\033[1;36m' ;;
    *:accent) printf '\033[1;33m' ;;
    *) printf '\033[0m' ;;
  esac
}

color_for() {
  if [ "$NO_COLOR_FLAG" -eq 1 ]; then
    printf ''
    return 0
  fi
  theme_code "$1" "$2"
}

render() {
  local temp app hum code wind cond glyph name unit wunit
  temp=$(get_current_field "$NORMALIZED" temperature_2m)
  app=$(get_current_field "$NORMALIZED" apparent_temperature)
  hum=$(get_current_field "$NORMALIZED" relative_humidity_2m)
  code=$(get_current_field "$NORMALIZED" weather_code)
  wind=$(get_current_field "$NORMALIZED" wind_speed_10m)
  name=$(get_location_field "$NORMALIZED" name)
  cond=$(wmo_label "$code")
  glyph=$(wmo_glyph "$code")
  unit='°C'
  wunit='km/h'
  if [ "$UNITS" = imperial ]; then
    unit='°F'
    wunit='mph'
  fi
  local title accent reset
  title=$(color_for "$THEME" title)
  accent=$(color_for "$THEME" accent)
  reset=$(color_for "$THEME" reset)
  printf '%s%s%s  %s%s%s · feels %s · %s %s\n' \
    "$title" "$name" "$reset" \
    "$accent" "$(round_number "$temp")$unit" "$reset" \
    "$(round_number "$app")$unit" "$cond" "$glyph"
  printf 'Humidity %s%% · Wind %s %s\n' "$(round_number "$hum")" "$(round_number "$wind")" "$wunit"
  if [ "$CURRENT_ONLY" -eq 0 ]; then
    local dates wds codes maxs mins D W C X N i n
    dates=$(get_daily_array "$NORMALIZED" time)
    wds=$(get_daily_array "$NORMALIZED" weekday)
    codes=$(get_daily_array "$NORMALIZED" weather_code)
    maxs=$(get_daily_array "$NORMALIZED" temperature_2m_max)
    mins=$(get_daily_array "$NORMALIZED" temperature_2m_min)
    read_lines D "$dates"
    read_lines W "$wds"
    read_lines C "$codes"
    read_lines X "$maxs"
    read_lines N "$mins"
    n=${#D[@]}
    for ((i = 0; i < n; i++)); do
      printf '%s%-7s%s %s/%s  %s\n' \
        "$accent" "${W[$i]}" "$reset" \
        "$(round_number "${X[$i]}")°" "$(round_number "${N[$i]}")°" \
        "$(wmo_label "${C[$i]}")"
    done
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed`

- [ ] **Step 6: Commit**

```bash
git add examples/widgets/tclock-weather clock-tui/tests/weather-widget.sh clock-tui/tests/fixtures/weather/forecast-imperial.json
git commit -m "feat(weather): render current conditions, forecast and themes"
```

---

## Task 5: Local TTL cache

**Files:**
- Modify: `examples/widgets/tclock-weather`
- Modify: `clock-tui/tests/weather-widget.sh`

- [ ] **Step 1: Write the failing tests**

In `clock-tui/tests/weather-widget.sh`, insert this block right before the final `printf 'weather widget scenarios passed\n'`:

```bash
mtime_probe=$(mktemp)
mtime_value=$(file_mtime "$mtime_probe")
[[ "$mtime_value" =~ ^[0-9]+$ ]] || fail "file_mtime not numeric: [$mtime_value]"
rm -f "$mtime_probe"

calls="$test_tmp/cache.log"
rm -rf "$test_tmp/cache"
: >"$calls"
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --city Curitiba >/dev/null
assert_eq "$(wc -l <"$calls" | tr -d ' ')" '2' 'first run makes geocode+forecast calls'
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --city Curitiba >/dev/null
assert_eq "$(wc -l <"$calls" | tr -d ' ')" '2' 'second run within TTL uses cache'

rm -rf "$test_tmp/cache"
: >"$calls"
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --no-cache --city Curitiba >/dev/null
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --no-cache --city Curitiba >/dev/null
assert_eq "$(wc -l <"$calls" | tr -d ' ')" '4' 'no-cache always hits network'

rm -rf "$test_tmp/cache"
: >"$calls"
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --cache-secs 0 --city Curitiba >/dev/null
WEATHER_CALL_LOG_OVERRIDE="$calls" run_widget --cache-secs 0 --city Curitiba >/dev/null
assert_eq "$(wc -l <"$calls" | tr -d ' ')" '4' 'cache-secs 0 always hits network'
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: FAIL at `second run within TTL uses cache` — without a cache both runs hit the network, so the call count is `4`, not `2`. The first assertion already passes because the render path fetches.

- [ ] **Step 3: Implement the cache and wire `main`**

In `examples/widgets/tclock-weather`, add before `main`:

```bash
file_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=0
  case "$m" in '' | *[!0-9]*) m=0 ;; esac
  printf '%s' "$m"
}

cache_file() {
  local base
  if [ -n "$LAT" ] && [ -n "$LON" ]; then base="${LAT}_${LON}"; else base="$CITY"; fi
  base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/tclock-weather/%s_%s_%s_%s.json' "${XDG_CACHE_HOME:-$HOME/.cache}" "$base" "$DAYS" "$UNITS" "$CURRENT_ONLY"
}

cache_get() {
  if [ "$NO_CACHE" -eq 1 ]; then return 1; fi
  if [ "$CACHE_SECS" -le 0 ]; then return 1; fi
  local file mtime now
  file=$(cache_file)
  if [ ! -f "$file" ]; then return 1; fi
  mtime=$(file_mtime "$file")
  now=$(date +%s)
  if [ $((now - mtime)) -ge "$CACHE_SECS" ]; then return 1; fi
  cat "$file"
}

cache_put() {
  if [ "$NO_CACHE" -eq 1 ]; then return 0; fi
  if [ "$CACHE_SECS" -le 0 ]; then return 0; fi
  local file
  file=$(cache_file)
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s' "$1" >"$file" 2>/dev/null || true
}

main() {
  parse_args "$@"
  local cached
  if cached=$(cache_get); then
    NORMALIZED=$cached
  else
    resolve_location
    fetch_forecast
    NORMALIZED=$(build_normalized)
    cache_put "$NORMALIZED"
  fi
  if [ "$OUTPUT_JSON" -eq 1 ]; then
    printf '%s\n' "$NORMALIZED"
  else
    render
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash clock-tui/tests/weather-widget.sh`
Expected: `weather widget scenarios passed`

- [ ] **Step 5: Commit**

```bash
git add examples/widgets/tclock-weather clock-tui/tests/weather-widget.sh
git commit -m "feat(weather): add local TTL cache"
```

---

## Task 6: Rust wrapper so `cargo test` runs the harness

**Files:**
- Create: `clock-tui/tests/weather_widget.rs`
- Reference: `clock-tui/tests/system_health_widget.rs`

- [ ] **Step 1: Write the wrapper**

Create `clock-tui/tests/weather_widget.rs`:

```rust
use std::path::PathBuf;
use std::process::Command;

#[test]
fn weather_widget_scenarios() {
    let script = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/weather-widget.sh");
    let status = Command::new("bash")
        .arg(script)
        .status()
        .expect("run weather widget regression tests");

    assert!(status.success(), "weather widget scenarios failed");
}
```

- [ ] **Step 2: Run the Rust test**

Run: `cargo test --locked --package clock-tui --test weather_widget`
Expected: PASS (`weather widget scenarios` test passes and the harness prints `weather widget scenarios passed`).

- [ ] **Step 3: Commit**

```bash
git add clock-tui/tests/weather_widget.rs
git commit -m "test(weather): run the widget harness from cargo test"
```

---

## Task 7: Docs and packaging

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/release.yml`
- Modify: `packaging/aur/PKGBUILD-bin`
- Modify: `AGENTS.md`

- [ ] **Step 1: Add the README section**

In `README.md`, immediately before the line starting `### Bundled example: system-health widget`, insert:

```markdown
### Bundled example: weather widget

The repo ships a ready-to-use weather widget at
[`examples/widgets/tclock-weather`](./examples/widgets/tclock-weather). It fetches
current conditions plus an N-day forecast from [Open-Meteo](https://open-meteo.com)
(no API key) and renders them as a compact themed block:

```toml
[clock]
[[clock.widgets]]
title = "Weather"
command = ["tclock-weather", "--city", "Curitiba"]
refresh_secs = 900
```

Location comes from `--city NAME` (geocoded) or `--lat`/`--lon`. Use
`--units imperial` for °F/mph, `--days N` (1-16) to change the forecast length,
and `--current-only` to drop the daily rows. The widget honors
`TCLOCK_WIDGET_THEME` (`default`, `evangelion`, `nerv`), so it follows `Shift+T`.
It caches API responses for 15 minutes by default; `--no-cache` or
`--cache-secs 0` disables that. `--json` prints the normalized data instead of a
text block. The script prefers `jq` when installed and falls back to a pure-bash
JSON parser, so `jq` is optional.

The raw `wttr.in` command below still works if you prefer no extra script, but
the bundled widget is more reliable and testable.
```

- [ ] **Step 2: Update the release workflow**

In `.github/workflows/release.yml`, after the `tclock-system-health` install line (currently line 91), add:

```yaml
          install -Dm0755 examples/widgets/tclock-weather "$STAGE/tclock-weather"
```

Change the `tar czf` line (currently line 95) to include the new script:

```yaml
          tar czf ${{ matrix.artifact }}.tar.gz -C "$STAGE" tclock tclock-system-health tclock-weather LICENSE README.md docs/widget-themes.md
```

Change the manual install snippet (currently line 146) to extract the script too:

```yaml
            echo "curl -fsSL https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/clock-tui-linux-\$ARCH.tar.gz | tar xz -C ~/.local/bin tclock tclock-system-health tclock-weather"
```

- [ ] **Step 3: Update the AUR template**

In `packaging/aur/PKGBUILD-bin`, add `curl` to `depends` and the new script plus its `jq` optdepend:

```bash
depends=('gcc-libs' 'curl')
optdepends=('jq: faster JSON parsing in the tclock-weather example widget'
            'btrfs-progs: btrfs health row in the tclock-system-health example widget')
```

In `package()`, after the `tclock-system-health` line, add:

```bash
    install -Dm0755 -t "$pkgdir/usr/bin/"                 "tclock-weather"
```

Note: `jq` already appears in the existing optdepends for `tclock-system-health`;
merge the two `jq` reasons into one entry rather than duplicating the key.

- [ ] **Step 4: Update AGENTS.md**

In `AGENTS.md`, under "Runtime gotchas", extend the clock-widget bullet to name
the bundled example, e.g. append: "Bundled example widgets live in
`examples/widgets/` (`tclock-system-health`, `tclock-weather`); the weather
widget is TDD-covered by `clock-tui/tests/weather-widget.sh` via
`clock-tui/tests/weather_widget.rs` and must not hit the network in tests."

- [ ] **Step 5: Commit**

```bash
git add README.md .github/workflows/release.yml packaging/aur/PKGBUILD-bin AGENTS.md
git commit -m "docs(weather): document and package the weather widget"
```

---

## Task 8: CI parity and smoke test

**Files:** none (verification only)

- [ ] **Step 1: Run the full local CI parity sequence**

Run, in order, from the repo root:

```bash
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked --verbose
cargo test --locked --verbose
cargo xtask
```

Expected: all succeed. `cargo xtask` regenerates `assets/gen`; since `assets/gen`
is gitignored the follow-up `git diff --exit-code assets/gen` is a no-op, but run
`cargo xtask` anyway so local completions/manpage stay current (this change does
not touch the CLI, so no diff is expected).

- [ ] **Step 2: Shell syntax check**

Run: `bash -n examples/widgets/tclock-weather && bash -n clock-tui/tests/weather-widget.sh`
Expected: no output, exit 0.

If `shellcheck` is installed, also run `shellcheck examples/widgets/tclock-weather` and fix warnings that are not false positives (for example disable `SC2181` style checks only when justified).

- [ ] **Step 3: Live smoke test (network required)**

Run: `examples/widgets/tclock-weather --city Curitiba`
Expected: two current-condition lines plus three daily rows, e.g.:

```
Curitiba  <temp>°C · feels <temp>°C · <condition> <glyph>
Humidity <n>% · Wind <n> km/h
Today   <max>°/<min>°  <condition>
<weekday> <max>°/<min>°  <condition>
<weekday> <max>°/<min>°  <condition>
```

Also verify: `examples/widgets/tclock-weather --city Curitiba --current-only`,
`--units imperial`, `--lat -25.42 --lon -49.27`, and `--json`.

- [ ] **Step 4: Final commit if the smoke test required changes**

```bash
git add -A
git commit -m "fix(weather): polish after live smoke test"
```

Only commit if Step 3 required a change; otherwise skip.

---

## Task 9: Push the branch and open the PR in the fork

**Files:** none (git/GitHub only)

- [ ] **Step 1: Confirm branch and remotes**

Run: `git status -sb && git remote -v`
Expected: on `feat/tclock-weather-widget`, `origin` = `puppe1990/clock-tui`, `upstream` = `akitaonrails/clock-tui`, working tree clean.

- [ ] **Step 2: Push the branch to origin**

Run: `git push -u origin feat/tclock-weather-widget`

- [ ] **Step 3: Open the PR in the fork**

Run:

```bash
gh pr create --repo puppe1990/clock-tui --base master --head feat/tclock-weather-widget \
  --title "feat: bundled tclock-weather widget" \
  --body "Adds examples/widgets/tclock-weather: an Open-Meteo (no API key) weather widget for clock mode with current conditions, N-day forecast, metric/imperial units, themes, a TTL cache, and a jq-or-bash JSON parser. Covered by a deterministic fake-curl test harness run from cargo test."
```

Expected: prints the PR URL. Report it to the user.

