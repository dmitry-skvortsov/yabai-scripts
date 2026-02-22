#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

BORDERS=${BORDERS:-/opt/homebrew/bin/borders}
CONF="$HOME/.config/yabai/borders.conf"
SUPPRESS_GLOB="/tmp/yabai_suppress_*"
STATE_DIR=${STATE_DIR:-/tmp/yabai_agent}
mkdir -p "$STATE_DIR"

LOG="/tmp/yabai_borders.log"
PIDFILE="$STATE_DIR/borders.pid"

WIDTH=5.0
ACTIVE=0xffde3163
INACTIVE=0xffa6d189
BLACKLIST="Reverso"

[[ -f "$CONF" ]] && . "$CONF"

# Без форка date — требует bash 5.0+ (EPOCHREALTIME)
now_ms() {
  local t="${EPOCHREALTIME}"
  local s="${t%.*}" us="${t#*.}"
  printf '%s\n' "$(( s * 1000 + 10#${us:0:3} ))"
}

throttle() {
  local ms="$1" tfile="$STATE_DIR/borders_last"
  local now last=0
  now="$(now_ms)"
  # read -r builtin — без subshell
  [[ -f "$tfile" ]] && { read -r last < "$tfile" 2>/dev/null || true; }
  if (( now - last < ms )); then
    return 1
  fi
  printf '%s\n' "$now" > "$tfile"
  return 0
}

is_suppressed() {
  compgen -G "$SUPPRESS_GLOB" >/dev/null 2>&1
}

read_cached_pid() {
  local pid=""
  [[ -f "$PIDFILE" ]] && { read -r pid < "$PIDFILE" 2>/dev/null || true; }
  printf '%s' "$pid"
}

cache_pid() {
  printf '%s\n' "$1" > "$PIDFILE"
}

clear_cached_pid() {
  rm -f "$PIDFILE"
}

pid_is_borders() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1

  local comm
  comm="$(ps -p "$pid" -o comm= 2>/dev/null || true)"
  [[ "$comm" == "borders" ]]
}

refresh_pid_cache_from_system() {
  local pid=""
  pid="$(pgrep -x borders 2>/dev/null | head -n 1 || true)"
  if pid_is_borders "$pid"; then
    cache_pid "$pid"
    return 0
  fi
  clear_cached_pid
  return 1
}

start_borders() {
  nohup "$BORDERS" \
    blacklist="$BLACKLIST" \
    active_color="$ACTIVE" \
    inactive_color="$INACTIVE" \
    width="$WIDTH" >> "$LOG" 2>&1 &
  cache_pid "$!"
  disown "$!" 2>/dev/null || true
}

ensure() {
  local pid
  pid="$(read_cached_pid)"
  if pid_is_borders "$pid"; then
    return 0
  fi
  refresh_pid_cache_from_system && return 0
  start_borders
}

reload() {
  throttle 250 || return 0
  local pid
  pid="$(read_cached_pid)"

  if pid_is_borders "$pid"; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3; do
      sleep 0.03
      pid_is_borders "$pid" || break
    done
  else
    refresh_pid_cache_from_system || true
    pid="$(read_cached_pid)"
    if pid_is_borders "$pid"; then
      kill "$pid" >/dev/null 2>&1 || true
      for _ in 1 2 3; do
        sleep 0.03
        pid_is_borders "$pid" || break
      done
    else
      pkill -x borders >/dev/null 2>&1 || true
    fi
  fi

  clear_cached_pid
  start_borders
}

maybe() {
  is_suppressed && return 0
  throttle 250 || return 0
  ensure
}

case "${1:-}" in
  ensure) ensure ;;
  reload) reload ;;
  maybe)  maybe  ;;
  *) echo "usage: $0 ensure|reload|maybe" >&2; exit 2 ;;
esac
