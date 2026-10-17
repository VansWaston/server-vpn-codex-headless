#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SOURCE_ROOT=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  cat <<'EOF'
用法：./install.sh [选项]
  --prefix DIR          工具代码目录（默认 ~/.local/share/server-vpn-codex-headless）
  --bin-dir DIR         命令入口目录（默认 ~/.local/bin）
  --state-dir DIR       私有运行数据（默认 ~/.local/state/server-vpn-codex-headless）
  --mihomo-root DIR     接入已有 Mihomo 运行目录，保留配置、凭据、核心和进程
  --port PORT           本机代理端口（默认 7890；必须与已有配置一致）
  --screen-name NAME    Mihomo Screen 名称（默认 mihomo-server）
  --codex-bin FILE      已安装的 Codex CLI（默认从 PATH 查找）
  --codex-home DIR      Codex 状态目录（默认 CODEX_HOME 或 ~/.codex）
  --workspace-root DIR  可选工作目录范围；默认允许任意现有 Git 工作目录
  --install-codex       用现有 npm 在工具目录内安装 @openai/codex
  --codex-version VER   npm 版本或 dist-tag（默认 latest）
  --skip-core           不下载 Mihomo 核心（离线部署或稍后手动安装）
  --shell-init          在当前用户 .bashrc/.profile 中接入代理及首次登录自启
  --check               仅检查平台、依赖和路径，不写入
  -h, --help            显示帮助

支持 Linux x86_64 / aarch64，Bash >= 4.4，普通用户或 root，无需 systemd。
安装和升级均不会启动、停止或重启代理，不会迁移 Codex 登录及历史。
EOF
}
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
prefix=${XDG_DATA_HOME:-$HOME/.local/share}/server-vpn-codex-headless
bin_dir=$HOME/.local/bin
state_dir=${XDG_STATE_HOME:-$HOME/.local/state}/server-vpn-codex-headless
data_dir=$state_dir/codex-headless
migrated_home=$state_dir/codex-home
mihomo_root=''
port=7890
screen_name=mihomo-server
codex_bin=${CODEX_HEADLESS_BIN:-$(command -v codex || true)}
codex_home=${CODEX_HOME:-$HOME/.codex}
workspace_root=''
install_codex=0
codex_version=latest
skip_core=0
shell_init=0
check_only=0
# Load the existing installation before parsing explicit overrides. This makes
# an ordinary rerun an upgrade using the same runtime directories and CLI.
task_args=("$@")
for ((task_i=0; task_i<${#task_args[@]}; task_i++)); do
  if [[ ${task_args[task_i]} == --prefix && -n ${task_args[task_i+1]:-} ]]; then
    prefix=${task_args[task_i+1]}
    task_i=$((task_i+1))
  fi
done
if [[ -f "$prefix/toolkit.env" ]]; then
  [[ ! -L "$prefix/toolkit.env" && "$(stat -c '%u' "$prefix/toolkit.env")" == "$(id -u)" ]] \
    || die '已有配置类型或所有者异常'
  source "$prefix/toolkit.env"
  bin_dir=${TOOLKIT_BIN_DIR:-$bin_dir}
  state_dir=${CODEX_HEADLESS_DATA_MOUNT:-$state_dir}
  data_dir=${CODEX_HEADLESS_DATA_DIR:-$state_dir/codex-headless}
  migrated_home=${CODEX_MIGRATED_HOME:-$state_dir/codex-home}
  mihomo_root=${MIHOMO_ROOT:-$mihomo_root}
  port=${MIHOMO_PORT:-$port}
  screen_name=${MIHOMO_SCREEN_NAME:-$screen_name}
  codex_bin=${CODEX_HEADLESS_BIN:-$codex_bin}
  codex_home=${CODEX_DEFAULT_HOME:-$codex_home}
  workspace_root=${CODEX_HEADLESS_WORKSPACE_ROOT:-$workspace_root}
fi
while (( $# )); do
  case $1 in
    --prefix|--bin-dir|--state-dir|--mihomo-root|--port|--screen-name|--codex-bin|--codex-home|--workspace-root|--codex-version)
      [[ $# -ge 2 && -n $2 ]] || die "$1 缺少参数"
      case $1 in
        --prefix) prefix=$2 ;; --bin-dir) bin_dir=$2 ;;
        --state-dir) state_dir=$2; data_dir=$2/codex-headless; migrated_home=$2/codex-home ;;
        --mihomo-root) mihomo_root=$2 ;; --port) port=$2 ;; --screen-name) screen_name=$2 ;;
        --codex-bin) codex_bin=$2 ;; --codex-home) codex_home=$2 ;;
        --workspace-root) workspace_root=$2 ;; --codex-version) codex_version=$2 ;;
      esac
      shift 2 ;;
    --install-codex) install_codex=1; shift ;;
    --skip-core) skip_core=1; shift ;;
    --shell-init) shell_init=1; shift ;;
    --check) check_only=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done
[[ $(uname -s) == Linux ]] || die '当前仅支持 Linux'
case $(uname -m) in x86_64|amd64|aarch64|arm64) ;; *) die '仅提供 x86_64 / aarch64 发布包' ;; esac
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
  || die '需要 Bash 4.4 或更新版本'
missing=()
for task_cmd in curl gzip sha256sum screen flock realpath stat install awk sed git python3 find sort mktemp; do
  command -v "$task_cmd" >/dev/null 2>&1 || missing+=("$task_cmd")
done
if (( ${#missing[@]} )); then
  printf '缺少依赖：%s\n' "${missing[*]}" >&2
  printf 'Debian/Ubuntu: sudo apt-get install bash ca-certificates curl gzip coreutils screen util-linux git python3 python3-yaml\n' >&2
  printf 'RHEL/Fedora: sudo dnf install bash ca-certificates curl gzip coreutils screen util-linux git python3 python3-pyyaml\n' >&2
  exit 1
fi
python3 -c 'import yaml' 2>/dev/null || die '需要 PyYAML（python3-yaml 或 python3-pyyaml）'
[[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || die '端口无效'
port=$((10#$port))
[[ "$screen_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$ ]] || die 'Screen 名称无效'
[[ "$codex_version" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || die 'Codex 版本无效'
for task_var in prefix bin_dir state_dir data_dir migrated_home codex_home mihomo_root workspace_root; do
  task_value=${!task_var}
  [[ -n "$task_value" ]] || continue
  [[ "$task_value" != *$'\n'* && "$task_value" != *$'\r'* ]] || die '路径包含换行符'
  printf -v "$task_var" '%s' "$(realpath -m -s -- "$task_value")"
done
[[ "$prefix" != "$SOURCE_ROOT" && "$prefix" != / && "$state_dir" != / && "$bin_dir" != / ]] \
  || die '安装目录必须与源码目录不同，且不能是根目录'
[[ -n "$mihomo_root" ]] || mihomo_root=$state_dir/mihomo-server
mihomo_root=$(realpath -m -s -- "$mihomo_root")
[[ "$mihomo_root" != / ]] || die 'Mihomo 运行目录不能是根目录'
if [[ -n "$workspace_root" ]]; then
  workspace_root=$(realpath -e -- "$workspace_root") || die '工作范围不存在'
  [[ -d "$workspace_root" ]] || die '工作范围不是目录'
fi
if (( install_codex )); then
  command -v npm >/dev/null 2>&1 || die '--install-codex 需要已安装 Node.js 和 npm'
  codex_bin=$prefix/codex-cli/node_modules/.bin/codex
else
  [[ -n "$codex_bin" && -x "$codex_bin" ]] || die '找不到 Codex CLI；使用 --codex-bin 或 --install-codex'
  codex_bin=$(realpath -m -s -- "$codex_bin")
fi
if [[ -f "$mihomo_root/home/config.yaml" ]]; then
  python3 "$SOURCE_ROOT/mihomo-server/scripts/check-config.py" "$mihomo_root/home/config.yaml" "$port" \
    || die '已有活动配置与所选端口或监听边界不一致；未修改配置'
fi

# Do not overwrite an unrelated command or installation.
for task_cmd in mihomoctl codexctl; do
  if [[ -e "$bin_dir/$task_cmd" || -L "$bin_dir/$task_cmd" ]]; then
    [[ -f "$bin_dir/$task_cmd" && ! -L "$bin_dir/$task_cmd" ]] \
      && head -n 3 "$bin_dir/$task_cmd" | grep -Fq '# server-vpn-codex-headless managed command' \
      || die "命令入口已存在且不属于本工具：$bin_dir/$task_cmd"
  fi
done
if [[ -e "$prefix" ]]; then
  [[ -d "$prefix" && ! -L "$prefix" && -f "$prefix/.server-toolkit-install" ]] \
    || die "安装目录已存在且不属于本工具：$prefix"
fi
printf 'platform=%s %s\nprefix=%s\nbin_dir=%s\nstate_dir=%s\nmihomo_root=%s\nproxy=127.0.0.1:%s\ncodex=%s\n' \
  "$(uname -s)" "$(uname -m)" "$prefix" "$bin_dir" "$state_dir" "$mihomo_root" "$port" "$codex_bin"
(( check_only == 0 )) || exit 0

install -d -m 0700 "$prefix" "$state_dir" "$mihomo_root" "$codex_home" "$bin_dir"
exec 9>"$prefix/.install.lock"
flock -w 15 9 || die '已有安装正在进行'
printf 'server-vpn-codex-headless\n' > "$prefix/.server-toolkit-install"
# Only copy shipped code; never copy the source tree's private runtime files.
while IFS= read -r task_file; do
  task_relative=${task_file#"$SOURCE_ROOT/"}
  install -d -m 0700 "$(dirname -- "$prefix/$task_relative")"
  install -m 0700 "$task_file" "$prefix/$task_relative.next"
  mv -f -- "$prefix/$task_relative.next" "$prefix/$task_relative"
done < <(find "$SOURCE_ROOT/lib" "$SOURCE_ROOT/codex-headless/bin" \
  "$SOURCE_ROOT/codex-headless/libexec" "$SOURCE_ROOT/codex-headless/scripts" \
  "$SOURCE_ROOT/mihomo-server/scripts" -maxdepth 1 -type f ! -name '*.pyc' | LC_ALL=C sort)
for task_file in README.md SECURITY.md mihomo-server/README.md \
    mihomo-server/VERSION mihomo-server/releases.sha256 mihomo-server/config/config.template.yaml \
    mihomo-server/config/provider.fixture.yaml codex-headless/README.md; do
  install -d -m 0700 "$(dirname -- "$prefix/$task_file")"
  install -m 0600 "$SOURCE_ROOT/$task_file" "$prefix/$task_file.next"
  mv -f -- "$prefix/$task_file.next" "$prefix/$task_file"
done
# These manuals have been merged into the three component READMEs.
rm -f -- "$prefix/mihomo-server/README.server-vpn.md" "$prefix/codex-headless/OPERATIONS.md"
if (( install_codex )); then
  npm install --prefix "$prefix/codex-cli" --no-audit --no-fund "@openai/codex@$codex_version"
fi
write_default() {
  printf 'if [[ ! ${%s+x} ]]; then %s=%q; fi\n' "$1" "$1" "$2"
}
config=$prefix/toolkit.env
if [[ -f "$config" ]]; then
  cp -p -- "$config" "$config.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
fi
{
  printf '# Machine-local configuration. Environment variables override these defaults.\n'
  write_default TOOLKIT_BIN_DIR "$bin_dir"
  write_default MIHOMO_ROOT "$mihomo_root"
  write_default MIHOMO_PORT "$port"
  write_default MIHOMO_SCREEN_NAME "$screen_name"
  write_default CODEX_HEADLESS_DATA_DIR "$data_dir"
  write_default CODEX_HEADLESS_DATA_MOUNT "$state_dir"
  write_default CODEX_DEFAULT_HOME "$codex_home"
  write_default CODEX_MIGRATED_HOME "$migrated_home"
  write_default CODEX_HEADLESS_BIN "$codex_bin"
  write_default CODEX_HEADLESS_WORKSPACE_ROOT "$workspace_root"
  write_default CODEX_HEADLESS_REQUIRE_MOUNT "${CODEX_HEADLESS_REQUIRE_MOUNT:-0}"
  write_default CODEX_VSCODE_EXTENSIONS "${CODEX_VSCODE_EXTENSIONS:-$HOME/.vscode-server/extensions}"
} > "$config.next"
chmod 0600 "$config.next"
mv -f -- "$config.next" "$config"
if (( skip_core == 0 )); then
  SERVER_TOOLKIT_CONFIG="$config" MIHOMO_ROOT="$mihomo_root" "$prefix/mihomo-server/scripts/install-core.sh" 9>&-
fi
for task_cmd in mihomoctl codexctl; do
  case $task_cmd in mihomoctl) task_target=$prefix/mihomo-server/scripts/mihomoctl ;; codexctl) task_target=$prefix/codex-headless/bin/codexctl ;; esac
  {
    printf '#!/usr/bin/env bash\n# server-vpn-codex-headless managed command\n'
    printf 'export SERVER_TOOLKIT_CONFIG=${SERVER_TOOLKIT_CONFIG:-%q}\n' "$config"
    printf 'exec %q "$@"\n' "$task_target"
  } > "$bin_dir/$task_cmd.next"
  chmod 0700 "$bin_dir/$task_cmd.next"
  mv -f -- "$bin_dir/$task_cmd.next" "$bin_dir/$task_cmd"
done
{
  printf '# Generated Bash integration for server-vpn-codex-headless.\n'
  printf 'export PATH=%q:"$PATH"\n' "$bin_dir"
  printf 'export SERVER_TOOLKIT_CONFIG=${SERVER_TOOLKIT_CONFIG:-%q}\n' "$config"
  printf 'source %q\ntoolkit_set_proxy\n' "$prefix/lib/toolkit.sh"
  printf 'case $- in *i*) %q || true ;; esac\n' "$prefix/mihomo-server/scripts/ensure-running.sh"
} > "$prefix/shell-init.sh"
chmod 0600 "$prefix/shell-init.sh"
if (( shell_init )); then
  for profile in "$HOME/.bashrc" "$HOME/.profile"; do
    [[ ! -L "$profile" ]] || die "shell profile 是符号链接，请手动接入：$profile"
    if [[ -f "$profile" ]]; then
      cp -p -- "$profile" "$profile.bak.$(date -u +%Y%m%dT%H%M%SZ).$$"
      sed '/^# BEGIN server-vpn-codex-headless$/,/^# END server-vpn-codex-headless$/d' "$profile" > "$profile.toolkit-next"
    else
      : > "$profile.toolkit-next"
    fi
    {
      printf '\n# BEGIN server-vpn-codex-headless\n'
      printf 'if [ -n "${BASH_VERSION:-}" ]; then\n  . %q\nfi\n' "$prefix/shell-init.sh"
      printf '# END server-vpn-codex-headless\n'
    } >> "$profile.toolkit-next"
    chmod --reference="$profile" "$profile.toolkit-next" 2>/dev/null || chmod 0600 "$profile.toolkit-next"
    mv -f -- "$profile.toolkit-next" "$profile"
  done
fi
printf '\n安装完成。代理进程及现有配置已保留。\n配置文件：%s\n' "$config"
printf '当前 shell 可执行：source %q\n' "$prefix/shell-init.sh"
printf '新部署：mihomoctl set-url && mihomoctl update && mihomoctl start\n'
printf '登录及检查：codexctl login --device-auth；codexctl doctor\n'
