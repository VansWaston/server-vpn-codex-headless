# 服务器无头 Codex

这套工具让 Codex 在服务器本地代理后方运行。SSH 或 VS Code 断开后，已经启动的任务仍由 GNU Screen 托管；提示词、事件流、最终回复和可恢复的会话 ID 保存在数据盘。

日常启动、监控、在线/无头切换和重启恢复请优先阅读
[《服务器 Codex 无头任务操作手册》](OPERATIONS.md)。本文保留部署原理、迁移细节和完整技术说明。

手机远程连接不在当前配置范围内，也没有开放 Mihomo、Screen 或 Codex app-server 的网络端口。

## 已配置的组件

- 独立 Codex CLI：`/root/.local/bin/codex`
- 任务控制器：`/root/.local/bin/codexctl`
- 服务器本地代理：`127.0.0.1:7890`
- 任务数据：`/root/autodl-tmp/codex-headless`
- 规范 Codex 历史：`/root/autodl-tmp/codex-home`
- 旧路径兼容入口：最终化后 `/root/.codex` 指向上述数据盘目录

无头运行器不会使用旧的 `127.0.0.1:17890`。那个端口来自客户端 SSH/VPN 映射，本地连接断开后就不可用。每个任务都会显式设置：

```text
HTTP_PROXY=http://127.0.0.1:7890
HTTPS_PROXY=http://127.0.0.1:7890
ALL_PROXY=socks5h://127.0.0.1:7890
```

随后自动启动或检查 Mihomo，并且只有健康检查通过后才启动 Codex。

## 健康检查

```bash
codexctl doctor
```

正常结果应包含：

```text
healthy ... http=204 socks5h=204
Logged in using ChatGPT
codex=codex-cli ...
data_root=/root/autodl-tmp/codex-headless
```

迁移历史前，`codex_home` 显示 `/root/.codex`；迁移后显示 `/root/autodl-tmp/codex-home`。

也可单独检查代理：

```bash
/workspace/mihomo-server/scripts/mihomoctl status
/workspace/mihomo-server/scripts/mihomoctl health
```

## 启动无头任务

工作目录必须在 `/workspace` 内，并且必须是 Git 仓库。先将完整要求写入一个提示词文件：

```bash
install -d -m 0700 /workspace/prompts
vi /workspace/prompts/task.md
chmod 0600 /workspace/prompts/task.md
```

只读分析：

```bash
codexctl exec task-001 \
  /workspace/你的项目 \
  /workspace/prompts/task.md \
  read-only
```

允许修改工作区：

```bash
codexctl exec task-002 \
  /workspace/你的项目 \
  /workspace/prompts/task.md \
  workspace-write
```

`NAME` 必须唯一，只允许字母、数字、点、下划线和短横线，最长 48 个字符。默认沙箱是 `read-only`。仅对可信项目使用 `workspace-write`；控制器不会使用跳过沙箱的危险参数。

如果 IDE 当前对话和无头任务可能同时修改代码，不要让它们共用同一个工作树。为可写任务创建独立 Git worktree。下面的命令只复制已经提交的 `HEAD`，不会带入 IDE 中尚未提交的修改；启动前先确认任务依赖的改动已进入你认可的提交基线：

```bash
mkdir -p /workspace/codex-worktrees
git -C /workspace/你的项目 worktree add \
  -b codex/task-002 \
  /workspace/codex-worktrees/task-002 \
  HEAD

codexctl exec task-002 \
  /workspace/codex-worktrees/task-002 \
  /workspace/prompts/task.md \
  workspace-write
```

只读任务可以与 IDE 使用同一仓库，但分析期间不要同时修改它正在读取的文件，否则结论可能基于变化中的内容。一个工作树同一时间只保留一个可写者。

启动命令返回后，可以断开 SSH 或关闭本地电脑。查询状态：

```bash
codexctl status
codexctl status task-001
codexctl list
```

可能的状态：

- `running`：任务仍在运行。
- `completed`：成功完成。
- `failed`：Codex 或代理检查失败。
- `interrupted`：runner 已记录中断，或 Screen 消失后由 `status` 临时推断。后者不表示
  `exit-code`、`ended-at` 等终态元数据已经完整落盘。
- `conflict`：存在同名但无法确认归属的 Screen；先人工检查，不要盲目终止。

查询状态和恢复任务时，控制器只会自动清理由自己生成、名称精确匹配且标记为 `(Dead ???)` 的 Screen，不会清理其他会话。

## 查看结果和日志

```bash
codexctl result task-001
codexctl logs task-001 final
codexctl logs task-001 progress
codexctl logs task-001 proxy
codexctl logs task-001 screen
```

`result` 输出最新 attempt 的完整最终回复。`logs` 不指定类型时默认显示 `progress`，每类日志最多显示末尾 120 行。

文件实际保存在：

```text
/root/autodl-tmp/codex-headless/jobs/<NAME>/attempts/<NNNN>/
```

其中包括：

- `prompt.txt`：该轮提示词副本。
- `events.jsonl`：Codex 的 JSONL 事件流。
- `final.md`：最终回复。
- `session-id`：恢复会话使用的内部 ID。
- `progress.log`、`proxy-check.log`、`screen.log`：诊断日志。
- `state`、`exit-code` 和时间戳：运行状态。

任务目录和文件仅允许 root 读取。原始 `events.jsonl` 仍会保存以支持恢复，但不通过常用日志命令输出，因为其中可能包含会话 ID、代码、命令和工具结果。日志和提示词也可能包含其他敏感信息，不要提交到 Git 或公开分享。

## 继续同一会话

创建后续提示词：

```bash
vi /workspace/prompts/followup.md
chmod 0600 /workspace/prompts/followup.md
```

恢复：

```bash
codexctl resume task-001 /workspace/prompts/followup.md
```

控制器使用保存的准确会话 ID，新建下一个 attempt，并沿用原工作目录与沙箱。即使上一次任务没有正常执行退出清理，只要 `events.jsonl` 已包含 `thread.started`，控制器也会尝试找回会话 ID。控制器会阻止自己管理的同一任务并发运行；仍不要在 IDE 或裸 `codex` 命令中同时恢复该会话。

服务器重启不会从中间指令位置自动续跑。重启后先运行 `codexctl doctor` 和
`codexctl status task-001`；后者可能根据 Screen 消失临时显示 `interrupted`，并不表示
退出元数据已经完整落盘。保持 IDE 关闭，再使用 `resume` 创建新 attempt。

## 在当前 IDE 对话与独立无头任务之间切换

如果不要求把后台记录写回同一个聊天，推荐使用两个独立会话：

1. 当前 VS Code 对话作为前台协调会话。
2. 用 `codexctl exec NAME ...` 创建独立无头任务。
3. 启动命令返回后直接回到当前 IDE 对话；无头任务在 Screen 中继续。
4. 用 `codexctl status NAME` 查看进度，用 `codexctl result NAME` 读取结果。
5. 需要无头任务继续沿用自己的上下文时，只用 `codexctl resume NAME ...`。
6. 需要把结果交给当前 IDE 对话时，粘贴 `result`，或让当前对话读取无头 worktree 中的 Git diff。

示例：

```bash
# 启动后台任务
codexctl exec audit-api \
  /workspace/你的项目 \
  /workspace/prompts/audit.md \
  read-only

# 此时可继续使用 VS Code 当前对话

# 稍后回收结果
codexctl status audit-api
codexctl result audit-api

# 继续后台任务原有上下文
codexctl resume audit-api /workspace/prompts/audit-followup.md
```

不要使用 `codex exec resume --last` 或 `codex resume --last` 管理无头任务：多个会话并行时可能选错最近会话。控制器始终使用保存的准确 ID，且不会显示它。

不要用裸 `codex resume` 打开受管无头任务；它会绕过任务锁、固定工作目录、sandbox 和 attempt 日志，造成控制器记录与真实会话分叉。对独立无头会话始终使用 `codexctl resume NAME ...`。

## 把现有 VS Code 对话转为无头任务，再转回在线

控制器支持按可见标题精确登记一个现有 `vscode` 根会话，并用同一 thread ID 续写。
因此，无头 turn 完成后会保留在原聊天记录里。这个切换只能串行进行：IDE 与无头
Codex 不能同时打开或写入同一个线程。

登记会话时，控制器会验证来源、根线程、历史格式、归档状态和 canonical rollout，
并创建一份 `0600` 的接管前 rollout 快照；它不会在普通状态输出中显示 thread ID。
无头续写固定使用登记时 IDE 的同版本 Codex 二进制，避免较新独立 CLI 写入后旧 IDE
无法读取。不要在一次往返过程中升级 VS Code Codex 扩展；版本检查失败时不要绕过。
上游 CLI 要求把精确 ID 作为其子进程的位置参数；控制器不会把它放入 Screen/runner
命令行或普通输出，但运行期间拥有服务器进程查看权限的用户仍可能从该 Codex 子进程
看到它。因此，这套配置按当前单用户 root 服务器设计，不应直接搬到不互信的多用户主机。

第一次执行此类接管前，必须完成下文的 `finalize-codex-home.sh`。随后流程如下：

1. 等待目标对话当前 turn 完全结束，保存工作区；关闭所有连接这台服务器的 VS Code
   Remote 窗口，并从命令面板运行
   `Remote-SSH: Kill VS Code Server on Host...`。
2. 从普通 SSH 登录，确认 `pgrep -x codex` 没有输出。
3. 精确登记并启动。`--add-dir` 可重复使用，但只能指定 `/workspace` 下的具体目录；
   `read-only` 不接受附加写目录。

```bash
codexctl stage-vscode-title NAME \
  /workspace/目标工作树 \
  '对话的完整可见标题' \
  /workspace/prompts/task.md \
  workspace-write \
  --add-dir /workspace/结果目录

codexctl start NAME
```

把示例中的 `NAME`、工作树、可见标题、提示词和结果目录替换成当前任务的真实值。
这些值会成为后续 `status`、`resume`、`chat` 和 `ide-ready` 命令的固定入口。

`workspace-write` 的无头 `exec/resume` 在当前 bridge CLI 中只传
`--approve-for-me`；该选项本身选择 workspace-write，并启用自动审查。不要再同时
拼接 `--sandbox workspace-write`，两者在当前 CLI 中互斥。只读任务仍显式使用
`--sandbox read-only`。

`stage-vscode-title` 只登记，不运行；只有 `start` 会创建后台 Screen。启动后不要重连
VS Code。可从普通 SSH 查看：

```bash
codexctl status NAME
codexctl logs NAME progress
codexctl result NAME
```

只有最新状态仍是 `staged` 时才能运行 `start`。若一次启动已经形成
`failed` 或 `interrupted` attempt，修复原因后应使用：

```bash
codexctl resume NAME /workspace/prompts/recovery.md
```

它会保留旧 attempt 并创建下一个编号；不要修改旧日志，也不要再次执行 `start`。
VS Code bridge 会固定保存同构建的主程序、`codex-code-mode-host`、`rg`、
`codex-package.json`、`bwrap` 和 `zsh`，并在每次启动前校验 root 私有权限与
SHA-256 清单。只复制主 `codex` 文件是不完整的。

### 为任务设计路径权限

| 路径 | 实际存储 | 对任务的边界 |
| --- | --- | --- |
| `/workspace/PROJECT` | 容器 overlay | 主工作区，`workspace-write` 时可写 |
| `/workspace/RESULT_DIR` | 取决于服务器挂载 | 通过 `--add-dir` 明确附加可写 |
| `/root/autodl-tmp/models`、`datasets` | 数据盘 XFS | 如任务需要，仅作为输入读取 |
| `/root/autodl-tmp/results` | 数据盘 XFS | 仅在确需写入时使用具体子目录授权 |
| `/root/autodl-tmp/codex-home`、`codex-headless` | 数据盘 XFS | 由 Codex/runner 保存聊天和日志，不作为模型写目录 |

目录名称不能证明它位于数据盘；用 `findmnt -T PATH` 核对真实挂载，并在运行前执行
`df -h /workspace /workspace/RESULT_DIR /root/autodl-tmp` 检查剩余空间。
不要把整个 `/root/autodl-tmp`、`codex-home` 或 `codex-headless` 加为
`--add-dir`。

部分容器禁止 `bwrap` 创建 user namespace。若 workspace-write 的第一次本地沙箱执行
因此失败，应确认 `--approve-for-me` 随后对同一命令进行了自动审查和批准重试；没有
成功重试就应停止任务。这种环境不能被视为可对抗恶意代码的硬内核隔离。若需要该隔离，
应在宿主/容器层启用受支持的 user namespace，或把 Codex 放进具有精确只读/可写挂载的
外部容器；不要改用 `--dangerously-bypass-approvals-and-sandbox`。

任务结束或安全失败后，先检查是否可交还 IDE：

```bash
codexctl ide-ready NAME
```

只有输出 `ready` 后才重连 VS Code，然后从 Recent chats 打开原标题；同一个无头 turn
及其工具记录会出现在原对话。若列表尚未刷新，执行 `Developer: Reload Window`，不要
用 `--last` 猜测会话。

以后再次从在线转为无头，先写一个权限为 `0600` 的后续提示词，再重复“关闭 Remote、
Kill VS Code Server、确认无 Codex 进程”，然后执行：

```bash
codexctl resume NAME /workspace/prompts/followup.md
```

完成后仍用 `codexctl ide-ready NAME` 交还。服务器重启导致任务中断时，也先确认旧进程
和锁均已释放，再用同一条 `resume` 创建新 attempt。若需要 IDE 与后台同时工作，必须
使用两个会话和两个工作树，不能对同一个聊天做并发续写。

## 停止任务

独立 `exec` 任务需要应急停止时：

```bash
codexctl stop task-001
```

这是应急终止命令：它只会终止经过严格校验、属于该任务的 Screen，不会删除已有提示词、
日志或聊天文件，但正在生成的最后一段回复可能不完整。

对于接管自 VS Code 的任务，`stop` 不等同于正常的 Codex `turn/interrupt`，也不能
单独作为返回 IDE 的许可：

```bash
codexctl stop NAME
codexctl ide-ready NAME
```

只有第二条输出 `ready` 才能重连。常规交接优先等待任务自然结束。

## 可选：可重连的交互界面

如果以后需要 SSH 内的交互式 Codex：

```bash
codexctl tui interactive-001 /workspace/你的项目 workspace-write
codexctl attach interactive-001
```

在 Screen 内按 `Ctrl-A`，再按 `D`，即可分离而不结束 Codex。TUI 日志用 `codexctl logs interactive-001 screen` 查看。

## 一次性迁移 Codex 历史到数据盘

历史不能在 Codex 或 VS Code 仍写入时迁移或最终化。必须先结束当前对话，确认所有无头
任务均已结束；然后关闭 VS Code Remote 窗口，并在本地 VS Code 命令面板执行
`Remote-SSH: Kill VS Code Server on Host...`。重新从普通 SSH 登录服务器后执行：

```bash
codexctl status
pgrep -x codex
ls -l /root/autodl-tmp/codex-home/.migration-complete
```

`pgrep -x codex` 必须没有输出；若仍有进程，不要手工跳过保护检查，先找出仍连接服务器的
VS Code 窗口或 Screen 任务。这里不使用 `pgrep -af`，因为正在运行的恢复子进程命令行
可能含内部会话标识。

如果 `.migration-complete` 不存在，执行第一阶段迁移：

```bash
/workspace/codex-headless/scripts/migrate-codex-home.sh
```

如果该标记已经存在，不要重复运行迁移脚本，直接继续最终化。

若检测到任何 Codex 进程、正在运行的无头任务、另一迁移、残留的 stage 或空间不足，脚本会拒绝继续。迁移分为复制和最终化两步。第一步会：

1. 将 `/root/.codex` 复制到数据盘暂存目录。
2. 校验文件数量、总字节数和逐文件内容。
3. 再次确认没有 Codex 进程。
4. 落盘并原子启用 `/root/autodl-tmp/codex-home`。
5. 将独立 Codex CLI 链接切换到数据盘副本。
6. 暂时保留原 `/root/.codex` 实体目录。

`.migration-complete` 存在后仍不要重连 VS Code。状态数据库里的旧线程可能保存了
`/root/.codex/...` 绝对 rollout 路径；仅设置 `CODEX_HOME` 并不能改变这些路径。继续
在同一个普通 SSH 会话运行：

```bash
/workspace/codex-headless/scripts/finalize-codex-home.sh
```

最终化脚本再次要求所有 Codex 进程退出，并独占迁移锁。它会检查两份 SQLite 索引和
所有会话 JSONL，只接受内容相同、单侧存在或一侧是另一侧严格字节前缀的情形；检测到
真正分叉会立即停止。它只把较完整的 rollout 原子归并到数据盘，不覆盖 SQLite、配置、
缓存或锁文件。随后把原实体目录改名保留为带时间戳的 rollback 目录，并原子安装
`/root/.codex -> /root/autodl-tmp/codex-home`。脚本不会删除回滚副本，重复运行只做验证。

完成后重新登录，或执行：

```bash
exec bash -l
codexctl doctor
```

确认出现：

```text
codex_home=/root/autodl-tmp/codex-home
codex_compat=ready
```

只有上述检查成功后才重新连接 VS Code；迁移期间不要让 Remote 自动重连。打开新的 Codex 对话后，可在服务器终端只读取 app-server 的 `CODEX_HOME`：

```bash
tr '\0' '\n' <"/proc/$(pgrep -n -x codex)/environ" | grep '^CODEX_HOME='
```

它也必须显示 `CODEX_HOME=/root/autodl-tmp/codex-home`。若不是，立即关闭该 VS Code Remote 窗口并再次 Kill VS Code Server，避免新旧历史分叉。

不要删除最终化脚本保留的 `/root/.codex.rollback.*`。先运行几次新任务并验证历史恢复；
如需释放系统盘空间，应在另一次明确的清理操作中进行。

## VS Code 的服务器代理检查

重启 VS Code Remote 后，应确认 `.bashrc`、`.profile`、Remote Machine 设置、
extensionHost 和 Codex app-server 全部使用服务器本地 `7890`，并检查活动配置和进程环境
中没有遗留的客户端映射端口（例如 `17890`）。只有完成这项检查，才能确认 IDE 对话不再
依赖本地 VPN 映射。

## 故障排查

代理异常：

```bash
/workspace/mihomo-server/scripts/mihomoctl status
/workspace/mihomo-server/scripts/mihomoctl health
/workspace/mihomo-server/scripts/mihomoctl logs
codexctl logs task-001 proxy
```

登录失效：

```bash
codex login --device-auth
codex login status
```

其他常见情况：

- `--sandbox ... cannot be used with --approve-for-me`：旧 runner 同时传了两个互斥
  参数。当前版本在 workspace-write 分支只应传 `--approve-for-me`；失败 attempt
  修复后用 `resume`，不能再用 `start`。
- `failed to spawn code-mode host ... No such file or directory`：bridge 副本不完整。
  主程序旁必须有经过清单校验的 `codex-code-mode-host`、`codex-path/rg`、`rg`、
  `codex-package.json` 和 `codex-resources`。不要从其他版本混拷。
- `bwrap: No permissions to create a new namespace`：这是当前容器内核限制。确认任务
  使用 `--approve-for-me` 且随后同一命令出现成功的重试；若没有重试或持续失败，
  停止任务并查看 `events.jsonl`，不要关闭全部审批与沙箱。
- 环境仍显示 `17890`：完整重启旧的 IDE/extensionHost 或重新登录 SSH。
- `任务已存在`：继续同一受管聊天时使用 `codexctl resume NAME PROMPT_FILE`；只有创建
  独立新任务时才换一个新名称。控制器默认不删除历史。
- `上一次任务仍在运行`：优先等待完成；必须应急终止时先阅读操作手册第 10 节，
  VS Code 接管任务执行 `stop` 后仍以 `ide-ready` 的 `ready` 为唯一重连条件；独立
  `exec` 任务不适用 `ide-ready`。
- `attach 必须在交互式终端`：通过正常的交互式 SSH 终端运行。
- Git 仓库错误：运行 `git -C /workspace/你的项目 status` 检查。
- `final` 不存在：任务尚未完成，先查看 `status` 和 `progress`。

`$CODEX_HOME/auth.json` 含认证令牌；迁移前是 `/root/.codex/auth.json`，迁移后是 `/root/autodl-tmp/codex-home/auth.json`。两者都应按密码文件保护，绝不能提交、粘贴或公开。

## 官方依据

- [OpenAI Docs：Codex App Server](https://learn.chatgpt.com/docs/app-server)：按 thread ID 恢复原线程、交互来源列表和线程生命周期。
- [OpenAI Docs：Non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)：`codex exec`、JSONL、最终消息文件、sandbox 与 `resume`。
- [OpenAI Docs：Authentication](https://learn.chatgpt.com/docs/auth)：CLI 登录和凭据保护。
- [OpenAI Docs：Environment variables](https://learn.chatgpt.com/docs/config-file/environment-variables)：`CODEX_HOME`。
- [OpenAI Docs：Codex CLI](https://learn.chatgpt.com/docs/codex/cli)：独立 CLI 安装和使用入口。
- [OpenAI Docs：Projects and chats](https://learn.chatgpt.com/docs/projects)：保存聊天、最近聊天与工作目录。
- [OpenAI Docs：Git worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)：并行任务的工作树隔离。

## 安装后冒烟测试

新服务器部署完成后，创建一个不含秘密的临时任务并验证：

- 首次 `codex exec` 返回预期文本。
- JSONL、最终回复和会话 ID 均保存到数据盘。
- 同一会话的 `resume` 返回预期文本，且会话 ID 一致。
- 首次执行和恢复 attempt 的代理检查均记录 `http=204` 和 `socks5h=204`。
- 所有任务文件权限均为 `0600`。

假设验证任务名为 `smoke-test`，可用以下命令检查：

```bash
codexctl status smoke-test
codexctl result smoke-test
codexctl logs smoke-test proxy
```
