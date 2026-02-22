#!/usr/bin/env bash
# yabai-agent.sh — event agent for yabai (signal-based, v7-compatible)
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

YABAI=${YABAI:-/opt/homebrew/bin/yabai}
JQ=${JQ:-/opt/homebrew/bin/jq}

STATE_DIR=${STATE_DIR:-/tmp/yabai_agent}
mkdir -p "$STATE_DIR"
export YABAI JQ STATE_DIR

PIDFILE="$STATE_DIR/agent.pid"
LOCK_DIR="$STATE_DIR/agent.lock"
EVENT_LOCK_DIR="$STATE_DIR/event.lock"
DEBOUNCE_GEN_FILE="$STATE_DIR/refocus_gen"
DEBOUNCE_WANT="$STATE_DIR/refocus_want"
TOPOLOGY_DIRTY_FILE="$STATE_DIR/topology_dirty"
SUPPRESS_GLOB="/tmp/yabai_suppress_*"

DEBUG=${DEBUG:-0}
DEBUG_FLAG_FILE="$STATE_DIR/debug_enabled"
LOG_FILE="$STATE_DIR/agent.log"

# ---- tunables ----
REFOCUS_DEBOUNCE_MS=90
FOCUS_TRACK_THROTTLE_MS=70
LOG_ROTATE_BYTES=1048576
# ------------------

SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
AGENT_PID=0

SIGNAL_EVENTS=(
  window_focused
  window_destroyed
  window_minimized
  application_terminated
  space_created
  space_destroyed
  space_changed
  display_added
  display_removed
  display_moved
  display_resized
  display_changed
  dock_did_restart
)

now_ms() {
  local t="${EPOCHREALTIME}"
  local s="${t%.*}" us="${t#*.}"
  printf '%s\n' "$(( s * 1000 + 10#${us:0:3} ))"
}

sleep_ms() {
  local ms="${1:-0}"
  local sec=$(( ms / 1000 ))
  local rem=$(( ms % 1000 ))
  sleep "${sec}.$(printf '%03d' "$rem")"
}

debug_enabled() {
  [[ "$DEBUG" == "1" || -f "$DEBUG_FLAG_FILE" ]]
}

debug_log() {
  debug_enabled || return 0
  local msg="${1//\\t/$'\t'}"
  printf '%s\t%s\n' "$(now_ms)" "$msg" >> "$LOG_FILE"
}

maybe_rotate_log() {
  [[ -f "$LOG_FILE" ]] || return 0
  local size=0
  size="$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if (( size > LOG_ROTATE_BYTES )); then
    : > "$LOG_FILE"
  fi
}

read_pidfile() {
  local pid=""
  [[ -f "$PIDFILE" ]] && { read -r pid < "$PIDFILE" 2>/dev/null || true; }
  printf '%s' "$pid"
}

pid_owned_by_agent() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  local comm cmd
  comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  case "$comm" in
    bash|sh|zsh|yabai-agent.sh) ;;
    *) return 1 ;;
  esac

  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$cmd" == *"yabai-agent.sh run"* ]]
}

agent_pid_alive() {
  local pid="${1:-0}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$(read_pidfile)" == "$pid" ]] || return 1
  pid_owned_by_agent "$pid"
}

is_suppressed() {
  compgen -G "$SUPPRESS_GLOB" >/dev/null 2>&1
}

throttle() {
  local key="$1" ms="$2"
  local tfile="$STATE_DIR/throttle_$key"
  local now last=0
  now="$(now_ms)"
  [[ -f "$tfile" ]] && { read -r last < "$tfile" 2>/dev/null || true; }
  if (( now - last < ms )); then
    return 1
  fi
  printf '%s\n' "$now" > "$tfile"
  return 0
}

acquire_lock() {
  local tries=0 holder=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    tries=$(( tries + 1 ))
    if (( tries >= 10 )); then
      [[ -f "$LOCK_DIR/pid" ]] && { read -r holder < "$LOCK_DIR/pid" 2>/dev/null || holder=0; }
      if [[ "$holder" =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
        return 1
      fi
      rm -f "$LOCK_DIR/pid" 2>/dev/null || true
      rmdir "$LOCK_DIR" 2>/dev/null || true
      tries=0
    fi
    sleep 0.02
  done
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  return 0
}

release_lock() {
  rm -f "$LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

acquire_event_lock() {
  local max_ms="${1:-20}"
  local waited=0
  while ! mkdir "$EVENT_LOCK_DIR" 2>/dev/null; do
    sleep 0.01
    waited=$(( waited + 10 ))
    (( waited >= max_ms )) && return 1
  done
  printf '%s\n' "$$" > "$EVENT_LOCK_DIR/pid"
  return 0
}

release_event_lock() {
  rm -f "$EVENT_LOCK_DIR/pid" 2>/dev/null || true
  rmdir "$EVENT_LOCK_DIR" 2>/dev/null || true
}

signal_label() {
  printf 'yabai-agent-%s\n' "$1"
}

shell_quote() {
  local s="${1:-}"
  s="${s//\'/\'\\\'\'}"
  printf "'%s'" "$s"
}

signal_id_expr() {
  case "$1" in
    window_focused|window_destroyed|window_minimized)
      printf '%s\n' '${YABAI_WINDOW_ID:-0}'
      ;;
    # application_terminated has process-level payload (YABAI_PROCESS_ID), not window id.
    application_terminated)
      printf '%s\n' '0'
      ;;
    *)
      printf '%s\n' '0'
      ;;
  esac
}

register_signals() {
  local ev label id_expr action quoted_path
  quoted_path="$(shell_quote "$SELF_PATH")"
  for ev in "${SIGNAL_EVENTS[@]}"; do
    label="$(signal_label "$ev")"
    id_expr="$(signal_id_expr "$ev")"
    action="$quoted_path event '$ev' $id_expr"
    "$YABAI" -m signal --remove "$label" >/dev/null 2>&1 || true
    "$YABAI" -m signal --add "event=$ev" "label=$label" "action=$action" >/dev/null 2>&1 || true
  done
}

unregister_signals() {
  local ev label
  for ev in "${SIGNAL_EVENTS[@]}"; do
    label="$(signal_label "$ev")"
    "$YABAI" -m signal --remove "$label" >/dev/null 2>&1 || true
  done
}

# borders is an Accessibility app that tracks focus/spaces via macOS APIs itself.
# We only need to ensure it is running — not force-reload it on focus or space events.
borders_ensure() {
  "$HOME/.config/yabai/bordersctl.sh" ensure >/dev/null 2>&1 || true
}

# Hard reload (kill + restart) only when the borders process itself is expected
# to have died or become stale — i.e. after dock_did_restart.
borders_reload() {
  "$HOME/.config/yabai/bordersctl.sh" reload >/dev/null 2>&1 || true
}

remember_focus_from_json() {
  local win_json="$1"
  local out
  out="$("$JQ" -r '
    if (.role=="AXWindow" and .layer=="normal" and .visible==1 and .minimized==0
        and .subrole!="AXSystemDialog" and .subrole!="AXUnknown")
    then "\(.id) \(.display) \(.space)"
    else empty end
  ' <<< "$win_json" 2>/dev/null || true)"
  [[ -z "$out" ]] && return 0

  local id disp sp
  read -r id disp sp <<< "$out"
  [[ -z "${id:-}" || -z "${disp:-}" || -z "${sp:-}" ]] && return 0
  printf '%s\n' "$id" > "$STATE_DIR/last_${disp}_${sp}"
}

# Single IPC call: returns TSV "good_count focused_count focused_id target_id"
# good_count    = eligible windows on current space
# focused_count = how many of them currently have focus
# focused_id    = id of focused window (or 0)
# target        = candidate window id to focus (or empty)
query_space_focus_state() {
  local trigger_id="${1:-0}"
  local disp="${2:-1}"
  local sp="${3:-1}"

  local wins hist last_id=""
  wins="$("$YABAI" -m query --windows --space 2>/dev/null || echo '[]')"
  hist="$STATE_DIR/last_${disp}_${sp}"
  [[ -f "$hist" ]] && { read -r last_id < "$hist" 2>/dev/null || true; }

  "$JQ" -r \
    --argjson skip "$trigger_id" \
    --arg lid "${last_id:-0}" '
    def good: .visible==1 and .minimized==0 and .layer=="normal"
              and .role=="AXWindow"
              and .subrole!="AXSystemDialog" and .subrole!="AXUnknown";
    (map(select(good))) as $good |
    (map(select(good and (.id != $skip)))) as $cands |
    ($good | map(select(."has-focus"==true or .focused==1)) | first // null) as $foc |
    {
      good:    ($good | length),
      focused: ($good | map(select(."has-focus"==true or .focused==1)) | length),
      foc_id:  (if $foc then ($foc.id | tostring) else "0" end),
      target:  (
        if ($cands|length)==0 then ""
        elif ($lid != "0") and ([$cands[]|select(.id==($lid|tonumber))]|length)>0 then $lid
        else ($cands | sort_by(.id) | last | .id | tostring)
        end
      )
    } |
    "\(.good)\t\(.focused)\t\(.foc_id)\t\(.target)"
  ' <<< "$wins" 2>/dev/null || printf '0\t0\t0\t'
}

sa_mark_file() {
  local owner_pid="${1:-0}"
  printf '%s/sa_attempted_%s\n' "$STATE_DIR" "$owner_pid"
}

maybe_load_sa_once() {
  local owner_pid="${1:-$(read_pidfile)}"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 0

  local mark
  mark="$(sa_mark_file "$owner_pid")"
  [[ -f "$mark" ]] && { debug_log "sa_state\tskip_once=1\towner=$owner_pid"; return 0; }

  : > "$mark"
  sudo "$YABAI" --load-sa >/dev/null 2>&1 || true
  debug_log "sa_state\tload_attempted\towner=$owner_pid"
}

# Known trade-off: we spawn one short-lived sleep job per burst event.
# Jobs are guarded by owner liveness and never call refocus when owner is dead.
#
# Trade-off: gen update is a non-atomic read-modify-write across short-lived
# event handlers. Losing an intermediate increment is acceptable because only
# the last generation should fire after debounce.
schedule_refocus() {
  local trigger_id="${1:-0}"
  local owner_pid="${2:-$(read_pidfile)}"
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 0

  local gen=0
  [[ -f "$DEBOUNCE_GEN_FILE" ]] && { read -r gen < "$DEBOUNCE_GEN_FILE" 2>/dev/null || true; }
  gen=$(( gen + 1 ))
  printf '%s\n' "$gen" > "$DEBOUNCE_GEN_FILE"
  printf '%s\n' "$trigger_id" > "$DEBOUNCE_WANT"
  debug_log "debounce\tscheduled\tgen=$gen\ttrigger=$trigger_id\towner=$owner_pid"

  {
    local my_gen="$gen"
    sleep_ms "$REFOCUS_DEBOUNCE_MS"
    agent_pid_alive "$owner_pid" || exit 0

    local cur_gen=0
    [[ -f "$DEBOUNCE_GEN_FILE" ]] && { read -r cur_gen < "$DEBOUNCE_GEN_FILE" 2>/dev/null || true; }
    [[ "$cur_gen" -eq "$my_gen" ]] || exit 0

    local tid=0
    [[ -f "$DEBOUNCE_WANT" ]] && { read -r tid < "$DEBOUNCE_WANT" 2>/dev/null || true; }
    agent_pid_alive "$owner_pid" || exit 0
    if [[ -f "$TOPOLOGY_DIRTY_FILE" ]]; then
      prune_last_focus_state
      rm -f "$TOPOLOGY_DIRTY_FILE" 2>/dev/null || true
    fi
    debug_log "debounce\tfire\tgen=$my_gen\ttrigger=$tid\towner=$owner_pid"
    refocus_now "$tid"
  } &
  disown "$!" 2>/dev/null || true
}

refocus_now() {
  is_suppressed && { debug_log "refocus\tskipped\tsuppress=1"; return 0; }

  local trigger_id="${1:-0}"
  # One IPC call for space state + fullscreen check
  local space_json parsed is_fs rest disp sp
  space_json="$("$YABAI" -m query --spaces --space 2>/dev/null || echo '{}')"
  parsed="$("$JQ" -r \
    '"\(."is-native-fullscreen" // false)\t\(.display // 1)\t\(.index // 1)"' \
    <<< "$space_json" 2>/dev/null || printf 'false\t1\t1')"

  is_fs="${parsed%%$'\t'*}"
  rest="${parsed#*$'\t'}"
  disp="${rest%%$'\t'*}"
  sp="${rest##*$'\t'}"

  [[ "$is_fs" == "true" ]] && { debug_log "refocus\tskipped\tfullscreen=1"; return 0; }

  # One IPC call for all window state: good_count, focused_count, foc_id, target
  local state good_count focused_count foc_id target
  state="$(query_space_focus_state "$trigger_id" "$disp" "$sp")"
  good_count="${state%%$'\t'*}"; state="${state#*$'\t'}"
  focused_count="${state%%$'\t'*}"; state="${state#*$'\t'}"
  foc_id="${state%%$'\t'*}"
  target="${state##*$'\t'}"

  [[ "$good_count" =~ ^[0-9]+$ ]] || good_count=0
  [[ "$focused_count" =~ ^[0-9]+$ ]] || focused_count=0

  # If something already has focus, nothing to do.
  if (( focused_count > 0 )); then
    debug_log "refocus\tskipped\talready_focused=1\tfoc_id=$foc_id"
    return 0
  fi

  # No eligible windows on this space.
  if (( good_count == 0 )); then
    debug_log "refocus\ttarget=none\tdisp=$disp\tspace=$sp"
    borders_ensure
    return 0
  fi

  # No candidate (can happen if trigger is the only good window).
  if [[ -z "$target" ]]; then
    debug_log "refocus\ttarget=empty\tdisp=$disp\tspace=$sp"
    borders_ensure
    return 0
  fi

  debug_log "refocus\ttarget=$target\tdisp=$disp\tspace=$sp"
  local delay
  for delay in 0 30 80; do
    (( delay > 0 )) && sleep_ms "$delay"
    "$YABAI" -m window --focus "$target" >/dev/null 2>&1 && break
  done
  # borders redraws itself on the resulting window_focused signal.
}

handle_event_name() {
  local ev="${1:-}"
  local wid="${2:-0}"
  local owner_pid="${3:-$(read_pidfile)}"
  local suppress=0
  is_suppressed && suppress=1
  debug_log "event\t$ev\twindow=$wid\tsuppress=$suppress\towner=$owner_pid"

  case "$ev" in
    window_focused)
      # Track history; borders redraws itself, so no bordersctl call needed.
      if throttle "focus_track" "$FOCUS_TRACK_THROTTLE_MS"; then
        local win
        win="$("$YABAI" -m query --windows --window 2>/dev/null || true)"
        [[ -n "$win" ]] && remember_focus_from_json "$win"
      fi
      ;;
    window_destroyed|window_minimized|application_terminated)
      # Always attempt refocus: macOS may leave focus on non-window UI after close/minimize.
      schedule_refocus "$wid" "$owner_pid"
      ;;
    space_changed)
      # Focus should move on space switch, but check asynchronously in debounce worker.
      schedule_refocus "$wid" "$owner_pid"
      ;;
    space_created|space_destroyed)
      # Topology changes: defer pruning and check focus asynchronously.
      : > "$TOPOLOGY_DIRTY_FILE"
      schedule_refocus "$wid" "$owner_pid"
      ;;
    display_added|display_removed|display_moved|display_resized|display_changed)
      : > "$TOPOLOGY_DIRTY_FILE"
      schedule_refocus "$wid" "$owner_pid"
      ;;
    dock_did_restart)
      # Dock restart kills all accessibility-based apps including borders.
      # This is the only legitimate case for a hard borders reload.
      maybe_load_sa_once "$owner_pid"
      borders_reload
      ;;
  esac
}

cleanup_runtime_state() {
  # Debounce workers may still be sleeping after stop; they re-check owner PID and exit
  # without refocus once owner is gone. Missing files here are expected and safe.
  rm -f "$DEBOUNCE_GEN_FILE" "$DEBOUNCE_WANT"
  rm -f "$TOPOLOGY_DIRTY_FILE"
}

cleanup_owned_pidfile() {
  [[ "$(read_pidfile)" == "$$" ]] && rm -f "$PIDFILE"
}

cleanup_sa_marks() {
  local pid="${1:-0}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  rm -f "$(sa_mark_file "$pid")" 2>/dev/null || true
}

on_run_exit() {
  unregister_signals
  cleanup_runtime_state
  cleanup_sa_marks "$AGENT_PID"
  cleanup_owned_pidfile
  rm -f "$DEBUG_FLAG_FILE" 2>/dev/null || true
}

prune_last_focus_state() {
  # Keep only last_<display>_<space> keys that still exist.
  local spaces_json keys keyset key file
  spaces_json="$("$YABAI" -m query --spaces 2>/dev/null || echo '[]')"
  keys="$("$JQ" -r '.[] | "\(.display)_\(.index)"' <<< "$spaces_json" 2>/dev/null || true)"
  keyset=$'\n'"$keys"$'\n'

  while IFS= read -r file; do
    key="${file##*/last_}"
    [[ "$keyset" == *$'\n'"$key"$'\n'* ]] || rm -f "$file"
  done < <(find "$STATE_DIR" -maxdepth 1 -type f -name 'last_*_*' 2>/dev/null)
}

invalidate_stale_state_startup() {
  # Called once per process start; throttle files should survive signal callbacks.
  rm -f "$DEBOUNCE_GEN_FILE" "$DEBOUNCE_WANT"
  rm -f "$TOPOLOGY_DIRTY_FILE"
  prune_last_focus_state
}

run() {
  AGENT_PID=$$
  printf '%s\n' "$AGENT_PID" > "$PIDFILE"
  maybe_rotate_log
  if [[ "$DEBUG" == "1" ]]; then
    : > "$DEBUG_FLAG_FILE"
  else
    rm -f "$DEBUG_FLAG_FILE" 2>/dev/null || true
  fi

  invalidate_stale_state_startup
  unregister_signals
  register_signals
  debug_log "agent\tstarted\tpid=$AGENT_PID"

  trap 'exit 0' TERM INT
  trap 'on_run_exit' EXIT

  while true; do
    sleep 3600
  done
}

start() {
  acquire_lock || return 1

  local pid
  pid="$(read_pidfile)"
  if pid_owned_by_agent "$pid"; then
    release_lock
    return 0
  fi

  rm -f "$PIDFILE"
  DEBUG="$DEBUG" "$0" run >/dev/null 2>&1 &
  disown "$!" 2>/dev/null || true

  local tries=0
  while (( tries < 10 )); do
    pid="$(read_pidfile)"
    if pid_owned_by_agent "$pid"; then
      release_lock
      return 0
    fi
    sleep 0.01
    tries=$(( tries + 1 ))
  done

  release_lock
  return 1
}

stop() {
  acquire_lock || return 1

  local pid
  pid="$(read_pidfile)"
  if pid_owned_by_agent "$pid"; then
    kill "$pid" 2>/dev/null || true
    local tries=0
    while (( tries < 50 )); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.01
      tries=$(( tries + 1 ))
    done
  fi

  unregister_signals
  rm -f "$PIDFILE" "$DEBUG_FLAG_FILE"
  cleanup_sa_marks "$pid"
  cleanup_runtime_state
  release_lock
}

event() {
  local ev="${1:-}"
  local wid="${2:-0}"
  [[ -n "$ev" ]] || return 2

  local owner_pid
  owner_pid="$(read_pidfile)"
  agent_pid_alive "$owner_pid" || return 0

  local lock_budget_ms=80
  [[ "$ev" == "window_focused" ]] && lock_budget_ms=20
  if acquire_event_lock "$lock_budget_ms"; then
    trap 'release_event_lock' EXIT
  elif [[ "$ev" == "window_focused" ]]; then
    return 0
  fi

  handle_event_name "$ev" "$wid" "$owner_pid" || true
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  run) run ;;
  event) shift; event "$@" ;;
  *)
    echo "usage: $0 start|stop|run|event <event> [id]" >&2
    exit 2
    ;;
esac
