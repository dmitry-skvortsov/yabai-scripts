#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

YABAI=${YABAI:-/opt/homebrew/bin/yabai}
JQ=${JQ:-/opt/homebrew/bin/jq}
STATE_DIR=${STATE_DIR:-/tmp/yabai_agent}
ITERATIONS=${ITERATIONS:-50}
MODE="${1:-focus}"
IDLE_CHECKS=${IDLE_CHECKS:-80}
IDLE_INTERVAL_SEC=${IDLE_INTERVAL_SEC:-0.02}
SWITCH_DELAY_SEC=${SWITCH_DELAY_SEC:-0.08}

mkdir -p "$STATE_DIR"

SNAP_BEFORE="$STATE_DIR/stress_before.txt"
SNAP_AFTER="$STATE_DIR/stress_after.txt"

snapshot_processes() {
  ps -ax -o pid=,ppid=,command= \
    | awk '
        /yabai-agent\.sh run|(^|[[:space:]])borders([[:space:]]|$)|yabai_suppress_/ &&
        $0 !~ /stress_agent\.sh/ &&
        $0 !~ /awk / { print }
      '
}

run_load() {
  case "$MODE" in
    focus)
      for ((i = 0; i < ITERATIONS; i++)); do
        "$YABAI" -m window --focus east >/dev/null 2>&1 || true
        "$YABAI" -m window --focus west >/dev/null 2>&1 || true
      done
      ;;
    close)
      for ((i = 0; i < ITERATIONS; i++)); do
        "$YABAI" -m window --close >/dev/null 2>&1 || true
      done
      ;;
    query)
      for ((i = 0; i < ITERATIONS; i++)); do
        "$YABAI" -m query --windows >/dev/null 2>&1 || true
      done
      ;;
    *)
      echo "usage: $0 [focus|close|query]" >&2
      exit 2
      ;;
  esac
}

focus_reliability_summary() {
  local spaces_json displays_json current_space
  spaces_json="$("$YABAI" -m query --spaces 2>/dev/null || echo '[]')"
  displays_json="$("$YABAI" -m query --displays 2>/dev/null || echo '[]')"
  current_space="$("$JQ" -r '.[] | select(."has-focus"==true) | .index' <<< "$spaces_json" 2>/dev/null | head -n1)"

  local spaces_count displays_count
  spaces_count="$("$JQ" 'length' <<< "$spaces_json" 2>/dev/null || echo 0)"
  displays_count="$("$JQ" 'length' <<< "$displays_json" 2>/dev/null || echo 0)"

  local idle_miss_nonempty=0 idle_checks=0 winj has_focus count i
  for ((i = 0; i < IDLE_CHECKS; i++)); do
    winj="$("$YABAI" -m query --windows --space 2>/dev/null || echo '[]')"
    has_focus="$("$JQ" '[ .[] | select(."has-focus"==true or .focused==1) ] | length' <<< "$winj" 2>/dev/null || echo 0)"
    count="$("$JQ" 'length' <<< "$winj" 2>/dev/null || echo 0)"
    idle_checks=$(( idle_checks + 1 ))
    if (( count > 0 && has_focus == 0 )); then
      idle_miss_nonempty=$(( idle_miss_nonempty + 1 ))
    fi
    sleep "$IDLE_INTERVAL_SEC"
  done

  local switch_checks=0 switch_miss_nonempty=0 sp
  while IFS= read -r sp; do
    [[ -n "$sp" ]] || continue
    "$YABAI" -m space --focus "$sp" >/dev/null 2>&1 || true
    sleep "$SWITCH_DELAY_SEC"
    winj="$("$YABAI" -m query --windows --space 2>/dev/null || echo '[]')"
    has_focus="$("$JQ" '[ .[] | select(."has-focus"==true or .focused==1) ] | length' <<< "$winj" 2>/dev/null || echo 0)"
    count="$("$JQ" 'length' <<< "$winj" 2>/dev/null || echo 0)"
    switch_checks=$(( switch_checks + 1 ))
    if (( count > 0 && has_focus == 0 )); then
      switch_miss_nonempty=$(( switch_miss_nonempty + 1 ))
    fi
  done < <("$JQ" -r '.[] | select(."is-native-fullscreen"!=true) | .index' <<< "$spaces_json" 2>/dev/null || true)

  if [[ -n "${current_space:-}" ]]; then
    "$YABAI" -m space --focus "$current_space" >/dev/null 2>&1 || true
  fi

  echo "spaces_count=$spaces_count displays_count=$displays_count"
  echo "focus_idle_checks=$idle_checks focus_idle_miss_nonempty=$idle_miss_nonempty"
  echo "focus_switch_checks=$switch_checks focus_switch_miss_nonempty=$switch_miss_nonempty"
}

snapshot_processes > "$SNAP_BEFORE" || true
run_load
sleep 0.4
snapshot_processes > "$SNAP_AFTER" || true

YABAI_VERSION="$("$YABAI" --version 2>/dev/null || echo unknown)"
if "$YABAI" -m signal --list >/dev/null 2>&1; then
  SIGNAL_API=1
else
  SIGNAL_API=0
fi

echo "mode=$MODE iterations=$ITERATIONS"
echo "yabai_version=$YABAI_VERSION signal_api=$SIGNAL_API"
echo "before_snapshot=$SNAP_BEFORE"
echo "after_snapshot=$SNAP_AFTER"
focus_reliability_summary
