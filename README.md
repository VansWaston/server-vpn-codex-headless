# 服务器 VPN 与 Codex 无头运行工具

本仓库保存当前服务器上可复用的两套运维工具：

- [Mihomo/Clash 服务端配置](mihomo-server/README.md)：仅监听
  `127.0.0.1:7890`，通过 GNU Screen 常驻，并在首次 root 交互登录时自动恢复。
- [Codex 无头任务工具](codex-headless/README.md)：让任务在 SSH 或 VS Code
  断开后继续运行，并把事件流、最终回复和可恢复会话保存在数据盘。

日常切换、监控和恢复请直接看
[《Codex 无头任务操作手册》](codex-headless/OPERATIONS.md)；完整 VPN 部署与迁移流程见
[《服务器 Clash/Mihomo 部署复用手册》](mihomo-server/README.server-vpn.md)。

## 适用环境

当前版本面向单用户 `root`、AutoDL 风格目录布局的 Linux x86_64 容器，默认使用：

```text
/workspace/mihomo-server
/workspace/codex-headless
/root/autodl-tmp/codex-home
/root/autodl-tmp/codex-headless
```

脚本还依赖 Bash、curl、GNU Screen、flock、Git 和兼容版本的 Codex CLI。换到其他用户、
架构或目录前，应先参数化脚本中的固定路径并重新审计权限。

## 部署入口

1. 把仓库克隆到一个临时目录，不要直接覆盖正在运行的服务。
2. 按 VPN 完整手册的“前置检查”和“下载并验证官方核心”章节安装依赖与
   `mihomo-server/bin/mihomo`。仓库只记录固定版本及 SHA-256，不提交约 51 MB 的二进制。
3. 将两个组件分别部署为 `/workspace/mihomo-server` 和
   `/workspace/codex-headless`，保留文档指定的权限和兄弟目录关系。
4. 使用 `mihomoctl set-url` 在终端无回显录入订阅，再完成 VPN 健康检查和登录自启。
5. 按 Codex README 完成 `CODEX_HOME` 迁移、登录和 `codexctl doctor`，随后按操作手册
   启动或接管任务。

不要将本仓库中的模板直接复制到现有运行目录后盲目重启；先对比本机配置和版本，
并保留可回滚副本。

## 不进入 Git 的内容

本仓库有意不包含：

- VPN 订阅 URL、provider 节点、运行配置、缓存数据库、日志和 PID；
- Codex 的 `auth.json`、聊天事件、会话 ID、提示词、最终回复、日志和任务状态；
- Mihomo、Codex、VS Code bridge 等可执行二进制；
- shell profile 的机器实装副本、私钥、令牌和 `.env` 文件。

这些内容均可能泄露凭据、代码或聊天记录。详细处理规则见 [SECURITY.md](SECURITY.md)。
OpenAI 对无头执行、JSONL 输出、sandbox 和会话恢复的官方说明见
[Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)。

## 仓库性质

该仓库是当前服务器配置的私有灾备与复用基线，不是通用的一键安装器。提交前使用精确
白名单打包；即使远端是私有仓库，也应始终把凭据和运行态数据留在 Git 之外。
