# Codex 无头任务

通过 GNU Screen 运行 Codex，SSH 断开后继续执行，并保存结果和准确会话 ID。安装及公共配置见 [根目录说明](../README.md)。

## 命令速查

| 命令 | 作用 |
| --- | --- |
| `codexctl login --device-auth` | 经本机代理进行设备登录 |
| `codexctl login status` | 检查当前登录状态 |
| `codexctl doctor` | 检查代理、登录、CLI 版本和数据路径 |
| `codexctl exec NAME WORKDIR PROMPT_FILE [sandbox]` | 创建后台任务，默认 `read-only` |
| `codexctl tui NAME WORKDIR [sandbox]` | 创建可重连的交互终端，默认 `workspace-write` |
| `codexctl resume NAME PROMPT_FILE` | 按已保存的会话 ID 继续任务，创建新 attempt |
| `codexctl status [NAME]` / `codexctl list` | 查看一个或全部任务的状态 |
| `codexctl chat NAME [--follow]` | 查看助手消息，或持续跟随到终态 |
| `codexctl result NAME` | 查看最终回复 |
| `codexctl logs NAME [screen\|progress\|final\|proxy]` | 查看对应日志，默认 `progress` |
| `codexctl attach NAME` | 重连任务 Screen；`Ctrl-A`、`D` 脱离 |
| `codexctl stop NAME` | 停止归属验证通过的任务 |
| `codexctl stage-vscode-title NAME WORKDIR '精确标题' PROMPT_FILE [sandbox] [--add-dir DIR ...]` | 登记 IDE 会话，不启动；默认 `workspace-write` |
| `codexctl start NAME` | 启动已登记的 IDE 会话 |
| `codexctl ide-ready NAME` | 检查会话能否安全返回 IDE |

`NAME` 为 1–48 个字母、数字、点、下划线或短横线；提示词文件为 1 字节到 2 MiB，须仅属主可读。sandbox 仅支持 `read-only`、`workspace-write`。普通后台任务要求工作目录位于 Git 仓库。

## 辅助脚本

脚本位于安装目录 `codex-headless/scripts/`，读取相同的机器配置：

| 脚本及参数 | 作用 |
| --- | --- |
| `resume-when-ide-ready.sh NAME PROMPT_FILE [TIMEOUT_SECONDS]` | 等待 IDE writer lock 释放，全部检查通过后只调用一次恢复 |
| `retry-recoverable-attempt.sh NAME PROMPT_FILE BASE_ATTEMPT [MAX_RETRIES] [TIMEOUT_SECONDS]` | 监视后续 attempt，对识别出的网络或用量失败最多重试两次 |
| `migrate-codex-home.sh` | 可选：复制历史到 `CODEX_MIGRATED_HOME`，保留源目录 |
| `finalize-codex-home.sh` | 可选：校验迁移副本，合并允许的会话差异并安装兼容链接 |

## 运行示例

代理初始化完成后：

```bash
codexctl login --device-auth
codexctl doctor
printf '%s\n' '阅读仓库并总结结构。' > /tmp/task-prompt.txt
chmod 600 /tmp/task-prompt.txt
codexctl exec inspect /path/to/repository /tmp/task-prompt.txt read-only
codexctl chat inspect --follow
codexctl result inspect
codexctl resume inspect /tmp/task-prompt.txt
```

需要修改工作目录时选择 `workspace-write`。返回 `started` 表示后台运行，`completed` 表示已完成；每次恢复保留独立提示词、日志、结果和退出码。运行中的任务或会话 writer lock 未释放时，禁止并发恢复。

API key 用户通过标准输入登录：

```bash
printenv OPENAI_API_KEY | codexctl login --with-api-key
```

显式 `CODEX_HOME` 优先；否则使用配置的 `CODEX_DEFAULT_HOME`。现有登录和历史可以直接复用。认证方式见 [官方说明](https://learn.chatgpt.com/docs/auth)。

## VS Code 会话接管

此功能另需 `sqlite3`、`rg` 和服务器上的 Codex 扩展。先在 IDE 中停止当前生成，使线程释放 writer lock，再按精确标题登记和启动：

```bash
codexctl stage-vscode-title bridge /path/to/repository '精确标题' /tmp/task-prompt.txt workspace-write
codexctl start bridge
codexctl chat bridge --follow
# 回到 IDE 前：
codexctl ide-ready bridge
```

工具校验索引、rollout、writer lock 和匹配的扩展构建；无法唯一验证时拒绝接管。附加写目录仅允许 `workspace-write`，最多 32 个，且须符合配置的工作范围；不能把整个根目录作为附加写目录。普通 `exec`、`resume` 不依赖 IDE 扩展。

## 数据与可选迁移

任务保存在 `CODEX_HEADLESS_DATA_DIR/jobs/NAME/attempts/0001`，包括状态、JSONL 事件、进度、最终回复、会话 ID 和退出码。CLI 登录和历史保存在 `CODEX_HOME`，不应放入源码或发布包。

正常使用无需迁移。确需搬迁历史时，设置源 `CODEX_DEFAULT_HOME`、目标 `CODEX_MIGRATED_HOME`，退出同一用户的所有 Codex 进程，然后依次运行迁移与最终化脚本。迁移需要 rsync，源大小之外预留 5 GiB；最终化支持原工具的 `state_5.sqlite` 校验格式，不兼容或无法安全归并时拒绝处理。旧实体目录保留为 rollback 副本，位置记录在私有兼容标记中。

非交互执行及会话恢复见 [官方说明](https://learn.chatgpt.com/docs/non-interactive-mode)。
