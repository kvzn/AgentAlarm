# AgentAlarm v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 构建 macOS 菜单栏应用 AgentAlarm：Claude Code、Codex、Gemini CLI、OpenCode 的会话回合结束或等待人工时，播放提示音并语音播报"Agent 名 + 会话标题 + 状态"，菜单栏列出等待中的会话。

**Architecture:** 三个组件：纯逻辑 Swift Package `AgentAlarmCore`（事件模型、适配器、标题解析、策略、安装器、socket 编解码）、命令行工具 `agentalarm`（各 Agent 的 hook 调用它，它把 payload 归一化后经 Unix socket 推给 App）、SwiftUI `MenuBarExtra` 应用 `AgentAlarm.app`（socket 服务端、策略执行、声音/语音/横幅输出、设置与一键接入）。Core 用 `swift test` 测试；App 与 CLI 由 XcodeGen 生成的工程用 `xcodebuild` 构建。

**Tech Stack:** Swift 6（语言模式 6，严格并发）、SwiftUI + AppKit、AVFoundation（`AVSpeechSynthesizer`）、UserNotifications、ServiceManagement、系统 SQLite3、BSD Unix socket、Swift Testing、XcodeGen 2.46。无第三方运行时依赖。

**Spec:** `docs/superpowers/specs/2026-09-17-agentalarm-design.md`

## Global Constraints

- 最低系统 macOS 14；Swift 6；非沙盒；Hardened Runtime 开启；本地 ad hoc 签名（`CODE_SIGN_IDENTITY: "-"`）。
- App bundle id `com.jack.agentalarm`；CLI 位于 `AgentAlarm.app/Contents/MacOS/agentalarm`；软链接 `~/.local/bin/agentalarm`。
- Socket 路径 `~/Library/Application Support/AgentAlarm/agentalarm.sock`，目录 0700，socket 0600；协议为一行 JSON 加换行；单条上限 64 KB。
- CLI 的 `hook` 与 `notify` 永远以 0 退出，stdout 不输出任何内容，stderr 仅在 `AGENTALARM_DEBUG=1` 时输出，整体自我超时 1 秒。
- 统一事件字段与 `kind` 取值：`turn_complete`、`needs_permission`、`needs_input`、`idle_reminder`、`resumed`、`ended`。
- Agent 显示名：`claude` → Claude Code，`codex` → Codex，`gemini` → Gemini CLI，`opencode` → OpenCode。
- 播报模板："{Agent}，{标题}，已完成 / 需要授权 / 有问题要问你 / 还在等你"；合并句式"有 N 个会话在等待：A，B，C"，最多三个标题，超出加"等"。
- 策略常量：去重窗口 3 秒；会话冷却 10 秒；等待条目 24 小时过期；列表上限 50；语音抑制阈值 10 秒；标题播报截断 40 字，展示截断 80 字，字素边界加"…"；message 截断 200 字。
- `UserDefaults` 键前缀 `aa.`；`os.Logger` subsystem `com.jack.agentalarm`，category 为 `socket`、`policy`、`title`、`installer`、`output`。
- 配置文件含 `//` 或 `/*` 注释（字符串外）时拒绝自动改写。
- 自有 hook 条目识别标记：command 字符串包含 `/.local/bin/agentalarm hook <agent>`。
- Codex 只写 `~/.codex/hooks.json`，不碰 `config.toml` 的 `notify`。
- 本计划相对 spec 的四处已决定的实现取舍：传输层直接用 BSD socket（spec 允许在 `NWListener` 不合适时改用）；三种默认提示音使用系统自带的 Glass、Ping、Purr，不打包音频文件，用户仍可按 kind 改选任意系统音；菜单里"已查看"的条目用"✓ "前缀标记而不是灰色文字，因为菜单样式的 `MenuBarExtra` 不支持给单个菜单项着色；CLI 的命令逻辑放在 Core 的 `CLI/CLICommands.swift` 以便 `swift test` 覆盖，`CLI/main.swift` 只做入口与超时。

## File Structure

```
AgentAlarm/
  Package.swift                       AgentAlarmCore 库 + 测试；swift test 可独立运行
  project.yml                         XcodeGen：AgentAlarm（application）与 agentalarm（tool）两个 target
  .gitignore
  Sources/AgentAlarmCore/
    Events/AlarmEvent.swift           AlarmEvent、EventKind、HostInfo、EventSource、EventCoding
    Events/AgentNames.swift           displayName(for:)
    Support/TextTruncation.swift      字素安全截断
    Support/JSONAccess.swift          [String: Any] 取值扩展
    Support/SQLiteReader.swift        只读 sqlite 单行查询
    Support/ProcessTree.swift         父进程链与宿主 .app 识别
    Adapters/HookAdapter.swift        协议 + AdapterContext + AdapterRegistry
    Adapters/ClaudeAdapter.swift
    Adapters/CodexAdapter.swift
    Adapters/GeminiAdapter.swift
    Adapters/OpenCodeAdapter.swift
    Titles/TitleResolution.swift      TitleResolution、FallbackTitle
    Titles/ClaudeTitleResolver.swift
    Titles/CodexTitleResolver.swift
    Titles/GeminiTitleResolver.swift
    Titles/TitleService.swift         按 agent 分发 + 缓存
    Policy/Clock.swift
    Policy/WaitingList.swift
    Policy/AlertPolicy.swift
    Policy/SpeechComposer.swift
    Installer/HookTemplates.swift
    Installer/JSONHookInstaller.swift
    Installer/OpenCodePluginInstaller.swift
    Installer/SymlinkInstaller.swift
    Installer/AgentPaths.swift
    Installer/AgentIntegrationManager.swift
    Transport/SocketClient.swift
    Transport/SocketServer.swift
  Tests/AgentAlarmCoreTests/
    Fixtures/*.json, *.jsonl          录制的 payload 与样本会话
    TestSupport.swift                 fixture 加载、临时目录
    <每个源文件对应一个测试文件>
  CLI/
    main.swift                        入口、1 秒超时
    Commands.swift                    hook / notify / test / status / --version
  App/
    AgentAlarmApp.swift               @main、MenuBarExtra、Settings 场景、AppDelegate
    AppModel.swift                    事件管线：列表、策略、输出、日志
    AppSettings.swift                 UserDefaults 包装
    IntegrationStore.swift            接入状态与开关
    ActivityMonitor.swift             前台应用与键鼠空闲
    HostActivator.swift               激活宿主
    Outputs/SoundPlayer.swift
    Outputs/SpeechQueue.swift
    Outputs/BannerCenter.swift
    Views/MenuContent.swift
    Views/SettingsView.swift          四页设置
  docs/acceptance-checklist.md        手工验收清单
  README.md
```

---

### Task 1: 工程脚手架与 Core 测试基线

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/AgentAlarmCore/AgentAlarmCore.swift`
- Create: `Tests/AgentAlarmCoreTests/TestSupport.swift`
- Create: `Tests/AgentAlarmCoreTests/SmokeTests.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/.keep`

**Interfaces:**
- Produces: 测试辅助 `func fixtureData(_ name: String) throws -> Data`、`func fixtureJSON(_ name: String) throws -> [String: Any]`、`func makeTempDirectory() throws -> URL`，后续所有测试都用它们。

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentAlarmCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentAlarmCore", targets: ["AgentAlarmCore"]),
    ],
    targets: [
        .target(
            name: "AgentAlarmCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AgentAlarmCoreTests",
            dependencies: ["AgentAlarmCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: 写 .gitignore**

```
.build/
build/
*.xcodeproj
.swiftpm/
xcuserdata/
DerivedData/
.DS_Store
```

- [ ] **Step 3: 写库占位文件与测试辅助**

`Sources/AgentAlarmCore/AgentAlarmCore.swift`:

```swift
/// AgentAlarmCore：AgentAlarm 的纯逻辑层。
public enum AgentAlarmCoreInfo {
    public static let version = "0.1.0"
}
```

`Tests/AgentAlarmCoreTests/TestSupport.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

enum TestSupportError: Error { case fixtureMissing(String) }

func fixtureURL(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw TestSupportError.fixtureMissing(name)
    }
    return url
}

func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtureURL(name))
}

func fixtureJSON(_ name: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: fixtureData(name))
    return try #require(object as? [String: Any])
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentalarm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

`Tests/AgentAlarmCoreTests/SmokeTests.swift`:

```swift
import Testing
@testable import AgentAlarmCore

@Test func packageBuildsAndTestsRun() {
    #expect(AgentAlarmCoreInfo.version == "0.1.0")
}
```

创建空文件 `Tests/AgentAlarmCoreTests/Fixtures/.keep`（保证资源目录存在）。

- [ ] **Step 4: 运行测试确认基线通过**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 1 tests in 0 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "chore: scaffold AgentAlarmCore package with test baseline"
```

---

### Task 2: 统一事件模型与编解码

**Files:**
- Create: `Sources/AgentAlarmCore/Events/AlarmEvent.swift`
- Create: `Sources/AgentAlarmCore/Events/AgentNames.swift`
- Create: `Sources/AgentAlarmCore/Support/TextTruncation.swift`
- Create: `Sources/AgentAlarmCore/Support/JSONAccess.swift`
- Test: `Tests/AgentAlarmCoreTests/AlarmEventTests.swift`
- Test: `Tests/AgentAlarmCoreTests/TextTruncationTests.swift`

**Interfaces:**
- Produces:
  - `enum EventKind: String, Codable, Sendable, CaseIterable` 六个 case，`var isAlerting: Bool`
  - `struct HostInfo: Codable, Sendable, Equatable { bundleId: String; pid: Int32; name: String }`
  - `struct EventSource: Codable, Sendable, Equatable { hookEventName: String?; notificationType: String?; entrypoint: String? }`
  - `struct AlarmEvent: Codable, Sendable, Equatable` 字段见下，`init(id:agent:kind:sessionId:turnId:cwd:transcriptPath:title:message:host:timestamp:source:)` 带默认值
  - `enum EventCoding { static func encode(_:) throws -> Data; static func decode(_:) throws -> AlarmEvent }` 单行 JSON，键排序，ISO8601 时间
  - `enum AgentNames { static func displayName(for agent: String) -> String }`
  - `enum TextTruncation { static func truncate(_ text: String, to maxGraphemes: Int) -> String; static func firstLine(_ text: String) -> String }`
  - `extension Dictionary where Key == String, Value == Any { func string(_ key: String) -> String?; func dictionary(_ key: String) -> [String: Any]?; func array(_ key: String) -> [Any]?; func bool(_ key: String) -> Bool? }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/AlarmEventTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AlarmEventTests {
    @Test func roundTripsThroughSingleLineJSON() throws {
        let event = AlarmEvent(
            id: "E1", agent: "claude", kind: .turnComplete, sessionId: "S1",
            turnId: nil, cwd: "/Users/jack/Workspaces/AgentAlarm",
            transcriptPath: "/Users/jack/.claude/projects/x/S1.jsonl",
            title: nil, message: "done",
            host: HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 42, name: "Claude"),
            timestamp: Date(timeIntervalSince1970: 1_789_600_000),
            source: EventSource(hookEventName: "Stop", notificationType: nil, entrypoint: "claude-desktop"))
        let data = try EventCoding.encode(event)
        let line = try #require(String(data: data, encoding: .utf8))
        #expect(!line.contains("\n"))
        #expect(line.hasPrefix("{\"agent\":\"claude\""))
        #expect(line.contains("\"kind\":\"turn_complete\""))
        #expect(line.contains("\"timestamp\":\"2026-09-17T"))
        let decoded = try EventCoding.decode(data)
        #expect(decoded == event)
    }

    @Test func defaultsFillIdVersionAndTimestamp() {
        let event = AlarmEvent(agent: "codex", kind: .needsPermission, sessionId: "S2")
        #expect(event.v == 1)
        #expect(!event.id.isEmpty)
        #expect(abs(event.timestamp.timeIntervalSinceNow) < 5)
        #expect(event.source == EventSource())
    }

    @Test func alertingKinds() {
        #expect(EventKind.turnComplete.isAlerting)
        #expect(EventKind.needsPermission.isAlerting)
        #expect(EventKind.needsInput.isAlerting)
        #expect(EventKind.idleReminder.isAlerting)
        #expect(!EventKind.resumed.isAlerting)
        #expect(!EventKind.ended.isAlerting)
    }

    @Test func displayNames() {
        #expect(AgentNames.displayName(for: "claude") == "Claude Code")
        #expect(AgentNames.displayName(for: "codex") == "Codex")
        #expect(AgentNames.displayName(for: "gemini") == "Gemini CLI")
        #expect(AgentNames.displayName(for: "opencode") == "OpenCode")
        #expect(AgentNames.displayName(for: "MyBot") == "MyBot")
    }

    @Test func decodeRejectsUnknownKind() {
        let bad = Data("{\"v\":1,\"id\":\"x\",\"agent\":\"a\",\"kind\":\"nope\",\"sessionId\":\"s\",\"timestamp\":\"2026-09-17T00:00:00Z\",\"source\":{}}".utf8)
        #expect(throws: (any Error).self) { try EventCoding.decode(bad) }
    }
}
```

`Tests/AgentAlarmCoreTests/TextTruncationTests.swift`:

```swift
import Testing
@testable import AgentAlarmCore

@Suite struct TextTruncationTests {
    @Test func shortTextUnchanged() {
        #expect(TextTruncation.truncate("你好", to: 40) == "你好")
    }
    @Test func longTextCutAtGraphemeWithEllipsis() {
        let text = String(repeating: "字", count: 50)
        let cut = TextTruncation.truncate(text, to: 40)
        #expect(cut.count == 41)
        #expect(cut.hasSuffix("…"))
    }
    @Test func combinedEmojiNotSplit() {
        let flag = "👨‍👩‍👧"
        let text = "ab" + flag + "cd"
        #expect(TextTruncation.truncate(text, to: 3) == "ab" + flag + "…")
    }
    @Test func firstLineTrimsWhitespace() {
        #expect(TextTruncation.firstLine("  第一行 \n第二行") == "第一行")
        #expect(TextTruncation.firstLine("\n\n只有一行") == "只有一行")
    }
    @Test func jsonAccessHelpers() {
        let dict: [String: Any] = ["a": "x", "b": ["c": 1], "d": [1, 2], "e": true]
        #expect(dict.string("a") == "x")
        #expect(dict.string("zz") == nil)
        #expect(dict.dictionary("b")?["c"] as? Int == 1)
        #expect(dict.array("d")?.count == 2)
        #expect(dict.bool("e") == true)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test 2>&1 | grep -E "error:|passed|failed" | head`
Expected: 编译错误 `cannot find 'AlarmEvent' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Events/AlarmEvent.swift`:

```swift
import Foundation

public enum EventKind: String, Codable, Sendable, CaseIterable {
    case turnComplete = "turn_complete"
    case needsPermission = "needs_permission"
    case needsInput = "needs_input"
    case idleReminder = "idle_reminder"
    case resumed
    case ended

    public var isAlerting: Bool {
        switch self {
        case .resumed, .ended: return false
        default: return true
        }
    }
}

public struct HostInfo: Codable, Sendable, Equatable {
    public var bundleId: String
    public var pid: Int32
    public var name: String
    public init(bundleId: String, pid: Int32, name: String) {
        self.bundleId = bundleId; self.pid = pid; self.name = name
    }
}

public struct EventSource: Codable, Sendable, Equatable {
    public var hookEventName: String?
    public var notificationType: String?
    public var entrypoint: String?
    public init(hookEventName: String? = nil, notificationType: String? = nil, entrypoint: String? = nil) {
        self.hookEventName = hookEventName; self.notificationType = notificationType; self.entrypoint = entrypoint
    }
}

public struct AlarmEvent: Codable, Sendable, Equatable {
    public var v: Int
    public var id: String
    public var agent: String
    public var kind: EventKind
    public var sessionId: String
    public var turnId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var title: String?
    public var message: String?
    public var host: HostInfo?
    public var timestamp: Date
    public var source: EventSource

    public init(id: String = UUID().uuidString,
                agent: String,
                kind: EventKind,
                sessionId: String,
                turnId: String? = nil,
                cwd: String? = nil,
                transcriptPath: String? = nil,
                title: String? = nil,
                message: String? = nil,
                host: HostInfo? = nil,
                timestamp: Date = Date(),
                source: EventSource = EventSource()) {
        self.v = 1
        self.id = id; self.agent = agent; self.kind = kind; self.sessionId = sessionId
        self.turnId = turnId; self.cwd = cwd; self.transcriptPath = transcriptPath
        self.title = title; self.message = message; self.host = host
        self.timestamp = timestamp; self.source = source
    }
}

public enum EventCoding {
    public static func encode(_ event: AlarmEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> AlarmEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AlarmEvent.self, from: data)
    }
}
```

`Sources/AgentAlarmCore/Events/AgentNames.swift`:

```swift
public enum AgentNames {
    public static let supported = ["claude", "codex", "gemini", "opencode"]

    public static func displayName(for agent: String) -> String {
        switch agent {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "gemini": return "Gemini CLI"
        case "opencode": return "OpenCode"
        default: return agent
        }
    }
}
```

`Sources/AgentAlarmCore/Support/TextTruncation.swift`:

```swift
public enum TextTruncation {
    /// 按字素截断，超出时追加"…"。
    public static func truncate(_ text: String, to maxGraphemes: Int) -> String {
        guard text.count > maxGraphemes else { return text }
        return String(text.prefix(maxGraphemes)) + "…"
    }

    /// 取第一行非空文本并去掉首尾空白。
    public static func firstLine(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
```

`Sources/AgentAlarmCore/Support/JSONAccess.swift`:

```swift
public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [Any]? { self[key] as? [Any] }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通过（11 个测试）

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat(core): add unified AlarmEvent model, coding, names and text helpers"
```

---

### Task 3: HookAdapter 协议与 Claude 适配器

**Files:**
- Create: `Sources/AgentAlarmCore/Adapters/HookAdapter.swift`
- Create: `Sources/AgentAlarmCore/Adapters/ClaudeAdapter.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-stop.json`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-notification-permission.json`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-user-prompt-submit.json`
- Test: `Tests/AgentAlarmCoreTests/ClaudeAdapterTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AlarmEvent`、`EventKind`、`HostInfo`、`EventSource`、`Dictionary.string(_:)`。
- Produces:
  - `struct AdapterContext: Sendable { environment: [String: String]; host: HostInfo?; now: Date }`，`init(environment: [String: String] = [:], host: HostInfo? = nil, now: Date = Date())`
  - `protocol HookAdapter { var agent: String { get }; func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? }`
  - `struct ClaudeAdapter: HookAdapter`，`init()`

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/claude-stop.json`:

```json
{
  "session_id": "684ec27a-38f2-4acd-8ac6-fa79aaaa0001",
  "transcript_path": "/Users/jack/.claude/projects/-Users-jack-Workspaces-AgentAlarm/684ec27a-38f2-4acd-8ac6-fa79aaaa0001.jsonl",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": false
}
```

`Tests/AgentAlarmCoreTests/Fixtures/claude-notification-permission.json`:

```json
{
  "session_id": "684ec27a-38f2-4acd-8ac6-fa79aaaa0001",
  "transcript_path": "/Users/jack/.claude/projects/-Users-jack-Workspaces-AgentAlarm/684ec27a-38f2-4acd-8ac6-fa79aaaa0001.jsonl",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "Notification",
  "notification_type": "permission_prompt",
  "message": "Claude needs your permission to use Bash"
}
```

`Tests/AgentAlarmCoreTests/Fixtures/claude-user-prompt-submit.json`:

```json
{
  "session_id": "684ec27a-38f2-4acd-8ac6-fa79aaaa0001",
  "transcript_path": "/Users/jack/.claude/projects/-Users-jack-Workspaces-AgentAlarm/684ec27a-38f2-4acd-8ac6-fa79aaaa0001.jsonl",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "继续"
}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/ClaudeAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ClaudeAdapterTests {
    let adapter = ClaudeAdapter()
    let context = AdapterContext(
        environment: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"],
        host: HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 7, name: "Claude"),
        now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func stopBecomesTurnComplete() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("claude-stop.json"), context: context))
        #expect(event.agent == "claude")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "684ec27a-38f2-4acd-8ac6-fa79aaaa0001")
        #expect(event.cwd == "/Users/jack/Workspaces/AgentAlarm")
        #expect(event.transcriptPath?.hasSuffix(".jsonl") == true)
        #expect(event.host?.bundleId == "com.anthropic.claudefordesktop")
        #expect(event.timestamp == context.now)
        #expect(event.source.hookEventName == "Stop")
        #expect(event.source.entrypoint == "claude-desktop")
        #expect(event.title == nil)
        #expect(event.message == nil)
    }

    @Test func subagentStopIsIgnored() throws {
        var payload = try fixtureJSON("claude-stop.json")
        payload["agent_id"] = "agent-123"
        payload["agent_type"] = "Explore"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }

    @Test func notificationTypesMap() throws {
        let base = try fixtureJSON("claude-notification-permission.json")
        let expectations: [(String, EventKind?)] = [
            ("permission_prompt", .needsPermission),
            ("idle_prompt", .idleReminder),
            ("elicitation_dialog", .needsInput),
            ("elicitation_url_dialog", .needsInput),
            ("agent_needs_input", .needsInput),
            ("auth_success", nil),
            ("agent_completed", nil),
        ]
        for (type, kind) in expectations {
            var payload = base
            payload["notification_type"] = type
            let event = adapter.map(payload: payload, context: context)
            #expect(event?.kind == kind, "notification_type \(type)")
            if kind != nil { #expect(event?.source.notificationType == type) }
        }
    }

    @Test func promptSubmitAndSessionEndAreNonAlerting() throws {
        let submit = try #require(adapter.map(payload: try fixtureJSON("claude-user-prompt-submit.json"), context: context))
        #expect(submit.kind == .resumed)
        var end = try fixtureJSON("claude-stop.json")
        end["hook_event_name"] = "SessionEnd"
        end["reason"] = "exit"
        #expect(adapter.map(payload: end, context: context)?.kind == .ended)
    }

    @Test func unknownHookOrMissingSessionIsIgnored() throws {
        var payload = try fixtureJSON("claude-stop.json")
        payload["hook_event_name"] = "PreToolUse"
        #expect(adapter.map(payload: payload, context: context) == nil)
        payload = try fixtureJSON("claude-stop.json")
        payload["session_id"] = nil
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter ClaudeAdapterTests 2>&1 | grep -E "error:|passed|failed" | head -3`
Expected: 编译错误 `cannot find 'ClaudeAdapter' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Adapters/HookAdapter.swift`:

```swift
import Foundation

/// 适配器运行时上下文：环境变量、CLI 识别到的宿主、当前时间。
public struct AdapterContext: Sendable {
    public var environment: [String: String]
    public var host: HostInfo?
    public var now: Date
    public init(environment: [String: String] = [:], host: HostInfo? = nil, now: Date = Date()) {
        self.environment = environment; self.host = host; self.now = now
    }
}

/// 把某个 Agent 的原始 hook payload 映射为统一事件；无对应映射时返回 nil。
public protocol HookAdapter {
    var agent: String { get }
    func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent?
}
```

`Sources/AgentAlarmCore/Adapters/ClaudeAdapter.swift`:

```swift
import Foundation

public struct ClaudeAdapter: HookAdapter {
    public let agent = "claude"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let notificationType = payload.string("notification_type")
        let kind: EventKind
        switch hookName {
        case "Stop":
            if payload["agent_id"] != nil { return nil }
            kind = .turnComplete
        case "Notification":
            switch notificationType {
            case "permission_prompt": kind = .needsPermission
            case "idle_prompt": kind = .idleReminder
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": kind = .needsInput
            default: return nil
            }
        case "UserPromptSubmit":
            kind = .resumed
        case "SessionEnd":
            kind = .ended
        default:
            return nil
        }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: payload.string("cwd"),
            transcriptPath: payload.string("transcript_path"),
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName,
                                notificationType: notificationType,
                                entrypoint: context.environment["CLAUDE_CODE_ENTRYPOINT"]))
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter ClaudeAdapterTests 2>&1 | tail -2`
Expected: 5 个测试通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Adapters Tests/AgentAlarmCoreTests/ClaudeAdapterTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add HookAdapter protocol and Claude Code adapter"
```

---

### Task 4: Codex 适配器

**Files:**
- Create: `Sources/AgentAlarmCore/Adapters/CodexAdapter.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/codex-stop.json`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/codex-permission-request.json`
- Test: `Tests/AgentAlarmCoreTests/CodexAdapterTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `HookAdapter`、`AdapterContext`；Task 2 的 `TextTruncation.truncate`。
- Produces: `struct CodexAdapter: HookAdapter`，`init()`；内部 `static func permissionSummary(_ payload: [String: Any]) -> String?`。

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/codex-stop.json`:

```json
{
  "session_id": "01a0ad46-6f14-76c2-9f9e-bfc71b6ea713",
  "transcript_path": "/Users/jack/.codex/sessions/2026/09/17/rollout-2026-09-17T10-51-09-01a0ad46-6f14-76c2-9f9e-bfc71b6ea713.jsonl",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "Stop",
  "model": "gpt-5-codex",
  "permission_mode": "default",
  "turn_id": "turn-0001",
  "stop_hook_active": false,
  "last_assistant_message": "Done. I updated the README and ran the tests."
}
```

`Tests/AgentAlarmCoreTests/Fixtures/codex-permission-request.json`:

```json
{
  "session_id": "01a0ad46-6f14-76c2-9f9e-bfc71b6ea713",
  "transcript_path": null,
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "PermissionRequest",
  "model": "gpt-5-codex",
  "permission_mode": "default",
  "turn_id": "turn-0002",
  "tool_name": "Bash",
  "tool_use_id": "call_01",
  "tool_input": { "command": "rm -rf build" }
}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/CodexAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct CodexAdapterTests {
    let adapter = CodexAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func stopCarriesLastMessageAndTurnId() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("codex-stop.json"), context: context))
        #expect(event.agent == "codex")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "01a0ad46-6f14-76c2-9f9e-bfc71b6ea713")
        #expect(event.turnId == "turn-0001")
        #expect(event.message == "Done. I updated the README and ran the tests.")
        #expect(event.transcriptPath?.contains("/.codex/sessions/") == true)
        #expect(event.source.hookEventName == "Stop")
    }

    @Test func longMessageIsTruncatedTo200() throws {
        var payload = try fixtureJSON("codex-stop.json")
        payload["last_assistant_message"] = String(repeating: "a", count: 500)
        let event = try #require(adapter.map(payload: payload, context: context))
        #expect(event.message?.count == 201)
        #expect(event.message?.hasSuffix("…") == true)
    }

    @Test func permissionRequestSummarisesTool() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("codex-permission-request.json"), context: context))
        #expect(event.kind == .needsPermission)
        #expect(event.message == "Bash: rm -rf build")
        #expect(event.transcriptPath == nil)
    }

    @Test func permissionRequestWithArrayCommandAndWithoutCommand() throws {
        var payload = try fixtureJSON("codex-permission-request.json")
        payload["tool_input"] = ["command": ["git", "push", "--force"]]
        #expect(adapter.map(payload: payload, context: context)?.message == "Bash: git push --force")
        payload["tool_input"] = ["path": "/tmp/x"]
        #expect(adapter.map(payload: payload, context: context)?.message == "Bash")
    }

    @Test func promptSubmitSessionEndAndUnknown() throws {
        var payload = try fixtureJSON("codex-stop.json")
        payload["hook_event_name"] = "UserPromptSubmit"
        #expect(adapter.map(payload: payload, context: context)?.kind == .resumed)
        payload["hook_event_name"] = "SessionEnd"
        #expect(adapter.map(payload: payload, context: context)?.kind == .ended)
        payload["hook_event_name"] = "SubagentStop"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter CodexAdapterTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'CodexAdapter' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Adapters/CodexAdapter.swift`:

```swift
import Foundation

public struct CodexAdapter: HookAdapter {
    public let agent = "codex"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let kind: EventKind
        var message: String?
        switch hookName {
        case "Stop":
            kind = .turnComplete
            if let last = payload.string("last_assistant_message"), !last.isEmpty {
                message = TextTruncation.truncate(last, to: 200)
            }
        case "PermissionRequest":
            kind = .needsPermission
            message = Self.permissionSummary(payload)
        case "UserPromptSubmit":
            kind = .resumed
        case "SessionEnd":
            kind = .ended
        default:
            return nil
        }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            turnId: payload.string("turn_id"),
            cwd: payload.string("cwd"),
            transcriptPath: payload.string("transcript_path"),
            message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName))
    }

    static func permissionSummary(_ payload: [String: Any]) -> String? {
        guard let tool = payload.string("tool_name"), !tool.isEmpty else { return nil }
        let input = payload.dictionary("tool_input") ?? [:]
        var command = input.string("command")
        if command == nil, let parts = input.array("command") as? [String] {
            command = parts.joined(separator: " ")
        }
        guard let command, !command.isEmpty else { return tool }
        return TextTruncation.truncate("\(tool): \(command)", to: 200)
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter CodexAdapterTests 2>&1 | tail -2`
Expected: 5 个测试通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Adapters/CodexAdapter.swift Tests/AgentAlarmCoreTests/CodexAdapterTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add Codex adapter"
```

---

### Task 5: Gemini CLI 适配器

**Files:**
- Create: `Sources/AgentAlarmCore/Adapters/GeminiAdapter.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/gemini-after-agent.json`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/gemini-notification.json`
- Test: `Tests/AgentAlarmCoreTests/GeminiAdapterTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `HookAdapter`、`AdapterContext`。
- Produces: `struct GeminiAdapter: HookAdapter`，`init()`。

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/gemini-after-agent.json`:

```json
{
  "session_id": "session-2026-09-17T03-00-abcd1234",
  "transcript_path": "/Users/jack/.gemini/tmp/agentalarm/chats/session-2026-09-17T03-00-abcd1234.json",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "AfterAgent",
  "timestamp": "2026-09-17T03:00:00.000Z",
  "prompt": "fix the bug",
  "prompt_response": "I fixed the bug in main.swift and added a test.",
  "stop_hook_active": false
}
```

`Tests/AgentAlarmCoreTests/Fixtures/gemini-notification.json`:

```json
{
  "session_id": "session-2026-09-17T03-00-abcd1234",
  "transcript_path": "/Users/jack/.gemini/tmp/agentalarm/chats/session-2026-09-17T03-00-abcd1234.json",
  "cwd": "/Users/jack/Workspaces/AgentAlarm",
  "hook_event_name": "Notification",
  "timestamp": "2026-09-17T03:00:05.000Z",
  "notification_type": "ToolPermission",
  "message": "Gemini wants to run: npm test",
  "details": {}
}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/GeminiAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct GeminiAdapterTests {
    let adapter = GeminiAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func afterAgentBecomesTurnComplete() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("gemini-after-agent.json"), context: context))
        #expect(event.agent == "gemini")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "session-2026-09-17T03-00-abcd1234")
        #expect(event.message == "I fixed the bug in main.swift and added a test.")
        #expect(event.transcriptPath?.hasSuffix(".json") == true)
        #expect(event.source.hookEventName == "AfterAgent")
    }

    @Test func notificationBecomesNeedsPermission() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("gemini-notification.json"), context: context))
        #expect(event.kind == .needsPermission)
        #expect(event.message == "Gemini wants to run: npm test")
        #expect(event.source.notificationType == "ToolPermission")
    }

    @Test func beforeAgentSessionEndAndUnknown() throws {
        var payload = try fixtureJSON("gemini-after-agent.json")
        payload["hook_event_name"] = "BeforeAgent"
        #expect(adapter.map(payload: payload, context: context)?.kind == .resumed)
        payload["hook_event_name"] = "SessionEnd"
        #expect(adapter.map(payload: payload, context: context)?.kind == .ended)
        payload["hook_event_name"] = "AfterTool"
        #expect(adapter.map(payload: payload, context: context) == nil)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter GeminiAdapterTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'GeminiAdapter' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Adapters/GeminiAdapter.swift`:

```swift
import Foundation

public struct GeminiAdapter: HookAdapter {
    public let agent = "gemini"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let sessionId = payload.string("session_id"), !sessionId.isEmpty,
              let hookName = payload.string("hook_event_name") else { return nil }
        let kind: EventKind
        var message: String?
        switch hookName {
        case "AfterAgent":
            kind = .turnComplete
            if let response = payload.string("prompt_response"), !response.isEmpty {
                message = TextTruncation.truncate(response, to: 200)
            }
        case "Notification":
            kind = .needsPermission
            message = payload.string("message").map { TextTruncation.truncate($0, to: 200) }
        case "BeforeAgent":
            kind = .resumed
        case "SessionEnd":
            kind = .ended
        default:
            return nil
        }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: payload.string("cwd"),
            transcriptPath: payload.string("transcript_path"),
            message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: hookName,
                                notificationType: payload.string("notification_type")))
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter GeminiAdapterTests 2>&1 | tail -2`
Expected: 3 个测试通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Adapters/GeminiAdapter.swift Tests/AgentAlarmCoreTests/GeminiAdapterTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add Gemini CLI adapter"
```

---

### Task 6: OpenCode 适配器与 AdapterRegistry

**Files:**
- Create: `Sources/AgentAlarmCore/Adapters/OpenCodeAdapter.swift`
- Modify: `Sources/AgentAlarmCore/Adapters/HookAdapter.swift`（追加 `AdapterRegistry`）
- Create: `Tests/AgentAlarmCoreTests/Fixtures/opencode-idle.json`
- Test: `Tests/AgentAlarmCoreTests/OpenCodeAdapterTests.swift`

**Interfaces:**
- Consumes: Task 3-5 的适配器。
- Produces:
  - `struct OpenCodeAdapter: HookAdapter`，`init()`。插件传来的 payload 形状：`{ "kind": "<统一 kind 原始值>", "sessionID": "...", "title": "...|null", "directory": "...|null", "message": "...|null" }`
  - `enum AdapterRegistry { static func adapter(for agent: String) -> (any HookAdapter)? }`

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/opencode-idle.json`:

```json
{
  "kind": "turn_complete",
  "sessionID": "ses_7f3a1b2c",
  "title": "Add login page",
  "directory": "/Users/jack/Workspaces/LovedVoice",
  "message": null
}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/OpenCodeAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct OpenCodeAdapterTests {
    let adapter = OpenCodeAdapter()
    let context = AdapterContext(now: Date(timeIntervalSince1970: 1_789_600_000))

    @Test func idleCarriesTitleAndDirectory() throws {
        let event = try #require(adapter.map(payload: try fixtureJSON("opencode-idle.json"), context: context))
        #expect(event.agent == "opencode")
        #expect(event.kind == .turnComplete)
        #expect(event.sessionId == "ses_7f3a1b2c")
        #expect(event.title == "Add login page")
        #expect(event.cwd == "/Users/jack/Workspaces/LovedVoice")
        #expect(event.message == nil)
        #expect(event.source.hookEventName == "plugin")
    }

    @Test func allKindsAcceptedEmptyTitleBecomesNil() throws {
        for kind in EventKind.allCases {
            var payload = try fixtureJSON("opencode-idle.json")
            payload["kind"] = kind.rawValue
            payload["title"] = ""
            let event = try #require(adapter.map(payload: payload, context: context))
            #expect(event.kind == kind)
            #expect(event.title == nil)
        }
    }

    @Test func unknownKindOrMissingSessionIgnored() throws {
        var payload = try fixtureJSON("opencode-idle.json")
        payload["kind"] = "session.idle"
        #expect(adapter.map(payload: payload, context: context) == nil)
        payload = try fixtureJSON("opencode-idle.json")
        payload["sessionID"] = nil
        #expect(adapter.map(payload: payload, context: context) == nil)
    }

    @Test func registryResolvesSupportedAgents() {
        #expect(AdapterRegistry.adapter(for: "claude")?.agent == "claude")
        #expect(AdapterRegistry.adapter(for: "codex")?.agent == "codex")
        #expect(AdapterRegistry.adapter(for: "gemini")?.agent == "gemini")
        #expect(AdapterRegistry.adapter(for: "opencode")?.agent == "opencode")
        #expect(AdapterRegistry.adapter(for: "cursor") == nil)
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter OpenCodeAdapterTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'OpenCodeAdapter' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Adapters/OpenCodeAdapter.swift`:

```swift
import Foundation

/// 接收 OpenCode 插件已经归一化过的 payload。
public struct OpenCodeAdapter: HookAdapter {
    public let agent = "opencode"
    public init() {}

    public func map(payload: [String: Any], context: AdapterContext) -> AlarmEvent? {
        guard let rawKind = payload.string("kind"), let kind = EventKind(rawValue: rawKind),
              let sessionId = payload.string("sessionID"), !sessionId.isEmpty else { return nil }
        let title = payload.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let message = payload.string("message").flatMap { $0.isEmpty ? nil : TextTruncation.truncate($0, to: 200) }
        return AlarmEvent(
            agent: agent, kind: kind, sessionId: sessionId,
            cwd: payload.string("directory"),
            title: title, message: message,
            host: context.host, timestamp: context.now,
            source: EventSource(hookEventName: "plugin"))
    }
}
```

在 `Sources/AgentAlarmCore/Adapters/HookAdapter.swift` 末尾追加：

```swift
public enum AdapterRegistry {
    public static func adapter(for agent: String) -> (any HookAdapter)? {
        switch agent {
        case "claude": return ClaudeAdapter()
        case "codex": return CodexAdapter()
        case "gemini": return GeminiAdapter()
        case "opencode": return OpenCodeAdapter()
        default: return nil
        }
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test 2>&1 | tail -2`
Expected: 全部通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Adapters Tests/AgentAlarmCoreTests/OpenCodeAdapterTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add OpenCode adapter and adapter registry"
```

---

### Task 7: TitleResolution、退化标题与 Claude 标题解析器

**Files:**
- Create: `Sources/AgentAlarmCore/Titles/TitleResolution.swift`
- Create: `Sources/AgentAlarmCore/Titles/ClaudeTitleResolver.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-titled.jsonl`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-untitled.jsonl`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-question.jsonl`
- Test: `Tests/AgentAlarmCoreTests/ClaudeTitleResolverTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AlarmEvent`、`AgentNames`、`TextTruncation`、`Dictionary` 取值扩展。
- Produces:
  - `enum TitleOrigin: String, Sendable { customTitle, lastPrompt, threadName, threadTitle, sessionIndex, summary, firstMessage, provided, cwd, agentName }`
  - `struct TitleResolution: Equatable, Sendable { title: String; origin: TitleOrigin; reclassifiedKind: EventKind? }`，`init(title:origin:reclassifiedKind:)` 第三参默认 nil
  - `enum FallbackTitle { static func resolve(_ event: AlarmEvent) -> TitleResolution }`：cwd 目录名，否则 Agent 显示名
  - `enum ProvidedTitleResolver { static func resolve(_ event: AlarmEvent) -> TitleResolution }`：`event.title` 非空则用它
  - `struct ClaudeTitleResolver: Sendable { init(maxTailBytes: Int = 524288); func resolve(_ event: AlarmEvent) -> TitleResolution }`，`reclassifiedKind` 在 transcript 最后一条 assistant 记录含 `AskUserQuestion` 调用时为 `.needsInput`（由调用方决定只对 `turn_complete` 生效）

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-titled.jsonl`（每行一条 JSON）：

```
{"type":"user","message":{"role":"user","content":"帮我设计一个提醒工具"},"sessionId":"S1","uuid":"u1","timestamp":"2026-09-17T03:00:00.000Z"}
{"type":"custom-title","customTitle":"旧标题","sessionId":"S1"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好的，我先调研。"}]},"sessionId":"S1","uuid":"a1","timestamp":"2026-09-17T03:00:05.000Z"}
{"type":"custom-title","customTitle":"AgentAlarm 设计","sessionId":"S1"}
{"type":"last-prompt","lastPrompt":"继续","leafUuid":"a1","sessionId":"S1"}
```

`Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-untitled.jsonl`：

```
{"type":"user","message":{"role":"user","content":"修复登录页面的崩溃问题\n附带日志"},"sessionId":"S2","uuid":"u1","timestamp":"2026-09-17T03:00:00.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"已修复。"}]},"sessionId":"S2","uuid":"a1","timestamp":"2026-09-17T03:00:05.000Z"}
{"type":"last-prompt","lastPrompt":"修复登录页面的崩溃问题\n附带日志","leafUuid":"a1","sessionId":"S2"}
```

`Tests/AgentAlarmCoreTests/Fixtures/claude-transcript-question.jsonl`：

```
{"type":"custom-title","customTitle":"数据库迁移","sessionId":"S3"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"先确认一下。"}]},"sessionId":"S3","uuid":"a1","timestamp":"2026-09-17T03:00:05.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"用哪个数据库？"}]}}]},"sessionId":"S3","uuid":"a2","timestamp":"2026-09-17T03:00:06.000Z"}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/ClaudeTitleResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ClaudeTitleResolverTests {
    func event(transcript: String?, cwd: String? = "/Users/jack/Workspaces/AgentAlarm", kind: EventKind = .turnComplete) -> AlarmEvent {
        AlarmEvent(agent: "claude", kind: kind, sessionId: "S", cwd: cwd, transcriptPath: transcript)
    }

    @Test func usesLastCustomTitle() throws {
        let path = try fixtureURL("claude-transcript-titled.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "AgentAlarm 设计")
        #expect(r.origin == .customTitle)
        #expect(r.reclassifiedKind == nil)
    }

    @Test func fallsBackToLastPromptFirstLineTruncated() throws {
        let path = try fixtureURL("claude-transcript-untitled.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "修复登录页面的崩溃问题")
        #expect(r.origin == .lastPrompt)
    }

    @Test func detectsAskUserQuestionInLastAssistantRecord() throws {
        let path = try fixtureURL("claude-transcript-question.jsonl").path
        let r = ClaudeTitleResolver().resolve(event(transcript: path))
        #expect(r.title == "数据库迁移")
        #expect(r.reclassifiedKind == .needsInput)
    }

    @Test func missingFileFallsBackToCwdName() {
        let r = ClaudeTitleResolver().resolve(event(transcript: "/nonexistent/x.jsonl"))
        #expect(r.title == "AgentAlarm")
        #expect(r.origin == .cwd)
        let r2 = ClaudeTitleResolver().resolve(event(transcript: nil, cwd: nil))
        #expect(r2.title == "Claude Code")
        #expect(r2.origin == .agentName)
    }

    @Test func onlyTailIsReadAndPartialFirstLineDropped() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("big.jsonl")
        var text = "{\"type\":\"custom-title\",\"customTitle\":\"很早的标题\",\"sessionId\":\"S\"}\n"
        text += "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"" + String(repeating: "长", count: 300_000) + "\"},\"sessionId\":\"S\"}\n"
        text += "{\"type\":\"custom-title\",\"customTitle\":\"最新标题\",\"sessionId\":\"S\"}\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
        let r = ClaudeTitleResolver(maxTailBytes: 64 * 1024).resolve(event(transcript: file.path))
        #expect(r.title == "最新标题")
        #expect(r.origin == .customTitle)
    }

    @Test func providedTitleAndFallback() {
        let with = AlarmEvent(agent: "opencode", kind: .turnComplete, sessionId: "S", cwd: "/x/Proj", title: "Add login")
        #expect(ProvidedTitleResolver.resolve(with) == TitleResolution(title: "Add login", origin: .provided))
        let without = AlarmEvent(agent: "opencode", kind: .turnComplete, sessionId: "S", cwd: "/x/Proj", title: "")
        #expect(ProvidedTitleResolver.resolve(without) == TitleResolution(title: "Proj", origin: .cwd))
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter ClaudeTitleResolverTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'ClaudeTitleResolver' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Titles/TitleResolution.swift`:

```swift
import Foundation

public enum TitleOrigin: String, Sendable, Equatable {
    case customTitle, lastPrompt, threadName, threadTitle, sessionIndex, summary, firstMessage, provided, cwd, agentName
}

public struct TitleResolution: Equatable, Sendable {
    public var title: String
    public var origin: TitleOrigin
    public var reclassifiedKind: EventKind?
    public init(title: String, origin: TitleOrigin, reclassifiedKind: EventKind? = nil) {
        self.title = title; self.origin = origin; self.reclassifiedKind = reclassifiedKind
    }
}

public enum FallbackTitle {
    public static func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let cwd = event.cwd, !cwd.isEmpty {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if !name.isEmpty, name != "/" {
                return TitleResolution(title: name, origin: .cwd)
            }
        }
        return TitleResolution(title: AgentNames.displayName(for: event.agent), origin: .agentName)
    }
}

public enum ProvidedTitleResolver {
    public static func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return TitleResolution(title: title, origin: .provided)
        }
        return FallbackTitle.resolve(event)
    }
}
```

`Sources/AgentAlarmCore/Titles/ClaudeTitleResolver.swift`:

```swift
import Foundation

/// 从 Claude Code transcript JSONL 的尾部解析会话标题，并检测最后一条回复是否在向用户提问。
public struct ClaudeTitleResolver: Sendable {
    public var maxTailBytes: Int
    public init(maxTailBytes: Int = 512 * 1024) { self.maxTailBytes = maxTailBytes }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        guard let path = event.transcriptPath,
              let lines = Self.tailLines(path: path, maxBytes: maxTailBytes) else {
            return FallbackTitle.resolve(event)
        }
        var found: TitleResolution?
        var reclassified: EventKind?
        var sawAssistant = false
        for line in lines.reversed() {
            if found == nil, line.contains("custom-title"),
               let record = Self.parse(line), record.string("type") == "custom-title",
               let title = record.string("customTitle")?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                found = TitleResolution(title: title, origin: .customTitle)
            }
            if !sawAssistant, line.contains("assistant"),
               let record = Self.parse(line), record.string("type") == "assistant" {
                sawAssistant = true
                if Self.containsAskUserQuestion(record) { reclassified = .needsInput }
            }
            if found != nil, sawAssistant { break }
        }
        if found == nil {
            for line in lines.reversed() where line.contains("last-prompt") {
                guard let record = Self.parse(line), record.string("type") == "last-prompt",
                      let prompt = record.string("lastPrompt") else { continue }
                let first = TextTruncation.firstLine(prompt)
                if !first.isEmpty {
                    found = TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: .lastPrompt)
                    break
                }
            }
        }
        var result = found ?? FallbackTitle.resolve(event)
        result.reclassifiedKind = reclassified
        return result
    }

    /// 读取文件末尾最多 maxBytes，按行拆分；若从中间开始读则丢弃第一段不完整的行。
    static func tailLines(path: String, maxBytes: Int) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    static func parse(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    static func containsAskUserQuestion(_ record: [String: Any]) -> Bool {
        guard let message = record.dictionary("message"), let content = message.array("content") else { return false }
        return content.contains { item in
            guard let block = item as? [String: Any] else { return false }
            return block.string("type") == "tool_use" && block.string("name") == "AskUserQuestion"
        }
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test --filter ClaudeTitleResolverTests 2>&1 | tail -2`
Expected: 6 个测试通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Titles Tests/AgentAlarmCoreTests/ClaudeTitleResolverTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add title resolution model and Claude transcript resolver"
```

---

### Task 8: SQLiteReader 与 Codex 标题解析器

**Files:**
- Create: `Sources/AgentAlarmCore/Support/SQLiteReader.swift`
- Create: `Sources/AgentAlarmCore/Titles/CodexTitleResolver.swift`
- Test: `Tests/AgentAlarmCoreTests/CodexTitleResolverTests.swift`

**Interfaces:**
- Consumes: Task 7 的 `TitleResolution`、`FallbackTitle`；Task 2 的 `TextTruncation`。
- Produces:
  - `final class SQLiteReader { init(path: String) throws; func firstRow(sql: String, bindings: [String]) throws -> [String: String?]? }`，只读打开
  - `struct CodexTitleResolver: Sendable { init(codexHome: URL); func resolve(_ event: AlarmEvent) -> TitleResolution }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/CodexTitleResolverTests.swift`:

```swift
import Foundation
import SQLite3
import Testing
@testable import AgentAlarmCore

@Suite struct CodexTitleResolverTests {
    static func createDatabase(at url: URL, sql: String) {
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, sql, nil, nil, nil)
        sqlite3_close(db)
    }

    func makeCodexHome() throws -> URL {
        let home = try makeTempDirectory()
        // 旧库：故意缺少 name 列，用来验证会选编号最大的库
        Self.createDatabase(at: home.appendingPathComponent("state_4.sqlite"),
                            sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT NOT NULL); INSERT INTO threads VALUES('T1','wrong old db');")
        Self.createDatabase(at: home.appendingPathComponent("state_5.sqlite"), sql: """
            CREATE TABLE threads(id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
              cwd TEXT NOT NULL, title TEXT NOT NULL, name TEXT, first_user_message TEXT);
            INSERT INTO threads VALUES('T1',1,1,'/Users/jack/Workspaces/LovedVoice','请仔细设计如下feature','越狱 iPad 发布门禁','请仔细设计如下feature');
            INSERT INTO threads VALUES('T2',1,1,'/Users/jack/Workspaces/ATTweak',
              '本机连接了一台越狱iPad mini，请在上面进行一轮发布门禁测试，并记录所有失败项目以及对应的截图证据。\n第二行', NULL, 'x');
            INSERT INTO threads VALUES('T3',1,1,'/tmp','',NULL,'  first message only  ');
            """)
        try "{\"id\":\"T9\",\"thread_name\":\"索引里的名字\",\"updated_at\":1}\n"
            .write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)
        return home
    }

    func event(_ id: String) -> AlarmEvent {
        AlarmEvent(agent: "codex", kind: .turnComplete, sessionId: id, cwd: "/Users/jack/Workspaces/Fallback")
    }

    @Test func prefersUserAssignedName() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T1"))
        #expect(r == TitleResolution(title: "越狱 iPad 发布门禁", origin: .threadName))
    }

    @Test func fallsBackToTitleFirstLineTruncated() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T2"))
        #expect(r.origin == .threadTitle)
        #expect(r.title.count == 41)
        #expect(r.title.hasSuffix("…"))
        #expect(!r.title.contains("\n"))
    }

    @Test func fallsBackToFirstUserMessageWhenTitleEmpty() throws {
        let r = CodexTitleResolver(codexHome: try makeCodexHome()).resolve(event("T3"))
        #expect(r == TitleResolution(title: "first message only", origin: .firstMessage))
    }

    @Test func fallsBackToSessionIndexThenCwd() throws {
        let home = try makeCodexHome()
        #expect(CodexTitleResolver(codexHome: home).resolve(event("T9")) == TitleResolution(title: "索引里的名字", origin: .sessionIndex))
        #expect(CodexTitleResolver(codexHome: home).resolve(event("T404")) == TitleResolution(title: "Fallback", origin: .cwd))
        let emptyHome = try makeTempDirectory()
        #expect(CodexTitleResolver(codexHome: emptyHome).resolve(event("T1")).origin == .cwd)
    }

    @Test func sqliteReaderIsReadOnly() throws {
        let home = try makeCodexHome()
        let reader = try SQLiteReader(path: home.appendingPathComponent("state_5.sqlite").path)
        #expect(throws: (any Error).self) {
            _ = try reader.firstRow(sql: "INSERT INTO threads(id,created_at,updated_at,cwd,title) VALUES('X',1,1,'/','t')", bindings: [])
        }
        let row = try #require(try reader.firstRow(sql: "SELECT name FROM threads WHERE id = ?1", bindings: ["T2"]))
        #expect(row["name"] == .some(nil))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter CodexTitleResolverTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'CodexTitleResolver' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Support/SQLiteReader.swift`:

```swift
import Foundation
import SQLite3

/// 只读 SQLite 查询，只取第一行。
public final class SQLiteReader {
    public enum ReaderError: Error, Equatable { case open(Int32), prepare(String), step(String) }
    private var db: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK else {
            sqlite3_close(handle)
            throw ReaderError.open(rc)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    public func firstRow(sql: String, bindings: [String]) throws -> [String: String?]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReaderError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient)
        }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw ReaderError.step(String(cString: sqlite3_errmsg(db))) }
        var row: [String: String?] = [:]
        for column in 0..<sqlite3_column_count(statement) {
            let name = String(cString: sqlite3_column_name(statement, column))
            if let text = sqlite3_column_text(statement, column) {
                row[name] = String(cString: text)
            } else {
                row[name] = .some(nil)
            }
        }
        return row
    }
}
```

`Sources/AgentAlarmCore/Titles/CodexTitleResolver.swift`:

```swift
import Foundation

/// 从 ~/.codex/state_N.sqlite 的 threads 表取线程名或标题，退化到 session_index.jsonl 与 cwd。
public struct CodexTitleResolver: Sendable {
    public var codexHome: URL
    public init(codexHome: URL) { self.codexHome = codexHome }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        if let db = Self.latestStateDatabase(in: codexHome),
           let hit = Self.lookup(database: db, threadId: event.sessionId) {
            return hit
        }
        if let hit = Self.lookupSessionIndex(codexHome.appendingPathComponent("session_index.jsonl"), threadId: event.sessionId) {
            return hit
        }
        return FallbackTitle.resolve(event)
    }

    static func latestStateDatabase(in home: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: home.path) else { return nil }
        let candidates = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let digits = name.dropFirst("state_".count).dropLast(".sqlite".count)
            guard let number = Int(digits) else { return nil }
            return (number, name)
        }
        guard let best = candidates.max(by: { $0.0 < $1.0 }) else { return nil }
        return home.appendingPathComponent(best.1)
    }

    static func lookup(database: URL, threadId: String) -> TitleResolution? {
        guard let reader = try? SQLiteReader(path: database.path),
              let row = try? reader.firstRow(sql: "SELECT name, title, first_user_message FROM threads WHERE id = ?1",
                                             bindings: [threadId]) else { return nil }
        if let name = (row["name"] ?? nil)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return TitleResolution(title: name, origin: .threadName)
        }
        let fallbacks: [(String, TitleOrigin)] = [("title", .threadTitle), ("first_user_message", .firstMessage)]
        for (column, origin) in fallbacks {
            guard let text = row[column] ?? nil else { continue }
            let first = TextTruncation.firstLine(text)
            if !first.isEmpty {
                return TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: origin)
            }
        }
        return nil
    }

    static func lookupSessionIndex(_ url: URL, threadId: String) -> TitleResolution? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains(threadId) {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  record.string("id") == threadId,
                  let name = record.string("thread_name"), !name.isEmpty else { continue }
            return TitleResolution(title: name, origin: .sessionIndex)
        }
        return nil
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter CodexTitleResolverTests 2>&1 | tail -2`
Expected: 5 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Support/SQLiteReader.swift Sources/AgentAlarmCore/Titles/CodexTitleResolver.swift Tests/AgentAlarmCoreTests/CodexTitleResolverTests.swift
git commit -m "feat(core): add read-only SQLite reader and Codex title resolver"
```

---

### Task 9: Gemini 标题解析器与带缓存的 TitleService

**Files:**
- Create: `Sources/AgentAlarmCore/Titles/GeminiTitleResolver.swift`
- Create: `Sources/AgentAlarmCore/Titles/TitleService.swift`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/gemini-chat-summary.json`
- Create: `Tests/AgentAlarmCoreTests/Fixtures/gemini-chat-nosummary.json`
- Test: `Tests/AgentAlarmCoreTests/GeminiTitleResolverTests.swift`
- Test: `Tests/AgentAlarmCoreTests/TitleServiceTests.swift`

**Interfaces:**
- Consumes: Task 7、8 的解析器。
- Produces:
  - `struct GeminiTitleResolver: Sendable { init(); func resolve(_ event: AlarmEvent) -> TitleResolution }`
  - `final class TitleService: @unchecked Sendable { init(claude: ClaudeTitleResolver, codex: CodexTitleResolver, gemini: GeminiTitleResolver); func resolve(_ event: AlarmEvent) -> TitleResolution }`。事件自带非空 `title` 时任何 agent 都直接采用；否则 Claude 与 Gemini 按 `(agent, sessionId)` 与 transcript 修改时间缓存；Codex 不缓存；其他 agent 走 `ProvidedTitleResolver`。

- [ ] **Step 1: 写 fixture**

`Tests/AgentAlarmCoreTests/Fixtures/gemini-chat-summary.json`:

```json
{
  "sessionId": "session-2026-09-17T03-00-abcd1234",
  "projectHash": "abc",
  "startTime": "2026-09-17T03:00:00.000Z",
  "lastUpdated": "2026-09-17T03:05:00.000Z",
  "kind": "main",
  "summary": "Fix login crash and add regression test",
  "messages": [
    { "id": "m1", "timestamp": "2026-09-17T03:00:00.000Z", "type": "user", "content": "fix the login crash" },
    { "id": "m2", "timestamp": "2026-09-17T03:00:10.000Z", "type": "gemini", "content": "Done." }
  ]
}
```

`Tests/AgentAlarmCoreTests/Fixtures/gemini-chat-nosummary.json`:

```json
{
  "sessionId": "session-2026-09-17T04-00-ef567890",
  "projectHash": "abc",
  "startTime": "2026-09-17T04:00:00.000Z",
  "lastUpdated": "2026-09-17T04:05:00.000Z",
  "kind": "main",
  "messages": [
    { "id": "m1", "timestamp": "2026-09-17T04:00:00.000Z", "type": "user", "content": [ { "text": "  重构支付模块\n第二行" } ] }
  ]
}
```

- [ ] **Step 2: 写失败测试**

`Tests/AgentAlarmCoreTests/GeminiTitleResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct GeminiTitleResolverTests {
    func event(_ path: String?) -> AlarmEvent {
        AlarmEvent(agent: "gemini", kind: .turnComplete, sessionId: "S", cwd: "/Users/jack/Workspaces/Proj", transcriptPath: path)
    }

    @Test func usesSummary() throws {
        let r = GeminiTitleResolver().resolve(event(try fixtureURL("gemini-chat-summary.json").path))
        #expect(r == TitleResolution(title: "Fix login crash and add regression test", origin: .summary))
    }

    @Test func fallsBackToFirstUserMessageParts() throws {
        let r = GeminiTitleResolver().resolve(event(try fixtureURL("gemini-chat-nosummary.json").path))
        #expect(r == TitleResolution(title: "重构支付模块", origin: .firstMessage))
    }

    @Test func missingOrBrokenFileFallsBack() throws {
        #expect(GeminiTitleResolver().resolve(event("/nonexistent.json")).origin == .cwd)
        let dir = try makeTempDirectory()
        let broken = dir.appendingPathComponent("broken.json")
        try "not json".write(to: broken, atomically: true, encoding: .utf8)
        #expect(GeminiTitleResolver().resolve(event(broken.path)) == TitleResolution(title: "Proj", origin: .cwd))
    }
}
```

`Tests/AgentAlarmCoreTests/TitleServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct TitleServiceTests {
    func makeService(codexHome: URL) -> TitleService {
        TitleService(claude: ClaudeTitleResolver(), codex: CodexTitleResolver(codexHome: codexHome), gemini: GeminiTitleResolver())
    }

    @Test func dispatchesByAgent() throws {
        let service = makeService(codexHome: try makeTempDirectory())
        let claude = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S1", cwd: "/a/B",
                                transcriptPath: try fixtureURL("claude-transcript-titled.jsonl").path)
        #expect(service.resolve(claude).title == "AgentAlarm 设计")
        let gemini = AlarmEvent(agent: "gemini", kind: .turnComplete, sessionId: "S2",
                                transcriptPath: try fixtureURL("gemini-chat-summary.json").path)
        #expect(service.resolve(gemini).origin == .summary)
        let codex = AlarmEvent(agent: "codex", kind: .turnComplete, sessionId: "T404", cwd: "/a/CodexProj")
        #expect(service.resolve(codex) == TitleResolution(title: "CodexProj", origin: .cwd))
        let custom = AlarmEvent(agent: "mybot", kind: .turnComplete, sessionId: "S3", title: "Custom title")
        #expect(service.resolve(custom) == TitleResolution(title: "Custom title", origin: .provided))
        let claudeProvided = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S9", title: "测试提醒")
        #expect(service.resolve(claudeProvided) == TitleResolution(title: "测试提醒", origin: .provided), "任何 agent 自带标题都优先")
    }

    @Test func cachesUntilTranscriptModificationTimeChanges() throws {
        let service = makeService(codexHome: try makeTempDirectory())
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("s.jsonl")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        func write(_ title: String, mtime: Date) throws {
            try "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"S\"}\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        let event = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "S", transcriptPath: file.path)
        try write("第一版", mtime: fixedDate)
        #expect(service.resolve(event).title == "第一版")
        try write("第二版", mtime: fixedDate)
        #expect(service.resolve(event).title == "第一版", "同一修改时间应命中缓存")
        try write("第三版", mtime: fixedDate.addingTimeInterval(60))
        #expect(service.resolve(event).title == "第三版", "修改时间变化应重新解析")
    }
}
```

- [ ] **Step 3: 运行确认失败**

Run: `swift test --filter "GeminiTitleResolverTests|TitleServiceTests" 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'GeminiTitleResolver' in scope`

- [ ] **Step 4: 实现**

`Sources/AgentAlarmCore/Titles/GeminiTitleResolver.swift`:

```swift
import Foundation

/// 从 Gemini CLI 的 chats/session-*.json 读取 summary，退化到首条用户消息。
public struct GeminiTitleResolver: Sendable {
    public init() {}

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        guard let path = event.transcriptPath,
              let data = FileManager.default.contents(atPath: path),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return FallbackTitle.resolve(event)
        }
        if let summary = record.string("summary")?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            return TitleResolution(title: TextTruncation.truncate(summary, to: 40), origin: .summary)
        }
        for item in record.array("messages") ?? [] {
            guard let message = item as? [String: Any], message.string("type") == "user" else { continue }
            let first = TextTruncation.firstLine(Self.text(of: message["content"]))
            if !first.isEmpty {
                return TitleResolution(title: TextTruncation.truncate(first, to: 40), origin: .firstMessage)
            }
        }
        return FallbackTitle.resolve(event)
    }

    static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let parts = content as? [Any] {
            return parts.compactMap { part -> String? in
                if let string = part as? String { return string }
                return (part as? [String: Any])?.string("text")
            }.joined(separator: " ")
        }
        return ""
    }
}
```

`Sources/AgentAlarmCore/Titles/TitleService.swift`:

```swift
import Foundation

/// 按 agent 分发到对应解析器；Claude 与 Gemini 结果按 transcript 修改时间缓存。
public final class TitleService: @unchecked Sendable {
    private let claude: ClaudeTitleResolver
    private let codex: CodexTitleResolver
    private let gemini: GeminiTitleResolver
    private let lock = NSLock()
    private var cache: [String: (modified: Date, resolution: TitleResolution)] = [:]

    public init(claude: ClaudeTitleResolver, codex: CodexTitleResolver, gemini: GeminiTitleResolver) {
        self.claude = claude; self.codex = codex; self.gemini = gemini
    }

    public func resolve(_ event: AlarmEvent) -> TitleResolution {
        // 发送方已带标题（OpenCode 插件、notify、test）时直接采用，不再回查文件。
        if let provided = event.title?.trimmingCharacters(in: .whitespacesAndNewlines), !provided.isEmpty {
            return TitleResolution(title: provided, origin: .provided)
        }
        switch event.agent {
        case "claude": return cached(event) { claude.resolve($0) }
        case "gemini": return cached(event) { gemini.resolve($0) }
        case "codex": return codex.resolve(event)
        default: return ProvidedTitleResolver.resolve(event)
        }
    }

    private func cached(_ event: AlarmEvent, _ resolve: (AlarmEvent) -> TitleResolution) -> TitleResolution {
        let key = "\(event.agent):\(event.sessionId)"
        let modified = event.transcriptPath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        }
        lock.lock(); defer { lock.unlock() }
        if let modified, let entry = cache[key], entry.modified == modified {
            return entry.resolution
        }
        let resolution = resolve(event)
        if let modified { cache[key] = (modified, resolution) }
        return resolution
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `swift test 2>&1 | tail -2`
Expected: 全部通过

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentAlarmCore/Titles Tests/AgentAlarmCoreTests/GeminiTitleResolverTests.swift Tests/AgentAlarmCoreTests/TitleServiceTests.swift Tests/AgentAlarmCoreTests/Fixtures
git commit -m "feat(core): add Gemini title resolver and cached TitleService"
```

---

### Task 10: TimeSource 与等待列表 WaitingList

**Files:**
- Create: `Sources/AgentAlarmCore/Policy/TimeSource.swift`
- Create: `Sources/AgentAlarmCore/Policy/WaitingList.swift`
- Test: `Tests/AgentAlarmCoreTests/WaitingListTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AlarmEvent`、`EventKind`、`HostInfo`。
- Produces:
  - `protocol TimeSource: Sendable { var now: Date { get } }`；`struct SystemTimeSource: TimeSource`；`final class ManualTimeSource: TimeSource { init(now: Date); func advance(by: TimeInterval) }`
  - `struct WaitingEntry: Equatable, Sendable, Identifiable { id: String（"agent:sessionId"）; agent; sessionId; kind: EventKind; title: String; host: HostInfo?; cwd: String?; since: Date; updatedAt: Date; seen: Bool }`
  - `struct WaitingList: Sendable { init(expiry: TimeInterval = 86_400, capacity: Int = 50); var entries: [WaitingEntry]（按 updatedAt 降序）; var count: Int; mutating func apply(_ event: AlarmEvent, title: String, now: Date) -> Change; mutating func markSeen(id: String); mutating func remove(id: String); mutating func purgeExpired(now: Date) }`，`enum Change { added, updated, removed, ignored }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/WaitingListTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct WaitingListTests {
    let t0 = Date(timeIntervalSince1970: 1_789_600_000)

    func event(_ kind: EventKind, session: String = "S1", agent: String = "claude") -> AlarmEvent {
        AlarmEvent(agent: agent, kind: kind, sessionId: session, cwd: "/p/\(session)",
                   host: HostInfo(bundleId: "com.example.host", pid: 1, name: "Host"))
    }

    @Test func addUpdateRemove() {
        var list = WaitingList()
        #expect(list.apply(event(.turnComplete), title: "A", now: t0) == .added)
        #expect(list.count == 1)
        #expect(list.entries[0].kind == .turnComplete)
        #expect(list.entries[0].since == t0)
        #expect(list.apply(event(.needsPermission), title: "A2", now: t0.addingTimeInterval(5)) == .updated)
        #expect(list.count == 1)
        #expect(list.entries[0].kind == .needsPermission)
        #expect(list.entries[0].title == "A2")
        #expect(list.entries[0].since == t0)
        #expect(list.entries[0].updatedAt == t0.addingTimeInterval(5))
        #expect(list.apply(event(.resumed), title: "", now: t0.addingTimeInterval(6)) == .removed)
        #expect(list.count == 0)
        #expect(list.apply(event(.ended), title: "", now: t0) == .ignored)
    }

    @Test func idleReminderUpdatesOrCreates() {
        var list = WaitingList()
        #expect(list.apply(event(.idleReminder), title: "A", now: t0) == .added)
        #expect(list.entries[0].kind == .turnComplete)
        _ = list.apply(event(.needsInput), title: "A", now: t0.addingTimeInterval(1))
        #expect(list.apply(event(.idleReminder), title: "A", now: t0.addingTimeInterval(60)) == .updated)
        #expect(list.entries[0].kind == .needsInput, "idle 只更新时间不改 kind")
        #expect(list.entries[0].updatedAt == t0.addingTimeInterval(60))
    }

    @Test func seenResetsOnUpdateAndSortNewestFirst() {
        var list = WaitingList()
        _ = list.apply(event(.turnComplete, session: "S1"), title: "one", now: t0)
        _ = list.apply(event(.turnComplete, session: "S2"), title: "two", now: t0.addingTimeInterval(1))
        #expect(list.entries.map(\.sessionId) == ["S2", "S1"])
        list.markSeen(id: "claude:S1")
        #expect(list.entries[1].seen)
        _ = list.apply(event(.turnComplete, session: "S1"), title: "one again", now: t0.addingTimeInterval(2))
        #expect(list.entries.map(\.sessionId) == ["S1", "S2"])
        #expect(!list.entries[0].seen)
    }

    @Test func expiryAndCapacity() {
        var list = WaitingList(expiry: 100, capacity: 3)
        for i in 0..<5 {
            _ = list.apply(event(.turnComplete, session: "S\(i)"), title: "t", now: t0.addingTimeInterval(Double(i)))
        }
        #expect(list.count == 3)
        #expect(list.entries.map(\.sessionId) == ["S4", "S3", "S2"])
        _ = list.apply(event(.turnComplete, session: "S9"), title: "t", now: t0.addingTimeInterval(200))
        #expect(list.entries.map(\.sessionId) == ["S9"], "过期条目在下一次 apply 时清掉")
    }

    @Test func manualTimeSourceAdvances() {
        let clock = ManualTimeSource(now: t0)
        clock.advance(by: 30)
        #expect(clock.now == t0.addingTimeInterval(30))
        #expect(abs(SystemTimeSource().now.timeIntervalSinceNow) < 1)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter WaitingListTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'WaitingList' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Policy/TimeSource.swift`:

```swift
import Foundation

public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

/// 测试用可拨动的时钟。
public final class ManualTimeSource: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    public init(now: Date) { current = now }
    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    public func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}
```

`Sources/AgentAlarmCore/Policy/WaitingList.swift`:

```swift
import Foundation

public struct WaitingEntry: Equatable, Sendable, Identifiable {
    public var id: String { "\(agent):\(sessionId)" }
    public var agent: String
    public var sessionId: String
    public var kind: EventKind
    public var title: String
    public var host: HostInfo?
    public var cwd: String?
    public var since: Date
    public var updatedAt: Date
    public var seen: Bool
}

/// 等待中的会话列表：按 updatedAt 降序，超期与超量自动清理。
public struct WaitingList: Sendable {
    public enum Change: Equatable, Sendable { case added, updated, removed, ignored }

    public private(set) var entries: [WaitingEntry] = []
    public var expiry: TimeInterval
    public var capacity: Int

    public init(expiry: TimeInterval = 86_400, capacity: Int = 50) {
        self.expiry = expiry; self.capacity = capacity
    }

    public var count: Int { entries.count }

    public mutating func apply(_ event: AlarmEvent, title: String, now: Date) -> Change {
        purgeExpired(now: now)
        let id = "\(event.agent):\(event.sessionId)"
        let index = entries.firstIndex { $0.id == id }
        switch event.kind {
        case .resumed, .ended:
            guard let index else { return .ignored }
            entries.remove(at: index)
            return .removed
        case .idleReminder:
            if let index {
                entries[index].updatedAt = now
                resort()
                return .updated
            }
            insert(WaitingEntry(agent: event.agent, sessionId: event.sessionId, kind: .turnComplete, title: title,
                                host: event.host, cwd: event.cwd, since: now, updatedAt: now, seen: false))
            return .added
        case .turnComplete, .needsPermission, .needsInput:
            if let index {
                var entry = entries[index]
                entry.kind = event.kind
                entry.title = title
                entry.host = event.host ?? entry.host
                entry.cwd = event.cwd ?? entry.cwd
                entry.updatedAt = now
                entry.seen = false
                entries[index] = entry
                resort()
                return .updated
            }
            insert(WaitingEntry(agent: event.agent, sessionId: event.sessionId, kind: event.kind, title: title,
                                host: event.host, cwd: event.cwd, since: now, updatedAt: now, seen: false))
            return .added
        }
    }

    public mutating func markSeen(id: String) {
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index].seen = true }
    }

    public mutating func remove(id: String) {
        entries.removeAll { $0.id == id }
    }

    public mutating func purgeExpired(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.updatedAt) > expiry }
    }

    private mutating func insert(_ entry: WaitingEntry) {
        entries.append(entry)
        resort()
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    private mutating func resort() {
        entries.sort { $0.updatedAt > $1.updatedAt }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter WaitingListTests 2>&1 | tail -2`
Expected: 5 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Policy Tests/AgentAlarmCoreTests/WaitingListTests.swift
git commit -m "feat(core): add TimeSource and WaitingList"
```

---

### Task 11: AlertPolicy（去重、冷却、暂停、静音时段、语音抑制）

**Files:**
- Create: `Sources/AgentAlarmCore/Policy/AlertPolicy.swift`
- Test: `Tests/AgentAlarmCoreTests/AlertPolicyTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AlarmEvent`、`HostInfo`。
- Produces:
  - `struct QuietHours: Equatable, Sendable { startMinute: Int; endMinute: Int; func contains(minuteOfDay: Int) -> Bool }`
  - `struct PolicySettings: Equatable, Sendable { dedupWindow = 3; sessionCooldown = 10; repeatReminders = true; suppressSpeechWhenHostActive = true; userActiveThreshold = 10; quietHours: QuietHours? = nil }`，`init()`
  - `struct ActivityState: Equatable, Sendable { frontmostBundleId: String?; secondsSinceUserInput: TimeInterval }`
  - `enum SilentReason: String { nonAlertingKind, duplicate, cooldown, reminderDisabled, paused, quietHours }`
  - `enum AlertDecision: Equatable { silent(SilentReason); alert(speak: Bool) }`
  - `struct AlertPolicy: Sendable { init(settings: PolicySettings = .init()); var settings; var pausedUntil: Date?; func isPaused(at: Date) -> Bool; mutating func pause(for: TimeInterval?, now: Date)（nil = 直到恢复）; mutating func resume(); mutating func decide(_ event: AlarmEvent, activity: ActivityState, now: Date, calendar: Calendar = .current) -> AlertDecision }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/AlertPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AlertPolicyTests {
    let t0 = Date(timeIntervalSince1970: 1_789_600_000)
    let idle = ActivityState(frontmostBundleId: "com.apple.finder", secondsSinceUserInput: 120)
    let host = HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 1, name: "Claude")

    func event(_ kind: EventKind, session: String = "S1", host: HostInfo? = nil) -> AlarmEvent {
        AlarmEvent(agent: "claude", kind: kind, sessionId: session, host: host)
    }

    @Test func nonAlertingKindsAreSilent() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.resumed), activity: idle, now: t0) == .silent(.nonAlertingKind))
        #expect(policy.decide(event(.ended), activity: idle, now: t0) == .silent(.nonAlertingKind))
    }

    @Test func duplicateWithinThreeSecondsThenCooldownTenSeconds() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0) == .alert(speak: true))
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0.addingTimeInterval(2)) == .silent(.duplicate))
        #expect(policy.decide(event(.needsPermission), activity: idle, now: t0.addingTimeInterval(5)) == .silent(.cooldown))
        #expect(policy.decide(event(.needsPermission), activity: idle, now: t0.addingTimeInterval(11)) == .alert(speak: true))
        #expect(policy.decide(event(.turnComplete, session: "S2"), activity: idle, now: t0.addingTimeInterval(1)) == .alert(speak: true), "不同会话互不影响")
    }

    @Test func reminderSwitch() {
        var policy = AlertPolicy()
        #expect(policy.decide(event(.idleReminder), activity: idle, now: t0) == .alert(speak: true))
        policy.settings.repeatReminders = false
        #expect(policy.decide(event(.idleReminder, session: "S2"), activity: idle, now: t0) == .silent(.reminderDisabled))
    }

    @Test func pauseForDurationAndUntilResumed() {
        var policy = AlertPolicy()
        policy.pause(for: 900, now: t0)
        #expect(policy.isPaused(at: t0.addingTimeInterval(899)))
        #expect(policy.decide(event(.turnComplete), activity: idle, now: t0) == .silent(.paused))
        #expect(!policy.isPaused(at: t0.addingTimeInterval(901)))
        #expect(policy.decide(event(.turnComplete, session: "S2"), activity: idle, now: t0.addingTimeInterval(901)) == .alert(speak: true))
        policy.pause(for: nil, now: t0)
        #expect(policy.isPaused(at: t0.addingTimeInterval(1_000_000)))
        policy.resume()
        #expect(!policy.isPaused(at: t0))
    }

    @Test func quietHoursWrapMidnight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var policy = AlertPolicy()
        policy.settings.quietHours = QuietHours(startMinute: 23 * 60, endMinute: 7 * 60)
        let lateNight = utc.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 23, minute: 30))!
        let morning = utc.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 6, minute: 59))!
        let noon = utc.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 12, minute: 0))!
        #expect(policy.decide(event(.turnComplete, session: "A"), activity: idle, now: lateNight, calendar: utc) == .silent(.quietHours))
        #expect(policy.decide(event(.turnComplete, session: "B"), activity: idle, now: morning, calendar: utc) == .silent(.quietHours))
        #expect(policy.decide(event(.turnComplete, session: "C"), activity: idle, now: noon, calendar: utc) == .alert(speak: true))
        #expect(!QuietHours(startMinute: 600, endMinute: 600).contains(minuteOfDay: 600))
    }

    @Test func speechSuppressedOnlyWhenHostFrontmostAndUserActive() {
        var policy = AlertPolicy()
        let active = ActivityState(frontmostBundleId: host.bundleId, secondsSinceUserInput: 3)
        #expect(policy.decide(event(.turnComplete, session: "A", host: host), activity: active, now: t0) == .alert(speak: false))
        #expect(policy.decide(event(.turnComplete, session: "B", host: nil), activity: active, now: t0) == .alert(speak: true))
        let otherApp = ActivityState(frontmostBundleId: "com.googlecode.iterm2", secondsSinceUserInput: 3)
        #expect(policy.decide(event(.turnComplete, session: "C", host: host), activity: otherApp, now: t0) == .alert(speak: true))
        let awayFromKeyboard = ActivityState(frontmostBundleId: host.bundleId, secondsSinceUserInput: 30)
        #expect(policy.decide(event(.turnComplete, session: "D", host: host), activity: awayFromKeyboard, now: t0) == .alert(speak: true))
        policy.settings.suppressSpeechWhenHostActive = false
        #expect(policy.decide(event(.turnComplete, session: "E", host: host), activity: active, now: t0) == .alert(speak: true))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AlertPolicyTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'AlertPolicy' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Policy/AlertPolicy.swift`:

```swift
import Foundation

public struct QuietHours: Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public init(startMinute: Int, endMinute: Int) { self.startMinute = startMinute; self.endMinute = endMinute }

    public func contains(minuteOfDay minute: Int) -> Bool {
        if startMinute == endMinute { return false }
        if startMinute < endMinute { return minute >= startMinute && minute < endMinute }
        return minute >= startMinute || minute < endMinute
    }
}

public struct PolicySettings: Equatable, Sendable {
    public var dedupWindow: TimeInterval = 3
    public var sessionCooldown: TimeInterval = 10
    public var repeatReminders = true
    public var suppressSpeechWhenHostActive = true
    public var userActiveThreshold: TimeInterval = 10
    public var quietHours: QuietHours? = nil
    public init() {}
}

public struct ActivityState: Equatable, Sendable {
    public var frontmostBundleId: String?
    public var secondsSinceUserInput: TimeInterval
    public init(frontmostBundleId: String?, secondsSinceUserInput: TimeInterval) {
        self.frontmostBundleId = frontmostBundleId; self.secondsSinceUserInput = secondsSinceUserInput
    }
}

public enum SilentReason: String, Sendable, Equatable {
    case nonAlertingKind, duplicate, cooldown, reminderDisabled, paused, quietHours
}

public enum AlertDecision: Equatable, Sendable {
    case silent(SilentReason)
    case alert(speak: Bool)
}

/// 提醒策略。检查顺序：kind → 去重 → 冷却 → 重复提醒开关 → 暂停 → 静音时段 → 语音抑制。
public struct AlertPolicy: Sendable {
    public var settings: PolicySettings
    public var pausedUntil: Date?
    private var lastSeen: [String: Date] = [:]
    private var lastAlert: [String: Date] = [:]

    public init(settings: PolicySettings = PolicySettings()) { self.settings = settings }

    public func isPaused(at now: Date) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }

    /// duration 为 nil 表示直到手动恢复。
    public mutating func pause(for duration: TimeInterval?, now: Date) {
        pausedUntil = duration.map { now.addingTimeInterval($0) } ?? .distantFuture
    }

    public mutating func resume() { pausedUntil = nil }

    public mutating func decide(_ event: AlarmEvent, activity: ActivityState, now: Date, calendar: Calendar = .current) -> AlertDecision {
        guard event.kind.isAlerting else { return .silent(.nonAlertingKind) }
        let dedupKey = "\(event.agent):\(event.sessionId):\(event.kind.rawValue)"
        if let last = lastSeen[dedupKey], now.timeIntervalSince(last) < settings.dedupWindow {
            return .silent(.duplicate)
        }
        lastSeen[dedupKey] = now
        let sessionKey = "\(event.agent):\(event.sessionId)"
        if let last = lastAlert[sessionKey], now.timeIntervalSince(last) < settings.sessionCooldown {
            return .silent(.cooldown)
        }
        if event.kind == .idleReminder, !settings.repeatReminders { return .silent(.reminderDisabled) }
        if isPaused(at: now) { return .silent(.paused) }
        if let quiet = settings.quietHours {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            if quiet.contains(minuteOfDay: minute) { return .silent(.quietHours) }
        }
        lastAlert[sessionKey] = now
        var speak = true
        if settings.suppressSpeechWhenHostActive,
           let host = event.host,
           host.bundleId == activity.frontmostBundleId,
           activity.secondsSinceUserInput < settings.userActiveThreshold {
            speak = false
        }
        return .alert(speak: speak)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter AlertPolicyTests 2>&1 | tail -2`
Expected: 6 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Policy/AlertPolicy.swift Tests/AgentAlarmCoreTests/AlertPolicyTests.swift
git commit -m "feat(core): add AlertPolicy with dedup, cooldown, pause, quiet hours and speech suppression"
```

---

### Task 12: SpeechComposer 播报文案

**Files:**
- Create: `Sources/AgentAlarmCore/Policy/SpeechComposer.swift`
- Test: `Tests/AgentAlarmCoreTests/SpeechComposerTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `AgentNames`、`TextTruncation`、`EventKind`。
- Produces:
  - `struct SpeechItem: Equatable, Sendable { agent: String; title: String; kind: EventKind }`，`init(agent:title:kind:)`
  - `enum SpeechComposer { static func statusPhrase(_ kind: EventKind) -> String; static func sentence(for item: SpeechItem) -> String; static func sentence(for items: [SpeechItem]) -> String }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/SpeechComposerTests.swift`:

```swift
import Testing
@testable import AgentAlarmCore

@Suite struct SpeechComposerTests {
    @Test func singleSentencesFollowTemplate() {
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "claude", title: "AgentAlarm 设计", kind: .turnComplete)) == "Claude Code，AgentAlarm 设计，已完成")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "codex", title: "登录页", kind: .needsPermission)) == "Codex，登录页，需要授权")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "gemini", title: "迁移", kind: .needsInput)) == "Gemini CLI，迁移，有问题要问你")
        #expect(SpeechComposer.sentence(for: SpeechItem(agent: "opencode", title: "重构", kind: .idleReminder)) == "OpenCode，重构，还在等你")
    }

    @Test func longTitleTruncatedTo40ForSpeech() {
        let item = SpeechItem(agent: "claude", title: String(repeating: "长", count: 60), kind: .turnComplete)
        let sentence = SpeechComposer.sentence(for: item)
        #expect(sentence == "Claude Code，" + String(repeating: "长", count: 40) + "…，已完成")
    }

    @Test func batchesCoalesce() {
        let items = (1...4).map { SpeechItem(agent: "claude", title: "会话\($0)", kind: .turnComplete) }
        #expect(SpeechComposer.sentence(for: Array(items.prefix(1))) == "Claude Code，会话1，已完成")
        #expect(SpeechComposer.sentence(for: Array(items.prefix(2))) == "有 2 个会话在等待：会话1，会话2")
        #expect(SpeechComposer.sentence(for: Array(items.prefix(3))) == "有 3 个会话在等待：会话1，会话2，会话3")
        #expect(SpeechComposer.sentence(for: items) == "有 4 个会话在等待：会话1，会话2，会话3等")
        #expect(SpeechComposer.sentence(for: []) == "")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SpeechComposerTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'SpeechComposer' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Policy/SpeechComposer.swift`:

```swift
public struct SpeechItem: Equatable, Sendable {
    public var agent: String
    public var title: String
    public var kind: EventKind
    public init(agent: String, title: String, kind: EventKind) {
        self.agent = agent; self.title = title; self.kind = kind
    }
}

public enum SpeechComposer {
    public static func statusPhrase(_ kind: EventKind) -> String {
        switch kind {
        case .turnComplete: return "已完成"
        case .needsPermission: return "需要授权"
        case .needsInput: return "有问题要问你"
        case .idleReminder: return "还在等你"
        case .resumed, .ended: return ""
        }
    }

    public static func sentence(for item: SpeechItem) -> String {
        "\(AgentNames.displayName(for: item.agent))，\(TextTruncation.truncate(item.title, to: 40))，\(statusPhrase(item.kind))"
    }

    public static func sentence(for items: [SpeechItem]) -> String {
        guard items.count > 1 else { return items.first.map { sentence(for: $0) } ?? "" }
        let titles = items.prefix(3).map { TextTruncation.truncate($0.title, to: 40) }.joined(separator: "，")
        let suffix = items.count > 3 ? "等" : ""
        return "有 \(items.count) 个会话在等待：\(titles)\(suffix)"
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test 2>&1 | tail -2`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Policy/SpeechComposer.swift Tests/AgentAlarmCoreTests/SpeechComposerTests.swift
git commit -m "feat(core): add SpeechComposer templates and coalescing"
```

---

### Task 13: HookTemplates 与 JSONHookInstaller

**Files:**
- Create: `Sources/AgentAlarmCore/Installer/HookTemplates.swift`
- Create: `Sources/AgentAlarmCore/Installer/JSONHookInstaller.swift`
- Test: `Tests/AgentAlarmCoreTests/HookTemplatesTests.swift`
- Test: `Tests/AgentAlarmCoreTests/JSONHookInstallerTests.swift`

**Interfaces:**
- Consumes: Task 10 的 `TimeSource`。
- Produces:
  - `enum HookTemplates { static func marker(agent: String) -> String（"/.local/bin/agentalarm hook <agent>"）; static func command(cliPath: String, agent: String) -> String; static func claude(cliPath:) -> [String: Any]; static func codex(cliPath:) -> [String: Any]; static func gemini(cliPath:) -> [String: Any]; static func template(agent: String, cliPath: String) -> [String: Any]? }`，返回值是写入 `"hooks"` 键下的字典
  - `enum InstallerError: Error, Equatable { containsComments, rootNotObject, hooksNotObject }`
  - `struct JSONHookInstaller { init(backupDirectory: URL, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()); var backupsToKeep = 10; func install(hooks: [String: Any], marker: String, into fileURL: URL) throws; func uninstall(marker: String, from fileURL: URL) throws; func isInstalled(marker: String, in fileURL: URL) -> Bool; func requiresManualEdit(fileURL: URL) -> Bool; static func containsComments(_ text: String) -> Bool; static func merge(hooks: [String: Any], into root: [String: Any], marker: String) -> [String: Any]; static func remove(marker: String, from root: [String: Any]) -> [String: Any]; static func containsMarker(_ root: [String: Any], marker: String) -> Bool }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/HookTemplatesTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct HookTemplatesTests {
    let cli = "/Users/jack/.local/bin/agentalarm"

    func hooks(_ dict: [String: Any], _ event: String) -> [[String: Any]] {
        let groups = dict[event] as? [[String: Any]] ?? []
        return groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }

    @Test func claudeTemplate() {
        let t = HookTemplates.claude(cliPath: cli)
        #expect(Set(t.keys) == ["Stop", "Notification", "UserPromptSubmit", "SessionEnd"])
        let stop = hooks(t, "Stop")[0]
        #expect(stop["command"] as? String == "/Users/jack/.local/bin/agentalarm hook claude")
        #expect(stop["async"] as? Bool == true)
        #expect(stop["timeout"] as? Int == 5)
        let notif = (t["Notification"] as? [[String: Any]])?[0]
        #expect(notif?["matcher"] as? String == "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input")
        let end = hooks(t, "SessionEnd")[0]
        #expect(end["timeout"] as? Int == 1)
        #expect(end["async"] == nil)
    }

    @Test func codexTemplate() {
        let t = HookTemplates.codex(cliPath: cli)
        #expect(Set(t.keys) == ["Stop", "PermissionRequest", "UserPromptSubmit", "SessionEnd"])
        #expect(hooks(t, "Stop")[0]["async"] as? Bool == true)
        #expect(hooks(t, "PermissionRequest")[0]["async"] == nil)
        #expect(hooks(t, "SessionEnd")[0]["timeout"] as? Int == 2)
        #expect((t["Stop"] as? [[String: Any]])?[0]["matcher"] == nil)
    }

    @Test func geminiTemplateUsesMilliseconds() {
        let t = HookTemplates.gemini(cliPath: cli)
        #expect(Set(t.keys) == ["AfterAgent", "Notification", "BeforeAgent", "SessionEnd"])
        for event in t.keys {
            #expect(hooks(t, event)[0]["timeout"] as? Int == 3000)
            #expect(hooks(t, event)[0]["command"] as? String == "/Users/jack/.local/bin/agentalarm hook gemini")
        }
    }

    @Test func markerAndQuoting() {
        #expect(HookTemplates.marker(agent: "codex") == "/.local/bin/agentalarm hook codex")
        #expect(HookTemplates.command(cliPath: "/Users/some one/.local/bin/agentalarm", agent: "claude") == "'/Users/some one/.local/bin/agentalarm' hook claude")
        #expect(HookTemplates.template(agent: "opencode", cliPath: cli) == nil)
        #expect(HookTemplates.template(agent: "gemini", cliPath: cli)?.count == 4)
    }
}
```

`Tests/AgentAlarmCoreTests/JSONHookInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct JSONHookInstallerTests {
    let marker = HookTemplates.marker(agent: "claude")
    let cli = "/Users/jack/.local/bin/agentalarm"

    func installer(_ dir: URL) -> JSONHookInstaller {
        JSONHookInstaller(backupDirectory: dir.appendingPathComponent("backups"),
                          timeSource: ManualTimeSource(now: Date(timeIntervalSince1970: 1_789_600_000)))
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func commentDetectionIgnoresSlashesInsideStrings() {
        #expect(JSONHookInstaller.containsComments("{\n  // note\n  \"a\": 1\n}"))
        #expect(JSONHookInstaller.containsComments("{ \"a\": 1 /* x */ }"))
        #expect(!JSONHookInstaller.containsComments("{ \"url\": \"http://localhost:1/\", \"b\": \"a/*b\", \"c\": \"say \\\"//\\\"\" }"))
    }

    @Test func mergePreservesExistingHooksAndIsIdempotent() {
        let existing: [String: Any] = [
            "model": "opus",
            "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo hi"]]]]],
        ]
        let once = JSONHookInstaller.merge(hooks: HookTemplates.claude(cliPath: cli), into: existing, marker: marker)
        let twice = JSONHookInstaller.merge(hooks: HookTemplates.claude(cliPath: cli), into: once, marker: marker)
        #expect(once["model"] as? String == "opus")
        let stopGroups = (once["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopGroups?.count == 2)
        #expect(((stopGroups?[0]["hooks"] as? [[String: Any]])?[0]["command"] as? String) == "echo hi")
        #expect(JSONHookInstaller.containsMarker(once, marker: marker))
        #expect(NSDictionary(dictionary: twice) == NSDictionary(dictionary: once))
    }

    @Test func removeIsPreciseAndCleansEmptyContainers() {
        let mixed: [String: Any] = [
            "hooks": [
                "Stop": [["matcher": "", "hooks": [
                    ["type": "command", "command": "echo hi"],
                    ["type": "command", "command": "\(cli) hook claude", "async": true],
                ]]],
                "SessionEnd": [["matcher": "", "hooks": [["type": "command", "command": "\(cli) hook claude"]]]],
            ],
            "other": true,
        ]
        let cleaned = JSONHookInstaller.remove(marker: marker, from: mixed)
        let hooks = cleaned["hooks"] as? [String: Any]
        #expect(hooks?["SessionEnd"] == nil)
        let stopHooks = ((hooks?["Stop"] as? [[String: Any]])?[0]["hooks"] as? [[String: Any]])
        #expect(stopHooks?.count == 1)
        #expect(cleaned["other"] as? Bool == true)
        let onlyOurs: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "\(cli) hook claude"]]]]]]
        #expect(JSONHookInstaller.remove(marker: marker, from: onlyOurs)["hooks"] == nil)
    }

    @Test func installCreatesFileBacksUpAndUninstallRestoresSemantics() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent(".claude/settings.json")
        let inst = installer(dir)
        #expect(!inst.isInstalled(marker: marker, in: file))
        try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
        #expect(inst.isInstalled(marker: marker, in: file))
        #expect(try readJSON(file)["hooks"] != nil)
        let backupsAfterCreate = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []
        #expect(backupsAfterCreate.isEmpty, "文件原本不存在时没有备份")

        try "{\"model\":\"opus\",\"permissions\":{\"allow\":[\"Bash(ls)\"]}}".write(to: file, atomically: true, encoding: .utf8)
        try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
        #expect(backups.count == 1)
        #expect(backups[0].hasPrefix("settings.json."))
        try inst.uninstall(marker: marker, from: file)
        let restored = try readJSON(file)
        #expect(restored["hooks"] == nil)
        #expect(restored["model"] as? String == "opus")
        #expect(((restored["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash(ls)"])
        #expect(!inst.isInstalled(marker: marker, in: file))
    }

    @Test func refusesFilesWithCommentsAndNonObjects() throws {
        let dir = try makeTempDirectory()
        let inst = installer(dir)
        let commented = dir.appendingPathComponent("c.json")
        try "{\n // hi\n \"a\": 1 }".write(to: commented, atomically: true, encoding: .utf8)
        #expect(inst.requiresManualEdit(fileURL: commented))
        #expect(throws: InstallerError.containsComments) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: commented)
        }
        let array = dir.appendingPathComponent("a.json")
        try "[1,2]".write(to: array, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.rootNotObject) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: array)
        }
        let badHooks = dir.appendingPathComponent("h.json")
        try "{\"hooks\": 5}".write(to: badHooks, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.hooksNotObject) {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: badHooks)
        }
    }

    @Test func backupsArePrunedToTen() throws {
        let dir = try makeTempDirectory()
        let file = dir.appendingPathComponent("settings.json")
        let clock = ManualTimeSource(now: Date(timeIntervalSince1970: 1_789_600_000))
        var inst = JSONHookInstaller(backupDirectory: dir.appendingPathComponent("backups"), timeSource: clock)
        inst.backupsToKeep = 3
        try "{}".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<5 {
            try inst.install(hooks: HookTemplates.claude(cliPath: cli), marker: marker, into: file)
            try inst.uninstall(marker: marker, from: file)
            clock.advance(by: 1)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)
        #expect(backups.count == 3)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter "HookTemplatesTests|JSONHookInstallerTests" 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'HookTemplates' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Installer/HookTemplates.swift`:

```swift
import Foundation

/// 各 Agent 的 hook 配置模板。返回值是要写入配置文件 "hooks" 键下的字典。
public enum HookTemplates {
    public static func marker(agent: String) -> String { "/.local/bin/agentalarm hook \(agent)" }

    public static func command(cliPath: String, agent: String) -> String {
        "\(shellQuoted(cliPath)) hook \(agent)"
    }

    static func shellQuoted(_ path: String) -> String {
        let safe = path.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
        if safe { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func claude(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "claude")
        let asyncHook: [String: Any] = ["type": "command", "command": cmd, "async": true, "timeout": 5]
        let endHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 1]
        return [
            "Stop": [["matcher": "", "hooks": [asyncHook]]],
            "Notification": [["matcher": "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input",
                              "hooks": [asyncHook]]],
            "UserPromptSubmit": [["matcher": "", "hooks": [asyncHook]]],
            "SessionEnd": [["matcher": "", "hooks": [endHook]]],
        ]
    }

    public static func codex(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "codex")
        let asyncHook: [String: Any] = ["type": "command", "command": cmd, "async": true, "timeout": 5]
        let syncHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 5]
        let endHook: [String: Any] = ["type": "command", "command": cmd, "timeout": 2]
        return [
            "Stop": [["hooks": [asyncHook]]],
            "PermissionRequest": [["hooks": [syncHook]]],
            "UserPromptSubmit": [["hooks": [asyncHook]]],
            "SessionEnd": [["hooks": [endHook]]],
        ]
    }

    public static func gemini(cliPath: String) -> [String: Any] {
        let cmd = command(cliPath: cliPath, agent: "gemini")
        let hook: [String: Any] = ["type": "command", "command": cmd, "timeout": 3000]
        var result: [String: Any] = [:]
        for event in ["AfterAgent", "Notification", "BeforeAgent", "SessionEnd"] {
            result[event] = [["hooks": [hook]]]
        }
        return result
    }

    public static func template(agent: String, cliPath: String) -> [String: Any]? {
        switch agent {
        case "claude": return claude(cliPath: cliPath)
        case "codex": return codex(cliPath: cliPath)
        case "gemini": return gemini(cliPath: cliPath)
        default: return nil
        }
    }
}
```

`Sources/AgentAlarmCore/Installer/JSONHookInstaller.swift`:

```swift
import Foundation

public enum InstallerError: Error, Equatable {
    case containsComments
    case rootNotObject
    case hooksNotObject
}

/// 把 hook 条目幂等地合并进 JSON 配置文件，或精确移除；写前备份，原子写入。
public struct JSONHookInstaller {
    public var backupDirectory: URL
    public var fileManager: FileManager
    public var timeSource: any TimeSource
    public var backupsToKeep = 10

    public init(backupDirectory: URL, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()) {
        self.backupDirectory = backupDirectory; self.fileManager = fileManager; self.timeSource = timeSource
    }

    // MARK: 文件操作

    public func install(hooks: [String: Any], marker: String, into fileURL: URL) throws {
        let root = try readRoot(fileURL)
        let merged = try Self.mergeChecked(hooks: hooks, into: root, marker: marker)
        try backupIfExists(fileURL)
        try write(merged, to: fileURL)
    }

    public func uninstall(marker: String, from fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let root = try readRoot(fileURL)
        let cleaned = Self.remove(marker: marker, from: root)
        try backupIfExists(fileURL)
        try write(cleaned, to: fileURL)
    }

    public func isInstalled(marker: String, in fileURL: URL) -> Bool {
        guard let root = try? readRoot(fileURL) else { return false }
        return Self.containsMarker(root, marker: marker)
    }

    public func requiresManualEdit(fileURL: URL) -> Bool {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return Self.containsComments(text)
    }

    private func readRoot(_ fileURL: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        if Self.containsComments(text) { throw InstallerError.containsComments }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw InstallerError.rootNotObject
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw InstallerError.hooksNotObject }
        return root
    }

    private func write(_ root: [String: Any], to fileURL: URL) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: fileURL, options: .atomic)
    }

    private func backupIfExists(_ fileURL: URL) throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = fileURL.lastPathComponent
        let target = backupDirectory.appendingPathComponent("\(name).\(formatter.string(from: timeSource.now))")
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.copyItem(at: fileURL, to: target)
        let siblings = (try? fileManager.contentsOfDirectory(atPath: backupDirectory.path))?
            .filter { $0.hasPrefix("\(name).") }.sorted(by: >) ?? []
        for stale in siblings.dropFirst(backupsToKeep) {
            try? fileManager.removeItem(at: backupDirectory.appendingPathComponent(stale))
        }
    }

    // MARK: 纯函数

    /// 字符串外出现 // 或 /* 即视为含注释。
    public static func containsComments(_ text: String) -> Bool {
        var inString = false
        var escaped = false
        var previous: Character = " "
        for char in text {
            if inString {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { inString = false }
            } else {
                if char == "\"" { inString = true }
                else if previous == "/" && (char == "/" || char == "*") { return true }
            }
            previous = char
        }
        return false
    }

    static func mergeChecked(hooks: [String: Any], into root: [String: Any], marker: String) throws -> [String: Any] {
        if let existing = root["hooks"], !(existing is [String: Any]) { throw InstallerError.hooksNotObject }
        return merge(hooks: hooks, into: root, marker: marker)
    }

    public static func merge(hooks: [String: Any], into root: [String: Any], marker: String) -> [String: Any] {
        var result = root
        var hooksDict = root["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            let newGroups = value as? [Any] ?? []
            var groups = hooksDict[event] as? [Any] ?? []
            if !groups.contains(where: { groupContainsMarker($0, marker: marker) }) {
                groups.append(contentsOf: newGroups)
            }
            hooksDict[event] = groups
        }
        result["hooks"] = hooksDict
        return result
    }

    public static func remove(marker: String, from root: [String: Any]) -> [String: Any] {
        var result = root
        guard var hooksDict = root["hooks"] as? [String: Any] else { return result }
        for (event, value) in hooksDict {
            let groups = value as? [Any] ?? []
            let kept: [Any] = groups.compactMap { group in
                guard var dict = group as? [String: Any], let hooks = dict["hooks"] as? [Any] else { return group }
                let remaining = hooks.filter { !hookContainsMarker($0, marker: marker) }
                if remaining.isEmpty { return nil }
                dict["hooks"] = remaining
                return dict
            }
            if kept.isEmpty { hooksDict.removeValue(forKey: event) } else { hooksDict[event] = kept }
        }
        if hooksDict.isEmpty { result.removeValue(forKey: "hooks") } else { result["hooks"] = hooksDict }
        return result
    }

    public static func containsMarker(_ root: [String: Any], marker: String) -> Bool {
        guard let hooksDict = root["hooks"] as? [String: Any] else { return false }
        return hooksDict.values.contains { value in
            (value as? [Any] ?? []).contains { groupContainsMarker($0, marker: marker) }
        }
    }

    static func groupContainsMarker(_ group: Any, marker: String) -> Bool {
        guard let dict = group as? [String: Any], let hooks = dict["hooks"] as? [Any] else { return false }
        return hooks.contains { hookContainsMarker($0, marker: marker) }
    }

    static func hookContainsMarker(_ hook: Any, marker: String) -> Bool {
        guard let dict = hook as? [String: Any], let command = dict["command"] as? String else { return false }
        return command.contains(marker)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter "HookTemplatesTests|JSONHookInstallerTests" 2>&1 | tail -2`
Expected: 10 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Installer Tests/AgentAlarmCoreTests/HookTemplatesTests.swift Tests/AgentAlarmCoreTests/JSONHookInstallerTests.swift
git commit -m "feat(core): add hook templates and idempotent JSON hook installer with backups"
```

---

### Task 14: OpenCode 插件安装器与软链接安装器

**Files:**
- Create: `Sources/AgentAlarmCore/Installer/OpenCodePluginInstaller.swift`
- Create: `Sources/AgentAlarmCore/Installer/SymlinkInstaller.swift`
- Test: `Tests/AgentAlarmCoreTests/OpenCodePluginInstallerTests.swift`
- Test: `Tests/AgentAlarmCoreTests/SymlinkInstallerTests.swift`

**Interfaces:**
- Produces:
  - `struct OpenCodePluginInstaller { static let markerLine = "// AgentAlarm plugin v1, managed by AgentAlarm.app"; static let fileName = "agentalarm.ts"; init(fileManager: FileManager = .default); static func pluginSource(cliPath: String) -> String; func install(cliPath: String, pluginsDirectory: URL) throws; func uninstall(pluginsDirectory: URL) throws; func isInstalled(pluginsDirectory: URL) -> Bool }`
  - `enum SymlinkStatus: Equatable, Sendable { ok, missing, wrongTarget(String), notASymlink }`
  - `enum SymlinkError: Error, Equatable { pathIsNotSymlink }`
  - `struct SymlinkInstaller { init(fileManager: FileManager = .default); func status(link: URL, expectedTarget: URL) -> SymlinkStatus; @discardableResult func ensure(link: URL, target: URL) throws -> Bool }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/OpenCodePluginInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct OpenCodePluginInstallerTests {
    let cli = "/Users/jack/.local/bin/agentalarm"

    @Test func sourceHasMarkerCliPathAndEvents() {
        let source = OpenCodePluginInstaller.pluginSource(cliPath: cli)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == Substring(OpenCodePluginInstaller.markerLine))
        #expect(source.contains("const CLI = \"/Users/jack/.local/bin/agentalarm\""))
        for event in ["session.idle", "permission.asked", "question.asked", "session.status"] {
            #expect(source.contains("\"\(event)\""), event)
        }
        for kind in ["turn_complete", "needs_permission", "needs_input", "resumed"] {
            #expect(source.contains("\"\(kind)\""), kind)
        }
        #expect(source.contains("hook opencode --payload"))
        #expect(source.contains("parentID"))
    }

    @Test func installUninstallRoundTrip() throws {
        let dir = try makeTempDirectory().appendingPathComponent("plugins")
        let installer = OpenCodePluginInstaller()
        #expect(!installer.isInstalled(pluginsDirectory: dir))
        try installer.install(cliPath: cli, pluginsDirectory: dir)
        #expect(installer.isInstalled(pluginsDirectory: dir))
        let file = dir.appendingPathComponent(OpenCodePluginInstaller.fileName)
        #expect(try String(contentsOf: file, encoding: .utf8) == OpenCodePluginInstaller.pluginSource(cliPath: cli))
        try installer.uninstall(pluginsDirectory: dir)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func uninstallKeepsForeignFile() throws {
        let dir = try makeTempDirectory().appendingPathComponent("plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(OpenCodePluginInstaller.fileName)
        try "// someone else's plugin\nexport const X = 1\n".write(to: file, atomically: true, encoding: .utf8)
        let installer = OpenCodePluginInstaller()
        #expect(!installer.isInstalled(pluginsDirectory: dir))
        try installer.uninstall(pluginsDirectory: dir)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
```

`Tests/AgentAlarmCoreTests/SymlinkInstallerTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct SymlinkInstallerTests {
    @Test func createsRepairsAndReportsStatus() throws {
        let dir = try makeTempDirectory()
        let target = dir.appendingPathComponent("AgentAlarm.app/Contents/MacOS/agentalarm")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "binary".write(to: target, atomically: true, encoding: .utf8)
        let other = dir.appendingPathComponent("other")
        try "x".write(to: other, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("bin/agentalarm")
        let installer = SymlinkInstaller()

        #expect(installer.status(link: link, expectedTarget: target) == .missing)
        #expect(try installer.ensure(link: link, target: target) == true)
        #expect(installer.status(link: link, expectedTarget: target) == .ok)
        #expect(try installer.ensure(link: link, target: target) == false, "已正确时不重建")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(installer.status(link: link, expectedTarget: target) == .wrongTarget(other.path))
        #expect(try installer.ensure(link: link, target: target) == true)
        #expect(installer.status(link: link, expectedTarget: target) == .ok)
    }

    @Test func refusesToReplaceRegularFile() throws {
        let dir = try makeTempDirectory()
        let link = dir.appendingPathComponent("agentalarm")
        try "real file".write(to: link, atomically: true, encoding: .utf8)
        let target = dir.appendingPathComponent("target")
        try "t".write(to: target, atomically: true, encoding: .utf8)
        let installer = SymlinkInstaller()
        #expect(installer.status(link: link, expectedTarget: target) == .notASymlink)
        #expect(throws: SymlinkError.pathIsNotSymlink) { try installer.ensure(link: link, target: target) }
        #expect(try String(contentsOf: link, encoding: .utf8) == "real file")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter "OpenCodePluginInstallerTests|SymlinkInstallerTests" 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'OpenCodePluginInstaller' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Installer/OpenCodePluginInstaller.swift`:

```swift
import Foundation

/// 生成并管理 ~/.config/opencode/plugins/agentalarm.ts。
public struct OpenCodePluginInstaller {
    public static let markerLine = "// AgentAlarm plugin v1, managed by AgentAlarm.app"
    public static let fileName = "agentalarm.ts"
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public static func pluginSource(cliPath: String) -> String {
        let quotedPath = String(decoding: try! JSONEncoder().encode(cliPath), as: UTF8.self)
        return """
        \(markerLine)
        // 由 AgentAlarm.app 生成，卸载时由 App 删除；手动修改会在下次接入时被覆盖。
        const CLI = \(quotedPath)

        export const AgentAlarmPlugin = async ({ client, $ }) => {
          const send = async (kind, sessionID, message) => {
            try {
              if (!sessionID) return
              const res = await client.session.get({ path: { id: sessionID } })
              const session = res && res.data ? res.data : null
              if (!session || session.parentID) return
              const payload = JSON.stringify({
                kind,
                sessionID,
                title: session.title ?? null,
                directory: session.directory ?? null,
                message: message ?? null,
              })
              await $`${CLI} hook opencode --payload ${payload}`.quiet().nothrow()
            } catch (_) {}
          }
          return {
            event: async ({ event }) => {
              const p = (event && event.properties) || {}
              switch (event.type) {
                case "session.idle":
                  await send("turn_complete", p.sessionID)
                  break
                case "permission.asked":
                  await send("needs_permission", p.sessionID, typeof p.permission === "string" ? p.permission : undefined)
                  break
                case "question.asked":
                  await send("needs_input", p.sessionID)
                  break
                case "session.status":
                  if (p.status && p.status.type === "busy") await send("resumed", p.sessionID)
                  break
                default:
                  break
              }
            },
          }
        }

        """
    }

    public func install(cliPath: String, pluginsDirectory: URL) throws {
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        let file = pluginsDirectory.appendingPathComponent(Self.fileName)
        try Data(Self.pluginSource(cliPath: cliPath).utf8).write(to: file, options: .atomic)
    }

    public func uninstall(pluginsDirectory: URL) throws {
        guard isInstalled(pluginsDirectory: pluginsDirectory) else { return }
        try fileManager.removeItem(at: pluginsDirectory.appendingPathComponent(Self.fileName))
    }

    public func isInstalled(pluginsDirectory: URL) -> Bool {
        let file = pluginsDirectory.appendingPathComponent(Self.fileName)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.split(separator: "\n", omittingEmptySubsequences: false).first == Substring(Self.markerLine)
    }
}
```

`Sources/AgentAlarmCore/Installer/SymlinkInstaller.swift`:

```swift
import Foundation

public enum SymlinkStatus: Equatable, Sendable {
    case ok
    case missing
    case wrongTarget(String)
    case notASymlink
}

public enum SymlinkError: Error, Equatable {
    case pathIsNotSymlink
}

/// 维护 ~/.local/bin/agentalarm 指向 App 内 CLI 的软链接。
public struct SymlinkInstaller {
    public var fileManager: FileManager
    public init(fileManager: FileManager = .default) { self.fileManager = fileManager }

    public func status(link: URL, expectedTarget: URL) -> SymlinkStatus {
        guard let attributes = try? fileManager.attributesOfItem(atPath: link.path) else { return .missing }
        guard (attributes[.type] as? FileAttributeType) == .typeSymbolicLink else { return .notASymlink }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) else { return .missing }
        let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent()).standardizedFileURL.path
        return resolved == expectedTarget.standardizedFileURL.path ? .ok : .wrongTarget(destination)
    }

    /// 返回 true 表示新建或替换了链接。
    @discardableResult
    public func ensure(link: URL, target: URL) throws -> Bool {
        switch status(link: link, expectedTarget: target) {
        case .ok:
            return false
        case .notASymlink:
            throw SymlinkError.pathIsNotSymlink
        case .missing, .wrongTarget:
            try fileManager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.attributesOfItem(atPath: link.path)) != nil {
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            return true
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter "OpenCodePluginInstallerTests|SymlinkInstallerTests" 2>&1 | tail -2`
Expected: 5 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Installer Tests/AgentAlarmCoreTests/OpenCodePluginInstallerTests.swift Tests/AgentAlarmCoreTests/SymlinkInstallerTests.swift
git commit -m "feat(core): add OpenCode plugin installer and symlink installer"
```

---

### Task 15: AgentPaths 与 AgentIntegrationManager

**Files:**
- Create: `Sources/AgentAlarmCore/Installer/AgentPaths.swift`
- Create: `Sources/AgentAlarmCore/Installer/AgentIntegrationManager.swift`
- Test: `Tests/AgentAlarmCoreTests/AgentIntegrationManagerTests.swift`

**Interfaces:**
- Consumes: Task 13、14 的安装器与模板。
- Produces:
  - `struct AgentPaths: Sendable, Equatable { init(home: URL); static var standard: AgentPaths; home, claudeSettings, codexHome, codexHooks, geminiSettings, openCodePlugins, cliLink, appSupport, socket, backups: URL }`
  - `enum AgentIntegrationStatus: Equatable, Sendable { notInstalled, installed, awaitingTrust, verified, manualRequired(String) }`
  - `enum IntegrationError: Error, Equatable { unsupportedAgent(String) }`
  - `struct AgentIntegrationManager { init(paths: AgentPaths, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()); var paths; var cliPath: String; func install(_ agent: String) throws; func uninstall(_ agent: String) throws; func status(_ agent: String, verified: Bool) -> AgentIntegrationStatus; func manualSnippet(_ agent: String) -> String; func configFile(_ agent: String) -> URL? }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/AgentIntegrationManagerTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct AgentIntegrationManagerTests {
    @Test func pathsDeriveFromHome() {
        let paths = AgentPaths(home: URL(fileURLWithPath: "/Users/jack"))
        #expect(paths.claudeSettings.path == "/Users/jack/.claude/settings.json")
        #expect(paths.codexHome.path == "/Users/jack/.codex")
        #expect(paths.codexHooks.path == "/Users/jack/.codex/hooks.json")
        #expect(paths.geminiSettings.path == "/Users/jack/.gemini/settings.json")
        #expect(paths.openCodePlugins.path == "/Users/jack/.config/opencode/plugins")
        #expect(paths.cliLink.path == "/Users/jack/.local/bin/agentalarm")
        #expect(paths.appSupport.path == "/Users/jack/Library/Application Support/AgentAlarm")
        #expect(paths.socket.path == "/Users/jack/Library/Application Support/AgentAlarm/agentalarm.sock")
        #expect(paths.backups.path == "/Users/jack/Library/Application Support/AgentAlarm/backups")
    }

    @Test func installsAndUninstallsEveryAgent() throws {
        let home = try makeTempDirectory()
        let manager = AgentIntegrationManager(paths: AgentPaths(home: home))
        for agent in AgentNames.supported {
            #expect(manager.status(agent, verified: false) == .notInstalled, agent)
            try manager.install(agent)
            let expected: AgentIntegrationStatus = agent == "codex" ? .awaitingTrust : .installed
            #expect(manager.status(agent, verified: false) == expected, agent)
            #expect(manager.status(agent, verified: true) == .verified, agent)
            #expect(manager.configFile(agent).map { FileManager.default.fileExists(atPath: $0.path) } == true, agent)
        }
        let claude = try String(contentsOf: manager.paths.claudeSettings, encoding: .utf8)
        #expect(claude.contains("\(home.path)/.local/bin/agentalarm hook claude"))
        for agent in AgentNames.supported {
            try manager.uninstall(agent)
            #expect(manager.status(agent, verified: true) == .notInstalled, agent)
        }
        #expect(!FileManager.default.fileExists(atPath: manager.paths.openCodePlugins.appendingPathComponent("agentalarm.ts").path))
    }

    @Test func commentedConfigRequiresManualEditAndSnippetIsUsable() throws {
        let home = try makeTempDirectory()
        let manager = AgentIntegrationManager(paths: AgentPaths(home: home))
        try FileManager.default.createDirectory(at: manager.paths.geminiSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\n  // my settings\n  \"theme\": \"dark\"\n}".write(to: manager.paths.geminiSettings, atomically: true, encoding: .utf8)
        guard case .manualRequired = manager.status("gemini", verified: false) else {
            Issue.record("expected manualRequired"); return
        }
        #expect(throws: InstallerError.containsComments) { try manager.install("gemini") }
        let snippet = manager.manualSnippet("gemini")
        let parsed = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        #expect((parsed?["hooks"] as? [String: Any])?["AfterAgent"] != nil)
        #expect(manager.manualSnippet("opencode").hasPrefix(OpenCodePluginInstaller.markerLine))
    }

    @Test func unsupportedAgentThrows() throws {
        let manager = AgentIntegrationManager(paths: AgentPaths(home: try makeTempDirectory()))
        #expect(throws: IntegrationError.unsupportedAgent("cursor")) { try manager.install("cursor") }
        #expect(manager.status("cursor", verified: false) == .notInstalled)
        #expect(manager.configFile("cursor") == nil)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter AgentIntegrationManagerTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'AgentPaths' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Installer/AgentPaths.swift`:

```swift
import Foundation

/// 所有依赖 HOME 的路径集中在这里，测试时用临时目录替换。
public struct AgentPaths: Sendable, Equatable {
    public var home: URL
    public var claudeSettings: URL
    public var codexHome: URL
    public var codexHooks: URL
    public var geminiSettings: URL
    public var openCodePlugins: URL
    public var cliLink: URL
    public var appSupport: URL
    public var socket: URL
    public var backups: URL

    public init(home: URL) {
        self.home = home
        claudeSettings = home.appendingPathComponent(".claude/settings.json")
        codexHome = home.appendingPathComponent(".codex")
        codexHooks = codexHome.appendingPathComponent("hooks.json")
        geminiSettings = home.appendingPathComponent(".gemini/settings.json")
        openCodePlugins = home.appendingPathComponent(".config/opencode/plugins")
        cliLink = home.appendingPathComponent(".local/bin/agentalarm")
        appSupport = home.appendingPathComponent("Library/Application Support/AgentAlarm")
        socket = appSupport.appendingPathComponent("agentalarm.sock")
        backups = appSupport.appendingPathComponent("backups")
    }

    public static var standard: AgentPaths {
        AgentPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}
```

`Sources/AgentAlarmCore/Installer/AgentIntegrationManager.swift`:

```swift
import Foundation

public enum AgentIntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case awaitingTrust
    case verified
    case manualRequired(String)
}

public enum IntegrationError: Error, Equatable {
    case unsupportedAgent(String)
}

/// 每个 Agent 的接入、卸载、状态判定与手动片段。
public struct AgentIntegrationManager {
    public var paths: AgentPaths
    private let jsonInstaller: JSONHookInstaller
    private let pluginInstaller: OpenCodePluginInstaller
    private let fileManager: FileManager

    public init(paths: AgentPaths, fileManager: FileManager = .default, timeSource: any TimeSource = SystemTimeSource()) {
        self.paths = paths
        self.fileManager = fileManager
        jsonInstaller = JSONHookInstaller(backupDirectory: paths.backups, fileManager: fileManager, timeSource: timeSource)
        pluginInstaller = OpenCodePluginInstaller(fileManager: fileManager)
    }

    public var cliPath: String { paths.cliLink.path }

    public func configFile(_ agent: String) -> URL? {
        switch agent {
        case "claude": return paths.claudeSettings
        case "codex": return paths.codexHooks
        case "gemini": return paths.geminiSettings
        case "opencode": return paths.openCodePlugins.appendingPathComponent(OpenCodePluginInstaller.fileName)
        default: return nil
        }
    }

    public func install(_ agent: String) throws {
        if agent == "opencode" {
            try pluginInstaller.install(cliPath: cliPath, pluginsDirectory: paths.openCodePlugins)
            return
        }
        guard let template = HookTemplates.template(agent: agent, cliPath: cliPath), let file = configFile(agent) else {
            throw IntegrationError.unsupportedAgent(agent)
        }
        try jsonInstaller.install(hooks: template, marker: HookTemplates.marker(agent: agent), into: file)
    }

    public func uninstall(_ agent: String) throws {
        if agent == "opencode" {
            try pluginInstaller.uninstall(pluginsDirectory: paths.openCodePlugins)
            return
        }
        guard AgentNames.supported.contains(agent), let file = configFile(agent) else {
            throw IntegrationError.unsupportedAgent(agent)
        }
        try jsonInstaller.uninstall(marker: HookTemplates.marker(agent: agent), from: file)
    }

    public func status(_ agent: String, verified: Bool) -> AgentIntegrationStatus {
        let installed: Bool
        if agent == "opencode" {
            installed = pluginInstaller.isInstalled(pluginsDirectory: paths.openCodePlugins)
        } else {
            guard AgentNames.supported.contains(agent), let file = configFile(agent) else { return .notInstalled }
            if fileManager.fileExists(atPath: file.path), jsonInstaller.requiresManualEdit(fileURL: file) {
                return .manualRequired("配置文件含注释，自动改写会丢失注释，请手动粘贴片段")
            }
            installed = jsonInstaller.isInstalled(marker: HookTemplates.marker(agent: agent), in: file)
        }
        guard installed else { return .notInstalled }
        if verified { return .verified }
        return agent == "codex" ? .awaitingTrust : .installed
    }

    public func manualSnippet(_ agent: String) -> String {
        if agent == "opencode" { return OpenCodePluginInstaller.pluginSource(cliPath: cliPath) }
        guard let template = HookTemplates.template(agent: agent, cliPath: cliPath) else { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: ["hooks": template],
                                                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test 2>&1 | tail -2`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Installer Tests/AgentAlarmCoreTests/AgentIntegrationManagerTests.swift
git commit -m "feat(core): add AgentPaths and AgentIntegrationManager"
```

---

### Task 16: ProcessTree 宿主识别

**Files:**
- Create: `Sources/AgentAlarmCore/Support/ProcessTree.swift`
- Test: `Tests/AgentAlarmCoreTests/ProcessTreeTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `HostInfo`。
- Produces: `enum ProcessTree { struct Ancestor: Equatable, Sendable { pid: pid_t; path: String }; static func parentPid(of: pid_t) -> pid_t?; static func executablePath(of: pid_t) -> String?; static func ancestors(from pid: pid_t = getpid(), limit: Int = 32) -> [Ancestor]; static func appBundlePath(in executablePath: String) -> String?; static func detectHost(from ancestors: [Ancestor], bundleReader: (String) -> (bundleId: String, name: String)?) -> HostInfo?; static func detectHost() -> HostInfo? }`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/ProcessTreeTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

@Suite struct ProcessTreeTests {
    @Test func appBundlePathTakesOutermostApp() {
        #expect(ProcessTree.appBundlePath(in: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") == "/Applications/Claude.app")
        #expect(ProcessTree.appBundlePath(in: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == "/Applications/iTerm.app")
        #expect(ProcessTree.appBundlePath(in: "/usr/bin/zsh") == nil)
    }

    @Test func detectHostUsesFirstAppAndOutermostPidOfSameBundle() {
        let ancestors = [
            ProcessTree.Ancestor(pid: 10, path: "/bin/sh"),
            ProcessTree.Ancestor(pid: 9, path: "/Users/jack/.nvm/versions/node/v22/bin/node"),
            ProcessTree.Ancestor(pid: 8, path: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            ProcessTree.Ancestor(pid: 7, path: "/Applications/Claude.app/Contents/MacOS/Claude"),
            ProcessTree.Ancestor(pid: 1, path: "/sbin/launchd"),
        ]
        let host = ProcessTree.detectHost(from: ancestors) { bundlePath in
            bundlePath == "/Applications/Claude.app" ? ("com.anthropic.claudefordesktop", "Claude") : nil
        }
        #expect(host == HostInfo(bundleId: "com.anthropic.claudefordesktop", pid: 7, name: "Claude"))
        #expect(ProcessTree.detectHost(from: [ProcessTree.Ancestor(pid: 2, path: "/usr/bin/zsh")]) { _ in nil } == nil)
    }

    @Test func realAncestorsAreReadable() {
        let ancestors = ProcessTree.ancestors()
        #expect(!ancestors.isEmpty)
        #expect(ancestors.allSatisfy { $0.pid > 0 && $0.path.hasPrefix("/") })
        _ = ProcessTree.detectHost()
        #expect(ProcessTree.parentPid(of: 1) == nil || ProcessTree.parentPid(of: 1) == 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter ProcessTreeTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'ProcessTree' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Support/ProcessTree.swift`:

```swift
import Darwin
import Foundation

/// 沿父进程链向上找到宿主 .app，用于语音抑制和跳转。
public enum ProcessTree {
    public struct Ancestor: Equatable, Sendable {
        public var pid: pid_t
        public var path: String
        public init(pid: pid_t, path: String) { self.pid = pid; self.path = path }
    }

    public static func parentPid(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func ancestors(from pid: pid_t = getpid(), limit: Int = 32) -> [Ancestor] {
        var result: [Ancestor] = []
        var current = parentPid(of: pid)
        while let candidate = current, result.count < limit {
            if let path = executablePath(of: candidate) {
                result.append(Ancestor(pid: candidate, path: path))
            }
            if candidate == 1 { break }
            current = parentPid(of: candidate)
        }
        return result
    }

    /// 取路径中第一个 ".app/Contents/" 之前的部分，即最外层 App。
    public static func appBundlePath(in executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/Contents/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }

    public static func detectHost(from ancestors: [Ancestor],
                                  bundleReader: (String) -> (bundleId: String, name: String)?) -> HostInfo? {
        guard let firstIndex = ancestors.firstIndex(where: { appBundlePath(in: $0.path) != nil }),
              let bundlePath = appBundlePath(in: ancestors[firstIndex].path),
              let info = bundleReader(bundlePath) else { return nil }
        var pid = ancestors[firstIndex].pid
        for ancestor in ancestors[(firstIndex + 1)...] where appBundlePath(in: ancestor.path) == bundlePath {
            pid = ancestor.pid
        }
        return HostInfo(bundleId: info.bundleId, pid: pid, name: info.name)
    }

    public static func detectHost() -> HostInfo? {
        detectHost(from: ancestors(), bundleReader: readBundle)
    }

    static func readBundle(_ path: String) -> (bundleId: String, name: String)? {
        guard let bundle = Bundle(path: path), let identifier = bundle.bundleIdentifier else { return nil }
        let info = bundle.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return (identifier, name)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter ProcessTreeTests 2>&1 | tail -2`
Expected: 3 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Support/ProcessTree.swift Tests/AgentAlarmCoreTests/ProcessTreeTests.swift
git commit -m "feat(core): add process tree host detection"
```

---

### Task 17: Unix socket 传输（客户端与服务端）

**Files:**
- Create: `Sources/AgentAlarmCore/Transport/SocketClient.swift`
- Create: `Sources/AgentAlarmCore/Transport/SocketServer.swift`
- Test: `Tests/AgentAlarmCoreTests/SocketTransportTests.swift`

**Interfaces:**
- Consumes: Task 2 的 `EventCoding`。
- Produces:
  - `struct SocketClient { init(path: String, timeout: TimeInterval = 0.5, maxMessageBytes: Int = 65_536); enum SendResult: Equatable { delivered, unavailable, timedOut, tooLarge }; func send(_ data: Data) -> SendResult; func probe() -> Bool }`
  - `final class SocketServer: @unchecked Sendable { enum ServerError: Error { pathTooLong, create(Int32), bind(Int32), listen(Int32) }; init(path: String, maxMessageBytes: Int = 65_536, handler: @escaping @Sendable (Data) -> Void); func start() throws; func stop() }`
  - 注意 macOS Unix socket 路径上限 104 字节；测试要用 `/tmp/aa-<短id>.sock` 这种短路径。

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/SocketTransportTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Data] = []
    let semaphore = DispatchSemaphore(value: 0)
    func append(_ data: Data) { lock.lock(); items.append(data); lock.unlock(); semaphore.signal() }
    var received: [Data] { lock.lock(); defer { lock.unlock() }; return items }
}

@Suite(.serialized) struct SocketTransportTests {
    func shortSocketPath() -> String { "/tmp/aa-\(UUID().uuidString.prefix(8)).sock" }

    @Test func roundTripDeliversOneEventPerConnection() throws {
        let path = shortSocketPath()
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let event = AlarmEvent(id: "E1", agent: "claude", kind: .turnComplete, sessionId: "S1", timestamp: Date(timeIntervalSince1970: 1_789_600_000))
        let client = SocketClient(path: path)
        #expect(client.send(try EventCoding.encode(event)) == .delivered)
        #expect(client.send(try EventCoding.encode(event)) == .delivered)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(collector.received.count == 2)
        #expect(try EventCoding.decode(collector.received[0]) == event)
        #expect(client.probe())
        var mode = stat()
        stat(path, &mode)
        #expect(mode.st_mode & 0o777 == 0o600)
    }

    @Test func serverKeepsOnlyFirstLineAndDropsOversized() throws {
        let path = shortSocketPath()
        let collector = Collector()
        let server = SocketServer(path: path, maxMessageBytes: 1024) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let client = SocketClient(path: path, maxMessageBytes: 1024)
        #expect(client.send(Data("{\"a\":1}\n{\"b\":2}\n".utf8)) == .delivered)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(String(decoding: collector.received[0], as: UTF8.self) == "{\"a\":1}")
        #expect(client.send(Data(repeating: 0x41, count: 2048)) == .tooLarge)
        #expect(collector.received.count == 1)
    }

    @Test func unavailableServerFailsFast() {
        let client = SocketClient(path: shortSocketPath())
        let started = Date()
        #expect(client.send(Data("{}".utf8)) == .unavailable)
        #expect(!client.probe())
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test func tooLongPathIsRejected() {
        let long = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        #expect(throws: (any Error).self) { try SocketServer(path: long) { _ in }.start() }
        #expect(SocketClient(path: long).send(Data("{}".utf8)) == .unavailable)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter SocketTransportTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'SocketServer' in scope`

- [ ] **Step 3: 实现**

`Sources/AgentAlarmCore/Transport/SocketClient.swift`:

```swift
import Darwin
import Foundation

enum UnixSocketAddress {
    static let maxPathBytes = 103

    static func make(path: String) -> sockaddr_un? {
        guard path.utf8.count <= maxPathBytes else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { strlcpy(&address.sun_path.0, $0, MemoryLayout.size(ofValue: address.sun_path)) }
        return address
    }

    static func withSockaddr<T>(_ address: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}

/// 向 App 的 Unix socket 发送一行 JSON。
public struct SocketClient {
    public enum SendResult: Equatable, Sendable { case delivered, unavailable, timedOut, tooLarge }

    public var path: String
    public var timeout: TimeInterval
    public var maxMessageBytes: Int

    public init(path: String, timeout: TimeInterval = 0.5, maxMessageBytes: Int = 65_536) {
        self.path = path; self.timeout = timeout; self.maxMessageBytes = maxMessageBytes
    }

    public func send(_ data: Data) -> SendResult {
        guard data.count <= maxMessageBytes else { return .tooLarge }
        guard let fd = connect() else { return .unavailable }
        defer { close(fd) }
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        let total = payload.count
        var offset = 0
        while offset < total {
            let written = payload.withUnsafeBytes { buffer -> Int in
                write(fd, buffer.baseAddress!.advanced(by: offset), total - offset)
            }
            if written <= 0 { return .timedOut }
            offset += written
        }
        shutdown(fd, SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 16)
        let read = Darwin.read(fd, &scratch, scratch.count)
        return read == 0 ? .delivered : .timedOut
    }

    public func probe() -> Bool {
        guard let fd = connect() else { return false }
        close(fd)
        return true
    }

    private func connect() -> Int32? {
        guard var address = UnixSocketAddress.make(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let rc = UnixSocketAddress.withSockaddr(&address) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else { close(fd); return nil }
        return fd
    }
}
```

`Sources/AgentAlarmCore/Transport/SocketServer.swift`:

```swift
import Darwin
import Foundation

/// 监听 Unix socket，每个连接读取第一行 JSON 交给 handler。
public final class SocketServer: @unchecked Sendable {
    public enum ServerError: Error { case pathTooLong, create(Int32), bind(Int32), listen(Int32) }

    private let path: String
    private let maxMessageBytes: Int
    private let handler: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "com.jack.agentalarm.socket")
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, maxMessageBytes: Int = 65_536, handler: @escaping @Sendable (Data) -> Void) {
        self.path = path; self.maxMessageBytes = maxMessageBytes; self.handler = handler
    }

    public func start() throws {
        guard var address = UnixSocketAddress.make(path: path) else { throw ServerError.pathTooLong }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.create(errno) }
        let bound = UnixSocketAddress.withSockaddr(&address) { bind(fd, $0, $1) }
        guard bound == 0 else { let code = errno; close(fd); throw ServerError.bind(code) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let code = errno; close(fd); throw ServerError.listen(code) }
        listenFD = fd
        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.acceptOne() }
        readSource.resume()
        source = readSource
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let handler = handler
        let limit = maxMessageBytes
        DispatchQueue.global(qos: .userInitiated).async {
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            var overflow = false
            while true {
                let count = read(client, &chunk, chunk.count)
                if count <= 0 { break }
                data.append(contentsOf: chunk[0..<count])
                if data.count > limit { overflow = true; break }
            }
            close(client)
            guard !overflow else { return }
            if let newline = data.firstIndex(of: 0x0A) { data = data.prefix(upTo: newline) }
            if !data.isEmpty { handler(data) }
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter SocketTransportTests 2>&1 | tail -2`
Expected: 4 个测试通过

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentAlarmCore/Transport Tests/AgentAlarmCoreTests/SocketTransportTests.swift
git commit -m "feat(core): add Unix socket client and server"
```

---

### Task 18: CLI 命令逻辑、XcodeGen 工程与 agentalarm 可执行程序

**Files:**
- Create: `Sources/AgentAlarmCore/CLI/CLICommands.swift`
- Create: `CLI/main.swift`
- Create: `project.yml`
- Test: `Tests/AgentAlarmCoreTests/CLICommandsTests.swift`

**Interfaces:**
- Consumes: Task 6 的 `AdapterRegistry`，Task 16 的 `ProcessTree`，Task 17 的 `SocketClient`，Task 15 的 `AgentPaths`。
- Produces:
  - `struct CLIEnvironment { arguments: [String]; environment: [String: String]; socketPath: String; detectHost: @Sendable () -> HostInfo?; readStdin: @Sendable () -> Data; log: @Sendable (String) -> Void; stdout: @Sendable (String) -> Void }`
  - `enum CLICommands { static let version: String; static let usage: String; static func run(_ env: CLIEnvironment) -> Int32; static func options(_ args: [String]) -> [String: String] }`
  - 可执行文件 `build/dd/Build/Products/Debug/agentalarm`

- [ ] **Step 1: 写失败测试**

`Tests/AgentAlarmCoreTests/CLICommandsTests.swift`:

```swift
import Foundation
import Testing
@testable import AgentAlarmCore

final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    private(set) var logs: [String] = []
    func out(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    func log(_ s: String) { lock.lock(); logs.append(s); lock.unlock() }
}

@Suite(.serialized) struct CLICommandsTests {
    func environment(_ args: [String], socket: String, stdin: Data = Data(), sink: OutputSink) -> CLIEnvironment {
        CLIEnvironment(arguments: args, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], socketPath: socket,
                       detectHost: { HostInfo(bundleId: "com.example.host", pid: 1, name: "Host") },
                       readStdin: { stdin }, log: { sink.log($0) }, stdout: { sink.out($0) })
    }

    @Test func optionsParsing() {
        let opts = CLICommands.options(["--agent", "MyBot", "--title", "Hello world", "--flag"])
        #expect(opts["agent"] == "MyBot")
        #expect(opts["title"] == "Hello world")
        #expect(opts["flag"] == "")
    }

    @Test func hookSendsMappedEventAndAlwaysExitsZero() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let sink = OutputSink()
        let code = CLICommands.run(environment(["hook", "claude"], socket: path, stdin: try fixtureData("claude-stop.json"), sink: sink))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "claude")
        #expect(event.kind == .turnComplete)
        #expect(event.host?.bundleId == "com.example.host")
        #expect(event.source.entrypoint == "cli")
        #expect(sink.lines.isEmpty, "hook 不能有 stdout")

        #expect(CLICommands.run(environment(["hook", "claude"], socket: path, stdin: Data("not json".utf8), sink: sink)) == 0)
        #expect(CLICommands.run(environment(["hook", "cursor"], socket: path, stdin: Data("{}".utf8), sink: sink)) == 0)
        var ignored = try fixtureJSON("claude-stop.json")
        ignored["hook_event_name"] = "PreToolUse"
        let ignoredData = try JSONSerialization.data(withJSONObject: ignored)
        #expect(CLICommands.run(environment(["hook", "claude"], socket: path, stdin: ignoredData, sink: sink)) == 0)
        #expect(collector.received.count == 1)
        #expect(sink.lines.isEmpty)
    }

    @Test func hookAcceptsPayloadOption() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let payload = String(decoding: try fixtureData("opencode-idle.json"), as: UTF8.self)
        let code = CLICommands.run(environment(["hook", "opencode", "--payload", payload], socket: path, sink: OutputSink()))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        #expect(try EventCoding.decode(collector.received[0]).title == "Add login page")
    }

    @Test func notifyBuildsGenericEvent() throws {
        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        let sink = OutputSink()
        let code = CLICommands.run(environment(["notify", "--agent", "MyBot", "--kind", "needs_input", "--title", "Deploy?", "--cwd", "/x/Proj"], socket: path, sink: sink))
        #expect(code == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "MyBot")
        #expect(event.kind == .needsInput)
        #expect(event.title == "Deploy?")
        #expect(event.cwd == "/x/Proj")
        #expect(event.sessionId.hasPrefix("notify-"))
        #expect(CLICommands.run(environment(["notify"], socket: path, sink: sink)) == 0, "缺少 --agent 也退出 0")
    }

    @Test func statusTestVersionAndUsage() throws {
        let missing = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let sink = OutputSink()
        #expect(CLICommands.run(environment(["status"], socket: missing, sink: sink)) == 1)
        #expect(sink.lines.last?.hasPrefix("unreachable") == true)
        #expect(CLICommands.run(environment(["test"], socket: missing, sink: sink)) == 1)
        #expect(CLICommands.run(environment(["--version"], socket: missing, sink: sink)) == 0)
        #expect(sink.lines.last == "agentalarm \(CLICommands.version)")
        #expect(CLICommands.run(environment([], socket: missing, sink: sink)) == 2)
        #expect(CLICommands.run(environment(["bogus"], socket: missing, sink: sink)) == 2)

        let path = "/tmp/aa-\(UUID().uuidString.prefix(8)).sock"
        let collector = Collector()
        let server = SocketServer(path: path) { collector.append($0) }
        try server.start()
        defer { server.stop() }
        #expect(CLICommands.run(environment(["status"], socket: path, sink: sink)) == 0)
        #expect(CLICommands.run(environment(["test", "--agent", "codex"], socket: path, sink: sink)) == 0)
        #expect(collector.semaphore.wait(timeout: .now() + 2) == .success)
        let event = try EventCoding.decode(collector.received[0])
        #expect(event.agent == "codex")
        #expect(event.title == "测试提醒")
        #expect(sink.lines.last == "已送达 AgentAlarm")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter CLICommandsTests 2>&1 | grep -E "error:" | head -2`
Expected: `cannot find 'CLICommands' in scope`

- [ ] **Step 3: 实现命令逻辑**

`Sources/AgentAlarmCore/CLI/CLICommands.swift`:

```swift
import Foundation

/// CLI 的全部行为都通过这个环境注入，便于测试。
public struct CLIEnvironment: Sendable {
    public var arguments: [String]
    public var environment: [String: String]
    public var socketPath: String
    public var detectHost: @Sendable () -> HostInfo?
    public var readStdin: @Sendable () -> Data
    public var log: @Sendable (String) -> Void
    public var stdout: @Sendable (String) -> Void

    public init(arguments: [String], environment: [String: String], socketPath: String,
                detectHost: @escaping @Sendable () -> HostInfo?,
                readStdin: @escaping @Sendable () -> Data,
                log: @escaping @Sendable (String) -> Void,
                stdout: @escaping @Sendable (String) -> Void) {
        self.arguments = arguments; self.environment = environment; self.socketPath = socketPath
        self.detectHost = detectHost; self.readStdin = readStdin; self.log = log; self.stdout = stdout
    }
}

public enum CLICommands {
    public static let version = "0.1.0"

    public static let usage = """
    usage: agentalarm hook <claude|codex|gemini|opencode> [--payload <json>]
           agentalarm notify --agent <name> [--kind <kind>] [--title <text>] [--session-id <id>] [--cwd <dir>] [--message <text>]
           agentalarm test [--agent <name>]
           agentalarm status
           agentalarm --version
    """

    public static func run(_ env: CLIEnvironment) -> Int32 {
        guard let command = env.arguments.first else { env.stdout(usage); return 2 }
        let rest = Array(env.arguments.dropFirst())
        switch command {
        case "--version", "version":
            env.stdout("agentalarm \(version)")
            return 0
        case "hook":
            runHook(rest, env)
            return 0
        case "notify":
            runNotify(rest, env)
            return 0
        case "test":
            return runTest(rest, env)
        case "status":
            return runStatus(env)
        default:
            env.stdout(usage)
            return 2
        }
    }

    /// `--key value` 与 `--flag`（值为空串）。
    public static func options(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else { index += 1; continue }
            let key = String(token.dropFirst(2))
            let next = index + 1 < args.count ? args[index + 1] : nil
            if let next, !next.hasPrefix("--") {
                result[key] = next
                index += 2
            } else {
                result[key] = ""
                index += 1
            }
        }
        return result
    }

    static func runHook(_ args: [String], _ env: CLIEnvironment) {
        guard let agent = args.first, let adapter = AdapterRegistry.adapter(for: agent) else {
            env.log("hook: unknown agent \(args.first ?? "<none>")")
            return
        }
        let opts = options(Array(args.dropFirst()))
        let raw = opts["payload"].map { Data($0.utf8) } ?? env.readStdin()
        guard let payload = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else {
            env.log("hook: payload is not a JSON object")
            return
        }
        let context = AdapterContext(environment: env.environment, host: env.detectHost(), now: Date())
        guard let event = adapter.map(payload: payload, context: context) else {
            env.log("hook: no mapping for \(payload["hook_event_name"] ?? payload["kind"] ?? "?")")
            return
        }
        send(event, env)
    }

    static func runNotify(_ args: [String], _ env: CLIEnvironment) {
        let opts = options(args)
        guard let agent = opts["agent"], !agent.isEmpty else {
            env.log("notify: --agent is required")
            return
        }
        let kind = opts["kind"].flatMap(EventKind.init(rawValue:)) ?? .turnComplete
        let event = AlarmEvent(
            agent: agent, kind: kind,
            sessionId: opts["session-id"].flatMap { $0.isEmpty ? nil : $0 } ?? "notify-\(UUID().uuidString)",
            cwd: opts["cwd"] ?? FileManager.default.currentDirectoryPath,
            title: opts["title"], message: opts["message"],
            host: env.detectHost(),
            source: EventSource(hookEventName: "notify"))
        send(event, env)
    }

    static func runTest(_ args: [String], _ env: CLIEnvironment) -> Int32 {
        let opts = options(args)
        let event = AlarmEvent(
            agent: opts["agent"].flatMap { $0.isEmpty ? nil : $0 } ?? "claude",
            kind: .turnComplete,
            sessionId: "test-\(UUID().uuidString)",
            cwd: FileManager.default.currentDirectoryPath,
            title: "测试提醒",
            host: env.detectHost(),
            source: EventSource(hookEventName: "test"))
        let result = send(event, env)
        if result == .delivered {
            env.stdout("已送达 AgentAlarm")
            return 0
        }
        env.stdout("AgentAlarm 未运行或未响应（\(result)），socket: \(env.socketPath)")
        return 1
    }

    static func runStatus(_ env: CLIEnvironment) -> Int32 {
        let reachable = SocketClient(path: env.socketPath).probe()
        env.stdout("\(reachable ? "reachable" : "unreachable"): \(env.socketPath)")
        return reachable ? 0 : 1
    }

    @discardableResult
    static func send(_ event: AlarmEvent, _ env: CLIEnvironment) -> SocketClient.SendResult {
        guard let data = try? EventCoding.encode(event) else {
            env.log("encode failed")
            return .unavailable
        }
        let result = SocketClient(path: env.socketPath).send(data)
        env.log("send \(event.agent)/\(event.kind.rawValue) -> \(result)")
        return result
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test 2>&1 | tail -2`
Expected: 全部通过

- [ ] **Step 5: 写 CLI 入口与 XcodeGen 工程**

`CLI/main.swift`:

```swift
import AgentAlarmCore
import Foundation

final class ExitCodeBox: @unchecked Sendable {
    var value: Int32 = 0
}

let debugEnabled = ProcessInfo.processInfo.environment["AGENTALARM_DEBUG"] == "1"
let cliEnvironment = CLIEnvironment(
    arguments: Array(CommandLine.arguments.dropFirst()),
    environment: ProcessInfo.processInfo.environment,
    socketPath: AgentPaths.standard.socket.path,
    detectHost: { ProcessTree.detectHost() },
    readStdin: { FileHandle.standardInput.readDataToEndOfFile() },
    log: { message in
        if debugEnabled { FileHandle.standardError.write(Data((message + "\n").utf8)) }
    },
    stdout: { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) })

let finished = DispatchSemaphore(value: 0)
let exitCode = ExitCodeBox()
DispatchQueue.global(qos: .userInitiated).async {
    exitCode.value = CLICommands.run(cliEnvironment)
    finished.signal()
}
// 整体自我超时 1 秒：无论卡在 stdin 还是 socket，都以 0 退出，绝不拖住 Agent。
if finished.wait(timeout: .now() + 1.0) == .timedOut {
    cliEnvironment.log("timed out after 1s, exiting 0")
    exit(0)
}
exit(exitCode.value)
```

`project.yml`（此任务只有 CLI target，App target 在 Task 19 加入）:

```yaml
name: AgentAlarm
options:
  bundleIdPrefix: com.jack
  deploymentTarget:
    macOS: "14.0"
  generateEmptyDirectories: true
  createIntermediateGroups: true
packages:
  AgentAlarmCore:
    path: .
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_STRICT_CONCURRENCY: complete
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    ENABLE_HARDENED_RUNTIME: YES
targets:
  agentalarm:
    type: tool
    platform: macOS
    sources: [CLI]
    dependencies:
      - package: AgentAlarmCore
    settings:
      base:
        PRODUCT_NAME: agentalarm
```

- [ ] **Step 6: 生成工程并构建 CLI**

Run:
```bash
xcodegen generate && xcodebuild -project AgentAlarm.xcodeproj -scheme agentalarm -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 手工验证 CLI 行为**

Run:
```bash
B=build/dd/Build/Products/Debug/agentalarm
$B --version
cat Tests/AgentAlarmCoreTests/Fixtures/claude-stop.json | AGENTALARM_DEBUG=1 $B hook claude; echo "exit=$?"
cat Tests/AgentAlarmCoreTests/Fixtures/claude-stop.json | $B hook claude | wc -c
$B status; echo "exit=$?"
time (echo '{' | $B hook claude)
```
Expected：版本行 `agentalarm 0.1.0`；带 DEBUG 时 stderr 出现 `send claude/turn_complete -> unavailable` 且 `exit=0`；不带 DEBUG 时 stdout 字节数为 0；`status` 输出 `unreachable: …` 且 `exit=1`；坏 JSON 也在 1 秒内退出。

- [ ] **Step 8: Commit**

```bash
git add Sources/AgentAlarmCore/CLI Tests/AgentAlarmCoreTests/CLICommandsTests.swift CLI project.yml
git commit -m "feat(cli): add agentalarm command-line tool and XcodeGen project"
```

---

### Task 19: App 骨架：设置存储、事件管线、声音与语音、菜单栏列表

**Files:**
- Modify: `project.yml`（追加 `AgentAlarm` application target）
- Create: `App/AgentAlarmApp.swift`
- Create: `App/AppSettings.swift`
- Create: `App/AppModel.swift`
- Create: `App/ActivityMonitor.swift`
- Create: `App/Outputs/SoundPlayer.swift`
- Create: `App/Outputs/SpeechQueue.swift`
- Create: `App/Views/MenuContent.swift`
- Create: `App/Views/SettingsView.swift`（本任务只放占位文本，Task 21 填充）

**Interfaces:**
- Consumes: Core 的 `SocketServer`、`EventCoding`、`TitleService`、`WaitingList`、`AlertPolicy`、`SpeechComposer`、`AgentPaths`、`ActivityState`。
- Produces（App 内部）:
  - `@MainActor @Observable final class AppSettings { static let shared; soundComplete/soundPermission/soundInput: String; soundVolume: Double; speechVoice: String; speechRate: Double; bannerEnabled: Bool; suppressWhenHostActive: Bool; userActiveThreshold: Double; repeatReminders: Bool; quietHoursEnabled: Bool; quietStartMinute: Int; quietEndMinute: Int; verifiedAgents: [String]; var policySettings: PolicySettings; func soundName(for: EventKind) -> String; func isVerified(_:) -> Bool; func markVerified(_:); func clearVerified(_:) }`
  - `@MainActor @Observable final class AppModel { static let shared; waiting: WaitingList; log: [LogEntry]; settings: AppSettings; paths: AgentPaths; lastError: String?; var isPaused: Bool; func start(); func receive(_ data: Data); func select(_ entry: WaitingEntry); func pause(minutes: Int?); func resume(); func sendTestAlert() }`
  - `struct LogEntry: Identifiable { date: Date; agent: String; kind: EventKind; title: String; outcome: String }`
  - `@MainActor enum ActivityMonitor { static func snapshot() -> ActivityState }`
  - `@MainActor final class SoundPlayer { static func systemSoundNames() -> [String]; func play(name: String, volume: Double) }`
  - `@MainActor final class SpeechQueue { var voiceIdentifier: String; var rate: Float; func enqueue(_ item: SpeechItem); func speakNow(_ text: String); static func availableVoices() -> [(id: String, label: String)] }`

- [ ] **Step 1: 在 project.yml 的 `targets:` 下追加 App target**

```yaml
  AgentAlarm:
    type: application
    platform: macOS
    sources: [App]
    dependencies:
      - package: AgentAlarmCore
      - target: agentalarm
        embed: true
        codeSign: true
        copy:
          destination: executables
    info:
      path: App/Info.plist
      properties:
        CFBundleIdentifier: com.jack.agentalarm
        CFBundleName: AgentAlarm
        CFBundleDisplayName: AgentAlarm
        CFBundleShortVersionString: "0.1.0"
        CFBundleVersion: "1"
        LSUIElement: true
        LSMinimumSystemVersion: "14.0"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.jack.agentalarm
        PRODUCT_NAME: AgentAlarm
```

- [ ] **Step 2: 写 AppSettings**

`App/AppSettings.swift`:

```swift
import AgentAlarmCore
import Foundation
import Observation

/// UserDefaults 包装，键前缀 aa.。
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults: UserDefaults

    var soundComplete: String { didSet { defaults.set(soundComplete, forKey: "aa.sound.complete") } }
    var soundPermission: String { didSet { defaults.set(soundPermission, forKey: "aa.sound.permission") } }
    var soundInput: String { didSet { defaults.set(soundInput, forKey: "aa.sound.input") } }
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: "aa.sound.volume") } }
    var speechVoice: String { didSet { defaults.set(speechVoice, forKey: "aa.speech.voice") } }
    var speechRate: Double { didSet { defaults.set(speechRate, forKey: "aa.speech.rate") } }
    var bannerEnabled: Bool { didSet { defaults.set(bannerEnabled, forKey: "aa.banner.enabled") } }
    var suppressWhenHostActive: Bool { didSet { defaults.set(suppressWhenHostActive, forKey: "aa.rules.suppressWhenHostActive") } }
    var userActiveThreshold: Double { didSet { defaults.set(userActiveThreshold, forKey: "aa.rules.userActiveThreshold") } }
    var repeatReminders: Bool { didSet { defaults.set(repeatReminders, forKey: "aa.rules.repeatReminders") } }
    var quietHoursEnabled: Bool { didSet { defaults.set(quietHoursEnabled, forKey: "aa.rules.quietHoursEnabled") } }
    var quietStartMinute: Int { didSet { defaults.set(quietStartMinute, forKey: "aa.rules.quietStart") } }
    var quietEndMinute: Int { didSet { defaults.set(quietEndMinute, forKey: "aa.rules.quietEnd") } }
    var verifiedAgents: [String] { didSet { defaults.set(verifiedAgents, forKey: "aa.integration.verified") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func string(_ key: String, _ fallback: String) -> String { defaults.string(forKey: key) ?? fallback }
        func double(_ key: String, _ fallback: Double) -> Double { defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key) }
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key) }
        soundComplete = string("aa.sound.complete", "Glass")
        soundPermission = string("aa.sound.permission", "Ping")
        soundInput = string("aa.sound.input", "Purr")
        soundVolume = double("aa.sound.volume", 0.8)
        speechVoice = string("aa.speech.voice", "")
        speechRate = double("aa.speech.rate", 0.5)
        bannerEnabled = bool("aa.banner.enabled", true)
        suppressWhenHostActive = bool("aa.rules.suppressWhenHostActive", true)
        userActiveThreshold = double("aa.rules.userActiveThreshold", 10)
        repeatReminders = bool("aa.rules.repeatReminders", true)
        quietHoursEnabled = bool("aa.rules.quietHoursEnabled", false)
        quietStartMinute = int("aa.rules.quietStart", 23 * 60)
        quietEndMinute = int("aa.rules.quietEnd", 8 * 60)
        verifiedAgents = defaults.stringArray(forKey: "aa.integration.verified") ?? []
    }

    var policySettings: PolicySettings {
        var policy = PolicySettings()
        policy.repeatReminders = repeatReminders
        policy.suppressSpeechWhenHostActive = suppressWhenHostActive
        policy.userActiveThreshold = userActiveThreshold
        policy.quietHours = quietHoursEnabled ? QuietHours(startMinute: quietStartMinute, endMinute: quietEndMinute) : nil
        return policy
    }

    func soundName(for kind: EventKind) -> String {
        switch kind {
        case .needsPermission: return soundPermission
        case .needsInput: return soundInput
        default: return soundComplete
        }
    }

    func isVerified(_ agent: String) -> Bool { verifiedAgents.contains(agent) }
    func markVerified(_ agent: String) { if !verifiedAgents.contains(agent) { verifiedAgents.append(agent) } }
    func clearVerified(_ agent: String) { verifiedAgents.removeAll { $0 == agent } }
}
```

- [ ] **Step 3: 写 ActivityMonitor、SoundPlayer、SpeechQueue**

`App/ActivityMonitor.swift`:

```swift
import AgentAlarmCore
import AppKit
import CoreGraphics

@MainActor
enum ActivityMonitor {
    static func snapshot() -> ActivityState {
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        return ActivityState(frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                             secondsSinceUserInput: idle)
    }
}
```

`App/Outputs/SoundPlayer.swift`:

```swift
import AppKit

@MainActor
final class SoundPlayer {
    private var current: NSSound?

    static func systemSoundNames() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }

    func play(name: String, volume: Double) {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = Float(max(0, min(1, volume)))
        current?.stop()
        current = sound
        sound.play()
    }
}
```

`App/Outputs/SpeechQueue.swift`:

```swift
import AgentAlarmCore
import AVFoundation

/// 串行播报，300 毫秒内到达的多条合并成一句。
@MainActor
final class SpeechQueue: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var pending: [SpeechItem] = []
    private var speaking = false
    private var pumpScheduled = false

    var voiceIdentifier: String = ""
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func enqueue(_ item: SpeechItem) {
        pending.append(item)
        schedulePump()
    }

    /// 设置页试听用，直接播放，不参与合并。
    func speakNow(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = true
        synthesizer.speak(makeUtterance(text))
    }

    static func availableVoices() -> [(id: String, label: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
            .map { ($0.identifier, "\($0.name)（\($0.language)）") }
    }

    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            pumpScheduled = false
            pump()
        }
    }

    private func pump() {
        guard !speaking, !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        speaking = true
        synthesizer.speak(makeUtterance(SpeechComposer.sentence(for: batch)))
    }

    private func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        if !voiceIdentifier.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        }
        utterance.rate = rate
        return utterance
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.pump() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false; self.pump() }
    }
}
```

- [ ] **Step 4: 写 AppModel**

`App/AppModel.swift`:

```swift
import AgentAlarmCore
import AppKit
import Foundation
import Observation
import OSLog

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let agent: String
    let kind: EventKind
    let title: String
    let outcome: String
}

/// 事件管线：socket → 标题解析 → 等待列表 → 策略 → 声音/语音/日志。
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var waiting = WaitingList()
    private(set) var log: [LogEntry] = []
    private(set) var policy: AlertPolicy
    var lastError: String?

    let settings: AppSettings
    let paths: AgentPaths

    @ObservationIgnored private let titleService: TitleService
    @ObservationIgnored private var server: SocketServer?
    @ObservationIgnored private let sound = SoundPlayer()
    @ObservationIgnored private let speech = SpeechQueue()
    @ObservationIgnored private let logger = Logger(subsystem: "com.jack.agentalarm", category: "policy")
    @ObservationIgnored private let socketLogger = Logger(subsystem: "com.jack.agentalarm", category: "socket")

    var isPaused: Bool { policy.isPaused(at: Date()) }

    init(settings: AppSettings = .shared, paths: AgentPaths = .standard) {
        self.settings = settings
        self.paths = paths
        policy = AlertPolicy(settings: settings.policySettings)
        titleService = TitleService(claude: ClaudeTitleResolver(),
                                    codex: CodexTitleResolver(codexHome: paths.codexHome),
                                    gemini: GeminiTitleResolver())
    }

    func start() {
        do {
            try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let server = SocketServer(path: paths.socket.path) { data in
                Task { @MainActor in AppModel.shared.receive(data) }
            }
            try server.start()
            self.server = server
            socketLogger.info("listening at \(self.paths.socket.path, privacy: .public)")
        } catch {
            lastError = "无法监听 socket：\(error)"
            socketLogger.error("listen failed: \(String(describing: error), privacy: .public)")
        }
    }

    func receive(_ data: Data) {
        guard let event = try? EventCoding.decode(data) else {
            socketLogger.error("undecodable event, \(data.count) bytes")
            return
        }
        settings.markVerified(event.agent)
        guard event.kind.isAlerting else {
            _ = waiting.apply(event, title: "", now: Date())
            record(event, title: "", outcome: "list: \(event.kind.rawValue)")
            return
        }
        let service = titleService
        Task.detached(priority: .userInitiated) {
            let resolution = await AppModel.resolveWithBudget(event, service: service)
            await MainActor.run { AppModel.shared.process(event, resolution: resolution) }
        }
    }

    /// 标题解析预算 1 秒：先到先用，超时用退化标题，不阻塞提醒。
    nonisolated static func resolveWithBudget(_ event: AlarmEvent, service: TitleService) async -> TitleResolution {
        await withTaskGroup(of: TitleResolution.self) { group in
            group.addTask { service.resolve(event) }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return FallbackTitle.resolve(event)
            }
            let first = await group.next() ?? FallbackTitle.resolve(event)
            group.cancelAll()
            return first
        }
    }

    private func process(_ incoming: AlarmEvent, resolution: TitleResolution) {
        var event = incoming
        if event.kind == .turnComplete, let reclassified = resolution.reclassifiedKind { event.kind = reclassified }
        let displayTitle = TextTruncation.truncate(resolution.title, to: 80)
        _ = waiting.apply(event, title: displayTitle, now: Date())
        policy.settings = settings.policySettings
        let decision = policy.decide(event, activity: ActivityMonitor.snapshot(), now: Date())
        switch decision {
        case .silent(let reason):
            record(event, title: displayTitle, outcome: "silent: \(reason.rawValue)")
        case .alert(let speak):
            sound.play(name: settings.soundName(for: event.kind), volume: settings.soundVolume)
            if speak {
                speech.voiceIdentifier = settings.speechVoice
                speech.rate = Float(settings.speechRate)
                speech.enqueue(SpeechItem(agent: event.agent, title: resolution.title, kind: event.kind))
            }
            didAlert(event, title: displayTitle)
            record(event, title: displayTitle, outcome: speak ? "alert + speech" : "alert, speech suppressed")
        }
        logger.info("\(event.agent, privacy: .public)/\(event.kind.rawValue, privacy: .public) -> \(String(describing: decision), privacy: .public) title=\(resolution.origin.rawValue, privacy: .public)")
    }

    /// 提醒发生后的扩展点，Task 20 在这里发系统横幅。
    func didAlert(_ event: AlarmEvent, title: String) {}

    private func record(_ event: AlarmEvent, title: String, outcome: String) {
        log.insert(LogEntry(date: Date(), agent: event.agent, kind: event.kind, title: title, outcome: outcome), at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }

    func select(_ entry: WaitingEntry) {
        waiting.markSeen(id: entry.id)
    }

    func pause(minutes: Int?) {
        policy.pause(for: minutes.map { Double($0) * 60 }, now: Date())
    }

    func resume() { policy.resume() }

    func sendTestAlert() {
        let event = AlarmEvent(agent: "claude", kind: .turnComplete, sessionId: "test-\(UUID().uuidString)",
                               cwd: paths.home.path, title: "测试提醒", source: EventSource(hookEventName: "test"))
        if let data = try? EventCoding.encode(event) { receive(data) }
    }

    func previewSpeech(_ text: String) {
        speech.voiceIdentifier = settings.speechVoice
        speech.rate = Float(settings.speechRate)
        speech.speakNow(text)
    }

    func previewSound(_ name: String) {
        sound.play(name: name, volume: settings.soundVolume)
    }
}
```

- [ ] **Step 5: 写菜单、占位设置页与 App 入口**

`App/Views/MenuContent.swift`:

```swift
import AgentAlarmCore
import AppKit
import SwiftUI

enum ElapsedFormatter {
    static func string(since date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟" }
        return "\(seconds / 3600) 小时"
    }
}

struct MenuContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.waiting.entries.isEmpty {
            Text("没有等待中的会话")
        }
        ForEach(model.waiting.entries) { entry in
            Button(label(for: entry)) { model.select(entry) }
        }
        Divider()
        Button("测试提醒") { model.sendTestAlert() }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 AgentAlarm") { NSApp.terminate(nil) }
    }

    private func label(for entry: WaitingEntry) -> String {
        let prefix = entry.seen ? "✓ " : ""
        return "\(prefix)\(AgentNames.displayName(for: entry.agent)) · \(entry.title) · \(SpeechComposer.statusPhrase(entry.kind)) · \(ElapsedFormatter.string(since: entry.updatedAt))"
    }
}
```

`App/Views/SettingsView.swift`（占位，Task 21 替换）:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Text("设置页在 Task 21 实现").padding(40)
    }
}
```

`App/AgentAlarmApp.swift`:

```swift
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.stop()
    }
}

struct MenuBarLabel: View {
    let count: Int
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 { Text("\(count)") }
        }
    }
}

@main
struct AgentAlarmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environment(model)
        } label: {
            MenuBarLabel(count: model.waiting.count)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView().environment(model)
        }
    }
}
```

在 `App/AppModel.swift` 的 `func start()` 之后加入：

```swift
    func stop() {
        server?.stop()
        server = nil
    }
```

- [ ] **Step 6: 生成工程并构建 App**

Run:
```bash
xcodegen generate && xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
ls build/dd/Build/Products/Debug/AgentAlarm.app/Contents/MacOS/
```
Expected: `** BUILD SUCCEEDED **`，目录里同时有 `AgentAlarm` 与 `agentalarm`。

- [ ] **Step 7: 运行并端到端验证**

Run:
```bash
open build/dd/Build/Products/Debug/AgentAlarm.app
sleep 2
build/dd/Build/Products/Debug/AgentAlarm.app/Contents/MacOS/agentalarm status
build/dd/Build/Products/Debug/AgentAlarm.app/Contents/MacOS/agentalarm test
cat Tests/AgentAlarmCoreTests/Fixtures/codex-permission-request.json | build/dd/Build/Products/Debug/AgentAlarm.app/Contents/MacOS/agentalarm hook codex
log show --last 2m --predicate 'subsystem == "com.jack.agentalarm"' --style compact | tail -5
```
Expected：菜单栏出现铃铛；`status` 输出 `reachable`；`test` 输出 `已送达 AgentAlarm`，听到 Glass 音效与"Claude Code，测试提醒，已完成"；Codex 授权事件后听到 Ping 与"Codex，AgentAlarm，需要授权"（标题退化为 cwd 目录名）；菜单里出现两行条目且铃铛旁显示 2；日志里有两条 `alert` 记录。测完 `pkill -x AgentAlarm`。

- [ ] **Step 8: Commit**

```bash
git add project.yml App
git commit -m "feat(app): add menu bar app skeleton with socket pipeline, sound and speech"
```

---

### Task 20: 系统横幅、宿主激活与暂停菜单

**Files:**
- Create: `App/Outputs/BannerCenter.swift`
- Create: `App/HostActivator.swift`
- Modify: `App/AppModel.swift`
- Modify: `App/Views/MenuContent.swift`

**Interfaces:**
- Consumes: Task 19 的 `AppModel`、`AppSettings.bannerEnabled`。
- Produces:
  - `@MainActor final class BannerCenter: NSObject, UNUserNotificationCenterDelegate { private(set) var authorized: Bool; func requestAuthorization(); func post(event: AlarmEvent, title: String) }`
  - `@MainActor enum HostActivator { @discardableResult static func activate(_ host: HostInfo?) -> Bool }`

- [ ] **Step 1: 写 HostActivator 与 BannerCenter**

`App/HostActivator.swift`:

```swift
import AgentAlarmCore
import AppKit

/// 优先按 pid 激活，进程已退出则按 bundle id 找同类运行中的应用。
@MainActor
enum HostActivator {
    @discardableResult
    static func activate(_ host: HostInfo?) -> Bool {
        guard let host else { return false }
        if let app = NSRunningApplication(processIdentifier: host.pid), app.bundleIdentifier == host.bundleId {
            return app.activate()
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == host.bundleId }) {
            return app.activate()
        }
        return false
    }
}
```

`App/Outputs/BannerCenter.swift`:

```swift
import AgentAlarmCore
import Foundation
import UserNotifications

@MainActor
final class BannerCenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private(set) var authorized = false

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(event: AlarmEvent, title: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(AgentNames.displayName(for: event.agent)) · \(SpeechComposer.statusPhrase(event.kind))"
        content.body = title
        content.sound = nil
        if let host = event.host {
            content.userInfo = ["bundleId": host.bundleId, "pid": Int(host.pid), "name": host.name]
        }
        center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let bundleId = info["bundleId"] as? String else { return }
        let pid = Int32(info["pid"] as? Int ?? 0)
        let name = info["name"] as? String ?? ""
        await MainActor.run { HostActivator.activate(HostInfo(bundleId: bundleId, pid: pid, name: name)) }
    }
}
```

- [ ] **Step 2: 接入 AppModel**

在 `App/AppModel.swift` 中：

在 `@ObservationIgnored private let speech = SpeechQueue()` 下面加一行：

```swift
    @ObservationIgnored private let banner = BannerCenter()
```

把 `func start()` 里 `do {` 之前加一行：

```swift
        banner.requestAuthorization()
```

把 `func didAlert(_ event: AlarmEvent, title: String) {}` 替换为：

```swift
    var bannerAuthorized: Bool { banner.authorized }

    func didAlert(_ event: AlarmEvent, title: String) {
        guard settings.bannerEnabled else { return }
        banner.post(event: event, title: title)
    }
```

把 `func select(_ entry: WaitingEntry)` 替换为：

```swift
    func select(_ entry: WaitingEntry) {
        waiting.markSeen(id: entry.id)
        HostActivator.activate(entry.host)
    }
```

- [ ] **Step 3: 菜单加入暂停子菜单**

在 `App/Views/MenuContent.swift` 的 `Button("测试提醒")` 之前插入：

```swift
        Menu(model.isPaused ? "已暂停提醒" : "暂停提醒") {
            Button("15 分钟") { model.pause(minutes: 15) }
            Button("30 分钟") { model.pause(minutes: 30) }
            Button("60 分钟") { model.pause(minutes: 60) }
            Button("直到恢复") { model.pause(minutes: nil) }
            Divider()
            Button("恢复提醒") { model.resume() }.disabled(!model.isPaused)
        }
```

- [ ] **Step 4: 构建并手工验证**

Run:
```bash
xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
open build/dd/Build/Products/Debug/AgentAlarm.app
```
然后在 iTerm 里执行 `build/dd/Build/Products/Debug/AgentAlarm.app/Contents/MacOS/agentalarm test`。
Expected：首次启动出现通知权限弹窗，允许后 `test` 产生横幅"Claude Code · 已完成 / 测试提醒"；把 Finder 切到前台再点横幅，iTerm 被激活（CLI 的父进程链指向 iTerm）；菜单里点击该条目同样激活 iTerm，且条目前出现 ✓；选择"暂停提醒 → 15 分钟"后再 `test`，无声音无横幅但条目仍进入列表；"恢复提醒"后恢复正常。

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): add notification banners, host activation and pause menu"
```

---

### Task 21: 接入状态、设置窗口、软链接修复与登录启动

**Files:**
- Create: `App/IntegrationStore.swift`
- Create: `App/LoginItem.swift`
- Modify: `App/AppModel.swift`
- Modify: `App/Views/SettingsView.swift`（替换占位）
- Create: `App/Views/IntegrationsTab.swift`
- Create: `App/Views/SoundsTab.swift`
- Create: `App/Views/RulesTab.swift`
- Create: `App/Views/GeneralTab.swift`

**Interfaces:**
- Consumes: Task 15 的 `AgentIntegrationManager`、`AgentIntegrationStatus`，Task 14 的 `SymlinkInstaller`、`SymlinkStatus`，Task 19 的 `AppModel`、`AppSettings`。
- Produces:
  - `@MainActor @Observable final class IntegrationStore { statuses: [String: AgentIntegrationStatus]; symlinkStatus: SymlinkStatus; lastError: String?; let manager: AgentIntegrationManager; var cliTarget: URL; func refresh(); func repairSymlink(); func setEnabled(_ agent: String, _ enabled: Bool); func isEnabled(_ agent: String) -> Bool; func snippet(_ agent: String) -> String; func configPath(_ agent: String) -> String }`
  - `@MainActor enum LoginItem { static var isEnabled: Bool; static func setEnabled(_: Bool) throws }`
  - `AppModel.integrations: IntegrationStore`

- [ ] **Step 1: 写 IntegrationStore 与 LoginItem**

`App/IntegrationStore.swift`:

```swift
import AgentAlarmCore
import Foundation
import Observation
import OSLog

@MainActor @Observable
final class IntegrationStore {
    private(set) var statuses: [String: AgentIntegrationStatus] = [:]
    private(set) var symlinkStatus: SymlinkStatus = .missing
    var lastError: String?

    @ObservationIgnored let manager: AgentIntegrationManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let symlinks = SymlinkInstaller()
    @ObservationIgnored private let logger = Logger(subsystem: "com.jack.agentalarm", category: "installer")

    var cliTarget: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agentalarm") }

    init(manager: AgentIntegrationManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
    }

    func refresh() {
        for agent in AgentNames.supported {
            statuses[agent] = manager.status(agent, verified: settings.isVerified(agent))
        }
        symlinkStatus = symlinks.status(link: manager.paths.cliLink, expectedTarget: cliTarget)
    }

    func repairSymlink() {
        do {
            if try symlinks.ensure(link: manager.paths.cliLink, target: cliTarget) {
                logger.info("symlink repaired -> \(self.cliTarget.path, privacy: .public)")
            }
        } catch {
            lastError = "无法创建 ~/.local/bin/agentalarm：\(error)"
            logger.error("symlink failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func setEnabled(_ agent: String, _ enabled: Bool) {
        let name = AgentNames.displayName(for: agent)
        do {
            if enabled {
                try manager.install(agent)
                logger.info("installed \(agent, privacy: .public)")
            } else {
                try manager.uninstall(agent)
                settings.clearVerified(agent)
                logger.info("uninstalled \(agent, privacy: .public)")
            }
            lastError = nil
        } catch InstallerError.containsComments {
            lastError = "\(name) 的配置文件含注释，请用下方片段手动添加"
        } catch {
            lastError = "\(name) 接入失败：\(error)，原文件未改动，备份目录 \(manager.paths.backups.path)"
            logger.error("install \(agent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func isEnabled(_ agent: String) -> Bool {
        switch statuses[agent] {
        case .installed, .awaitingTrust, .verified: return true
        default: return false
        }
    }

    func snippet(_ agent: String) -> String { manager.manualSnippet(agent) }

    func configPath(_ agent: String) -> String { manager.configFile(agent)?.path ?? "" }
}
```

`App/LoginItem.swift`:

```swift
import ServiceManagement

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: 接入 AppModel**

在 `App/AppModel.swift` 中：

在 `let paths: AgentPaths` 下面加一行：

```swift
    let integrations: IntegrationStore
```

在 `init` 里 `self.paths = paths` 之后加一行：

```swift
        integrations = IntegrationStore(manager: AgentIntegrationManager(paths: paths), settings: settings)
```

在 `func start()` 最开头（`banner.requestAuthorization()` 之前）加一行：

```swift
        integrations.repairSymlink()
```

把 `receive` 里的 `settings.markVerified(event.agent)` 替换为：

```swift
        if !settings.isVerified(event.agent) {
            settings.markVerified(event.agent)
            integrations.refresh()
        }
```

- [ ] **Step 3: 写设置窗口四页**

`App/Views/SettingsView.swift`（整体替换）:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            IntegrationsTab().tabItem { Label("接入", systemImage: "link") }
            SoundsTab().tabItem { Label("声音与语音", systemImage: "speaker.wave.2") }
            RulesTab().tabItem { Label("规则", systemImage: "slider.horizontal.3") }
            GeneralTab().tabItem { Label("通用", systemImage: "gear") }
        }
        .frame(width: 600, height: 480)
    }
}
```

`App/Views/IntegrationsTab.swift`:

```swift
import AgentAlarmCore
import SwiftUI

struct IntegrationsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.integrations
        Form {
            Section("Agent 接入") {
                ForEach(AgentNames.supported, id: \.self) { agent in
                    AgentRow(agent: agent, store: store)
                }
            }
            Section("命令行工具") {
                LabeledContent("软链接 ~/.local/bin/agentalarm") { Text(symlinkText(store.symlinkStatus)) }
                LabeledContent("指向") { Text(store.cliTarget.path).font(.caption).textSelection(.enabled) }
                Button("修复软链接") { store.repairSymlink() }
            }
            if let error = store.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.refresh() }
    }

    private func symlinkText(_ status: SymlinkStatus) -> String {
        switch status {
        case .ok: return "正常"
        case .missing: return "缺失"
        case .wrongTarget(let target): return "指向错误：\(target)"
        case .notASymlink: return "该路径是普通文件，请先手动移走"
        }
    }
}

struct AgentRow: View {
    let agent: String
    let store: IntegrationStore

    private var status: AgentIntegrationStatus { store.statuses[agent] ?? .notInstalled }

    private var manualRequired: Bool {
        if case .manualRequired = status { return true }
        return false
    }

    private var statusText: String {
        switch status {
        case .notInstalled: return "未接入"
        case .installed: return "已接入，等待收到第一条事件"
        case .awaitingTrust: return "已写入 hooks.json，待信任"
        case .verified: return "已验证"
        case .manualRequired(let reason): return reason
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { store.isEnabled(agent) }, set: { store.setEnabled(agent, $0) })) {
                Text(AgentNames.displayName(for: agent))
            }
            .disabled(manualRequired)
            Text("\(statusText) · \(store.configPath(agent))")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if case .awaitingTrust = status {
                Text("在任一 Codex 终端会话中运行 /hooks 并信任 AgentAlarm；收到第一条 Codex 事件后自动变为已验证。")
                    .font(.caption)
            }
            if manualRequired {
                DisclosureGroup("手动配置片段") {
                    TextEditor(text: .constant(store.snippet(agent)))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 160)
                }
            }
        }
    }
}
```

`App/Views/SoundsTab.swift`:

```swift
import AgentAlarmCore
import SwiftUI

struct SoundsTab: View {
    @Environment(AppModel.self) private var model
    private let sounds = SoundPlayer.systemSoundNames()
    private let voices = SpeechQueue.availableVoices()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("提示音") {
                soundRow("完成", $settings.soundComplete)
                soundRow("需要授权", $settings.soundPermission)
                soundRow("向你提问", $settings.soundInput)
                Slider(value: $settings.soundVolume, in: 0...1) { Text("音量") }
            }
            Section("语音") {
                Picker("语音", selection: $settings.speechVoice) {
                    Text("自动（中文）").tag("")
                    ForEach(voices, id: \.id) { voice in Text(voice.label).tag(voice.id) }
                }
                Slider(value: $settings.speechRate, in: 0.3...0.7) { Text("语速") }
                Button("试听语音") {
                    model.previewSpeech(SpeechComposer.sentence(for: SpeechItem(agent: "claude", title: "AgentAlarm 设计", kind: .turnComplete)))
                }
            }
            Section("系统横幅") {
                Toggle("发送系统通知横幅，点击横幅跳回宿主应用", isOn: $settings.bannerEnabled)
                if !model.bannerAuthorized {
                    Text("系统通知权限未授予，横幅不会显示；请在 系统设置 → 通知 中允许 AgentAlarm。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func soundRow(_ label: String, _ selection: Binding<String>) -> some View {
        HStack {
            Picker(label, selection: selection) {
                ForEach(sounds, id: \.self) { Text($0).tag($0) }
            }
            Button("试听") { model.previewSound(selection.wrappedValue) }
        }
    }
}
```

`App/Views/RulesTab.swift`:

```swift
import SwiftUI

struct RulesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("语音抑制") {
                Toggle("宿主应用在前台且我正在操作时不播报语音（仍播提示音）", isOn: $settings.suppressWhenHostActive)
                Stepper("键鼠活跃判定窗口：\(Int(settings.userActiveThreshold)) 秒", value: $settings.userActiveThreshold, in: 3...60, step: 1)
            }
            Section("重复提醒") {
                Toggle("回合结束约 60 秒仍无人回复时再提醒一次", isOn: $settings.repeatReminders)
            }
            Section("静音时段") {
                Toggle("启用静音时段（只更新列表，不出声）", isOn: $settings.quietHoursEnabled)
                DatePicker("开始", selection: minuteBinding($settings.quietStartMinute), displayedComponents: .hourAndMinute)
                DatePicker("结束", selection: minuteBinding($settings.quietEndMinute), displayedComponents: .hourAndMinute)
            }
        }
        .formStyle(.grouped)
    }

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }
}
```

`App/Views/GeneralTab.swift`:

```swift
import AgentAlarmCore
import SwiftUI

struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时自动启动 AgentAlarm", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = "设置失败：\(error.localizedDescription)"
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red) }
                if let error = model.lastError { Text(error).foregroundStyle(.red) }
            }
            Section("最近事件（最多 100 条）") {
                if model.log.isEmpty {
                    Text("还没有收到事件").foregroundStyle(.secondary)
                }
                ForEach(model.log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.date.formatted(date: .omitted, time: .standard))  \(AgentNames.displayName(for: entry.agent)) · \(entry.kind.rawValue)")
                        Text("\(entry.title)  →  \(entry.outcome)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
```

- [ ] **Step 4: 构建并手工验证**

Run:
```bash
xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
open build/dd/Build/Products/Debug/AgentAlarm.app
ls -l ~/.local/bin/agentalarm
cp ~/.claude/settings.json /tmp/claude-settings-before.json
```
然后在菜单里打开"设置…"：
1. 接入页软链接显示"正常"。
2. 打开 Claude Code 开关，确认 `~/.claude/settings.json` 出现四个事件的 hook 条目且备份出现在 `~/Library/Application Support/AgentAlarm/backups/`；用 `diff <(jq -S 'del(.hooks)' ~/.claude/settings.json) <(jq -S 'del(.hooks)' /tmp/claude-settings-before.json)` 确认其他键无变化。
3. 在 iTerm 里运行交互式 `claude`，发一句"回复 ok"，回合结束后听到提示音与播报，接入页状态变为"已验证"。
4. 打开 Codex 开关，确认 `~/.codex/hooks.json` 生成且 `config.toml` 未改动；状态显示"待信任"。在 Codex TUI 里运行 `/hooks` 信任后发一句话，回合结束后状态变为"已验证"。
5. 打开 Gemini 与 OpenCode 开关，分别验证 `~/.gemini/settings.json` 的 `hooks` 与 `~/.config/opencode/plugins/agentalarm.ts`。
6. 关闭四个开关，确认条目被精确移除、插件文件被删除。
7. 声音页试听三种音效与语音；规则页改阈值后再测抑制；通用页打开登录启动，在"系统设置 → 通用 → 登录项"里能看到 AgentAlarm。

- [ ] **Step 5: Commit**

```bash
git add App
git commit -m "feat(app): add integration toggles, settings window, symlink repair and login item"
```

---

### Task 22: README、验收清单与最终验证

**Files:**
- Create: `README.md`
- Create: `docs/acceptance-checklist.md`

- [ ] **Step 1: 写 README**

`README.md`:

````markdown
# AgentAlarm

macOS 菜单栏工具：Claude Code、Codex、Gemini CLI、OpenCode 的会话回合结束或等待人工时，播放提示音并语音播报"Agent 名 + 会话标题 + 状态"，菜单栏列出等待中的会话，点击跳回宿主应用。

## 构建与运行

依赖：Xcode 27、macOS 14+、XcodeGen（`brew install xcodegen`）。

```bash
swift test                                   # Core 单元测试
xcodegen generate                            # 生成 AgentAlarm.xcodeproj（不入库）
xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/AgentAlarm.app
```

App 启动后会在 `~/.local/bin/agentalarm` 建立指向 App 内 CLI 的软链接。

## 接入 Agent

菜单栏 → 设置… → 接入，打开对应开关。App 会备份并改写：

| Agent | 写入位置 | 备注 |
|---|---|---|
| Claude Code | `~/.claude/settings.json` 的 `hooks` | Stop、Notification、UserPromptSubmit、SessionEnd |
| Codex | `~/.codex/hooks.json` | 需在 Codex TUI 运行一次 `/hooks` 信任；不改 `config.toml` 的 `notify` |
| Gemini CLI | `~/.gemini/settings.json` 的 `hooks` | AfterAgent、Notification、BeforeAgent、SessionEnd |
| OpenCode | `~/.config/opencode/plugins/agentalarm.ts` | 插件自带会话标题 |

配置文件含注释时不会自动改写，界面会给出可复制的片段。备份在 `~/Library/Application Support/AgentAlarm/backups/`。

## 命令行

```bash
agentalarm test                 # 发一条测试提醒
agentalarm status               # App 是否在监听
agentalarm notify --agent MyBot --title "构建完成" --kind turn_complete
echo '<hook json>' | agentalarm hook claude
```

`hook` 与 `notify` 永远以 0 退出且无 stdout；`AGENTALARM_DEBUG=1` 时在 stderr 打印诊断。

## 排查

- `agentalarm status` 显示 unreachable：App 未运行，或 socket 文件 `~/Library/Application Support/AgentAlarm/agentalarm.sock` 被清理，重启 App。
- 没有播报：看 设置 → 通用 → 最近事件 里的 outcome；`silent: cooldown` 是同会话 10 秒内重复，`alert, speech suppressed` 是宿主在前台且你正在操作。
- 系统日志：`log show --last 10m --predicate 'subsystem == "com.jack.agentalarm"' --style compact`
- 标题不对：Claude 读 transcript 的 `custom-title`，Codex 读 `~/.codex/state_N.sqlite` 的 `threads.name`，都属内部格式，解析失败时退化为项目目录名。

## 文档

- 设计规格：`docs/superpowers/specs/2026-09-17-agentalarm-design.md`
- 调研：`docs/research/2026-09-17-agent-notification-survey.md`
- 验收清单：`docs/acceptance-checklist.md`
````

- [ ] **Step 2: 写验收清单**

`docs/acceptance-checklist.md`:

```markdown
# AgentAlarm v1 手工验收清单

每项通过后打勾并记录日期。

## 基础
- [ ] `swift test` 全部通过
- [ ] `xcodebuild -scheme AgentAlarm` 构建成功，App 内含 `Contents/MacOS/agentalarm`
- [ ] App 启动后 `~/.local/bin/agentalarm` 软链接正确；`agentalarm status` 为 reachable
- [ ] `agentalarm test`：提示音 + 语音 + 横幅 + 菜单条目
- [ ] App 未运行时 `agentalarm hook claude < fixture` 在 1 秒内退出且退出码 0、无 stdout

## Claude Code
- [ ] 桌面 App（Claude.app）：回合结束 → 播报该会话标题，状态"已完成"
- [ ] 桌面 App：出现权限提示约 6 秒后 → "需要授权"
- [ ] 桌面 App：Claude 用 AskUserQuestion 提问 → "有问题要问你"
- [ ] CLI（iTerm）：回合结束 → 播报，标题为 `/rename` 后的名字或项目目录名
- [ ] 60 秒无回复 → 再提醒一次"还在等你"；关闭"重复提醒"后不再提醒
- [ ] 用户回复后条目从菜单列表消失
- [ ] Claude.app 在前台且正在打字时，只有提示音没有语音

## Codex
- [ ] 打开开关后 `~/.codex/hooks.json` 生成，`config.toml` 的 `notify` 未变
- [ ] TUI 里 `/hooks` 信任后：回合结束 → 播报，标题为线程名或首条消息
- [ ] 授权请求 → "需要授权"
- [ ] VS Code 扩展中的 Codex 会话 → 同样触发
- [ ] Codex 桌面版（ChatGPT.app）是否触发 hooks：记录结果 ______

## Gemini CLI
- [ ] 回合结束 → 播报，标题为 summary 或首条消息
- [ ] 工具授权提示 → "需要授权"

## OpenCode
- [ ] TUI：回合结束 → 播报，标题为 OpenCode 自动标题
- [ ] 授权与提问事件 → 对应状态
- [ ] OpenCode.app 桌面版 → 同样触发：记录结果 ______

## 交互
- [ ] 点击横幅 → 宿主应用（Claude.app / iTerm / VS Code）被激活
- [ ] 点击菜单条目 → 宿主激活且条目出现 ✓
- [ ] 暂停 15 分钟 → 无声无横幅，列表仍更新；恢复后正常
- [ ] 静音时段内 → 无声
- [ ] 三个会话几乎同时结束 → 合并播报"有 3 个会话在等待：…"

## 卸载
- [ ] 关闭四个开关后，各配置文件恢复到只剩用户自己的内容；插件文件被删除
- [ ] 备份目录最多保留 10 份
```

- [ ] **Step 3: 最终全量验证**

Run:
```bash
swift test 2>&1 | tail -2
xcodegen generate && xcodebuild -project AgentAlarm.xcodeproj -scheme AgentAlarm -configuration Debug -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
git status --short
```
Expected：测试全部通过，构建成功，工作区只剩 README 与清单待提交。

- [ ] **Step 4: Commit**

```bash
git add README.md docs/acceptance-checklist.md
git commit -m "docs: add README and manual acceptance checklist"
```
