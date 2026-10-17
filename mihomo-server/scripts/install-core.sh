#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/../../lib/toolkit.sh"

# Preserve an existing core, including one that is currently running.
if [[ -e "$MIHOMO_ROOT/bin/mihomo" ]]; then
  [[ -x "$MIHOMO_ROOT/bin/mihomo" ]] || { printf '已有核心不可执行。\n' >&2; exit 1; }
  printf '保留已有 Mihomo 核心：%s\n' "$MIHOMO_ROOT/bin/mihomo"
  exit 0
fi
[[ $(uname -s) == Linux ]] || { printf '仅支持 Linux。\n' >&2; exit 1; }
case $(uname -m) in
  x86_64|amd64) arch=amd64-compatible ;;
  aarch64|arm64) arch=arm64 ;;
  *) printf '未提供此架构的固定版本：%s\n' "$(uname -m)" >&2; exit 1 ;;
esac
asset="mihomo-linux-$arch-v1.19.30.gz"
expected=$(awk -v name="$asset" '$2 == name {print $1}' "$SCRIPT_DIR/../releases.sha256")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { printf '缺少发布包校验值。\n' >&2; exit 1; }
install -d -m 0700 "$MIHOMO_ROOT/bin"
work=$(mktemp -d "$MIHOMO_ROOT/bin/.download.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
curl --disable --fail --location --proto '=https' --proto-redir '=https' \
  --connect-timeout 15 --max-time 300 --retry 2 --silent --show-error \
  "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.30/$asset" -o "$work/$asset"
printf '%s  %s\n' "$expected" "$work/$asset" | sha256sum --check --status
gzip -dc -- "$work/$asset" > "$work/mihomo"
chmod 0700 "$work/mihomo"
"$work/mihomo" -v
# A second installation must never replace an intervening core.
ln -- "$work/mihomo" "$MIHOMO_ROOT/bin/mihomo"
printf 'Mihomo 核心已通过 SHA-256 校验并安装。\n'
