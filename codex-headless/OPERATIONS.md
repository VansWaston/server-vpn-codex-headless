# 服务器 Codex 无头任务操作手册

本手册用于这台服务器上的日常操作。它覆盖两类任务：

- **独立无头任务**：后台任务拥有独立聊天，可以与 VS Code 前台对话并行运行。
- **接管现有 VS Code 对话**：后台继续同一个聊天，完成后再把它交还给 VS Code。

本文只使用 `/root/.local/bin/codexctl` 管理任务。除故障诊断外，不要直接运行裸
`codex exec resume`、`codex resume --last` 或手工操作任务 Screen。

## 1. 先记住四条规则

1. **同一个聊天只能有一个写入者。** 接管现有 VS Code 对话时，VS Code 和无头
   Codex 不能同时运行。
2. **只有 `codexctl ide-ready NAME` 输出 `ready`，才允许重新打开原 VS Code 对话。**
   `status` 显示 `completed` 或 `interrupted` 都不能代替这项检查。
3. **当前 `codexctl stop` 是应急终止，不是常规在线交接。** 它关闭 Screen，可能使
   正在生成的最后一段回复不完整。最稳妥的做法仍是等待当前无头 turn 自然结束。
4. **一个工作树同一时间只保留一个可写者。** 独立并行任务应使用单独的 Git
   worktree；已发生的文件修改不会因停止 Codex 而自动回滚。

## 2. 常用命令速查

| 目的 | 命令 |
| --- | --- |
| 全面健康检查 | `codexctl doctor` |
| 列出任务 | `codexctl list` |
| 查看一个任务 | `codexctl status NAME` |
| 查看本轮聊天记录 | `codexctl chat NAME` |
| 实时跟随聊天输出 | `codexctl chat NAME --follow` |
| 查看运行进度 | `codexctl logs NAME progress` |
| 查看最终回复 | `codexctl result NAME` |
| 继续同一无头聊天 | `codexctl resume NAME PROMPT_FILE` |
| 检查能否交还 VS Code | `codexctl ide-ready NAME` |
| 应急停止 | `codexctl stop NAME` |
| 检查代理 | `/workspace/mihomo-server/scripts/mihomoctl health` |

`codexctl doctor` 会幂等地尝试启动 Mihomo，然后检查代理、Codex 登录和目录状态，
并非纯粹的只读命令。

## 3. 首次使用：完成历史迁移

这一步只做一次。已经看到 `codex_compat=ready` 时直接跳到第 4 节。

### 3.1 退出所有 Codex 写入者

1. 等当前在线回复完全结束。
2. 保存工作区并关闭所有连接本服务器的 VS Code Remote 窗口。
3. 在本地 VS Code 命令面板执行：
   `Remote-SSH: Kill VS Code Server on Host...`。
4. 从普通 SSH 登录服务器，执行：

```bash
codexctl status
pgrep -x codex
```

`codexctl status` 中不能有 `running` 任务，`pgrep -x codex` 必须没有输出。若有输出，
不要继续，也不要用 `kill -9` 绕过检查。

### 3.2 根据迁移阶段执行脚本

检查第一阶段完成标记：

```bash
ls -l /root/autodl-tmp/codex-home/.migration-complete
```

- 文件存在：不要重复迁移，直接执行最终化。
- 文件不存在：先运行迁移，再运行最终化。

```bash
# 仅在 .migration-complete 不存在时运行
/workspace/codex-headless/scripts/migrate-codex-home.sh

# 第一阶段完成后运行
/workspace/codex-headless/scripts/finalize-codex-home.sh

exec bash -l
codexctl doctor
```

必须看到：

```text
codex_home=/root/autodl-tmp/codex-home
codex_compat=ready
```

未出现 `ready` 时不要启动 VS Code，也不要登记真实接管任务。保留最终化脚本创建的
`/root/.codex.rollback.*`，不要立即删除。

## 4. 每次运行前的检查

```bash
codexctl doctor
/workspace/mihomo-server/scripts/mihomoctl health
codex login status
```

应确认：

- Mihomo 同时通过 HTTP 和 SOCKS5 健康检查；
- Codex 已登录；
- `codex_home` 位于数据盘；
- 接管 VS Code 对话时，`codex_compat=ready`。

服务器重启后，Mihomo 会在首次交互式 root 登录时通过 profile hook 尝试启动；它不是
登录前运行的 systemd 开机服务。代理的部署、订阅更新和自启动细节见
[服务器 Clash/Mihomo 部署复用手册](../mihomo-server/README.server-vpn.md)。

## 5. 准备提示词

提示词应明确写出目标、允许修改的范围、验收命令、最长运行时间和失败时如何收尾。

```bash
install -d -m 0700 /workspace/prompts
vi /workspace/prompts/task.md
chmod 0600 /workspace/prompts/task.md
```

控制器要求提示词是 1 字节到 2 MiB 的普通可读文件，且 group/other 没有读取权限。
不要把订阅链接、令牌或其他秘密写入提示词。

## 6. 模式 A：独立无头任务（推荐并行方式）

如果只需要后台完成工作，不要求记录回到当前 VS Code 聊天，使用独立任务最简单。

### 6.1 只读任务

```bash
codexctl exec audit-001 \
  /workspace/你的项目 \
  /workspace/prompts/task.md \
  read-only
```

### 6.2 可写任务

先创建独立 worktree：

```bash
mkdir -p /workspace/codex-worktrees
git -C /workspace/你的项目 worktree add \
  -b codex/impl-001 \
  /workspace/codex-worktrees/impl-001 \
  HEAD

codexctl exec impl-001 \
  /workspace/codex-worktrees/impl-001 \
  /workspace/prompts/task.md \
  workspace-write
```

启动命令返回后可以断开 SSH，VS Code 当前对话也可以继续使用。不要让前台对话同时
修改这个独立 worktree。

## 7. 模式 B：把现有 VS Code 对话转为无头任务

本节会让后台继续**同一个聊天记录**。整个往返必须串行完成。

### 7.1 在线端退出

1. 等目标对话当前 turn 完全结束。
2. 保存工作区。
3. 关闭所有 VS Code Remote 窗口。
4. 执行 `Remote-SSH: Kill VS Code Server on Host...`。
5. 从普通 SSH 确认：

```bash
pgrep -x codex
```

必须没有输出。

### 7.2 第一次登记并启动

`stage-vscode-title` 只登记，不运行；标题必须与 Recent chats 中的可见标题完全一致且
只能匹配一个根对话。

通用接管示例：

```bash
codexctl stage-vscode-title NAME \
  /workspace/PROJECT \
  '对话的完整可见标题' \
  /workspace/prompts/NAME-headless.md \
  workspace-write \
  --add-dir /workspace/RESULT_DIR

codexctl start NAME
```

看到 `started` 后，无头任务已由 Screen 托管，可以断开 SSH。此时不要重新连接 VS Code。

同一任务只登记一次。以后再从在线转为无头，使用第 11 节的 `resume`，不要重新
`stage-vscode-title`。

### 7.3 第一次启动失败后

`start` 只接受 `staged`。一旦最新 attempt 已是 `failed` 或 `interrupted`，
先修复原因并准备一份 `0600` 的恢复提示，然后执行：

```bash
codexctl resume NAME /workspace/prompts/NAME-recovery.md
```

控制器会保留失败记录并创建新 attempt。不要手工把 `state` 改回 `staged`。

### 7.4 任务路径权限核对

```bash
findmnt -T /root/autodl-tmp
df -h /workspace /workspace/RESULT_DIR /root/autodl-tmp
codexctl status NAME
```

建议的权限合同是：主工作树和 `/workspace/RESULT_DIR` 可写；数据盘上的模型、数据集和
历史结果默认只读使用；聊天和任务日志由 runner 写入数据盘，但不把 `codex-home` 或
`codex-headless` 暴露成任务写目录。目录名不能证明挂载位置，启动前应使用
`findmnt -T /workspace/RESULT_DIR` 核对。

## 8. 监控任务

```bash
codexctl status NAME
codexctl logs NAME progress
codexctl logs NAME proxy
```

任务完成后：

```bash
codexctl result NAME
```

`result` 只有在最新 attempt 已生成 `final.md` 后才可用。`logs` 只显示最新 attempt 的
末尾 120 行；`exec`/`vscode` 任务不能使用 `attach`，它只支持 `tui` 任务。

常见状态：

| 状态 | 含义 | 操作 |
| --- | --- | --- |
| `staged` | 已登记但未启动 | 执行 `codexctl start NAME` |
| `running` | 正在执行 | 继续等待或查看 `progress` |
| `completed` | 正常完成 | 执行 `ide-ready` |
| `failed` | 执行失败 | 查看 `progress` 和 `proxy`，再决定交还或 `resume` |
| `interrupted` | Screen/服务器中断，或仅由状态查询推断 | 不能直接重连；执行 `ide-ready` 或恢复 |
| `conflict` | 同名 Screen 无法验证归属 | 停止操作，人工检查，不要盲目终止 |

## 9. 无头任务结束后转回在线

先运行唯一的交接门禁：

```bash
codexctl ide-ready NAME
```

只有看到类似以下输出才继续：

```text
ready name=NAME version=...
```

然后：

1. 重新连接 VS Code Remote。
2. 从 Recent chats 打开“对话的完整可见标题”。
3. 若列表没有刷新，执行 `Developer: Reload Window`。
4. 不要用 `--last` 猜测会话。

无头 turn、工具记录和最终回复会出现在原聊天中。

## 10. 无头任务尚未结束时转回在线

### 10.1 首选：等待自然结束

这是当前工具中保留聊天终态最可靠的方式：

```bash
codexctl status NAME
codexctl logs NAME progress
```

任务完成后按第 9 节执行 `ide-ready`。

### 10.2 紧急接管：接受当前 turn 可能不完整

当前控制器尚未提供基于 Codex `turn/interrupt` 的一键安全交接命令。必须立即停止时，
可以使用：

```bash
codexctl stop NAME
codexctl status NAME
codexctl ide-ready NAME
```

如果最后一条命令没有输出 `ready`：

```bash
sleep 2
codexctl ide-ready NAME
```

仍不通过时保持 VS Code 关闭，查看：

```bash
codexctl status NAME
codexctl logs NAME progress
codexctl logs NAME screen
```

不要绕过 `ide-ready`。`stop` 当前通过关闭 Screen 终止任务，可能留下未完成的流式回复；
它不会回滚已经写入工作树的文件，也不能证明任务启动的 GPU 服务或后台进程都已退出。
对使用 GPU 或其他后台服务的任务，还应检查 `nvidia-smi` 和项目相关进程，再决定是否继续实验。

> 计划中的正确接口是 `codexctl handoff-online NAME`：发送一次正常中断，等待 Codex
> 记录 `interrupted`、runner 写完终态并释放锁，然后才输出 `ready`。当前
> `codexctl` 帮助中没有该命令，因此不要把它当作已经可用。

## 11. 从在线再次转为无头

1. 等在线 turn 结束并保存工作区。
2. 关闭 VS Code Remote，并 Kill VS Code Server。
3. 确认 `pgrep -x codex` 没有输出。
4. 编写新的 `0600` 提示词。
5. 恢复已登记任务：

```bash
vi /workspace/prompts/NAME-followup.md
chmod 0600 /workspace/prompts/NAME-followup.md

codexctl resume NAME /workspace/prompts/NAME-followup.md
```

控制器会使用保存的准确会话标识并创建新的 attempt。不要使用裸 `codex resume`，也不要
使用 `--last`。

### 11.1 当前聊天正占用 writer lock 时延迟续跑

如果需要先在当前 VS Code 聊天中读完交接说明，再关闭 Remote，可以预先启动一次性
等待器：

```bash
screen -dmS cxw-NAME \
  /workspace/codex-headless/scripts/resume-when-ide-ready.sh \
  NAME /workspace/prompts/NAME-followup.md 43200
```

等待器只轮询 `codexctl ide-ready`。它不会结束 VS Code、删除锁或伪造终态；全部检查
通过后只调用一次 `codexctl resume`，即使启动失败也不会盲目创建更多 attempt。启动
等待器后，读完当前消息并关闭所有连接到该服务器的 VS Code Remote 窗口，再执行
`Remote-SSH: Kill VS Code Server on Host...`。不要在任务运行期间重新打开原聊天。

从普通 SSH 检查：

```bash
cat /root/autodl-tmp/codex-headless/run/deferred-NAME.state
tail -n 50 /root/autodl-tmp/codex-headless/run/deferred-NAME.log
codexctl status NAME
```

脚本默认等待 12 小时，允许的超时范围为 60 秒到 24 小时。每个 NAME 由独占锁防止
重复等待；提示词在等待期间被修改时会拒绝启动。

## 12. 服务器重启后的恢复

服务器重启不会从中断的模型步骤自动续跑。

```bash
codexctl doctor
codexctl status NAME
```

- 想继续无头执行：保持 VS Code 关闭，准备新的提示词后运行
  `codexctl resume NAME PROMPT_FILE`。
- 想回到在线：先运行 `codexctl ide-ready NAME`；只有 `ready` 才能连接。
- 硬重启后若 `status` 显示 `interrupted`，但 `ide-ready` 因缺少结束元数据而失败，
  不要手工伪造 `state`、`exit-code` 或锁文件。可先用一个恢复提示词执行一次 `resume`，
  让新 attempt 正常收尾，再执行 `ide-ready`；若 `resume` 也拒绝，保留现场进行诊断。

## 13. 日志、历史和敏感数据

每次 attempt 保存在：

```text
/root/autodl-tmp/codex-headless/jobs/<NAME>/attempts/<NNNN>/
```

主要文件：

- `prompt.txt`：本轮提示词副本；
- `events.jsonl`：完整事件流，可能含代码、命令和内部会话标识；
- `final.md`：最终回复；
- `progress.log`、`proxy-check.log`、`screen.log`：诊断日志；
- `state`、`exit-code`、时间戳：运行状态。

### 13.1 从普通 SSH 查看无头聊天

查看最新 attempt 已经输出的全部助手消息：

```bash
codexctl chat NAME
```

从当前已有消息开始实时跟随，直到该 attempt 进入终态：

```bash
codexctl chat NAME --follow
```

按 `Ctrl-C` 只会退出本地查看器，不会停止无头任务。另开一个 SSH 终端可同时查看状态、
基础设施诊断和最终回复：

```bash
codexctl status NAME
codexctl logs NAME progress
codexctl result NAME
```

`chat` 在启动时选择最新 attempt；如果延迟续跑器尚在等待 VS Code writer lock，先等
`status` 显示新的 attempt 为 `running`，再启动 `--follow`。该命令只渲染助手消息和
turn 终态，不显示内部会话 ID；完整 `events.jsonl` 仍按敏感数据处理。

这些文件和 `$CODEX_HOME/auth.json` 都按秘密处理：不要提交到 Git，不要粘贴到公开聊天、
工单或截图中。订阅链接的保护规则见 Mihomo 手册。

### 13.2 对用量/网络失败做有限自动续接

长任务可在一次性 writer-lock 等待器之外启动恢复监视器。它只对最新 attempt 明确的
usage/rate-limit、WebSocket/TLS 或连接失败自动调用同一受管 `resume`，不会因正常完成、
科研失败或人工 `interrupted` 重跑。下面示例最多重试两次，总监视时间 48 小时：

```bash
screen -dmS cxr-NAME \
  /workspace/codex-headless/scripts/retry-recoverable-attempt.sh \
  NAME /workspace/prompts/NAME-resume.md <BASE_ATTEMPT> 2 172800
```

从普通 SSH 查看监视状态和日志：

```bash
cat /root/autodl-tmp/codex-headless/run/retry-NAME.state
tail -f /root/autodl-tmp/codex-headless/run/retry-NAME.log
```

需要切回在线会话时，先停止恢复监视器，避免在线 writer lock 以后释放时又自动续接：

```bash
screen -S cxr-NAME -X quit
```

这只停止监视器，不停止已经运行的 attempt。提示词必须是 `root:root` 且组/其他用户无
权限；监视器启动时固定其 SHA256，等待期间发生变化会 fail closed。

## 14. 常见故障

### `codex_compat=pending`

历史迁移尚未最终化。关闭全部 Codex/VS Code 进程，按第 3 节运行
`finalize-codex-home.sh`。

### `Codex writer lock 正在被占用`

目标聊天仍被 VS Code 或另一个 Codex 进程打开。关闭对应客户端并 Kill VS Code
Server；不要删除锁文件。

### `任务不存在`

首次接管尚未登记。按第 7 节运行 `stage-vscode-title`；若只是名称写错，先运行
`codexctl list`。

### `任务已存在`

不要重复登记。继续同一聊天使用 `codexctl resume NAME PROMPT_FILE`；独立新任务应换
一个新名称。

### `上一次任务仍在运行`

不要并发恢复同一会话。等待它结束；若必须停止，阅读第 10 节的风险后再使用 `stop`。

### 代理或登录失败

```bash
/workspace/mihomo-server/scripts/mihomoctl status
/workspace/mihomo-server/scripts/mihomoctl health
/workspace/mihomo-server/scripts/mihomoctl logs
codex login status
```

只有确实退出登录时才执行：

```bash
codex login --device-auth
```

### `ide-ready` 版本检查失败

一次在线/无头往返期间 VS Code Codex 扩展版本发生了变化。不要绕过检查，也不要直接
打开原聊天；保持 VS Code 关闭并进行版本对齐或人工诊断。

### `--sandbox` 与 `--approve-for-me` 冲突

workspace-write 无头任务只应使用 `--approve-for-me`；它已经选择 workspace-write。
修复 runner 后，对已经失败的 attempt 使用 `codexctl resume`，不要重复 `start`。

### 缺少 `codex-code-mode-host`

VS Code bridge 不能只保存主 `codex`。当前控制器还会固定并校验 code-mode host、
`rg`、package 元数据、`bwrap` 和 `zsh`。若日志仍报缺件，保持任务停止，禁止从
不同扩展版本手工拼装文件。

### `bwrap: No permissions to create a new namespace`

本容器内核当前不允许本地 bubblewrap namespace。使用 `--approve-for-me` 时，事件流
应显示失败命令经过自动审查后被再次执行并成功。若只有连续失败而没有成功重试，停止
任务并保留现场。不要使用 `--dangerously-bypass-approvals-and-sandbox`。这套配置
适用于单用户 root 服务器；需要硬隔离时，应在宿主/容器层提供 user namespace 或精确
外部挂载边界。

## 15. 禁止事项

- 不要让 VS Code 和无头 Codex 同时写同一个聊天。
- 不要直接编辑或删除 `session-id`、`state`、锁文件和 rollout JSONL。
- 不要用 `kill -9`、`pkill codex`、`screen -wipe` 代替控制器。
- 不要用 `codex resume --last` 或 `codex exec resume --last`。
- 不要在一次接管往返中升级 VS Code Codex 扩展。
- 不要把 `/root/autodl-tmp/codex-home`、任务数据或代理 secrets 暴露给其他用户。

## 16. 官方参考

- [OpenAI Docs：Codex App Server](https://learn.chatgpt.com/docs/app-server)：线程恢复、
  `turn/interrupt`、终态事件和后台终端生命周期。
- [OpenAI Docs：Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)：
  `codex exec`、JSONL、最终回复与会话恢复。
- [完整技术说明](README.md)：本机目录布局、安全校验和实现细节。
