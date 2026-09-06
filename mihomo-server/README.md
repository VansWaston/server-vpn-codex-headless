# 服务器端 Clash/Mihomo

这套目录用于无图形界面的 Linux 容器。它运行 FLClash 所使用的兼容核心 Mihomo，而不是安装 Flutter/GTK 图形界面。

## 当前安全边界

- 混合 HTTP/SOCKS 代理只监听 `127.0.0.1:7890`。
- 不开启 `allow-lan`、外部控制 API、TUN、透明代理或系统全局代理。
- 订阅仅作为 `proxy-provider` 载入，不能覆盖本地监听地址、开启 TUN 或替换本地规则。
- 订阅 URL 保存在权限为 `0600` 的 curl 配置中，不出现在进程参数和普通日志里。
- 下载内容先在临时目录用 `mihomo -t` 校验，通过后才原子替换；旧 provider 留作 `subscription.yaml.previous`。

## 登录自动启动

Mihomo 运行在名为 `mihomo-server` 的 GNU Screen 会话中，SSH 或本地连接断开后仍会继续运行。

系统已安装 `/etc/profile.d/mihomo-login-autostart.sh`。如果容器重启导致代理消失，首次交互式 root 登录会调用 `scripts/ensure-running.sh` 自动恢复。脚本使用 `flock` 防止多个并发登录重复启动，失败信息记录在 `logs/login-autostart.log`，不会阻断登录。

这是“首次登录后自启”，不是无人登录时的开机服务；当前容器的 PID 1 不是 systemd。如需开机后、登录前启动，应另接 AutoDL 的实例启动命令。

若服务器异常中断留下精确名为 `mihomo-server` 的 `(Dead ???)` Screen，控制器会在确认没有受管 Mihomo 进程、没有 7890 监听者后清理该死会话，再重新启动；不会清理其他 Screen。

## 接入或更新订阅

```bash
cd /workspace/mihomo-server
./scripts/mihomoctl set-url
./scripts/mihomoctl update
./scripts/mihomoctl restart
./scripts/mihomoctl status
```

`set-url` 会无回显读取 URL。不要把 URL 写进 shell 命令、截图、工单或 Git。

如果 `update` 报 provider 解析失败，说明链接可能返回 Base64/V2Ray 列表而不是 Clash YAML。应向订阅服务获取 Clash.Meta/Mihomo 兼容链接，不要把节点凭据交给在线订阅转换网站。

## Shell 与任务使用代理

代理进程自动启动不等于透明接管服务器流量。当前部署已在 root 的 `.bashrc` 和 `.profile` 中将常见代理环境变量固定到服务器本地 `127.0.0.1:7890`。新登录 shell 会自动使用它。

脚本或隔离 shell 也可以显式加载：

```bash
source /workspace/mihomo-server/scripts/proxy-env.sh
curl --fail --silent --show-error \
  --output /dev/null --write-out '%{http_code}\n' \
  https://cp.cloudflare.com
```

随后从同一 shell 启动需要代理的 Codex 或其他任务。没有修改 `/etc/environment`、防火墙或默认路由。

取消当前 shell 的代理变量：

```bash
source /workspace/mihomo-server/scripts/proxy-env-unset.sh
```

## 17890 与本地 VPN 映射

`127.0.0.1:17890` 是旧的客户端 SSH/VPN 映射，不是服务器常驻代理。使用它的进程会在本地连接断开时失去网络。服务器任务必须使用 `127.0.0.1:7890`。

修改 shell 配置不会改变已经运行的进程。若 VS Code extensionHost 或 Codex app-server 仍继承 `17890`，必须完整关闭并重新连接 VS Code Remote；仅新开终端无效。无头 Codex 控制器会在每次启动时显式覆盖为 `7890`：

```bash
codexctl doctor
```

无头运行的完整说明见 `/workspace/codex-headless/README.md`。

## 运维与回滚

```bash
./scripts/mihomoctl test
./scripts/mihomoctl logs
./scripts/mihomoctl restart
./scripts/mihomoctl stop
```

如需停用登录自启，可把钩子改名为非 `.sh` 后缀：

```bash
mv /etc/profile.d/mihomo-login-autostart.sh \
  /etc/profile.d/mihomo-login-autostart.sh.disabled
```
