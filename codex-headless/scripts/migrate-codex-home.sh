#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SOURCE='/root/.codex'
DATA_MOUNT='/root/autodl-tmp'
TARGET="$DATA_MOUNT/codex-home"
STAGE="$DATA_MOUNT/codex-home.stage"
MARKER='.migration-complete'
MIGRATION_LOCK="$DATA_MOUNT/.codex-home-migration.lock"
CODEX_LINK='/root/.local/bin/codex'
CODEX_LINK_TMP="$CODEX_LINK.migration.$$"
stage_created=0
diff_file=''

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

cleanup() {
  local rc=$?
  set +e
  [[ -z "$diff_file" ]] || rm -f -- "$diff_file"
  rm -f -- "$CODEX_LINK_TMP"
  if (( rc != 0 && stage_created == 1 )) \
    && [[ "$STAGE" == '/root/autodl-tmp/codex-home.stage' ]] \
    && [[ -d "$STAGE" && ! -e "$TARGET" ]]; then
    printf '正在清理本次失败产生的暂存副本。\n' >&2
    rm -rf --one-file-system -- "$STAGE"
  fi
  trap - EXIT
  exit "$rc"
}

trap cleanup EXIT

count_codex_processes() {
  local proc executable count=0
  for proc in /proc/[0-9]*; do
    executable=$(readlink -e -- "$proc/exe" 2>/dev/null || true)
    if [[ "${executable##*/}" == 'codex' ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

require_no_codex_processes() {
  local count
  count=$(count_codex_processes)
  (( count == 0 )) \
    || die "检测到 $count 个 Codex 进程；请先完全退出 Codex、VS Code Codex 和 Screen 任务"
}

[[ "$(id -u)" -eq 0 ]] || die "必须以 root 运行"
command -v rsync >/dev/null 2>&1 || die "缺少 rsync"
command -v flock >/dev/null 2>&1 || die "缺少 flock"
[[ -d "$SOURCE" ]] || die "源 CODEX_HOME 不存在"
[[ -L "$CODEX_LINK" ]] || die "Codex CLI 安装链接不存在：$CODEX_LINK"
codex_link_target=$(readlink -- "$CODEX_LINK") || die "无法读取 Codex CLI 安装链接"
[[ "$codex_link_target" == "$SOURCE/"* ]] \
  || die "Codex CLI 安装链接不在源 CODEX_HOME 中；拒绝猜测迁移路径"
codex_link_relative=${codex_link_target#"$SOURCE/"}

read -r mount_target mount_source mount_type mount_options < <(
  findmnt -rn -T "$DATA_MOUNT" -o TARGET,SOURCE,FSTYPE,OPTIONS
) || die "无法确认数据盘挂载"
[[ "$mount_target" == "$DATA_MOUNT" ]] || die "数据盘挂载点异常"
[[ "$mount_type" != "overlay" && ",$mount_options," == *,rw,* ]] \
  || die "数据盘不是独立可写挂载"

exec 8>"$MIGRATION_LOCK"
flock -n 8 || die "有无头 Codex 任务正在运行，或另一迁移正在进行"
[[ ! -e "$TARGET" && ! -L "$TARGET" ]] \
  || die "目标已存在（包括悬空符号链接）；拒绝覆盖：$TARGET"
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] \
  || die "暂存目录已存在（包括悬空符号链接）；请先人工检查：$STAGE"
require_no_codex_processes

source_bytes=$(du -sb -- "$SOURCE" | awk '{print $1}')
available_bytes=$(df -B1 --output=avail "$DATA_MOUNT" | awk 'NR == 2 {print $1}')
[[ "$source_bytes" =~ ^[0-9]+$ ]] || die "无法读取源目录大小"
[[ "$available_bytes" =~ ^[0-9]+$ ]] || die "无法读取数据盘可用空间"
(( ${#source_bytes} <= 18 && ${#available_bytes} <= 18 )) \
  || die "空间数值超出脚本的安全整数范围"
required_bytes=$((10#$source_bytes + 5368709120))
(( 10#$available_bytes >= required_bytes )) \
  || die "数据盘空间不足；迁移要求源大小之外至少保留 5 GiB"

mkdir -m 0700 -- "$STAGE" || die "无法原子创建迁移暂存目录"
stage_created=1
diff_file=$(mktemp "$DATA_MOUNT/codex-migrate-diff.XXXXXX")

printf '正在复制 Codex 状态；不会输出会话内容或文件名。\n'
rsync -aHAX --numeric-ids --one-file-system "$SOURCE/" "$STAGE/"
[[ -x "$STAGE/$codex_link_relative" ]] \
  || die "迁移副本中缺少独立 Codex CLI"
ln -s -- "$TARGET/$codex_link_relative" "$CODEX_LINK_TMP"

source_count=$(find "$SOURCE" -xdev -type f -printf '.' | wc -c)
target_count=$(find "$STAGE" -xdev -type f -printf '.' | wc -c)
source_file_bytes=$(find "$SOURCE" -xdev -type f -printf '%s\n' \
  | LC_ALL=C awk '{sum += $1} END {printf "%.0f\n", sum}')
target_file_bytes=$(find "$STAGE" -xdev -type f -printf '%s\n' \
  | LC_ALL=C awk '{sum += $1} END {printf "%.0f\n", sum}')
[[ "$source_count" =~ ^[0-9]+$ && "$target_count" =~ ^[0-9]+$ ]] \
  || die "文件数量校验结果不是整数"
[[ "$source_file_bytes" =~ ^[0-9]+$ && "$target_file_bytes" =~ ^[0-9]+$ ]] \
  || die "文件字节数校验结果不是整数"
[[ "$source_count" == "$target_count" ]] || die "文件数量校验失败"
[[ "$source_file_bytes" == "$target_file_bytes" ]] || die "文件字节数校验失败"

rsync -aHAXnc --numeric-ids --one-file-system --delete --itemize-changes \
  "$SOURCE/" "$STAGE/" >"$diff_file"
[[ ! -s "$diff_file" ]] || die "rsync 一致性复检发现差异；请保持 Codex 完全停止后重试"

require_no_codex_processes
sync -f "$STAGE"
printf 'source=%s\ncompleted_at=%s\n' "$SOURCE" "$(date -Is)" >"$STAGE/$MARKER"
chmod 0600 "$STAGE/$MARKER"
sync -f "$STAGE"
mv -T -- "$STAGE" "$TARGET"
stage_created=0
chmod 0700 "$TARGET"
mv -Tf -- "$CODEX_LINK_TMP" "$CODEX_LINK"
sync -f "$DATA_MOUNT"

printf '迁移副本已完成：%s\n' "$TARGET"
printf '原目录仍保留用于回滚：%s\n' "$SOURCE"
printf 'Codex CLI 链接已切换到数据盘副本。\n'
printf '现在不要重连 VS Code：旧会话索引仍可能引用原目录的绝对路径。\n'
printf '下一步请保持所有 Codex 进程退出并运行：\n'
printf '  /workspace/codex-headless/scripts/finalize-codex-home.sh\n'
printf '最终化成功后，再打开新登录 shell并运行 codexctl doctor。\n'
