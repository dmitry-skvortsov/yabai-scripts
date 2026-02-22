#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

YABAI=${YABAI:-/opt/homebrew/bin/yabai}
JQ=${JQ:-/opt/homebrew/bin/jq}

SUPPRESS_PREFIX="/tmp/yabai_suppress_"

kind="${1:-}"
[[ -z "$kind" ]] && { echo "usage: $0 ghostty|chrome|zen" >&2; exit 2; }

space_json="$("$YABAI" -m query --spaces --space 2>/dev/null || echo '{}')"
space_parsed="$("$JQ" -r \
  '"\(.index // 0)\t\(.display // 0)\t\(."is-native-fullscreen" // false)"' \
  <<< "$space_json" 2>/dev/null || printf '0\t0\tfalse')"
cur_space="${space_parsed%%$'\t'*}"
rest="${space_parsed#*$'\t'}"
cur_disp="${rest%%$'\t'*}"
is_fs="${rest##*$'\t'}"
[[ "$cur_space" == "0" || "$cur_disp" == "0" ]] && exit 0

if [[ "$is_fs" == "true" ]]; then
  exit 0
fi

suppress_token="${SUPPRESS_PREFIX}$$.${RANDOM:-0}.${EPOCHREALTIME//./}"
: >"$suppress_token"
trap 'rm -f "$suppress_token" 2>/dev/null || true' EXIT

app_filter=""
spawn() { :; }

case "$kind" in
  chrome)
    app_filter='select(.app=="Google Chrome")'
    spawn() {
      if pgrep -x "Google Chrome" >/dev/null 2>&1; then
        /usr/bin/osascript >/dev/null 2>&1 <<'OSA'
tell application "Google Chrome" to make new window
OSA
      else
        /usr/bin/open -g -a "Google Chrome" \
          --args --new-window --no-first-run --no-default-browser-check \
          >/dev/null 2>&1 || true
      fi
    }
    ;;

  ghostty)
    app_filter='select(.app=="Ghostty")'
    spawn() {
      if pgrep -ax "[Gg]hostty" >/dev/null 2>&1; then
        /usr/bin/osascript >/dev/null 2>&1 <<'OSA'
tell application "Ghostty" to activate
tell application "System Events"
  if exists process "Ghostty" then
    tell process "Ghostty" to keystroke "n" using {command down}
  end if
end tell
OSA
      else
        /usr/bin/open -a "Ghostty" >/dev/null 2>&1 || true
      fi
    }
    ;;

  zen)
    app_filter='select(.app|test("^Zen"))'
    spawn() {
      "/Applications/Zen.app/Contents/MacOS/zen" -new-window about:blank \
        >/dev/null 2>&1 &
      disown || true
    }
    ;;

  *)
    echo "unknown kind: $kind" >&2
    exit 2
    ;;
esac

baseline_max_id="$(
  wins="$("$YABAI" -m query --windows 2>/dev/null || echo '[]')"
  "$JQ" -r "map($app_filter) |
            map(select(.role==\"AXWindow\" and .layer==\"normal\" and .minimized==0)) |
            (max_by(.id).id // 0)" \
    <<< "$wins" 2>/dev/null || echo 0
)"
[[ "$baseline_max_id" == "null" || -z "$baseline_max_id" ]] && baseline_max_id=0

spawn

pick_newer_than_baseline() {
  local wins
  wins="$("$YABAI" -m query --windows 2>/dev/null || echo '[]')"
  "$JQ" -r --argjson base "$baseline_max_id" "
    map($app_filter) |
    map(select(.role==\"AXWindow\" and .layer==\"normal\"
               and .minimized==0 and (.id > \$base))) |
    (max_by(.id).id // empty)
  " <<< "$wins" 2>/dev/null || true
}

new_id=""
# Быстрые первые проверки + экспоненциальное увеличение паузы.
for delay in 0.02 0.04 0.08 0.16 0.32 0.50; do
  sleep "$delay"
  new_id="$(pick_newer_than_baseline)"
  [[ -n "$new_id" && "$new_id" != "null" ]] && break
done

[[ -z "$new_id" || "$new_id" == "null" ]] && exit 0

"$YABAI" -m display --focus "$cur_disp"  >/dev/null 2>&1 || true
"$YABAI" -m space   --focus "$cur_space" >/dev/null 2>&1 || true
"$YABAI" -m window "$new_id" --space "$cur_space" --focus >/dev/null 2>&1 || true

for delay in 0.03 0.08 0.14; do
  sleep "$delay"
  "$YABAI" -m window --focus "$new_id" >/dev/null 2>&1 && break
done
