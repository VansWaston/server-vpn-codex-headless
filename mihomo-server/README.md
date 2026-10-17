# Mihomo 服务器代理

管理仅监听 `127.0.0.1` 的 HTTP/SOCKS5 代理，核心通过 GNU Screen 常驻。安装及通用参数见 [根目录说明](../README.md)。

## 命令速查

| 命令 | 作用 |
| --- | --- |
| `mihomoctl set-url` | 在交互终端无回显保存 HTTPS 订阅地址 |
| `mihomoctl update` | 先直连、失败后经本机代理下载并校验订阅；加载更新需再执行 `restart` |
| `mihomoctl start` | 启动服务；健康实例存在时保持运行 |
| `mihomoctl stop` | 停止受管进程并清理 PID、Screen |
| `mihomoctl restart` | 在同一控制锁内停止并重新启动 |
| `mihomoctl status` | 检查进程、监听和 Screen 归属 |
| `mihomoctl health` | 验证 HTTP CONNECT 与 SOCKS5h 均返回 204 |
| `mihomoctl nodes` | 列出订阅中的完整节点名称 |
| `mihomoctl node '节点全名'` | 精确选择节点；运行中自动重启，失败恢复原配置 |
| `mihomoctl node --auto` | 恢复全部订阅节点自动测速选择 |
| `mihomoctl test` | 校验活动配置及本机监听策略 |
| `mihomoctl logs` | 查看最近 80 行运行日志 |
| `mihomoctl version` | 查看核心版本 |

辅助脚本位于安装目录 `mihomo-server/scripts/`：

| 脚本 | 使用方式 |
| --- | --- |
| `ensure-running.sh` | 确认服务运行；用于登录或服务器启动命令 |
| `proxy-env.sh` | 用 `source` 加载当前 shell 的代理变量 |
| `proxy-env-unset.sh` | 用 `source` 清除当前 shell 的代理变量 |
| `install-core.sh` | 下载并校验固定版本核心；已有核心会保留 |

## 首次使用

```bash
mihomoctl set-url
mihomoctl update
mihomoctl start
mihomoctl health
```

刷新保留活动配置和节点筛选；旧订阅保存为 `subscription.yaml.previous`。下载内容在隔离目录中校验，通过后原子安装。订阅作为 provider 使用，不能覆盖本地监听和路由策略。

节点名称含空格或特殊符号时加引号。代理停止时，`node` 只保存选择；启动后生效。`--auto` 依据测试地址延迟选节点。

## 接入已有代理

安装时用 `--mihomo-root DIR` 指向已有运行目录，匹配 `--port` 和 `--screen-name`，然后运行 `mihomoctl status`。受管核心的启动参数须为：

```text
DIR/bin/mihomo -d DIR/home -f DIR/home/config.yaml
```

进程须运行在相应 GNU Screen 会话中。归属或端口不一致时会报告冲突，不会抢占外部服务。安装保留现有文件；需要搬迁运行目录时，应停止服务后复制数据、更新配置，再启动。

## 运行数据与 Shell 代理

`MIHOMO_ROOT` 保存核心和私有运行数据：

| 路径 | 内容 |
| --- | --- |
| `bin/mihomo` | 核心可执行文件 |
| `home/config.yaml` | 活动配置、节点筛选 |
| `home/providers/` | 含节点凭据的订阅及上一份副本 |
| `secrets/subscription.curl` | 权限 0600 的订阅地址 |
| `run/` / `logs/` | PID、锁和日志 |

默认端口为 7890；配置校验要求回环监听，并禁用 LAN、额外监听、控制 API、TUN 和 DNS 服务。`status` 验证受管进程和 socket 所有者；`health` 检查 Cloudflare 测试地址，目标站点需另行验证。

```bash
TOOLKIT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/server-vpn-codex-headless"
source "$TOOLKIT_DIR/mihomo-server/scripts/proxy-env.sh"
# 清除当前 shell 代理：
source "$TOOLKIT_DIR/mihomo-server/scripts/proxy-env-unset.sh"
```

自定义安装时替换 `TOOLKIT_DIR`。代理变量只影响采用它们的应用；Codex 后台任务会自行加载相同端口。

## 排查

`conflict`：核对运行目录、端口、Screen 名及占用进程。`degraded`：查看日志，确认进程、监听和 Screen 状态是否一致。网络超时、TLS EOF 或上游限流：刷新订阅或换节点后，重新验证目标站点。
