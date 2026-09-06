#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SOURCE='/root/.codex'
DATA_MOUNT='/root/autodl-tmp'
TARGET="$DATA_MOUNT/codex-home"
MIGRATION_MARKER="$TARGET/.migration-complete"
COMPAT_MARKER="$TARGET/.compat-symlink-complete"
MIGRATION_LOCK="$DATA_MOUNT/.codex-home-migration.lock"
SOURCE_DB="$SOURCE/state_5.sqlite"
TARGET_DB="$TARGET/state_5.sqlite"

candidate_raw=''
candidate_list=''
db_path_list=''
copy_list=''
merge_tmp=''
link_tmp=''
marker_tmp=''
rollback_dir=''
source_moved=0
link_installed=0
marker_installed=0
success=0

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

safe_remove_temp() {
  local path=${1:-}
  [[ -n "$path" ]] || return 0
  case "$path" in
    /tmp/codex-finalize.*|"$TARGET"/.rollout-merge.*|"$TARGET"/sessions/*/.rollout-merge.*|"$TARGET"/archived_sessions/*/.rollout-merge.*|"$TARGET"/.compat-marker.*|/root/.codex.link.*)
      rm -f -- "$path" 2>/dev/null || true
      ;;
  esac
}

cleanup() {
  local rc=$?
  local restored=0
  trap - HUP INT TERM
  set +e

  safe_remove_temp "$merge_tmp"
  safe_remove_temp "$link_tmp"
  safe_remove_temp "$marker_tmp"
  safe_remove_temp "$candidate_raw"
  safe_remove_temp "$candidate_list"
  safe_remove_temp "$db_path_list"
  safe_remove_temp "$copy_list"

  if (( rc != 0 && success == 0 )); then
    if [[ -n "$rollback_dir" && -d "$rollback_dir" && ! -L "$rollback_dir" ]] \
      && [[ -L "$SOURCE" ]] \
      && [[ "$(readlink -- "$SOURCE" 2>/dev/null)" == "$TARGET" ]]; then
      if ! unlink -- "$SOURCE" 2>/dev/null; then
        printf '严重错误：无法移除未完成的兼容入口；原目录仍保留在回滚位置。\n' >&2
      fi
    fi

    if [[ -n "$rollback_dir" ]] \
      && [[ ! -e "$SOURCE" && ! -L "$SOURCE" ]] \
      && [[ -d "$rollback_dir" && ! -L "$rollback_dir" ]]; then
      if mv -T -- "$rollback_dir" "$SOURCE" 2>/dev/null; then
        source_moved=0
        restored=1
      else
        printf '严重错误：自动恢复原 Codex 目录失败；原目录仍保留在回滚位置。\n' >&2
      fi
    elif [[ -d "$SOURCE" && ! -L "$SOURCE" ]] \
      && { [[ -z "$rollback_dir" ]] || [[ ! -e "$rollback_dir" && ! -L "$rollback_dir" ]]; }; then
      restored=1
    fi

    if (( marker_installed == 1 )) && [[ -f "$COMPAT_MARKER" && ! -L "$COMPAT_MARKER" ]]; then
      if (( restored == 1 )); then
        rm -f -- "$COMPAT_MARKER" 2>/dev/null \
          || printf '警告：无法移除未完成的兼容标记。\n' >&2
      else
        printf '警告：为保留回滚位置记录，兼容标记未被删除。\n' >&2
      fi
    fi
  fi

  trap - EXIT
  exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必需命令：$1"
}

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
    || die "检测到 $count 个 Codex 进程；请完全退出 VS Code Codex 和所有无头任务后重试"
}

validate_data_mount_and_marker() {
  local mount_target mount_source mount_type mount_options
  local target_mode target_uid target_gid marker_mode marker_uid marker_gid

  read -r mount_target mount_source mount_type mount_options < <(
    findmnt -rn -T "$DATA_MOUNT" -o TARGET,SOURCE,FSTYPE,OPTIONS
  ) || die '无法确认数据盘挂载'
  [[ "$mount_target" == "$DATA_MOUNT" ]] || die '数据盘挂载点异常'
  [[ "$mount_type" != 'overlay' && ",$mount_options," == *,rw,* ]] \
    || die '数据盘不是独立可写挂载'

  [[ -d "$TARGET" && ! -L "$TARGET" ]] || die '数据盘 Codex 目录不是实体目录'
  read -r target_mode target_uid target_gid < <(stat -c '%a %u %g' "$TARGET" 2>/dev/null) \
    || die '无法读取数据盘 Codex 目录权限'
  [[ "$target_mode" == '700' && "$target_uid" == '0' && "$target_gid" == '0' ]] \
    || die '数据盘 Codex 目录必须由 root 拥有且权限为 0700'

  [[ -f "$MIGRATION_MARKER" && ! -L "$MIGRATION_MARKER" ]] \
    || die '缺少有效的迁移完成标记'
  read -r marker_mode marker_uid marker_gid < <(stat -c '%a %u %g' "$MIGRATION_MARKER" 2>/dev/null) \
    || die '无法读取迁移完成标记权限'
  [[ "$marker_mode" == '600' && "$marker_uid" == '0' && "$marker_gid" == '0' ]] \
    || die '迁移完成标记权限或所有者异常'
  grep -Fxq 'source=/root/.codex' "$MIGRATION_MARKER" 2>/dev/null \
    || die '迁移完成标记内容异常'
  grep -Eq '^completed_at=.+$' "$MIGRATION_MARKER" 2>/dev/null \
    || die '迁移完成标记不完整'
}

sqlite_integrity_check() {
  local db=$1 result
  [[ -f "$db" && ! -L "$db" ]] || die '会话数据库缺失或类型异常'
  result=$(sqlite3 -readonly "$db" 'PRAGMA integrity_check;' 2>/dev/null) \
    || die '会话数据库完整性检查无法执行'
  [[ "$result" == 'ok' ]] || die '会话数据库完整性检查失败'
}

validate_completed_symlink() {
  local source_real target_real source_inode target_inode
  local marker_mode marker_uid marker_gid recorded_target recorded_rollback recorded_status

  [[ -L "$SOURCE" ]] || die '兼容入口不是符号链接'
  [[ "$(readlink -- "$SOURCE" 2>/dev/null)" == "$TARGET" ]] \
    || die '兼容入口指向了非预期目录'
  source_real=$(realpath -e -- "$SOURCE" 2>/dev/null) || die '无法解析兼容入口'
  target_real=$(realpath -e -- "$TARGET" 2>/dev/null) || die '无法解析数据盘目录'
  [[ "$source_real" == "$target_real" ]] || die '兼容入口与数据盘目录真实路径不同'
  source_inode=$(stat -Lc '%d:%i' "$SOURCE" 2>/dev/null) || die '无法读取兼容入口 inode'
  target_inode=$(stat -Lc '%d:%i' "$TARGET" 2>/dev/null) || die '无法读取数据盘目录 inode'
  [[ "$source_inode" == "$target_inode" ]] || die '兼容入口与数据盘目录 inode 不同'

  [[ -f "$COMPAT_MARKER" && ! -L "$COMPAT_MARKER" ]] || die '缺少兼容完成标记'
  read -r marker_mode marker_uid marker_gid < <(stat -c '%a %u %g' "$COMPAT_MARKER" 2>/dev/null) \
    || die '无法读取兼容完成标记权限'
  [[ "$marker_mode" == '600' && "$marker_uid" == '0' && "$marker_gid" == '0' ]] \
    || die '兼容完成标记权限或所有者异常'
  recorded_target=$(sed -n 's/^target=//p' "$COMPAT_MARKER" 2>/dev/null)
  recorded_rollback=$(sed -n 's/^rollback=//p' "$COMPAT_MARKER" 2>/dev/null)
  recorded_status=$(sed -n 's/^status=//p' "$COMPAT_MARKER" 2>/dev/null)
  [[ "$recorded_target" == "$TARGET" && "$recorded_status" == 'complete' ]] \
    || die '兼容完成标记内容异常'
  [[ "$recorded_rollback" =~ ^/root/\.codex\.rollback\.[0-9]{8}T[0-9]{6}Z\.[0-9]+$ ]] \
    || die '兼容完成标记中的回滚位置异常'
  [[ -d "$recorded_rollback" && ! -L "$recorded_rollback" ]] \
    || die '回滚目录缺失或类型异常'
}

validate_db_relationship() {
  local old_only old_newer bad_paths db_check_output
  local -a db_checks=()
  local sql

  sqlite_integrity_check "$SOURCE_DB"
  sqlite_integrity_check "$TARGET_DB"

  sql="ATTACH DATABASE 'file:$SOURCE_DB?mode=ro' AS old;
SELECT count(*) FROM old.threads o LEFT JOIN main.threads n USING(id) WHERE n.id IS NULL;
SELECT count(*) FROM old.threads o JOIN main.threads n USING(id)
 WHERE max(COALESCE(o.updated_at_ms,0),COALESCE(o.updated_at,0)*1000)
         > max(COALESCE(n.updated_at_ms,0),COALESCE(n.updated_at,0)*1000)
    OR max(COALESCE(o.recency_at_ms,0),COALESCE(o.recency_at,0)*1000)
         > max(COALESCE(n.recency_at_ms,0),COALESCE(n.recency_at,0)*1000)
    OR COALESCE(o.tokens_used,0) > COALESCE(n.tokens_used,0);
SELECT count(*) FROM (
  SELECT rollout_path FROM main.threads
  UNION ALL
  SELECT rollout_path FROM old.threads
) WHERE rollout_path IS NULL OR rollout_path=''
   OR instr(rollout_path,char(9))>0 OR instr(rollout_path,char(10))>0
   OR instr(rollout_path,char(11))>0 OR instr(rollout_path,char(12))>0
   OR instr(rollout_path,char(13))>0;"

  db_check_output=$(sqlite3 -readonly "$TARGET_DB" "$sql" 2>/dev/null) \
    || die '无法比较新旧会话索引'
  mapfile -t db_checks <<<"$db_check_output"
  (( ${#db_checks[@]} == 3 )) || die '新旧会话索引比较结果异常'
  old_only=${db_checks[0]}
  old_newer=${db_checks[1]}
  bad_paths=${db_checks[2]}
  [[ "$old_only" =~ ^[0-9]+$ && "$old_newer" =~ ^[0-9]+$ && "$bad_paths" =~ ^[0-9]+$ ]] \
    || die '新旧会话索引比较结果不是整数'
  (( old_only == 0 )) || die '旧数据库含有数据盘数据库缺失的线程；拒绝自动归并'
  (( old_newer == 0 )) || die '旧数据库含有更新的线程元数据；拒绝自动归并'
  (( bad_paths == 0 )) || die '数据库含有空路径或控制字符路径；拒绝自动归并'
}

relative_rollout_path() {
  local path=$1 rel
  case "$path" in
    "$SOURCE"/sessions/*.jsonl|"$SOURCE"/archived_sessions/*.jsonl)
      rel=${path#"$SOURCE"/}
      ;;
    "$TARGET"/sessions/*.jsonl|"$TARGET"/archived_sessions/*.jsonl)
      rel=${path#"$TARGET"/}
      ;;
    *)
      return 1
      ;;
  esac
  case "/$rel/" in
    */../*|*/./*) return 1 ;;
  esac
  printf '%s\n' "$rel"
}

collect_candidates() {
  local path rel tree section
  declare -gA referenced_rollouts=()

  candidate_raw=$(mktemp /tmp/codex-finalize.candidates.XXXXXX) \
    || die '无法创建私有候选清单'
  candidate_list=$(mktemp /tmp/codex-finalize.sorted.XXXXXX) \
    || die '无法创建私有排序清单'
  db_path_list=$(mktemp /tmp/codex-finalize.dbpaths.XXXXXX) \
    || die '无法创建私有数据库路径清单'
  copy_list=$(mktemp /tmp/codex-finalize.copy.XXXXXX) \
    || die '无法创建私有归并清单'
  chmod 0600 "$candidate_raw" "$candidate_list" "$db_path_list" "$copy_list" \
    || die '无法保护私有清单权限'

  if ! sqlite3 -readonly "$TARGET_DB" \
    "ATTACH DATABASE 'file:$SOURCE_DB?mode=ro' AS old;
     SELECT rollout_path FROM main.threads
     UNION
     SELECT rollout_path FROM old.threads;" \
    >"$db_path_list" 2>/dev/null; then
    die '无法读取数据库引用的会话路径'
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || die '数据库引用了空会话路径'
    rel=$(relative_rollout_path "$path") \
      || die '数据库引用了允许目录以外的会话路径'
    referenced_rollouts["$rel"]=1
    printf '%s\n' "$rel" >>"$candidate_raw"
  done <"$db_path_list"

  for tree in "$SOURCE" "$TARGET"; do
    for section in sessions archived_sessions; do
      [[ ! -e "$tree/$section" && ! -L "$tree/$section" ]] && continue
      [[ -d "$tree/$section" && ! -L "$tree/$section" ]] \
        || die '会话目录类型异常'
      if [[ -n "$(find "$tree/$section" -xdev -type l -print -quit 2>/dev/null)" ]]; then
        die '会话目录中存在符号链接；拒绝自动归并'
      fi
      if [[ -n "$(find "$tree/$section" -xdev \( -name $'*\n*' -o -name $'*\r*' \) -print -quit 2>/dev/null)" ]]; then
        die '会话目录中存在控制字符文件名；拒绝自动归并'
      fi
      if ! find "$tree/$section" -xdev -type f -name '*.jsonl' \
        -printf "$section/%P\n" >>"$candidate_raw" 2>/dev/null; then
        die '无法扫描会话 JSONL'
      fi
    done
  done

  LC_ALL=C sort -u "$candidate_raw" >"$candidate_list" \
    || die '无法整理会话候选清单'
}

classify_candidates() {
  local rel old new old_size new_size
  local identical=0 data_ahead=0 root_ahead=0 old_only=0 data_only=0

  : >"$copy_list"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    old="$SOURCE/$rel"
    new="$TARGET/$rel"

    if [[ -e "$old" || -L "$old" ]]; then
      [[ -f "$old" && ! -L "$old" ]] || die '旧树会话候选不是普通文件'
    fi
    if [[ -e "$new" || -L "$new" ]]; then
      [[ -f "$new" && ! -L "$new" ]] || die '数据盘会话候选不是普通文件'
    fi

    if [[ -f "$old" && -f "$new" ]]; then
      old_size=$(stat -c %s "$old" 2>/dev/null) || die '无法读取旧树会话大小'
      new_size=$(stat -c %s "$new" 2>/dev/null) || die '无法读取数据盘会话大小'
      if cmp -s "$old" "$new"; then
        identical=$((identical + 1))
      elif (( old_size < new_size )) && cmp -s -n "$old_size" "$old" "$new"; then
        data_ahead=$((data_ahead + 1))
      elif (( new_size < old_size )) && cmp -s -n "$new_size" "$old" "$new"; then
        root_ahead=$((root_ahead + 1))
        printf '%s\n' "$rel" >>"$copy_list"
      else
        die '检测到真正分叉的会话 JSONL；拒绝自动归并'
      fi
    elif [[ -f "$old" ]]; then
      old_only=$((old_only + 1))
      printf '%s\n' "$rel" >>"$copy_list"
    elif [[ -f "$new" ]]; then
      data_only=$((data_only + 1))
    elif [[ ${referenced_rollouts[$rel]+present} ]]; then
      die '数据库引用的会话 JSONL 在两侧均缺失'
    fi
  done <"$candidate_list"

  chmod 0600 "$copy_list" || die '无法保护归并清单权限'
  printf '会话审计：相同=%d，数据盘较新=%d，旧树较新=%d，旧树独有=%d，数据盘独有=%d。\n' \
    "$identical" "$data_ahead" "$root_ahead" "$old_only" "$data_only"
}

atomic_copy_rollout() {
  local source_file=$1 target_file=$2 target_dir source_attrs temp_attrs
  target_dir=${target_file%/*}

  if [[ ! -d "$target_dir" ]]; then
    install -d -o 0 -g 0 -m 0700 -- "$target_dir" 2>/dev/null \
      || die '无法创建数据盘会话目录'
  fi
  [[ -d "$target_dir" && ! -L "$target_dir" ]] || die '数据盘会话父目录类型异常'
  [[ -f "$source_file" && ! -L "$source_file" ]] || die '待归并会话源文件类型异常'
  if [[ -e "$target_file" || -L "$target_file" ]]; then
    [[ -f "$target_file" && ! -L "$target_file" ]] || die '待归并会话目标文件类型异常'
  fi

  merge_tmp=$(mktemp "$target_dir/.rollout-merge.XXXXXX") \
    || die '无法在数据盘创建会话临时文件'
  if ! cp --reflink=auto --preserve=all -- "$source_file" "$merge_tmp" 2>/dev/null; then
    die '无法复制待归并会话'
  fi
  chown --reference="$source_file" "$merge_tmp" 2>/dev/null \
    || die '无法保留会话文件所有者'
  chmod --reference="$source_file" "$merge_tmp" 2>/dev/null \
    || die '无法保留会话文件权限'
  touch --reference="$source_file" "$merge_tmp" 2>/dev/null \
    || die '无法保留会话文件时间戳'
  cmp -s "$source_file" "$merge_tmp" || die '会话临时副本内容校验失败'
  source_attrs=$(stat -c '%u:%g:%a' "$source_file" 2>/dev/null) \
    || die '无法读取会话源文件属性'
  temp_attrs=$(stat -c '%u:%g:%a' "$merge_tmp" 2>/dev/null) \
    || die '无法读取会话临时文件属性'
  [[ "$source_attrs" == "$temp_attrs" ]] || die '会话临时副本权限或所有者校验失败'
  sync -f "$merge_tmp" 2>/dev/null || die '无法同步会话临时副本'
  mv -Tf -- "$merge_tmp" "$target_file" 2>/dev/null \
    || die '无法原子安装归并后的会话文件'
  merge_tmp=''
  sync -f "$target_dir" 2>/dev/null || die '无法同步会话目录'
  cmp -s "$source_file" "$target_file" || die '归并后的会话内容校验失败'
}

merge_planned_rollouts() {
  local rel old new old_size new_size

  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    old="$SOURCE/$rel"
    new="$TARGET/$rel"
    [[ -f "$old" && ! -L "$old" ]] || die '待归并的旧树会话已发生变化'

    if [[ -f "$new" && ! -L "$new" ]]; then
      old_size=$(stat -c %s "$old" 2>/dev/null) || die '无法复检旧树会话大小'
      new_size=$(stat -c %s "$new" 2>/dev/null) || die '无法复检数据盘会话大小'
      if cmp -s "$old" "$new"; then
        continue
      elif (( old_size < new_size )) && cmp -s -n "$old_size" "$old" "$new"; then
        continue
      elif ! (( new_size < old_size )) || ! cmp -s -n "$new_size" "$old" "$new"; then
        die '待归并会话在复制前发生分叉'
      fi
    elif [[ -e "$new" || -L "$new" ]]; then
      die '待归并会话目标类型已发生变化'
    fi

    atomic_copy_rollout "$old" "$new"
  done <"$copy_list"
}

verify_merged_rollouts() {
  local rel old new old_size new_size
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    old="$SOURCE/$rel"
    new="$TARGET/$rel"
    if [[ -f "$old" && ! -L "$old" ]]; then
      [[ -f "$new" && ! -L "$new" ]] || die '归并后数据盘仍缺少旧树会话'
      old_size=$(stat -c %s "$old" 2>/dev/null) || die '无法验证旧树会话大小'
      new_size=$(stat -c %s "$new" 2>/dev/null) || die '无法验证数据盘会话大小'
      if cmp -s "$old" "$new"; then
        continue
      fi
      (( old_size < new_size )) && cmp -s -n "$old_size" "$old" "$new" \
        || die '归并后会话内容校验失败'
    elif [[ -f "$new" && ! -L "$new" ]]; then
      continue
    elif [[ ${referenced_rollouts[$rel]+present} ]]; then
      die '归并后数据库引用的会话仍然缺失'
    fi
  done <"$candidate_list"
}

install_compat_marker() {
  [[ ! -e "$COMPAT_MARKER" && ! -L "$COMPAT_MARKER" ]] \
    || die '兼容完成标记已存在但兼容入口尚未安装'
  marker_tmp=$(mktemp "$TARGET/.compat-marker.XXXXXX") \
    || die '无法创建兼容标记临时文件'
  printf 'status=complete\ntarget=%s\nrollback=%s\ncompleted_at=%s\n' \
    "$TARGET" "$rollback_dir" "$(date -Is)" >"$marker_tmp"
  chmod 0600 "$marker_tmp" || die '无法设置兼容标记权限'
  chown 0:0 "$marker_tmp" || die '无法设置兼容标记所有者'
  sync -f "$marker_tmp" 2>/dev/null || die '无法同步兼容标记'
  mv -T -- "$marker_tmp" "$COMPAT_MARKER" 2>/dev/null \
    || die '无法原子安装兼容标记'
  marker_tmp=''
  marker_installed=1
  sync -f "$TARGET" 2>/dev/null || die '无法同步数据盘 Codex 目录'
}

install_compat_symlink() {
  rollback_dir="/root/.codex.rollback.$(date -u +%Y%m%dT%H%M%SZ).$$"
  link_tmp="/root/.codex.link.$$"
  [[ ! -e "$rollback_dir" && ! -L "$rollback_dir" ]] || die '回滚位置已存在；拒绝覆盖'
  [[ ! -e "$link_tmp" && ! -L "$link_tmp" ]] || die '兼容入口临时位置已存在；拒绝覆盖'

  ln -s -- "$TARGET" "$link_tmp" 2>/dev/null || die '无法创建兼容入口临时链接'
  install_compat_marker
  require_no_codex_processes
  source_moved=1
  mv -T -- "$SOURCE" "$rollback_dir" 2>/dev/null \
    || die '无法原子保留原 Codex 目录'
  link_installed=1
  mv -T -- "$link_tmp" "$SOURCE" 2>/dev/null || die '无法原子安装兼容入口'
  link_tmp=''
  link_installed=1
  sync -f /root 2>/dev/null || die '无法同步兼容入口'
}

main() {
  local source_inode target_inode lock_inode fd_inode

  [[ "$(id -u)" -eq 0 ]] || die '必须以 root 运行'
  for command_name in flock findmnt sqlite3 realpath stat cmp find sort mktemp install cp chmod chown touch sync mv ln readlink sed grep date rm unlink id; do
    require_command "$command_name"
  done

  [[ ! -L "$MIGRATION_LOCK" ]] || die '迁移锁不能是符号链接'
  [[ ! -e "$MIGRATION_LOCK" || -f "$MIGRATION_LOCK" ]] || die '迁移锁类型异常'
  exec 8>>"$MIGRATION_LOCK"
  lock_inode=$(stat -Lc '%d:%i' "$MIGRATION_LOCK" 2>/dev/null) || die '无法读取迁移锁 inode'
  fd_inode=$(stat -Lc '%d:%i' "/proc/$$/fd/8" 2>/dev/null) || die '无法读取迁移锁文件描述符'
  [[ "$lock_inode" == "$fd_inode" && ! -L "$MIGRATION_LOCK" ]] \
    || die '迁移锁在打开过程中发生变化'
  chmod 0600 "$MIGRATION_LOCK" || die '无法保护迁移锁权限'
  flock -n 8 || die '有无头 Codex 任务正在运行，或另一迁移正在进行'

  validate_data_mount_and_marker
  require_no_codex_processes

  if [[ -L "$SOURCE" ]]; then
    sqlite_integrity_check "$TARGET_DB"
    validate_completed_symlink
    success=1
    printf '兼容入口已经正确安装；验证通过，无需再次归并。\n'
    return 0
  fi

  [[ -d "$SOURCE" ]] || die '原 Codex 状态目录缺失或类型异常'
  source_inode=$(stat -Lc '%d:%i' "$SOURCE" 2>/dev/null) || die '无法读取原 Codex 目录 inode'
  target_inode=$(stat -Lc '%d:%i' "$TARGET" 2>/dev/null) || die '无法读取数据盘 Codex 目录 inode'
  [[ "$source_inode" != "$target_inode" ]] || die '两个 Codex 目录已指向同一 inode，但兼容入口不是符号链接'

  validate_db_relationship
  collect_candidates
  classify_candidates
  merge_planned_rollouts
  verify_merged_rollouts

  require_no_codex_processes
  validate_db_relationship
  verify_merged_rollouts
  install_compat_symlink
  validate_completed_symlink

  success=1
  printf 'Codex 状态最终化完成；旧绝对路径与数据盘 CODEX_HOME 已统一。\n'
  printf '原实体目录已保留为回滚副本；其位置记录在权限为 0600 的兼容标记中。\n'
}

main "$@"
