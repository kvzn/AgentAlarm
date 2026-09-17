# 各 Coding Agent 的"等待人工"信号调研（2026-09-17）

目的：为 AgentAlarm（macOS 菜单栏提醒工具）确定每个 Agent 如何把"回合结束 / 等待授权 / 向人提问"通知给外部程序，以及会话标题从哪里取。

验证方式：本机安装的 Claude Code 2.1.259、Codex CLI 0.146.0、Gemini CLI 0.31.0、OpenCode 1.18.18 通过二进制字符串、本地配置、本地会话文件核对；其余 Agent 仅查官方文档。标注"未验证"的条目请在实现时实测。

## 1. Claude Code（本机主用，入口以 claude-desktop 为主）

| 项目 | 事实 |
|---|---|
| Hook 事件 | `Stop`（每次回合结束）、`Notification`（matcher：`permission_prompt`、`idle_prompt`、`elicitation_dialog`、`elicitation_url_dialog`、`agent_needs_input`、`agent_completed`、`auth_success` 等）、`PermissionRequest`、`SessionStart/End`、`SubagentStop` 等 |
| Hook 类型 | `command`（stdin JSON）、`http`（POST JSON 到 URL）、`mcp_tool`、`prompt`、`agent`；支持 `async: true`、`timeout` |
| 配置位置 | `~/.claude/settings.json`（全局）、`.claude/settings.json`、`.claude/settings.local.json` |
| Payload 字段 | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`notification_type`、`permission_mode`、`stop_hook_active`；无标题、无最后一条消息 |
| 时序 | `permission_prompt` 在提示出现约 6s 后触发；`idle_prompt` 在回合结束约 60s 无输入后触发 |
| 客户端覆盖 | CLI、桌面 App（Claude.app，`com.anthropic.claudefordesktop`）、VS Code 扩展均执行 hooks；`claude -p` 不触发 Stop/Notification；`--bare` 跳过 hooks |
| 标题来源 | 不在 payload。本机验证：transcript JSONL 中有 `{"type":"custom-title","customTitle":"…","sessionId":"…"}` 记录（全库 3634 条），取最后一条即可；备选 `{"type":"last-prompt","lastPrompt":"…"}`。官方声明该格式为内部格式，可能随版本变化 |
| 宿主识别 | 记录里有 `entrypoint` 字段，本机取值 `claude-desktop`、`cli`；hook 进程可读环境变量 `CLAUDE_CODE_ENTRYPOINT`、`CLAUDE_SESSION_ID`、`CLAUDE_PROJECT_DIR` |
| 退出码语义 | 0 正常；2 阻断（Stop 时会让 Claude 继续工作）；其他为非阻断错误。提醒用 hook 必须始终返回 0 |

## 2. Codex CLI 0.146.0 / Codex 桌面版（ChatGPT.app，`com.openai.codex`）

| 项目 | 事实 |
|---|---|
| Hooks | `features hooks` = stable/true。事件：`SessionStart/End`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`PreCompact`、`PostCompact`、`Stop`、`SubagentStart/Stop`、`Interrupt` |
| Hook 配置 | `~/.codex/hooks.json` 或 `config.toml` 的 `[hooks]`；项目级 `.codex/hooks.json` 仅信任项目。**非托管 hooks 需在 TUI 里 `/hooks` 信任一次**，否则不执行 |
| Hook payload | stdin JSON：`session_id`（=thread id）、`transcript_path`、`cwd`、`hook_event_name`、`model`、`permission_mode`、`turn_id`；`Stop` 另有 `last_assistant_message`、`stop_hook_active`；`PermissionRequest` 有 `tool_name`、`tool_input`。支持 `async`、`timeout` |
| 缺口 | Agent 向用户提问（request_user_input）没有 hook 也没有 notify，见 openai/codex#45125；仅 app-server JSON-RPC 有 `item/tool/requestUserInput` |
| 旧版 notify | `config.toml` 的 `notify = [...]`，JSON 作为最后一个 argv 传入，fire-and-forget，仅 `agent-turn-complete`。**本机已被 Codex Computer Use 占用**，一个配置只能放一条命令 |
| TUI 通知 | `[tui] notifications`、`notification_method = auto/osc9/bel`、`notification_condition`；仅终端内可见 |
| 会话存储 | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`；`session_meta` 无标题；回合边界为 `event_msg` 的 `task_started`/`task_complete` |
| 标题来源 | `~/.codex/state_5.sqlite` 表 `threads`：`name`（用户命名，约 5% 会话有）、`title`（自动=首条用户消息，可能很长）、`first_user_message`、`cwd`、`source`（本机多为 `vscode`）；`~/.codex/session_index.jsonl` 为 `{id, thread_name, updated_at}`，只含命名过的线程 |
| 桌面版 | 文档称 hooks 在桌面版也执行，未实测；桌面版是否触发 notify 未验证 |

## 3. Gemini CLI 0.31.0

| 项目 | 事实 |
|---|---|
| Hooks | `~/.gemini/settings.json` 的 `hooks`；事件 `AfterAgent`（每回合模型最终回复后）、`Notification`（`notification_type` 仅 `ToolPermission`）、`SessionStart/End`、`BeforeAgent` 等 |
| Payload | `session_id`、`transcript_path`、`cwd`、`hook_event_name`、`timestamp`；`AfterAgent` 加 `prompt`、`prompt_response`、`stop_hook_active` |
| 注意 | hooks **同步**执行，`timeout` 单位毫秒，默认 60000；stdout 必须是纯 JSON 或为空；`gemini hooks migrate` 可从 Claude hooks 迁移 |
| 内置通知 | `general.enableNotifications`（仅 macOS，默认关）走 OSC 9 / BEL，覆盖 ask_user 提问，但只有终端能收到 |
| 标题来源 | `~/.gemini/tmp/<project-slug>/chats/session-*.json` 的 `summary` 字段，LLM 懒生成，可能缺失；备选首条用户消息 |
| 副作用提示 | 调研时运行 `gemini --list-sessions` 触发了 Gemini 自身的 30 天会话清理，删除了一个 2026-03-02 的过期 Jetpack 会话文件 |

## 4. OpenCode 1.18.18（含 OpenCode.app）

| 项目 | 事实 |
|---|---|
| 插件 | `~/.config/opencode/plugins/*.ts` 进程内 JS；`event` 钩子收 `session.idle {sessionID}`、`session.status`、`permission.asked`、`question.asked`、`session.updated {info.title}`；官方示例正是 `session.idle` 时 `osascript display notification` |
| HTTP/SSE | 每个 TUI 起本地 HTTP 服务，`GET /event` SSE 推同样事件；`GET /session/:id` 返回 `title` |
| 内置 | `tui.json` 的 `attention` 段支持通知与音效（question/permission/error/done） |
| 标题来源 | `~/.local/share/opencode/opencode.db` 表 `session.title`；插件内可用 `client.session.get()` 直接拿 |

## 5. 其他 Agent（仅文档，未本机验证）

| Agent | 机制 | 回合结束 / 授权 / 提问 | 标题 | 配置 |
|---|---|---|---|---|
| Cursor CLI | `stop` hook，stdin JSON | ✓ / ✗ / ✗ | `~/.cursor/chats/<hash>/<uuid>/store.db`（第三方说法） | `~/.cursor/hooks.json` |
| GitHub Copilot CLI | `agentStop` + 异步 `notification`（`agent_idle`、`permission_prompt`、`elicitation_dialog`）| ✓ / ✓ / ✓ | `~/.copilot/session-state/<id>/` | `~/.copilot/hooks/*.json` |
| Kiro CLI | `AgentStop` hook | ✓ / ✗ / ✗ | SQLite in `~/.kiro/` | `.kiro/hooks/*.json` |
| Amp | 插件 `agent.end`（`event.status`） | ✓ / 部分 / 部分 | 云端线程 | `~/.config/amp/plugins/` |
| Factory Droid | `Stop` + `Notification`（`idle_prompt`、`permission_prompt`、`elicitation_dialog`），与 Claude 同构 | ✓ / ✓ / ✓ | `~/.factory/sessions/*.jsonl` 头行 `title` | `~/.factory/hooks.json` |
| Aider | `--notifications-command`，无参数无 payload | 单一事件 | 无 | `.aider.conf.yml` |

## 6. macOS 侧可用能力（本机核对）

- 系统自带 `curl 8.7`（支持 `--unix-socket`）、`nc -U`、`jq`、`python3`、`osascript`。
- 框架：`ServiceManagement`（`SMAppService` 登录启动）、`AVFoundation`（`AVSpeechSynthesizer`）、`UserNotifications`、`Network`（`NWListener` 支持 Unix socket）。
- 中文语音：`Tingting`（zh_CN 标准）、`Meijia`（zh_TW）、`Sinji`（zh_HK）以及一组 Eddy/Flo/Reed 等新式语音；英文语音充足。
- Focus/勿扰状态没有公开 API；`~/Library/DoNotDisturb/DB/Assertions.json` 本机不存在，不可依赖。
- 已装宿主应用：Claude.app、ChatGPT.app（Codex）、Cursor.app、Visual Studio Code.app、OpenCode.app、iTerm.app、ZCode.app（`dev.zcode.app`）。

## 7. 对设计的直接结论

1. 主流 Agent 都收敛到"Claude Code 风格 hook：shell 命令 + stdin JSON"，且都有回合结束事件；授权/提问事件覆盖不齐，需按 Agent 做映射表。
2. 没有任何 Agent 把会话标题放进 hook payload，标题必须由提醒程序按 `session_id`/`transcript_path` 回查本地文件或数据库，并准备好退化到 `cwd` 项目名。
3. Codex 的 `notify` 是单值配置且已被占用，应走 hooks；hooks 需要用户在 TUI 信任一次。
4. 被动监听 transcript 文件的方案只能看到回合结束，看不到授权提示（授权在被回答前不写入文件），且格式全部是内部格式，只适合做兜底。
