#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../../lib/toolkit.sh"
BASE_DIR="$SERVER_TOOLKIT_ROOT/codex-headless"
CODEXCTL="$BASE_DIR/bin/codexctl"
DATA_ROOT="$CODEX_HEADLESS_DATA_DIR"
RUN_DIR="$DATA_ROOT/run"
DEFAULT_TIMEOUT_SECONDS=43200
POLL_SECONDS=10

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  resume-when-ide-ready.sh NAME PROMPT_FILE [TIMEOUT_SECONDS]

等待受管 VS Code 会话释放 writer lock；通过全部 ide-ready 检查后，只调用一次
codexctl resume。它不会关闭 VS Code、删除锁或重复创建 attempt。
EOF
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

[[ $# -eq 2 || $# -eq 3 ]] || {
  usage >&2
  exit 2
}

name="$1"
prompt_arg="$2"
timeout_seconds="${3:-$DEFAULT_TIMEOUT_SECONDS}"

[[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,47}$ ]] \
  || die 'NAME 只允许 1-48 个字母、数字、点、下划线或短横线'
[[ "$timeout_seconds" =~ ^[0-9]+$ \
   && "$timeout_seconds" -ge 60 \
   && "$timeout_seconds" -le 86400 ]] \
  || die 'TIMEOUT_SECONDS 必须是 60 到 86400 的整数'
[[ -x "$CODEXCTL" && ! -L "$CODEXCTL" ]] || die 'codexctl 不存在或类型异常'

prompt=$(realpath -e -- "$prompt_arg") || die '提示词文件不存在'
[[ -f "$prompt" && ! -L "$prompt" && -r "$prompt" ]] || die '提示词必须是可读普通文件'
[[ "$(stat -c '%u' "$prompt")" -eq "$TOOLKIT_UID" ]] || die '提示词文件不属于当前用户'
prompt_mode=$(stat -c '%a' "$prompt")
(( (8#$prompt_mode & 0077) == 0 )) || die '提示词文件权限过宽；必须仅属主可读'
prompt_hash=$(sha256sum -- "$prompt" | awk '{print $1}')

install -d -m 0700 "$RUN_DIR"
log_file="$RUN_DIR/deferred-${name}.log"
state_file="$RUN_DIR/deferred-${name}.state"
lock_file="$RUN_DIR/deferred-${name}.lock"
probe_file="$RUN_DIR/.deferred-${name}-probe.$$"

for private_file in "$log_file" "$state_file" "$lock_file"; do
  if [[ -e "$private_file" || -L "$private_file" ]]; then
    [[ -f "$private_file" && ! -L "$private_file" \
       && "$(stat -c '%u' "$private_file")" -eq "$TOOLKIT_UID" ]] \
      || die '延迟恢复状态文件类型或属主异常'
  fi
done

exec 9>>"$lock_file"
chmod 0600 "$lock_file"
flock -n 9 || die "已有同名延迟恢复器：$name"
touch "$log_file"
chmod 0600 "$log_file"

cleanup() {
  rm -f -- "$probe_file"
}

cancelled() {
  local signal="$1"
  write_value "cancelled signal=$signal at=$(timestamp)" "$state_file"
  printf '%s cancelled signal=%s\n' "$(timestamp)" "$signal" >>"$log_file"
  exit 128
}

trap cleanup EXIT
trap 'cancelled HUP' HUP
trap 'cancelled INT' INT
trap 'cancelled TERM' TERM

deadline=$(( $(date +%s) + timeout_seconds ))
write_value "waiting started=$(timestamp) timeout_seconds=$timeout_seconds" "$state_file"
printf '%s waiting name=%s prompt_sha256=%s timeout_seconds=%s\n' \
  "$(timestamp)" "$name" "$prompt_hash" "$timeout_seconds" >>"$log_file"

while (( $(date +%s) < deadline )); do
  if "$CODEXCTL" ide-ready "$name" >"$probe_file" 2>&1; then
    current_hash=$(sha256sum -- "$prompt" | awk '{print $1}')
    [[ "$current_hash" == "$prompt_hash" ]] || {
      write_value "failed reason=prompt-changed at=$(timestamp)" "$state_file"
      printf '%s failed: prompt changed while waiting\n' "$(timestamp)" >>"$log_file"
      exit 3
    }

    write_value "starting at=$(timestamp)" "$state_file"
    printf '%s ide-ready passed; invoking exactly one resume\n' "$(timestamp)" >>"$log_file"
    if "$CODEXCTL" resume "$name" "$prompt" >>"$log_file" 2>&1; then
      write_value "started at=$(timestamp)" "$state_file"
      printf '%s resume accepted\n' "$(timestamp)" >>"$log_file"
      exit 0
    else
      rc=$?
      write_value "failed reason=resume-exit-$rc at=$(timestamp)" "$state_file"
      printf '%s resume failed rc=%s; not retrying\n' "$(timestamp)" "$rc" >>"$log_file"
      exit "$rc"
    fi
  fi

  if rg -Fq -- 'Codex 内置 thread-writer-lock 正在被占用' "$probe_file" \
     || rg -Fq -- '无法取得任务控制锁' "$probe_file"; then
    sleep "$POLL_SECONDS"
    continue
  fi

  write_value "failed reason=ide-ready at=$(timestamp)" "$state_file"
  printf '%s ide-ready failed for a non-retryable reason:\n' "$(timestamp)" >>"$log_file"
  sed -n '1,40p' "$probe_file" >>"$log_file"
  exit 4
done

write_value "timed-out at=$(timestamp)" "$state_file"
printf '%s timed out waiting for IDE writer lock\n' "$(timestamp)" >>"$log_file"
exit 5
