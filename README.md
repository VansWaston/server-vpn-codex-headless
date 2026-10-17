# 服务器代理与 Codex 无头任务

`mihomoctl` 管理服务器本机代理，`codexctl` 运行 SSH 断开后仍能继续的 Codex 任务。支持 Linux x86_64 / ARM64、Bash 4.4+、普通用户和 root，无需 systemd。

## 脚本入口

| 入口 | 用途 | 说明 |
| --- | --- | --- |
| `./install.sh --help` | 安装、升级、查看安装参数 | 下方安装说明 |
| `mihomoctl` | 启停代理、刷新订阅、切换节点 | [Mihomo 命令](mihomo-server/README.md#命令速查) |
| `codexctl` | 登录、运行、恢复和查看任务 | [Codex 命令](codex-headless/README.md#命令速查) |
| `bash scripts/check.sh` | 语法和离线集成测试 | 下方维护说明 |
| `bash scripts/package.sh [输出路径]` | 生成可迁移安装包 | 下方维护说明 |

## 安装

Debian / Ubuntu 依赖：

```bash
sudo apt-get update
sudo apt-get install -y bash ca-certificates curl gzip coreutils screen util-linux git python3 python3-yaml
```

RHEL / Fedora 安装对应系统包，PyYAML 包名为 `python3-pyyaml`。VS Code 会话接管另需 `sqlite3`、`rg`；历史迁移另需 `rsync`。

```bash
git clone git@github.com:VansWaston/server-vpn-codex-headless.git
cd server-vpn-codex-headless
./install.sh --check
./install.sh --shell-init
export PATH="$HOME/.local/bin:$PATH"
```

以上使用已安装的 Codex CLI；若已有 Node.js / npm，可改用 `./install.sh --install-codex --shell-init`。需要固定 CLI 版本时增加 `--codex-version VERSION`。

安装后按 [Mihomo 初始化步骤](mihomo-server/README.md#首次使用) 配置代理，再按 [Codex 示例](codex-headless/README.md#运行示例) 登录并运行任务。安装器保留已有核心；首次下载按架构选择固定的 Mihomo v1.19.30 并验证 SHA-256。

## 安装目录与参数

| 参数 | 默认位置或行为 |
| --- | --- |
| `--prefix DIR` | 代码：`${XDG_DATA_HOME:-$HOME/.local/share}/server-vpn-codex-headless` |
| `--bin-dir DIR` | 命令：`$HOME/.local/bin` |
| `--state-dir DIR` | 私有数据父目录：`${XDG_STATE_HOME:-$HOME/.local/state}/server-vpn-codex-headless` |
| `--mihomo-root DIR` | 代理数据：状态父目录下的 `mihomo-server`；也可接入已有目录 |
| `--codex-bin FILE` | Codex CLI：从 PATH 查找 |
| `--codex-home DIR` | 登录和历史：`$CODEX_HOME` 或 `$HOME/.codex` |
| `--port PORT` / `--screen-name NAME` | 代理端口 `7890` / Screen 名 `mihomo-server` |
| `--workspace-root DIR` | 可选工作目录范围，默认不限制位置 |
| `--skip-core` | 离线安装；自行提供 `代理数据目录/bin/mihomo` |
| `--shell-init` | 接入当前用户 `.bashrc`、`.profile`，保留备份 |
| `--check` | 仅检查依赖和路径 |

安装器不启动或重启代理，也不迁移 Codex 历史。已有服务可用 `--mihomo-root` 指向原目录，再按 [接入条件](mihomo-server/README.md#接入已有代理) 验证；端口和 Screen 名须与现有服务一致。

## 运行配置

机器配置保存在安装目录 `toolkit.env`，权限为 0600；环境变量优先于文件默认值。代码、代理数据、任务数据和登录目录分别存放，默认运行数据不会写入源码目录。

| 变量 | 用途 |
| --- | --- |
| `MIHOMO_ROOT` / `MIHOMO_PORT` / `MIHOMO_SCREEN_NAME` | 代理运行目录、端口和 Screen 名；端口须与活动配置一致 |
| `CODEX_HEADLESS_BIN` / `CODEX_DEFAULT_HOME` | CLI 路径和默认登录/会话目录；显式 `CODEX_HOME` 优先 |
| `CODEX_HEADLESS_DATA_DIR` | 任务、日志和结果目录 |
| `CODEX_HEADLESS_WORKSPACE_ROOT` | 工作目录允许范围 |
| `CODEX_HEADLESS_DATA_MOUNT` / `CODEX_HEADLESS_REQUIRE_MOUNT` | 状态父目录；默认不要求独立挂载，设为 1 时才检查 |
| `CODEX_VSCODE_EXTENSIONS` | 可选 IDE 接管使用的扩展目录，默认 `~/.vscode-server/extensions` |
| `CODEX_MIGRATED_HOME` | 可选历史迁移目标 |

登录自启由安装目录 `shell-init.sh` 调用代理恢复脚本；这是首次交互登录恢复。无人登录时启动，可把恢复脚本接入服务器现有启动命令。手动 source `shell-init.sh` 也会加载当前 shell 的代理变量并尝试恢复代理。

## 升级、验证与打包

```bash
git pull --ff-only
./install.sh
# 自定义安装目录：./install.sh --prefix /path/to/installed-tools
bash scripts/check.sh
MIHOMO_TEST_BIN=/path/to/mihomo bash scripts/check.sh
bash scripts/package.sh
```

升级沿用已有安装配置，保留运行数据，不自动重启服务。未设置 `MIHOMO_TEST_BIN` 时跳过真实核心测试，其余测试使用离线 CLI；设置后增加隔离端口的真实核心验证。

发布包位于 `dist/server-vpn-codex-headless.tar.gz`，解压后可运行 `install.sh`，无需 Git 元数据。打包仅包含 `packaging-files.txt` 白名单中的源码、文档和测试。凭据及运行数据处理见 [SECURITY.md](SECURITY.md)。
