# 凭据与运行数据

真实订阅、节点、认证和任务数据应保存在仓库外的私有目录。默认安装将代码、运行数据和 Codex 登录状态分开存放。

## 允许入库

- 源码、安装脚本、文档和固定版本校验值；
- `config/config.template.yaml`：只有通用监听和 provider 规则，不含实际节点；
- `config/provider.fixture.yaml`：仅包含无认证的 DIRECT 自测节点；
- 使用 `example.invalid` 或明确虚构值的测试样例。

## 禁止入库或打包

- 实际 `home/config.yaml`、provider 节点、`subscription.curl` 和订阅备份；
- `auth.json`、API key、令牌、SSH 私钥、Cookie 和真实 `.env`；
- 会话 ID、提示词、事件、结果、日志、数据库、PID 和运行备份；
- 安装生成的 `toolkit.env` 及其他机器私有配置。

`.gitignore` 不会保护已跟踪文件。检查时同时覆盖工作目录、忽略文件、Git 索引及历史提交；压缩包须检查成员内容。发布包只取 `packaging-files.txt` 明确列出的文件，不递归打包运行目录。

若发现已提交的真实凭据，先撤销或轮换，再处理完整 Git 历史；删除当前文件不能消除历史中的副本。审查输出只报告位置和类型，不回显凭据。

默认代理只监听本机回环地址，不开放 LAN、控制 API、TUN 或 Codex app-server 端口。
