#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

YABAI=${YABAI:-/opt/homebrew/bin/yabai}
JQ=${JQ:-/opt/homebrew/bin/jq}

DIR="${1:-next}"
SUPPRESS_PREFIX="/tmp/yabai_suppress_"
STATE_DIR=${STATE_DIR:-/tmp/yabai_agent}
mkdir -p "$STATE_DIR"

win="$("$YABAI" -m query --windows --window 2>/dev/null || echo '{}')"
win_parsed="$("$JQ" -r '"\(.id // 0)\t\(.display // 0)\t\(.space // 0)"' \
  <<< "$win" 2>/dev/null || printf '0\t0\t0')"
win_id="${win_parsed%%$'\t'*}"
rest="${win_parsed#*$'\t'}"
cur_disp="${rest%%$'\t'*}"
cur_space="${rest##*$'\t'}"
[[ "$win_id" == "0" || "$cur_disp" == "0" || "$cur_space" == "0" ]] && exit 0

space_json="$("$YABAI" -m query --spaces --space 2>/dev/null || echo '{}')"
if "$JQ" -e '."is-native-fullscreen"==true' <<< "$space_json" >/dev/null 2>&1; then
  exit 0
fi

spaces="$("$YABAI" -m query --spaces 2>/dev/null || echo '[]')"

target_space="$(
  "$JQ" -r \
    --argjson d "$cur_disp" \
    --argjson cs "$cur_space" \
    --arg dir "$DIR" '
    def on_disp: map(select(.display==$d and (."is-native-fullscreen"!=true)))
                 | sort_by(.index);
    (on_disp) as $s |
    if ($s|length)==0 then empty else
      ($s | to_entries | map(select(.value.index==$cs)) | .[0].key // -1) as $pos |
      if $pos < 0 then empty
      elif $dir=="next" then $s[(($pos+1)%($s|length))].index
      else $s[((($pos-1)+($s|length))%($s|length))].index
      end
    end
  ' <<< "$spaces" 2>/dev/null || true
)"

[[ -z "$target_space" || "$target_space" == "$cur_space" ]] && exit 0

suppress_token="${SUPPRESS_PREFIX}$$.${RANDOM:-0}.${EPOCHREALTIME//./}"
: >"$suppress_token"
trap 'rm -f "$suppress_token" 2>/dev/null || true' EXIT

"$YABAI" -m window "$win_id" --space "$target_space" --focus >/dev/null 2>&1 || exit 0
"$YABAI" -m window --focus "$win_id" >/dev/null 2>&1 || true
