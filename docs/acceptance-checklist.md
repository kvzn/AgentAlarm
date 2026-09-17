# AgentAlarm v1 手工验收清单

每项通过后打勾并记录日期。

## 基础
- [ ] `swift test` 全部通过（99 tests）
- [ ] `xcodebuild -scheme AgentAlarm` 构建成功，App 内含 `Contents/Helpers/agentalarm`
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
