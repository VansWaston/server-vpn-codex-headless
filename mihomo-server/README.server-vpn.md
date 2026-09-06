# 服务器 Clash/Mihomo 部署复用手册

本文用于在无图形界面的 Linux 服务器或容器上重复部署 Clash 兼容代理，并在首次交互式 root 登录时自动恢复服务。

> 名称说明：这里配置的是 Mihomo 的 HTTP/SOCKS 出站代理，不是传统全局 VPN。本方案不开 TUN、不修改默认路由，也不替代用于远程管理的 WireGuard/Tailscale。

## 1. 方案边界

- 使用官方 Mihomo 核心，不安装 FLClash Flutter/GTK 桌面界面。
- 只监听 `127.0.0.1:7890`。
- 不启用 `allow-lan`、外部控制 API `9090`、TUN、透明代理或 DNS 劫持。
- 订阅只作为 `proxy-provider` 使用，不能改变本地监听和路由设置。
- 订阅 URL、节点文件、缓存和日志都按秘密处理。
- 订阅先在隔离目录执行 `mihomo -t`，成功后才原子替换。
- Mihomo 是经过严格校验的 GNU Screen 直接子进程，SSH 断开后继续运行。
- `/etc/profile.d` 钩子只在首次交互式 root 登录后启动，不是登录前的开机服务。
- 代理环境变量只注入明确选择的 shell，不改全局 `/etc/environment`。

当前配置包含 `empty-fallback: DIRECT`：订阅节点为空时允许直连，属于 fail-open，不是防泄漏 kill switch。需要严格禁止直连时，应单独调整策略并重新测试。

## 2. 参考基线

以下是本方案最初验证的环境；每次部署都应按第 3 节在目标服务器重新确认：

```text
Ubuntu 22.04
x86_64
PID 1: bash（不是 systemd）
GNU Screen 4.09
Mihomo v1.19.30 linux amd64 compatible
无 /dev/net/tun
```

官方资料：

- FLClash：<https://github.com/chen08209/FlClash>
- Mihomo Releases：<https://github.com/MetaCubeX/mihomo/releases>
- 通用配置：<https://wiki.metacubex.one/en/config/general/>
- Proxy Provider：<https://wiki.metacubex.one/en/config/proxy-providers/>
- systemd 参考：<https://wiki.metacubex.one/en/startup/service/>

若 PID 1 确实是 systemd，可改用最小权限 systemd 服务；不要在无 systemd 的容器里照搬该方案。

## 3. 新服务器前置检查

```bash
uname -m
cat /etc/os-release
ps -p 1 -o comm=
command -v curl gzip sha256sum screen flock
test -c /dev/net/tun && ls -l /dev/net/tun || true
```

Ubuntu/Debian 缺少依赖时：

```bash
apt-get update
apt-get install -y ca-certificates curl gzip screen util-linux coreutils
```

检查 `7890` 和 `9090` 是否已有监听。它们的十六进制端口分别为 `1ED2`、`2382`：

```bash
awk 'FNR > 1 && ($2 ~ /:1ED2$/ || $2 ~ /:2382$/) && $4 == "0A" \
  {print FILENAME, $2, $4, $10}' /proc/net/tcp /proc/net/tcp6
```

首次部署应无输出。若端口被占用，必须先识别所有者；不要直接运行 `pkill mihomo`、`killall` 或 `fuser -k`。

## 4. 下载并验证官方核心

下面固定已验证版本，便于复现：

```bash
MIHOMO_ROOT='/workspace/mihomo-server'
MIHOMO_VERSION='v1.19.30'
MIHOMO_ASSET="mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"
MIHOMO_ARCHIVE_SHA256='db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9'

install -d -m 0700 \
  "$MIHOMO_ROOT" \
  "$MIHOMO_ROOT/bin" \
  "$MIHOMO_ROOT/config" \
  "$MIHOMO_ROOT/home/providers" \
  "$MIHOMO_ROOT/secrets" \
  "$MIHOMO_ROOT/run" \
  "$MIHOMO_ROOT/logs" \
  "$MIHOMO_ROOT/scripts"

curl -fL --proto '=https' --tlsv1.2 --connect-timeout 20 --retry 3 \
  "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${MIHOMO_ASSET}" \
  -o "/tmp/${MIHOMO_ASSET}"

printf '%s  %s\n' "$MIHOMO_ARCHIVE_SHA256" "/tmp/${MIHOMO_ASSET}" \
  | sha256sum --check -

gzip -dkf "/tmp/${MIHOMO_ASSET}"
install -m 0755 "/tmp/${MIHOMO_ASSET%.gz}" "$MIHOMO_ROOT/bin/mihomo"
"$MIHOMO_ROOT/bin/mihomo" -v
sha256sum "$MIHOMO_ROOT/bin/mihomo"
```

当前两个摘要不同是正常的：

```text
官方 .gz 资产：db214c7a2517e63c150d123178d16d102e03a241ccdae4e5e07ffbe9cf56c6f9
解压后二进制：8ad44e28fe72be4640254b96741b677f4074991b99186cc4486a1c28ded02b1a
```

必须先验证 `.gz` 再解压。ARM64 等其他架构要从官方 Release 选择对应资产和摘要。升级版本时同时更新：

- `VERSION`
- 资产名与 SHA-256
- `scripts/mihomoctl` 中的订阅 `User-Agent`

禁止把 `latest` 下载地址与旧 SHA-256 混用。

## 5. 可复用文件和私密运行文件

应复制到新服务器的白名单文件：

```text
.gitignore
VERSION
README.md
README.server-vpn.md
bin/mihomo
config/config.template.yaml
config/mihomo-login-autostart.sh
scripts/mihomoctl
scripts/ensure-running.sh
scripts/proxy-env.sh
scripts/proxy-env-unset.sh
```

不得进入模板、Git、公开归档或工单的运行文件：

```text
secrets/subscription.curl
home/config.yaml
home/providers/subscription.yaml
home/providers/subscription.yaml.previous
home/cache.db
logs/*
run/*
所有 *.bak 和 *.previous
```

复制后恢复权限：

```bash
chmod 0700 /workspace/mihomo-server
chmod 0700 /workspace/mihomo-server/{bin,config,home,secrets,run,logs,scripts}
chmod 0755 /workspace/mihomo-server/bin/mihomo
chmod 0755 /workspace/mihomo-server/scripts/mihomoctl
chmod 0700 /workspace/mihomo-server/scripts/ensure-running.sh
chmod 0755 /workspace/mihomo-server/scripts/proxy-env.sh
chmod 0755 /workspace/mihomo-server/scripts/proxy-env-unset.sh
chmod 0600 /workspace/mihomo-server/config/config.template.yaml

bash -n /workspace/mihomo-server/scripts/mihomoctl
bash -n /workspace/mihomo-server/scripts/ensure-running.sh
dash -n /workspace/mihomo-server/config/mihomo-login-autostart.sh
```

脚本固定使用 `/workspace/mihomo-server`、root 和端口 `7890`。更换路径、用户或端口时，必须同步修改模板、管理脚本、登录脚本与环境脚本。

## 6. 安全录入订阅

不要将订阅 URL 放进命令参数、shell history、聊天、截图、Git 或日志。使用无回显交互输入：

```bash
cd /workspace/mihomo-server
./scripts/mihomoctl set-url
```

不读取内容，仅检查权限：

```bash
stat -c 'mode=%a owner=%U:%G size=%s' secrets/subscription.curl
wc -l secrets/subscription.curl
```

预期为 `mode=600` 且一行。

下载并隔离验证：

```bash
./scripts/mihomoctl update
./scripts/mihomoctl test
```

只有看到以下结果才能继续：

```text
configuration file ... test is successful
订阅已通过 Mihomo 语法校验并原子安装。
```

若解析失败，链接可能返回 Base64/V2Ray URI，而不是 Clash/Mihomo provider YAML。应向订阅服务获取 Mihomo/Clash.Meta 兼容链接，不要把节点凭据交给在线订阅转换网站。

`update` 是手动刷新订阅；节点健康检查不等于自动刷新订阅内容。

## 7. 启动与严格状态验证

```bash
./scripts/mihomoctl start
./scripts/mihomoctl status
./scripts/mihomoctl health
```

健康状态示例：

```text
running pid=12345 mode=screen listen=127.0.0.1:7890
healthy pid=12345 http=204 socks5h=204
```

新版 `status` 不只检查 Screen 名称。只有同时满足下列条件才返回成功：

- 恰好一个使用本目录二进制和配置的 Mihomo 进程。
- `127.0.0.1:7890` 恰好一个 LISTEN socket。
- socket 的唯一所有者是该 Mihomo PID。
- 恰好一个经过参数验证的 `mihomo-server` Screen 会话。
- Mihomo PID 是该 Screen server 的直接子进程。
- `7890` 没有通配或其他地址监听，`9090` 没有监听。

退出码：

```text
0  healthy/running
3  stopped
4  degraded，受管进程、socket 或 Screen 状态不一致
5  conflict，7890 被非受管或无法识别的进程占用
```

若发现旧进程和 Screen 重复实例，执行 `start` 或 `restart` 时只会清理经过“可执行文件 + 精确参数”验证属于本部署的进程；不会杀死未知端口所有者。

可再人工检查：

```bash
screen -ls
pgrep -a -x mihomo
awk 'FNR > 1 && ($2 ~ /:1ED2$/ || $2 ~ /:2382$/) && $4 == "0A" \
  {print FILENAME, $2, $4, $10}' /proc/net/tcp /proc/net/tcp6
```

日志可能包含访问域名和节点标签，分享前应脱敏。

## 8. 配置首次登录自动启动

先完成手动启动和 `health` 验证，再安装登录钩子：

```bash
install -m 0644 -o root -g root \
  /workspace/mihomo-server/config/mihomo-login-autostart.sh \
  /etc/profile.d/mihomo-login-autostart.sh

dash -n /etc/profile.d/mihomo-login-autostart.sh
cmp -s \
  /workspace/mihomo-server/config/mihomo-login-autostart.sh \
  /etc/profile.d/mihomo-login-autostart.sh
```

工作方式：

- 只处理交互式 root 登录。
- `ensure-running.sh` 用登录锁合并并发登录。
- `mihomoctl` 用独立控制锁串行化 `set-url/update/start/stop/restart`。
- 已健康运行时不会创建第二个实例。
- 启动失败记录到 `logs/login-autostart.log`，但不阻断登录。

维护窗口内做端到端测试：

```bash
./scripts/mihomoctl stop
bash --login -i -c 'true'
sleep 1
./scripts/mihomoctl status
./scripts/mihomoctl health
```

注意：这只保证“重启后的首次交互式 root 登录后启动”。非交互 SSH、非 root 用户、未加载 `/etc/profile` 的 shell 和无人登录阶段不会触发。容器重建时 `/workspace` 与 `/etc` 的持久性可能不同，需重新检查登录钩子。

## 9. 让指定任务使用代理

代理守护进程启动不表示整台服务器自动走代理。仅在需要的 shell 中加载：

```bash
source /workspace/mihomo-server/scripts/proxy-env.sh
```

随后从同一 shell 启动 Codex 或其他任务。长任务可放入单独 Screen：

```bash
screen -S codex-work
source /workspace/mihomo-server/scripts/proxy-env.sh
# 启动任务；按 Ctrl-A，再按 D 脱离
```

恢复会话：

```bash
screen -r codex-work
```

取消当前 shell 的代理变量：

```bash
source /workspace/mihomo-server/scripts/proxy-env-unset.sh
```

环境变量只影响当前 shell 及其后代，已运行进程不会改变；部分应用也可能不遵守这些变量。

云元数据地址和私网服务不应经过代理。按平台需要补充 `NO_PROXY`，例如：

```bash
export NO_PROXY="${NO_PROXY:+$NO_PROXY,}169.254.169.254"
export no_proxy="$NO_PROXY"
```

## 10. 日常更新

订阅更新：

```bash
cd /workspace/mihomo-server
./scripts/mihomoctl update
./scripts/mihomoctl restart
./scripts/mihomoctl status
./scripts/mihomoctl health
```

更换订阅 URL：

```bash
./scripts/mihomoctl set-url
./scripts/mihomoctl update
./scripts/mihomoctl restart
./scripts/mihomoctl health
```

只有一代 `subscription.yaml.previous`；连续成功更新会覆盖更早版本。

核心升级必须先停止旧进程，再替换二进制。否则旧进程的 `/proc/PID/exe` 会显示 deleted，严格管理器会将它视为未知状态：

```bash
./scripts/mihomoctl stop
install -m 0755 bin/mihomo.next bin/mihomo.next.checked
bin/mihomo.next.checked -v
mv bin/mihomo bin/mihomo.previous
mv bin/mihomo.next.checked bin/mihomo
./scripts/mihomoctl test
./scripts/mihomoctl start
./scripts/mihomoctl health
```

升级前必须按第 4 节验证新资产摘要，并更新 `VERSION` 和管理脚本 User-Agent。

## 11. 故障排查

状态、数据面和日志：

```bash
./scripts/mihomoctl status
./scripts/mihomoctl health
./scripts/mihomoctl logs
tail -n 80 logs/login-autostart.log
```

常见情况：

- `stopped`：运行 `test` 后再 `start`。
- `degraded`：执行 `restart`，管理器会精确清理本部署的残留实例并重建。
- `conflict`：7890 属于未知进程；先人工识别，不要盲目结束进程。
- HTTP/SOCKS 超时：查看日志，重新 `update`、`restart`、`health`。
- 登录未启动：检查 `/etc/profile.d/mihomo-login-autostart.sh`、脚本语法和 `logs/login-autostart.log`。
- 订阅泄漏：删除本地文件并不能使链接失效，必须到服务商处撤销或轮换订阅凭据。

## 12. 回滚与停用

取消当前 shell 代理并停止服务：

```bash
source /workspace/mihomo-server/scripts/proxy-env-unset.sh
/workspace/mihomo-server/scripts/mihomoctl stop
```

可恢复地停用登录钩子：

```bash
mv /etc/profile.d/mihomo-login-autostart.sh \
  /etc/profile.d/mihomo-login-autostart.sh.disabled
```

恢复上一代 provider：

```bash
install -m 0600 \
  home/providers/subscription.yaml.previous \
  home/providers/subscription.yaml.next
mv home/providers/subscription.yaml.next home/providers/subscription.yaml
./scripts/mihomoctl test
./scripts/mihomoctl restart
./scripts/mihomoctl health
```

核心回滚：

```bash
./scripts/mihomoctl stop
mv bin/mihomo bin/mihomo.failed
mv bin/mihomo.previous bin/mihomo
./scripts/mihomoctl test
./scripts/mihomoctl start
./scripts/mihomoctl health
```

调整防火墙、默认路由或远程登录设置前，始终保留一个已验证的 SSH/控制台救援会话。

## 13. 制作无秘密迁移包

不要复制整个运行目录。使用白名单创建模板包：

```bash
cd /workspace/mihomo-server
tar -czf /tmp/mihomo-server-template.tar.gz \
  .gitignore \
  VERSION \
  README.md \
  README.server-vpn.md \
  bin/mihomo \
  config/config.template.yaml \
  config/mihomo-login-autostart.sh \
  scripts/mihomoctl \
  scripts/ensure-running.sh \
  scripts/proxy-env.sh \
  scripts/proxy-env-unset.sh
```

检查清单：

```bash
tar -tzf /tmp/mihomo-server-template.tar.gz
```

归档中不得出现 `subscription.curl`、`subscription.yaml`、`cache.db`、日志、锁文件、PID 文件、节点名或任何备份。新服务器解压后重新创建私有目录、录入订阅并执行完整验证。

## 14. 验收清单

- [ ] 二进制来自官方 Release，压缩资产 SHA-256 校验通过。
- [ ] CPU 架构与下载资产匹配。
- [ ] `mihomoctl test` 成功。
- [ ] `mihomoctl status` 返回严格健康状态。
- [ ] 恰好一个受管 Mihomo PID和一个已验证 Screen 会话。
- [ ] Mihomo 是该 Screen 的直接子进程并持有唯一 socket。
- [ ] 只监听 `127.0.0.1:7890`，没有 `9090`。
- [ ] `mihomoctl health` 的 HTTP 和 SOCKS5h 均为 `204`。
- [ ] 订阅、provider、cache 和日志权限不宽于 `0600`，父目录为 `0700`。
- [ ] 停止后模拟重新登录能自动恢复。
- [ ] 重复登录不产生第二实例。
- [ ] 迁移包只使用白名单且不含秘密。
- [ ] 回滚和停用登录钩子的路径已经记录。
