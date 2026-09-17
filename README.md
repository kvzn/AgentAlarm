# AgentAlarm

macOS 菜单栏工具：Claude Code、Codex、Gemini CLI、OpenCode 的会话回合结束或等待人工时，播放提示音并语音播报"Agent 名 + 会话标题 + 状态"，菜单栏列出等待中的会话，点击跳回宿主应用。

## 构建与运行

依赖：Xcode 27、macOS 14+、XcodeGen（`brew install xcodegen`）。

```bash
swift test                                   # Core 单元测试（102 tests）
xcodegen generate                            # 生成 AgentAlarm.xcodeproj（不入库）
xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/AgentAlarm.app
```

App 启动后会在 `~/.local/bin/agentalarm` 建立指向 App 内 CLI（`AgentAlarm.app/Contents/Helpers/agentalarm`）的软链接。

## 接入 Agent

菜单栏 → 设置… → 接入，打开对应开关。App 会备份并改写：

| Agent | 写入位置 | 备注 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `hooks` | Stop、Notification、UserPromptSubmit、SessionEnd |
| Codex | `~/.codex/hooks.json` | 只提醒回合结束（Codex Desktop 对每次工具调用都会触发 `PermissionRequest`，无法区分是否真的在等你授权，所以不接该事件）。首次需信任：在终端启动一次 `codex`，启动时会弹出 "Hooks need review"，选 "Trust all and continue"（或随时输入 `/hooks`）；信任记录写在 `config.toml` 的 `[hooks.state]`，hooks 内容变化后要重新信任。Codex 桌面版与 VS Code 共用这份配置，信任后新开会话生效；不改 `config.toml` 的 `notify` |
| Gemini CLI | `~/.gemini/settings.json` 的 `hooks` | AfterAgent、Notification、BeforeAgent、SessionEnd |
| OpenCode | `~/.config/opencode/plugins/agentalarm.ts` | 插件自带会话标题 |

OpenCode 需要重启（或重新加载会话）才会加载新写入的插件。

首次接入会整体重写目标 JSON 文件（键按字母排序），因此纳入版本控制的 `settings.json` 会出现整文件 diff。

配置文件含注释时不会自动改写，界面会给出可复制的片段。接入页若显示"配置文件含注释且已包含 AgentAlarm 的 hooks"，App 不会自动改写该文件，卸载需手动删除 command 含 `/.local/bin/agentalarm` 的条目。备份在 `~/Library/Application Support/AgentAlarm/backups/`。

## 命令行

```bash
agentalarm test                 # 发一条测试提醒
agentalarm status               # App 是否在监听
agentalarm settings             # 打开设置窗口（菜单栏图标被隐藏时用这个）
agentalarm notify --agent MyBot --title "构建完成" --kind turn_complete
echo '<hook json>' | agentalarm hook claude
```

以上示例假设 `~/.local/bin` 已在 `PATH` 中；否则请用完整路径 `~/.local/bin/agentalarm`。

`hook` 与 `notify` 永远以 0 退出且无 stdout；`AGENTALARM_DEBUG=1` 时在 stderr 打印诊断。

## 排查

- `agentalarm status` 显示 unreachable：App 未运行，或 socket 文件 `~/Library/Application Support/AgentAlarm/agentalarm.sock` 被清理，重启 App。
- 没有播报：看 设置 → 通用 → 最近事件 里的 outcome；`silent: cooldown` 是同会话 10 秒内重复，`alert, speech suppressed` 是宿主在前台且你正在操作。
- 系统日志：`log show --last 10m --info --predicate 'subsystem == "com.jack.agentalarm"' --style compact`
- 标题不对：Claude 读 transcript 的 `custom-title`，Codex 读 `~/.codex/state_N.sqlite` 的 `threads.name`，都属内部格式，解析失败时退化为项目目录名。
- 用 `pkill` 或强制退出 App 时 socket 文件会残留，下次启动会自动清理；从菜单"退出 AgentAlarm"退出则会立即删除。
- 看不到菜单栏图标：带刘海的 MacBook 上菜单栏放不下时，macOS 会整体隐藏新加入的状态项，提醒功能不受影响。App 检测到图标被隐藏会发一次横幅（未授权通知时改为语音播报），设置页顶部也会常驻提示；腾出菜单栏空间后图标自动出现。此时可用 `agentalarm settings` 打开设置窗口。
- 改了 hook 模板后想让配置跟上：重新接入（关闭再打开开关）是刷新 hook 模板的方式，已存在的条目不会被自动改写。

## 文档

- 设计规格：`docs/superpowers/specs/2026-09-17-agentalarm-design.md`
- 调研：`docs/research/2026-09-17-agent-notification-survey.md`
- 验收清单：`docs/acceptance-checklist.md`
