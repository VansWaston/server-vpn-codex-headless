#!/usr/bin/env bash
set -uo pipefail

BASE_DIR='/workspace/mihomo-server'
CTL="$BASE_DIR/scripts/mihomoctl"
RUN_DIR="$BASE_DIR/run"
LOG_DIR="$BASE_DIR/logs"
LOCK_FILE="$RUN_DIR/login-autostart.lock"
LOG_FILE="$LOG_DIR/login-autostart.log"

umask 077
install -d -m 0700 "$RUN_DIR" "$LOG_DIR"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0
fi

if "$CTL" status >/dev/null 2>&1; then
  exit 0
fi

if {
  printf '[%s] Login detected; starting Mihomo.\n' "$(date -Is)"
  "$CTL" start
} >>"$LOG_FILE" 2>&1; then
  exit 0
else
  rc=$?
fi

printf '[%s] Mihomo login autostart failed with exit code %s.\n' "$(date -Is)" "$rc" >>"$LOG_FILE"
printf 'Mihomo 自动启动失败；请查看 %s\n' "$LOG_FILE" >&2
exit "$rc"
