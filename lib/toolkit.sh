#!/usr/bin/env bash
# Shared configuration for installed tools and source-tree execution.
# Configuration files are Bash files owned by the current user.

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  printf '需要 Bash 4.4 或更新版本。\n' >&2
  return 1
fi

SERVER_TOOLKIT_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TOOLKIT_UID=$(id -u)
TOOLKIT_GID=$(id -g)
toolkit_config=${SERVER_TOOLKIT_CONFIG:-$SERVER_TOOLKIT_ROOT/toolkit.env}
if [[ -e "$toolkit_config" ]]; then
  if [[ ! -f "$toolkit_config" || -L "$toolkit_config" \
        || "$(stat -c '%u' "$toolkit_config")" != "$TOOLKIT_UID" ]]; then
    printf '配置文件类型或所有者异常：%s\n' "$toolkit_config" >&2
    return 1
  fi
  # shellcheck source=/dev/null
  source "$toolkit_config"
elif [[ -n ${SERVER_TOOLKIT_CONFIG:-} ]]; then
  printf '找不到配置文件：%s\n' "$toolkit_config" >&2
  return 1
fi

: "${MIHOMO_ROOT:=${XDG_STATE_HOME:-$HOME/.local/state}/server-vpn-codex-headless/mihomo-server}"
: "${MIHOMO_PORT:=7890}"
: "${MIHOMO_SCREEN_NAME:=mihomo-server}"
: "${CODEX_HEADLESS_DATA_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/server-vpn-codex-headless/codex-headless}"
: "${CODEX_HEADLESS_DATA_MOUNT:=${CODEX_HEADLESS_DATA_DIR%/*}}"
: "${CODEX_HEADLESS_REQUIRE_MOUNT:=0}"
: "${CODEX_HEADLESS_WORKSPACE_ROOT:=}"
: "${CODEX_DEFAULT_HOME:=${CODEX_HOME:-$HOME/.codex}}"
: "${CODEX_MIGRATED_HOME:=$CODEX_HEADLESS_DATA_MOUNT/codex-home}"
: "${CODEX_VSCODE_EXTENSIONS:=$HOME/.vscode-server/extensions}"
: "${CODEX_HEADLESS_BIN:=$(command -v codex || true)}"

if [[ ! "$MIHOMO_PORT" =~ ^[0-9]{1,5}$ ]] \
    || (( 10#$MIHOMO_PORT < 1 || 10#$MIHOMO_PORT > 65535 )); then
  printf 'MIHOMO_PORT 必须是 1 到 65535 的整数。\n' >&2
  return 1
fi
MIHOMO_PORT=$((10#$MIHOMO_PORT))
[[ "$MIHOMO_SCREEN_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || {
  printf 'MIHOMO_SCREEN_NAME 只能包含字母、数字、下划线和短横线。\n' >&2
  return 1
}
[[ "$CODEX_HEADLESS_REQUIRE_MOUNT" == 0 || "$CODEX_HEADLESS_REQUIRE_MOUNT" == 1 ]] || {
  printf 'CODEX_HEADLESS_REQUIRE_MOUNT 只能是 0 或 1。\n' >&2
  return 1
}

# Normalize paths before recording them in jobs or comparing /proc argv.
for toolkit_var in MIHOMO_ROOT CODEX_HEADLESS_DATA_DIR CODEX_HEADLESS_DATA_MOUNT \
    CODEX_DEFAULT_HOME CODEX_MIGRATED_HOME CODEX_VSCODE_EXTENSIONS; do
  toolkit_value=${!toolkit_var}
  [[ "$toolkit_value" != *$'\n'* && "$toolkit_value" != *$'\r'* ]] || {
    printf '路径不能包含换行符：%s\n' "$toolkit_var" >&2
    return 1
  }
  printf -v "$toolkit_var" '%s' "$(realpath -m -s -- "$toolkit_value")"
done
if [[ -n "$CODEX_HEADLESS_WORKSPACE_ROOT" ]]; then
  CODEX_HEADLESS_WORKSPACE_ROOT=$(realpath -e -- "$CODEX_HEADLESS_WORKSPACE_ROOT") || return 1
  [[ -d "$CODEX_HEADLESS_WORKSPACE_ROOT" ]] || return 1
fi

toolkit_require_storage() {
  [[ -d "$CODEX_HEADLESS_DATA_MOUNT" && -w "$CODEX_HEADLESS_DATA_MOUNT" ]] || {
    printf '状态目录的父目录不可写：%s\n' "$CODEX_HEADLESS_DATA_MOUNT" >&2
    return 1
  }
  [[ "$CODEX_HEADLESS_REQUIRE_MOUNT" == 1 ]] || return 0
  local target source fstype options
  read -r target source fstype options < <(
    findmnt -rn -T "$CODEX_HEADLESS_DATA_MOUNT" -o TARGET,SOURCE,FSTYPE,OPTIONS
  ) || return 1
  [[ "$target" == "$CODEX_HEADLESS_DATA_MOUNT" && "$fstype" != overlay \
     && ",$options," == *,rw,* ]] || {
    printf '要求独立可写挂载：%s\n' "$CODEX_HEADLESS_DATA_MOUNT" >&2
    return 1
  }
}

toolkit_workdir_allowed() {
  local path=$1
  [[ -z "$CODEX_HEADLESS_WORKSPACE_ROOT" \
     || "$CODEX_HEADLESS_WORKSPACE_ROOT" == / \
     || "$path" == "$CODEX_HEADLESS_WORKSPACE_ROOT" \
     || "$path" == "$CODEX_HEADLESS_WORKSPACE_ROOT"/* ]]
}

toolkit_set_proxy() {
  export HTTP_PROXY="http://127.0.0.1:$MIHOMO_PORT"
  export HTTPS_PROXY="$HTTP_PROXY"
  export ALL_PROXY="socks5h://127.0.0.1:$MIHOMO_PORT"
  export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" all_proxy="$ALL_PROXY"
  export NO_PROXY='127.0.0.1,localhost,::1' no_proxy='127.0.0.1,localhost,::1'
}

export MIHOMO_ROOT MIHOMO_PORT MIHOMO_SCREEN_NAME CODEX_HEADLESS_DATA_DIR \
  CODEX_HEADLESS_DATA_MOUNT CODEX_HEADLESS_REQUIRE_MOUNT CODEX_HEADLESS_WORKSPACE_ROOT \
  CODEX_DEFAULT_HOME CODEX_MIGRATED_HOME CODEX_HEADLESS_BIN CODEX_VSCODE_EXTENSIONS
unset toolkit_var toolkit_value toolkit_config
