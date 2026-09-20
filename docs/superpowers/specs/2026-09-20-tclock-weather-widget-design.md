# Design: bundled `tclock-weather` widget

Date: 2026-09-20
Status: approved (pending written-spec review)
Branch: `feat/tclock-weather-widget`
Fork: `puppe1990/clock-tui` (origin), `akitaonrails/clock-tui` (upstream)

## Context

Clock mode already supports command widgets: any executable that prints text to
stdout and exits can be rendered below the clock, with ANSI colors, per-widget
refresh, groups, and popup actions. The README currently documents a weather
widget as a raw `curl 'https://wttr.in/...'` command.

That recipe is fragile (wttr.in rate limits, text scraping, no forecast
control), cannot be tested, and gives the user no way to pick units, theme, or
cache. This design turns weather into a first-class bundled widget, following
the precedent set by `examples/widgets/tclock-system-health`: a self-contained,
host-agnostic bash script shipped in release tarballs and referenced from
`[[clock.widgets]]`.

## Goals

- Ship `examples/widgets/tclock-weather`, a self-contained executable script.
- Fetch current conditions + N-day forecast from Open-Meteo (no API key).
- Resolve location from `--city` (geocoding) or explicit `--lat/--lon`.
- Support metric/imperial units and the app's widget themes
  (`TCLOCK_WIDGET_THEME`).
- Provide a local TTL cache so a short widget refresh does not hammer the API.
- Emit actionable errors and non-zero exit codes on failure.
- Be developed TDD-first with a deterministic, network-free test harness.

## Non-goals

- No changes to the Rust `tclock` binary or its config schema. Weather remains a
  command widget.
- No IP-based auto-geolocation. Location is explicit (`--city` or `--lat/--lon`).
- No hourly forecast in this iteration (daily only).
- No interactive UI; the script prints a snapshot and exits.
- No new runtime dependency for the app; the script alone talks to the network.

## Deliverable

`examples/widgets/tclock-weather` — bash script, `chmod +x`, no `.sh`
extension, mirroring `tclock-system-health`.

The script is sourceable: it ends with the standard
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` guard, so
`sourcing` loads functions without running `main` and tests can unit-test
parsing and rendering directly. It still works when executed normally.

## CLI

```
tclock-weather [--city NAME | --lat F --lon F] [--days N] [--current-only]
               [--units metric|imperial] [--theme NAME] [--json]
               [--cache-secs N] [--no-cache] [--timeout N] [--help]
```

Precedence: CLI flag > environment variable > default.

| Concern | Flag | Env | Default |
| --- | --- | --- | --- |
| Location | `--city`, `--lat`, `--lon` | `TCLOCK_WEATHER_CITY` | none (required) |
| Forecast length | `--days N` | — | `3` |
| Units | `--units metric\|imperial` | `TCLOCK_WEATHER_UNITS` | `metric` |
| Theme | `--theme NAME` | `TCLOCK_WIDGET_THEME` | `default` |
| Cache TTL | `--cache-secs N` | — | `900` |
| Cache off | `--no-cache` | — | cache on |
| Color off | `--no-color` | `NO_COLOR` | color on |
| Network timeout | `--timeout N` (secs) | — | `10` |
| Raw JSON | `--json` | — | off |

Notes:
- `--current-only` suppresses the daily block; `--days` is ignored with it.
- `--json` prints the processed JSON (location + current + daily) and exits,
  bypassing rendering; useful for debugging and for parse tests.
- `--no-color` (or `NO_COLOR` set, or a non-tty stdout) emits plain text with no
  ANSI escapes.
- `--help` prints usage and exits 0.
- `--lat`/`--lon` may be given together; if both are present, geocoding is
  skipped. If only one is given, that is an error.
- Unknown flags and malformed numeric values are errors.

## Data flow

1. **Resolve location**
   - If `--lat`/`--lon` given: use them; the display label is `lat,lon`
     formatted to two decimals unless a `--city` was also given, in which case
     the given city string is used as the label (no geocoding call).
   - Else if a city is available: call
     `https://geocoding-api.open-meteo.com/v1/search?name=<urlencoded>&count=1&language=en&format=json`,
     read `results[0].latitude`, `.longitude`, `.name`, `.country_code`.
   - Else: error (`no location given; pass --city or --lat/--lon`).

2. **Fetch forecast**
   - `https://api.open-meteo.com/v1/forecast`
   - Query:
     - `latitude`, `longitude`
     - `current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m`
     - `daily=weather_code,temperature_2m_max,temperature_2m_min`
     - `forecast_days=<N>`, `timezone=auto`
     - `temperature_unit=celsius|fahrenheit`
     - `wind_speed_unit=kmh|mph`
   - `--current-only` drops the `daily` params and only requests `current`.

3. **Parse**
   - Prefer `jq` when available; otherwise use a pure-bash fallback parser that
     extracts the flat `current` fields and the three `daily` arrays.
   - The parser produces a normalized, render-ready structure.

4. **Render** (unless `--json`)
   - Current block: temperature, apparent temperature, condition text + glyph,
     humidity, wind.
   - Daily block: one line per day with weekday/date, min/max, condition.
   - ANSI colors come from the theme palette.

5. **Cache**
   - File per `(lat,lon,days,units)` under
     `${XDG_CACHE_HOME:-$HOME/.cache}/tclock-weather/`.
   - A cache hit younger than `--cache-secs` skips both the geocode and forecast
     network calls. `--no-cache` ignores both read and write.
   - Cache writes are best-effort; failures never break rendering.

## Weather-code mapping

WMO weather codes map to a short text label and a glyph, e.g. `0` → Clear `☀`,
`1-3` partly cloudy `⛅`/`☁`, `45/48` fog, `51-57` drizzle, `61-67` rain,
`71-77` snow, `80-82` showers, `85-86` snow showers, `95-99` thunderstorm.
Unknown codes render `?`. Mapping is a pure function and is unit-tested per band.

## Theming

Palettes `default`, `evangelion` (purple/lavender), `nerv` (red/amber/green),
matching `tclock-system-health` conventions. The script reads
`TCLOCK_WIDGET_THEME` (or `--theme`) and emits the palette's ANSI escapes.
Unknown theme names fall back to `default`. Color is on by default so widgets
match current behavior; `--no-color` or the `NO_COLOR` environment variable
disables ANSI escapes. There is no tty auto-detection, which keeps color stable
under pipes and tests.

## Error handling (actionable, shift-left)

Every failure prints one line explaining what was attempted, what failed in
user terms, and the fix, then exits non-zero:

| Situation | Message gist |
| --- | --- |
| No location | "no location: pass --city NAME or --lat/--lon" |
| Only one of lat/lon | "both --lat and --lon are required" |
| Geocoding empty | "city 'X' not found; check spelling or use --lat/--lon" |
| Network/curl failure | "could not reach Open-Meteo (timeout Ns); check network" |
| Invalid JSON | "unexpected response from Open-Meteo; retry or check the service" |
| Bad `--days`/coords | "invalid --days 'x': expected a positive integer" |

The bash fallback parser guarantees the script works without `jq`, so a missing
parser never reaches the user.

`--json` on error still exits non-zero and prints the error to stderr.

## Testing strategy (TDD)

Harness mirroring `tclock-system-health`:

- `clock-tui/tests/weather-widget.sh` — bash scenario harness with assertions.
- `clock-tui/tests/weather_widget.rs` — thin Rust wrapper that runs the harness,
  so `cargo test` covers it (mirrors `system_health_widget.rs`).
- Fixtures under `clock-tui/tests/fixtures/weather/`:
  - `geocode-ok.json`, `geocode-empty.json`
  - `forecast-metric.json`, `forecast-imperial.json`
  - `malformed.json`
  - a fake `curl` executable that serves the right fixture based on the URL and
    records invocation count (for cache assertions); tests prepend its directory
    to `PATH` and point `XDG_CACHE_HOME` at a temp dir.

Scenarios (written failing first):
1. `--city` geocodes, renders current temp and 3 daily lines (metric).
2. `--lat/--lon` skips geocoding entirely (no geocode call observed).
3. `--units imperial` requests fahrenheit/mph and renders °F.
4. `--current-only` omits the daily block.
5. `--json` prints parseable JSON with location, current, and daily fields.
6. No location → actionable error, non-zero exit.
7. Only `--lat` (no `--lon`) → error.
8. Geocode returns no results → "not found" error.
9. `curl` exits non-zero → network error, non-zero exit.
10. `malformed.json` → invalid-response error.
11. Cache hit: two runs within TTL make only one forecast network call.
12. `--no-cache`: two runs make two network calls.
13. Expired TTL (`--cache-secs 0`) makes a fresh call.
14. Theme: `TCLOCK_WIDGET_THEME=nerv` emits nerv ANSI codes; unknown theme falls
    back to default.
15. `--no-color` emits no ANSI escapes.
16. WMO mapping for representative codes (0, 3, 61, 71, 95, unknown).
17. `--help` exits 0 and prints usage.
18. Invalid `--days abc` → error.

`cargo test --package clock-tui --test weather_widget` runs the suite. The
harness must not touch the real network; it fails loudly if `curl` is not the
fake.

## Docs and packaging

- README: add "Bundled example: weather widget" next to the system-health
  section; update the `wttr.in` recipe to point at `tclock-weather` while
  keeping a short raw-curl fallback for users without the script.
- `.github/workflows/release.yml`: include `tclock-weather` in both Linux
  tarballs and in the `install -Dm0755 examples/widgets/...` step, like
  `tclock-system-health`.
- `packaging/aur/PKGBUILD-bin`: install `tclock-weather` if the package ships
  bundled widgets.
- `AGENTS.md`: mention the new bundled widget alongside `tclock-system-health`
  where relevant.

## Verification

CI parity per `AGENTS.md`:
`cargo fmt --all --check`,
`cargo clippy --workspace --all-targets --locked -- -D warnings`,
`cargo build --locked --verbose`,
`cargo test --locked --verbose`,
`cargo xtask` + `git diff --exit-code assets/gen`.
Plus a manual smoke run against the live API (`tclock-weather --city Curitiba`)
and `shellcheck`/`bash -n` on the script if available.
