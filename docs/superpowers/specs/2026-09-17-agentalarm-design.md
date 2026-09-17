# AgentAlarm 设计规格（v1）

日期：2026-09-17
状态：已按 2026-09-17 讨论中的推荐项定稿，待实现计划。
调研依据：`docs/research/2026-09-17-agent-notification-survey.md`。

## 1. 目标与非目标

**目标。** 一个 macOS 菜单栏应用。当 Claude Code、Codex、Gemini CLI、OpenCode 任一会话回合结束、等待授权或向人提问时，播放提示音并用语音播报"Agent 名 + 会话标题 + 状态"，让人及时回到对应会话。菜单栏列出当前等待中的会话，点击可跳到宿主应用。

**v1 范围。** 四个 Agent：Claude Code、Codex、Gemini CLI、OpenCode，外加一个通用 `agentalarm notify` 命令供任意脚本或未来的 Agent 调用。宿主覆盖 CLI、桌面 App（Claude.app、ChatGPT.app 即 Codex 桌面版、OpenCode.app）和 IDE 扩展（VS Code、Cursor）。

**非目标（v1 明确不做）。** 播报回复摘要；其他 Agent 的内置适配器；Developer ID 签名、公证、自动更新、App Store；Windows 或 Linux；系统 Focus 状态感知；远程或手机推送；被动监听会话文件的兜底方案。

**已确认的决策。**

| 决策 | 结论 |
|---|---|
| 播报规则 | 提示音总是播放；宿主应用在前台且用户 10 秒内有键鼠操作时跳过语音 |
| 播报内容 | 只报 Agent 名和标题，不读回复 |
| 播报语言 | 中文模板，Agent 名保留英文，默认语音 Tingting，可换任意已安装语音 |
| 分发方式 | 自用，本地签名，从 Xcode 构建运行 |
| 配置改写 | App 自动写入各 Agent 的 hook 配置，先备份，可一键卸载 |

## 2. 总体架构

三个组件，一个仓库。

```
Agent 进程（hook 触发）
   │  stdin JSON 或 --payload
   ▼
agentalarm CLI  ──归一化、识别宿主──▶  Unix socket（一行 JSON）
                                            │
                                            ▼
                                   AgentAlarm.app
                                   去重合并 → 标题解析 → 策略判断
                                   → 提示音 + 语音 + 横幅 + 菜单栏列表
```

- **AgentAlarm.app**：SwiftUI `MenuBarExtra` 应用，`LSUIElement = true`，无 Dock 图标。负责 socket 服务、策略、输出、设置、hook 安装。
- **agentalarm CLI**：命令行工具，随 App 打包在 `AgentAlarm.app/Contents/Helpers/agentalarm`（默认 APFS 卷大小写不敏感，`Contents/MacOS/agentalarm` 会与 App 主可执行文件冲突）。App 每次启动时在 `~/.local/bin/agentalarm` 建立或修复指向它的软链接。各 Agent 的 hook 配置引用软链接的绝对路径。
- **AgentAlarmCore**：Swift Package，纯逻辑无 UI，被 App 和 CLI 共同链接。包含事件模型、适配器、标题解析器、提醒策略、配置安装器。

App 未运行时 CLI 连接 socket 失败，直接丢弃事件并以 0 退出，因为此时提醒没有意义。

## 3. 统一事件模型

CLI 与 App 之间、以及 App 内部统一使用下面的事件。字段用 camelCase，JSON 一行，UTF-8。

```json
{
  "v": 1,
  "id": "3F2A…",
  "agent": "claude",
  "kind": "turn_complete",
  "sessionId": "684ec27a-…",
  "turnId": null,
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "transcriptPath": "/Users/jack/.claude/projects/…/684ec27a-….jsonl",
  "title": null,
  "message": null,
  "host": { "bundleId": "com.anthropic.claudefordesktop", "pid": 6445, "name": "Claude" },
  "timestamp": "2026-09-17T03:00:00Z",
  "source": { "hookEventName": "Stop", "notificationType": null, "entrypoint": "claude-desktop" }
}
```

字段约定：

| 字段 | 含义 |
|---|---|
| `agent` | `claude`、`codex`、`gemini`、`opencode`，或 `notify` 命令传入的任意小写标识 |
| `kind` | `turn_complete`、`needs_permission`、`needs_input`、`idle_reminder`、`resumed`、`ended` |
| `sessionId` | Agent 自己的会话或线程 id；通用命令未提供时由 CLI 生成一个随机 id |
| `title` | 发送方已知的标题，否则为 null，由 App 解析 |
| `message` | 最后一条回复或授权说明的前 200 字，只用于菜单展示，不播报 |
| `host` | CLI 沿父进程链找到的第一个 `.app`，找不到为 null |
| `source` | 原始事件名等调试信息 |

前四种 `kind` 会触发提醒。`resumed` 表示用户已回复，`ended` 表示会话结束，二者只用于维护等待列表，从不提醒。

Agent 显示名固定：`claude` → Claude Code，`codex` → Codex，`gemini` → Gemini CLI，`opencode` → OpenCode。通用命令的显示名取 `--agent` 原文。

## 4. agentalarm CLI

子命令：

| 命令 | 行为 |
|---|---|
| `agentalarm hook <agent>` | 从 stdin 读原始 hook payload，或从 `--payload <json>` 读。按第 6 节映射为统一事件并发送。无对应映射的原始事件直接忽略 |
| `agentalarm notify --agent <名> --kind <kind> [--title] [--session-id] [--cwd] [--message]` | 通用入口，`--kind` 默认 `turn_complete` |
| `agentalarm test [--agent claude]` | 发送一条合成的 `turn_complete`，标题为"测试提醒"，用于验证链路 |
| `agentalarm status` | 输出 socket 是否可连接，退出码 0 或 1 |
| `agentalarm --version` | 版本号 |

硬性约束：

- `hook` 与 `notify` 总是以 0 退出，包括 payload 解析失败和 socket 不可用，避免 Claude 显示 hook 错误或 Gemini 把 stdout 当 JSON 解析失败。
- stdout 不输出任何内容。stderr 仅在环境变量 `AGENTALARM_DEBUG=1` 时输出诊断。
- 整体自我超时 1 秒：读 stdin、找宿主、连 socket、写入、等待对端关闭，任一步超时即放弃并以 0 退出。正常路径目标在 50 毫秒内完成，因为 Gemini 的 hook 是同步阻塞的。

**宿主识别。** 从自身父进程开始沿 `getppid` 链向上，用 `proc_pidpath` 取每个祖先的可执行路径，命中第一个包含 `.app/Contents/` 的路径即为宿主，用 `Bundle(path:)` 读 bundle id 和名称。到 pid 1 仍未命中则 `host` 为 null。Claude 桌面 App、VS Code、Cursor、iTerm、OpenCode.app 都能被这条规则识别。

## 5. 传输协议

- 路径：`~/Library/Application Support/AgentAlarm/agentalarm.sock`，目录权限 0700，socket 权限 0600。
- 协议：客户端连接后写入一行 JSON 加换行，然后关闭写端；服务端解析后关闭连接。没有响应体。
- App 启动时删除残留的 socket 文件再监听；退出时删除。
- 实现：优先 `Network.framework` 的 `NWListener` 绑定 `NWEndpoint.unix`；若该路径在目标系统上不可用，改用 BSD socket 加 `DispatchSource`。协议本身与实现无关。
- 服务端对单条消息上限 64 KB，超出丢弃并记录日志。

## 6. Agent 适配器

每个适配器由三部分组成：hook 配置模板、原始事件到统一事件的映射、标题解析。前两部分在 CLI 与安装器中，标题解析在 App 中。下文配置示例里的 `/Users/jack` 代表安装时展开的实际 HOME 路径。

### 6.1 Claude Code

配置文件 `~/.claude/settings.json`，写入以下条目，命令中的路径为安装时展开的绝对路径。

```json
{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook claude", "async": true, "timeout": 5 }] }],
    "Notification": [{ "matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input", "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook claude", "async": true, "timeout": 5 }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook claude", "async": true, "timeout": 5 }] }],
    "SessionEnd": [{ "matcher": "", "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook claude", "timeout": 1 }] }]
  }
}
```

映射：

| 原始事件 | 统一 kind |
|---|---|
| `Stop`，且 payload 无 `agent_id` | `turn_complete` |
| `Stop`，有 `agent_id`（子代理） | 忽略 |
| `Notification` / `permission_prompt` | `needs_permission` |
| `Notification` / `idle_prompt` | `idle_reminder` |
| `Notification` / `elicitation_dialog`、`elicitation_url_dialog`、`agent_needs_input` | `needs_input` |
| `Notification` / 其他 | 忽略 |
| `UserPromptSubmit` | `resumed` |
| `SessionEnd` | `ended` |

`source.entrypoint` 取环境变量 `CLAUDE_CODE_ENTRYPOINT`。

标题解析：从 `transcriptPath` 文件末尾向前读最多 512 KB，按行扫描，取最后一条 `{"type":"custom-title"}` 的 `customTitle`；没有则取最后一条 `{"type":"last-prompt"}` 的 `lastPrompt` 前 40 字；再没有则退化到 `cwd` 目录名。

改判规则：`Stop` 事件解析 transcript 时，若最后一条 `assistant` 记录的 `message.content` 里含 `tool_use` 且 `name` 为 `AskUserQuestion`，则把 kind 改为 `needs_input`。解析失败一律保持 `turn_complete`。

### 6.2 Codex

配置文件 `~/.codex/hooks.json`，不动 `config.toml` 里已被 Codex Computer Use 占用的 `notify`。

```json
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook codex", "timeout": 5 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook codex", "timeout": 5 }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook codex", "timeout": 5 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook codex", "timeout": 2 }] }]
  }
}
```

Codex 0.146 实测会跳过带 `async` 的 hook（提示 "async hooks are not supported yet"），因此四个事件全部同步执行，不写 `async` 键；CLI 在几十毫秒内返回，不影响回合。

映射：

| 原始事件 | 统一 kind | message |
|---|---|---|
| `Stop` | `turn_complete` | `last_assistant_message` 前 200 字 |
| `PermissionRequest` | `needs_permission` | `tool_name`，若 `tool_input.command` 存在则附上 |
| `UserPromptSubmit` | `resumed` | |
| `SessionEnd` | `ended` | |
| 其他 | 忽略 | |

Codex 向用户提问没有 hook，v1 接受该缺口。

信任步骤：Codex 只执行用户在 TUI 中用 `/hooks` 信任过的非托管 hooks。安装后 App 在该 Agent 的状态区显示提示"在任一 Codex 终端会话中运行 /hooks 并信任 AgentAlarm"，直到 App 收到第一条 Codex 事件后自动变为"已验证"。

标题解析：只读打开 `~/.codex/state_*.sqlite` 中编号最大的文件，查询 `SELECT name, title, first_user_message FROM threads WHERE id = ?`。优先 `name`；否则取 `title` 首行前 40 字；查询失败时读 `~/.codex/session_index.jsonl` 中匹配 id 的 `thread_name`；仍无则 `cwd` 目录名。

### 6.3 Gemini CLI

配置文件 `~/.gemini/settings.json` 的 `hooks` 键。Gemini 的 `timeout` 单位是毫秒，hook 同步执行。

```json
{
  "hooks": {
    "AfterAgent": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook gemini", "timeout": 3000 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook gemini", "timeout": 3000 }] }],
    "BeforeAgent": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook gemini", "timeout": 3000 }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "/Users/jack/.local/bin/agentalarm hook gemini", "timeout": 3000 }] }]
  }
}
```

映射：`AfterAgent` → `turn_complete`，message 取 `prompt_response` 前 200 字；`Notification`（`notification_type` 为 `ToolPermission`）→ `needs_permission`，message 取 `message`；`BeforeAgent` → `resumed`；`SessionEnd` → `ended`。

标题解析：读 `transcriptPath` 指向的 JSON，取顶层 `summary`；没有则取 `messages` 中第一条 `type` 为 `user` 的文本前 40 字；再没有则 `cwd` 目录名。

### 6.4 OpenCode

安装器生成插件文件 `~/.config/opencode/plugins/agentalarm.ts`，首行含标记注释 `// AgentAlarm plugin v1, managed by AgentAlarm.app`。插件行为：

- 监听 `event` 钩子。`session.idle` → `turn_complete`；`permission.asked` → `needs_permission`，message 取 `permission`；`question.asked` → `needs_input`；`session.status` 且 `status.type` 为 `busy` → `resumed`。
- 每个事件先用 `client.session.get` 取会话；若会话有 `parentID` 则视为子代理会话，忽略；否则把 `title`、`directory` 与事件一起组成 JSON，通过 `--payload` 参数调用 `/Users/jack/.local/bin/agentalarm hook opencode`。
- 所有调用包在 try/catch 中，插件永不抛错。

CLI 的 `opencode` 适配器直接接收插件已归一化的 `kind`、`sessionID`、`title`、`directory`，标题无需再解析；缺失时 `cwd` 目录名。

### 6.5 通用命令

`agentalarm notify` 直接构造统一事件，`title` 缺失时 App 用 `cwd` 目录名，`cwd` 也缺失时标题为 Agent 显示名本身。

## 7. 标题解析器（App 内）

- Claude 与 Gemini 按 `(agent, sessionId)` 缓存结果并记录文件修改时间，文件变化时重新解析；Codex 不缓存，每次重新查询，成本可忽略，且能跟上用户改名。
- 解析在后台队列执行，预算 1 秒，超时或出错即用退化标题并记录日志，不阻塞提醒。
- 播报用标题截断到 40 字，菜单展示截断到 80 字，均在字素边界截断并加省略号。
- 所有内部格式的解析都必须容错：字段缺失、文件不存在、schema 变更时退化而不是失败。

## 8. 提醒策略

按事件到达顺序在单一串行队列上执行。

1. **维护等待列表。** `turn_complete`、`needs_permission`、`needs_input` 把该 `(agent, sessionId)` 标为等待中并记录 kind 与时间；`idle_reminder` 在条目存在时只更新时间，不存在时新建条目并把 kind 记为 `turn_complete`；`resumed` 与 `ended` 移除该条目。条目 24 小时后自动过期，列表最多 50 条，超出丢弃最旧的。
2. **去重。** 相同 `(agent, sessionId, kind)` 在 3 秒内重复到达，只保留第一条。
3. **会话冷却。** 同一 `(agent, sessionId)` 在 10 秒内只提醒一次，其余只更新列表。
4. **重复提醒开关。** `idle_reminder` 仅在设置"重复提醒"开启时提醒，关闭时只维护列表。默认开启。
5. **暂停与静音时段。** 处于暂停期或静音时段内，只更新列表和菜单栏计数，不出声。暂停可选 15、30、60 分钟或直到手动恢复。静音时段为每天一个时间区间，默认关闭。
6. **提示音。** 每批提醒播放一次，按 kind 选音效。
7. **语音抑制。** 若事件 `host.bundleId` 等于当前前台应用的 bundle id，且用户最近一次键鼠事件距今不到 10 秒，则跳过语音，只播提示音。前台应用取 `NSWorkspace.shared.frontmostApplication`，键鼠空闲时长取 `CGEventSource.secondsSinceLastEventType`。`host` 为 null 时不抑制。阈值可在设置里改。
8. **合并播报。** 语音队列在开始播报时若积压两条或更多，合并为一句："有 N 个会话在等待：A，B，C"，最多列三个标题，其余用"等"。单条按模板播报。
9. **系统横幅。** 每条提醒发一条 `UNUserNotificationCenter` 通知，标题为"Agent 显示名 · 状态短语"，正文为会话标题，横幅不带系统声音。点击横幅激活宿主应用，宿主信息随通知的 userInfo 携带。默认开启。App 首次启动时请求通知权限，被拒绝时横幅功能静默关闭并在设置页说明。

播报模板：

| kind | 模板 |
|---|---|
| `turn_complete` | "{Agent}，{标题}，已完成" |
| `needs_permission` | "{Agent}，{标题}，需要授权" |
| `needs_input` | "{Agent}，{标题}，有问题要问你" |
| `idle_reminder` | "{Agent}，{标题}，还在等你" |

## 9. 输出与界面

**提示音。** 三段内置短音效对应完成、授权、提问，`idle_reminder` 复用完成音。可为每种改选 `/System/Library/Sounds` 里的系统音。音量 0 到 1，独立于系统音量，用 `NSSound` 播放。

**语音。** `AVSpeechSynthesizer`。默认语音为 zh-CN Tingting，可在已安装语音中任选；语速可调，默认系统默认速率。播报串行，不打断正在播报的句子。

**菜单栏。** `MenuBarExtra` 菜单样式，图标为铃铛符号，等待数大于 0 时在图标旁显示数字。菜单内容自上而下：等待中的会话列表，每行显示"Agent 显示名 · 标题 · 状态短语 · 等待时长"，点击激活对应宿主应用并把该行标为已查看，已查看只改变显示样式为灰色，不影响任何提醒规则；暂停子菜单；"测试提醒"；"设置…"；"退出"。

激活宿主：优先按 `host.pid` 找 `NSRunningApplication` 并 `activate`；进程已不存在则按 `host.bundleId` 找同 id 的运行中应用；都没有则不做任何事。

**设置窗口** 分四页：

- 接入：四个 Agent 各一行，显示状态（未接入、已接入、待信任、已验证、配置含注释需手动）与开关；下方显示 CLI 软链接状态与"修复"按钮。
- 声音与语音：三种音效选择与试听、音量、语音选择、语速、横幅开关。
- 规则：语音抑制开关与阈值、重复提醒开关、静音时段。
- 通用：登录时启动（`SMAppService`）、最近事件日志（最近 100 条，含原始事件与解析结果）。

## 10. 配置安装器

- 对象为 JSON 文件的 Agent（Claude、Codex、Gemini）：读取并解析为字典，保留所有未知键；对每个事件数组追加我们的 hook 组，若已存在则不重复；写前把原文件复制到 `~/Library/Application Support/AgentAlarm/backups/<文件名>.<时间戳>`，保留最近 10 份；写入时先写临时文件再原子替换。文件不存在时创建。
- 识别自有条目的规则：hook 的 `command` 字符串包含 `/.local/bin/agentalarm hook <agent>`。卸载时精确移除这些条目，事件数组变空则删除该键，`hooks` 变空则删除 `hooks` 键。
- 文件内含 `//` 或 `/*` 注释时拒绝自动改写，状态显示"配置含注释需手动"，并提供可复制的配置片段。
- OpenCode：写入插件文件；卸载时仅在首行标记匹配时删除。
- 软链接：App 每次启动检查 `~/.local/bin/agentalarm` 是否指向当前 bundle 内的 CLI，不是则重建，目录不存在则创建。
- 状态判定：文件中存在自有条目为"已接入"；App 曾收到该 Agent 的事件为"已验证"，该状态持久化，卸载该 Agent 时清除；Codex 在"已接入"且未验证时显示"待信任"。

## 11. 持久化

全部使用 `UserDefaults`，键名前缀 `aa.`：音效与音量、语音标识、语速、横幅开关、抑制开关与阈值、重复提醒开关、静音时段、各 Agent 已验证标记、登录启动状态。等待列表与事件日志仅存内存，重启即清空。

## 12. 错误处理与日志

- CLI 永不让 hook 失败，见第 4 节。
- App 收到无法解析的行：记录并丢弃。标题解析失败：退化并记录。语音或音效失败：记录，不影响列表与横幅。安装器失败：保留原文件，界面显示错误与备份路径。
- 日志用 `os.Logger`，subsystem `com.jack.agentalarm`，分类 `socket`、`policy`、`title`、`installer`、`output`。

## 13. 技术栈与工程结构

- Swift 6，SwiftUI 为主，AppKit 用于激活应用、音效与前台判断；系统 SQLite3 只读；`AVFoundation`、`UserNotifications`、`ServiceManagement`、`Network`。无第三方运行时依赖。
- 最低系统 macOS 14。非沙盒，Hardened Runtime 开启，本地开发签名。
- 开发期依赖：XcodeGen 用于从 `project.yml` 生成工程；Swift Testing 作为测试框架。
- App bundle id `com.jack.agentalarm`；CLI 无独立 bundle。

```
AgentAlarm/
  Package.swift                 AgentAlarmCore 库与其测试，可用 swift test 单独跑
  Sources/AgentAlarmCore/
    Events/                     统一事件模型与编解码
    Adapters/                   claude、codex、gemini、opencode、generic 的映射
    Titles/                     各 Agent 标题解析器
    Policy/                     去重、冷却、合并、抑制，时钟与前台状态可注入
    Installer/                  JSON 合并、备份、卸载、插件文件、软链接
    Transport/                  socket 客户端与服务端的编解码
  Tests/AgentAlarmCoreTests/
    Fixtures/                   录制的真实 payload 与样本会话文件
  App/                          SwiftUI 菜单栏应用
  CLI/                          agentalarm 可执行程序，仅参数解析与进程链识别
  project.yml                   XcodeGen 描述，生成 AgentAlarm.xcodeproj，xcodeproj 不入库
  docs/
```

App 与 CLI 两个 target 均依赖本地 package `AgentAlarmCore`；App target 的 Copy Files 阶段把 CLI 产物复制到 `Contents/Helpers/`（默认 APFS 卷大小写不敏感，`Contents/MacOS/agentalarm` 会与 App 主可执行文件冲突）。

## 14. 测试策略

- **适配器**：每个 Agent 的每种原始事件各一份 fixture，断言映射后的 kind、message、忽略规则，子代理事件被忽略。
- **标题解析**：Claude 用含 `custom-title` 与不含的两份 transcript 样本；Codex 在测试中用相同 schema 子集建临时 sqlite；Gemini 用含 `summary` 与不含的两份 JSON；全部覆盖文件缺失与格式损坏时的退化。
- **策略**：注入假时钟与假前台状态，覆盖去重、冷却、合并句式、抑制、暂停、静音时段、列表过期。
- **安装器**：在临时 HOME 下测试新建、合并进已有 hooks、重复安装幂等、卸载后语义等价原文件、含注释文件被拒绝、软链接修复。
- **传输**：CLI 与服务端在临时 socket 路径上做端到端往返，以及 App 未运行时 CLI 仍以 0 退出且在 1 秒内返回。
- **手工验收清单**：Claude 桌面 App 与 CLI 各触发完成、授权、提问；Codex 在 VS Code 与 TUI 各触发完成与授权并完成信任；Codex 桌面版是否触发 hooks；Gemini 完成与授权；OpenCode TUI 与 OpenCode.app 各触发完成、授权、提问；宿主在前台时语音被抑制；点击横幅与菜单项能跳回宿主。

## 15. 风险与应对

| 风险 | 应对 |
|---|---|
| Claude transcript 与 Codex sqlite 是内部格式，可能随版本变化 | 解析器容错退化；fixture 标注来源版本；日志记录退化原因 |
| Codex hooks 需要用户信任一次，且桌面版是否执行未实测 | 界面持续提示直到收到首条事件；验收清单包含桌面版 |
| Codex 向用户提问无 hook | v1 接受缺口，等待上游 |
| Gemini hook 同步且 stdout 必须为空 | CLI 不输出、1 秒自我超时 |
| `~/.local/bin` 软链接在 App 移动后失效 | 每次启动修复；接入页显示状态 |
| Gemini 或 Claude 配置文件含注释会被 JSON 重写破坏 | 检测到注释即拒绝自动改写并给出手动片段 |
| Claude.app 与 Codex 桌面版自带横幅，可能重复 | 横幅开关默认开，可关闭 |

## 16. 里程碑

1. Core 包：事件模型、四个适配器、标题解析器、策略，全部带测试。
2. CLI 与 socket 传输，App 骨架能收事件并出声播报，菜单栏列表可用。
3. 安装器与设置窗口，四个 Agent 一键接入与卸载。
4. 手工验收清单全部通过，修补细节。
