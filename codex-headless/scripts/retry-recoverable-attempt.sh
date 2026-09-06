#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

BASE_DIR='/workspace/codex-headless'
CODEXCTL="$BASE_DIR/bin/codexctl"
RESUME_WATCHER="$BASE_DIR/scripts/resume-when-ide-ready.sh"
DATA_ROOT='/root/autodl-tmp/codex-headless'
RUN_DIR="$DATA_ROOT/run"
POLL_SECONDS=10
RETRY_DELAY_SECONDS=300

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

write_value() {
  local value="$1" target="$2" tmp
  tmp="${target}.tmp.$$"
  printf '%s\n' "$value" >"$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$target"
}

timestamp() {
  date -Is
}

latest_attempt() {
  find "$attempts_dir" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended -regex '.*/[0-9]{4}' -printf '%f\n' \
    | LC_ALL=C sort | tail -n 1
}

recoverable_failure() {
  local attempt_dir="$1"
  python3 - "$attempt_dir/events.jsonl" "$attempt_dir/progress.log" <<'PY'
import json
import sys
from collections import deque
from pathlib import Path

events_path = Path(sys.argv[1])
progress_path = Path(sys.argv[2])
messages = []

try:
    with events_path.open("r", encoding="utf-8", errors="replace") as handle:
        tail = deque(handle, maxlen=40)
    for line in tail:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") in {"error", "turn.failed"}:
            messages.append(str(event.get("message") or event.get("error") or ""))
except OSError:
    pass

try:
    with progress_path.open("r", encoding="utf-8", errors="replace") as handle:
        messages.extend(deque(handle, maxlen=80))
except OSError:
    pass

text = "\n".join(messages).lower()
needles = (
    "usage limit",
    "rate limit",
    "stream disconnected",
    "connection reset",
    "connection failed",
    "tls handshake",
    "websocket connection limit",
    "failed to send websocket request",
    "error sending request",
    "unexpected eof",
)
raise SystemExit(0 if any(needle in text for needle in needles) else 1)
PY
}

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die '必须以 root 运行'
[[ $# -ge 3 && $# -le 5 ]] \
  || die '用法：retry-recoverable-attempt.sh NAME PROMPT_FILE BASE_ATTEMPT [MAX_RETRIES] [TIMEOUT_SECONDS]'

name="$1"
prompt_arg="$2"
base_attempt="$3"
max_retries="${4:-2}"
timeout_seconds="${5:-172800}"

[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]] || die 'NAME 无效'
[[ "$base_attempt" =~ ^[0-9]{4}$ ]] || die 'BASE_ATTEMPT 必须是四位数字'
[[ "$max_retries" =~ ^[0-2]$ ]] || die 'MAX_RETRIES 必须是 0 到 2'
[[ "$timeout_seconds" =~ ^[0-9]+$ \
   && "$timeout_seconds" -ge 600 \
   && "$timeout_seconds" -le 259200 ]] \
  || die 'TIMEOUT_SECONDS 必须是 600 到 259200 的整数'
[[ -x "$CODEXCTL" && -x "$RESUME_WATCHER" ]] || die '控制器或恢复器不可执行'

prompt=$(realpath -e -- "$prompt_arg") || die '提示词不存在'
[[ -f "$prompt" && ! -L "$prompt" && -r "$prompt" ]] || die '提示词类型异常'
[[ "$(stat -c '%u' "$prompt")" -eq 0 ]] || die '提示词不属于 root'
prompt_mode=$(stat -c '%a' "$prompt")
(( (8#$prompt_mode & 0077) == 0 )) || die '提示词权限过宽'
prompt_hash=$(sha256sum -- "$prompt" | awk '{print $1}')

job_dir="$DATA_ROOT/jobs/$name"
attempts_dir="$job_dir/attempts"
[[ -d "$attempts_dir" && ! -L "$attempts_dir" ]] || die 'attempts 目录异常'

install -d -m 0700 "$RUN_DIR"
log_file="$RUN_DIR/retry-${name}.log"
state_file="$RUN_DIR/retry-${name}.state"
lock_file="$RUN_DIR/retry-${name}.lock"

for private_file in "$log_file" "$state_file" "$lock_file"; do
  if [[ -e "$private_file" || -L "$private_file" ]]; then
    [[ -f "$private_file" && ! -L "$private_file" \
       && "$(stat -c '%u' "$private_file")" -eq 0 ]] \
      || die '恢复监视状态文件类型或属主异常'
  fi
done

exec 9>>"$lock_file"
chmod 0600 "$lock_file"
flock -n 9 || die "已有同名恢复监视器：$name"
touch "$log_file"
chmod 0600 "$log_file"

deadline=$(( $(date +%s) + timeout_seconds ))
seen_attempt="$base_attempt"
retries=0
write_value "watching base=$base_attempt retries=0 started=$(timestamp)" "$state_file"
printf '%s watching name=%s base=%s prompt_sha256=%s max_retries=%s\n' \
  "$(timestamp)" "$name" "$base_attempt" "$prompt_hash" "$max_retries" >>"$log_file"

while (( $(date +%s) < deadline )); do
  current_attempt=$(latest_attempt)
  if [[ -z "$current_attempt" \
     || $((10#$current_attempt)) -le $((10#$seen_attempt)) ]]; then
    sleep "$POLL_SECONDS"
    continue
  fi

  attempt_dir="$attempts_dir/$current_attempt"
  state_path="$attempt_dir/state"
  [[ -f "$state_path" && ! -L "$state_path" ]] || {
    sleep "$POLL_SECONDS"
    continue
  }
  state=$(head -n 1 "$state_path")
  case "$state" in
    staged|starting|running)
      sleep "$POLL_SECONDS"
      continue
      ;;
    completed)
      write_value "completed attempt=$current_attempt at=$(timestamp)" "$state_file"
      printf '%s attempt=%s completed; retry monitor exiting\n' \
        "$(timestamp)" "$current_attempt" >>"$log_file"
      exit 0
      ;;
    interrupted)
      write_value "stopped attempt=$current_attempt reason=interrupted at=$(timestamp)" "$state_file"
      printf '%s attempt=%s interrupted; not retrying\n' \
        "$(timestamp)" "$current_attempt" >>"$log_file"
      exit 0
      ;;
    failed)
      if ! recoverable_failure "$attempt_dir"; then
        write_value "stopped attempt=$current_attempt reason=non-recoverable at=$(timestamp)" "$state_file"
        printf '%s attempt=%s failed without a recognized transport/usage cause; not retrying\n' \
          "$(timestamp)" "$current_attempt" >>"$log_file"
        exit 0
      fi
      if (( retries >= max_retries )); then
        write_value "exhausted attempt=$current_attempt retries=$retries at=$(timestamp)" "$state_file"
        printf '%s attempt=%s recoverable failure but retry budget exhausted\n' \
          "$(timestamp)" "$current_attempt" >>"$log_file"
        exit 0
      fi
      current_hash=$(sha256sum -- "$prompt" | awk '{print $1}')
      [[ "$current_hash" == "$prompt_hash" ]] || die '等待期间提示词发生变化'
      seen_attempt="$current_attempt"
      retries=$((retries + 1))
      write_value "backoff attempt=$current_attempt retry=$retries at=$(timestamp)" "$state_file"
      printf '%s attempt=%s recoverable failure; retry=%s after %ss\n' \
        "$(timestamp)" "$current_attempt" "$retries" "$RETRY_DELAY_SECONDS" >>"$log_file"
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        sleep $((RETRY_DELAY_SECONDS / 10))
      done
      write_value "resuming after=$current_attempt retry=$retries at=$(timestamp)" "$state_file"
      if "$RESUME_WATCHER" "$name" "$prompt" 86400 >>"$log_file" 2>&1; then
        printf '%s retry=%s resume accepted\n' "$(timestamp)" "$retries" >>"$log_file"
      else
        rc=$?
        write_value "failed reason=resume-exit-$rc retry=$retries at=$(timestamp)" "$state_file"
        printf '%s retry=%s resume watcher failed rc=%s\n' \
          "$(timestamp)" "$retries" "$rc" >>"$log_file"
        exit "$rc"
      fi
      ;;
    *)
      write_value "stopped attempt=$current_attempt reason=unknown-state at=$(timestamp)" "$state_file"
      printf '%s attempt=%s unexpected state=%s; not retrying\n' \
        "$(timestamp)" "$current_attempt" "$state" >>"$log_file"
      exit 0
      ;;
  esac
done

write_value "timed-out last_attempt=$seen_attempt retries=$retries at=$(timestamp)" "$state_file"
printf '%s retry monitor timed out\n' "$(timestamp)" >>"$log_file"
exit 0
