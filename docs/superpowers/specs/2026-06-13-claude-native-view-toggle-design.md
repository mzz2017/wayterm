# Claude 原生视图切换 — 在活 zmx 会话上无损切换原始/原生 UI(设计稿)

Date: 2026-06-13
Branch (VVTerm): TBD（建议 `feat/claude-native-view`）
依赖：`feat/zmx-session-binding-ssh-auth`（已合入 main，提供 zmx 多路复用 + 会话绑定）

## Summary

VVTerm 已支持通过 zmx（轻量级终端多路复用器）保持远端会话持久化。当用户在一个
zmx 会话里跑 `claude`（Claude Code TUI）时，移动端透过 ghostty 渲染的「原始终端
视图」就像「一个没有移动端适配的网页」——能用，但强行看非常丑陋，且偶有光标/重排
的小显示问题。

本方案在**同一个活会话**上提供两种渲染：

1. **原始视图**：现有的 ghostty 终端（保留，给真 TUI / vim / htop / 普通 SSH 用）。
2. **原生视图**：把 claude 会话渲染成原生 SwiftUI（对话气泡、diff 卡片、工具卡、
   折叠 thinking、任务清单），专为移动端阅读优化。

两者**无损互切**——因为两个视图**都不持有会话**。会话活在 zmx 守护进程里的 claude
进程（+ pty + ghostty-vt 终端模型）。切视图只是换一个渲染器贴到屏幕上，进程毫不知情。

> 本质就是 Markdown 编辑器的「源码 ⇄ 预览」开关，只不过两边都接在同一个活会话上。

## 核心洞察：这是一个假二选一

「界面舒服」与「功能最新」看似矛盾，矛盾其实来自 **agent loop 跑在哪**：

- **重写型客户端**（自己在 app 里实现 tool calling、context、web search）：UI 再漂亮，
  本质是在重新发明 Claude Code，每出一个新功能（skills、新 permission 流、subagent、
  thinking、memory recall）都要追，**永远落后**。
- **终端透传型**（vvterm 现状）：agent loop 是**真 Claude Code**，永远最新——代价是被迫
  在手机上渲染一个为 80×24 字符网格设计的 TUI。

第三条路——**真引擎 + 原生外壳**——绕开二选一：让真 claude 照常在 zmx 里跑（永远最新），
同时在移动端**额外**用结构化数据渲染原生 UI（舒服）。关键在于：**这份结构化数据已经免费
存在了**，不需要为了拿到它而改变 claude 的跑法。下一节用已验证的事实证明这一点。

## Goals

- 在一个正在运行 claude 的 zmx 会话上，提供「原始视图 ⇄ 原生视图」的 per-tab 切换。
- 切换**无损**：不重启 claude、不丢失会话状态、不打断正在进行的 turn。
- 原生视图**专为移动端阅读优化**：对话/diff/工具/任务清单/折叠 thinking。
- 不依赖 Anthropic 任何 alpha 接口、不依赖云端 relay、不依赖第三方服务器。
- 完全复用 vvterm 现有的 SSH 传输、Keychain、zmx 会话绑定。
- 原始终端视图作为一等公民保留，给真 TUI 和「需要动手操作」的场景兜底。

## Non-Goals

- 不把 claude 改成 headless（`--print --output-format stream-json`）方式跑。理由见下：
  headless 模式下**没有真 TUI 可切**，会毁掉本方案要保留的那一极，变成另一个产品
  （「独立的原生 CC 前端」），不是本方案要的「一个活会话上的视图开关」。
- 不实现逐 token 流式渲染（原因见 §流式粒度：transcript 是消息级落盘，非逐 token）。
- 不接管 / 不重排 claude 的对话逻辑；原生视图是**渲染器**，不是 agent。
- 不做 Remote Control bridge 集成（`@alpha`，需 Anthropic OAuth + trusted-device，
  第三方长期依赖会被 breaking change 反复打脸）。
- 第一阶段不做原生侧的写操作（审批/发 prompt）；只读优先（见 §分阶段落地）。

## 已验证的关键事实

以下事实均已在本机实地验证（CLI `claude 2.1.177`、`~/.claude/projects/`、
`~/projects/zmx` 源码），不是凭记忆。它们是整个方案成立的地基。

### 事实 1：claude 跑成 TUI 时，本身就在实时写结构化 transcript

claude 交互式 TUI 运行的同时，会把完整会话以 newline-delimited JSON（`.jsonl`）实时
追加到：

```
~/.claude/projects/<cwd-slug>/<session-id>.jsonl
```

其中 `<cwd-slug>` 是工作目录路径的转义形式（如 `-home-mzz-projects-vvterm`），
`<session-id>` 是会话 UUID。本机实测该文件在会话进行中持续追加（mtime 实时更新），
内容是带**完整 message 内容**的事件：`user` / `assistant` / `system` /
`file-history-snapshot` / `permission-mode` / `attachment` 等。这正是 `/resume` 的
数据源。

**含义**：原始 TUI 在跑的同时，一份结构化会话流已经免费躺在磁盘上。要做原生渲染，
**只需 tail 这个文件**，不需要切 headless 去换取结构化输出。

### 事实 1.5：`claude --session-id <uuid>` 让 transcript 文件名可被预先钉死

`claude --help` 确认存在 `--session-id <uuid>` 旗标（"Use a specific session ID for
the session"）。这把「zmx 会话 ↔ transcript 文件」的绑定从**启发式猜测**（按 cwd +
mtime 找最新活跃 jsonl）升级为**确定性映射**：

- 在 zmx 里启动 claude 时由 vvterm 注入固定 uuid：`claude --session-id $UUID`；
- 该 uuid 同时存进 `ConnectionSession`（与 zmx 会话绑定一并持久化）；
- 原生视图直接 tail `~/.claude/projects/<cwd-slug>/$UUID.jsonl`，零歧义。

这是本方案能做到「可靠定位 transcript」的关键一环，详见 §代码接缝。

### 事实 2：zmx 明确「reattach 无损恢复屏幕状态」

`~/projects/zmx/README.md`：*"Re-attaching to a session restores previous terminal
state and output."* 源码层面已确认其实现机制：

- zmx 守护进程内嵌 **ghostty-vt**（ghostty 的 VT 解析器 + 终端 Screen 模型，作为 Zig
  依赖），把 PTY 每个字节喂进 `term.vtStream()`，维护一份**权威的终端 grid + scrollback**
  （`src/main.zig` daemonLoop，`max_scrollback = 10_000_000`）。
- 客户端 attach 时发 `Init`，守护进程调用 `util.serializeTerminalState` 把当前 grid +
  scrollback 序列化成 **VT/ANSI 字节**回放给新客户端（`src/main.zig` handleInit）。
- 另有 `zmx history <name> --vt|--html|--plain` 命令，把完整终端状态一次性导出
  （`util.serializeTerminal`，`HistoryFormat = { plain, vt, html }`）。

**含义**：原始 grid 任何时候都可从 zmx 重建。切回原始视图 = 让 ghostty 重放一次 VT
快照即可，会话不受影响。

### 事实 3：zmx 支持「只读第二观察者」，不打扰主客户端

zmx 守护进程把 PTY 的 `Output` 广播给**所有**连接的客户端
（`src/main.zig` handleOutput：`for (self.clients.items) |client| appendMessage(.Output)`）。
因此可以：

- 第二个客户端连上同一个 socket，**只收 `Output`、永不发 `Input`**，即可拿到实时 VT 流；
- 永不发 `Input` 就不会触发 leader 选举 / PTY resize，**完全不打扰主客户端**；
- 若要一次性快照而非常驻，发 `History` 标签即可，更轻。

**含义**：除了 tail jsonl，vvterm 还有第二条独立的「旁路观察」通道可选（VT 字节级），
两条路可互为补充 / 校验。但本方案主路径用 jsonl（结构化，渲染更省力）。

## Transcript 事件 → 原生 UI 映射

原生视图的渲染依据是 transcript 的事件流。以下映射来自对本机真实 jsonl 的逆向
（主样本 `18c224c2-….jsonl` 2588 行，及多份兄弟文件）。

### 顶层事件类型

每行一个 JSON 对象。线程关系：`uuid` + `parentUuid` 构成链表；`sessionId` 为文件名
UUID。部分事件带 `timestamp`（ISO-8601 UTC 毫秒），部分（header/state 记录）不带。

| `type` | 关键字段 | 原生 UI 元素 |
|---|---|---|
| `user` | `message.content`（string 或 tool_result 列表）、`promptSource`、`isMeta`、`toolUseResult` | 人类气泡；content 为 tool_result 列表时 → 工具结果行；`isMeta` → 系统注释 |
| `assistant` | `message.content[]`（text/thinking/tool_use）、`message.model`、`usage`、`stop_reason`、`isApiErrorMessage` | AI 气泡；按 content block 分别渲染；错误 → 错误横幅 |
| `system` | `subtype`（turn_duration / local_command / api_error / stop_hook_summary）、`level` | 折叠系统注释行；按 subtype → 时长 pill / 终端回显 / 错误重试横幅 |
| `attachment` | `attachment.type`（见子表） | 按子类型渲染 |
| `queue-operation` | `operation`（enqueue/popAll/remove）、`content` | 队列/待发 prompt 指示；enqueue → 幽灵 prompt chip |
| `file-history-snapshot` | `snapshot.trackedFileBackups`（filePath → {backupFileName, version, backupTime}） | 文件变更检查点标记（diff 按钮锚点） |
| `mode` / `permission-mode` | `mode` / `permissionMode`（plan / bypassPermissions） | 会话模式 / 权限模式徽章 |
| `ai-title` | `aiTitle` | 会话标题 |
| `last-prompt` / `worktree-state` | 内部指针 / worktree 上下文 | 隐藏 / worktree 横幅 |

**attachment 子类型**（`attachment.type`）值得单列，移动端很多「信息卡」来自这里：

| 子类型 | 字段 | 原生 UI |
|---|---|---|
| `hook_success` / `hook_cancelled` | hookName, stdout, exitCode, durationMs | 可折叠 hook 输出行 |
| `task_reminder` | `content[]`（id/subject/description/activeForm/status/blocks/blockedBy） | 原生任务清单卡（见下） |
| `edited_text_file` | filename, snippet（行号预览） | 文件已编辑 chip |
| `file` / `compact_file_reference` | filename, displayPath, content.file | 内联文件预览卡 / 紧凑引用 chip |
| `skill_listing` | names[], skillCount | 技能面板 |
| `command_permissions` | allowedTools[] | 已允许工具 chips |
| `date_change` | newDate | 日期分隔符 |

### assistant content block 与工具 input 形状

`assistant.message.content` 是有序 block 列表：

- **`text`** `{type, text}`：Markdown，渲染为 AI 文字气泡。
- **`thinking`** `{type, thinking, signature}`：⚠️ `thinking` 字段在磁盘上**恒为空串**
  （内容加密 at rest），仅 `signature` 非空。**transcript 拿不到 thinking 正文**，只能
  渲染一个折叠的「Thinking…」chip（无内容）。
- **`tool_use`** `{type, id, name, input}`：渲染为工具卡；`id` 被后续 `user` 事件的
  `tool_result` 用 `tool_use_id` 匹配。

关键工具的 `input` 形状（仅列 key，用于原生卡片布局）：

```
Bash:            { command, description, timeout? }
Read:            { file_path, offset?, limit? }
Edit:            { file_path, old_string, new_string, replace_all? }
Write:           { file_path, content }
Agent:           { description, subagent_type, prompt }
TaskCreate:      { subject, description, activeForm? }
TaskUpdate:      { taskId, status?, addBlocks?, addBlockedBy?, ... }
Skill:           { skill, args? }
AskUserQuestion: { questions: [{ question, header?, multiSelect, options:[{label,description}] }] }
ExitPlanMode:    { plan, planFilePath }
WebSearch/WebFetch: { query|url, ... }
```

### tool_result（user 事件里）

`user.message.content` 为 tool_result block 列表：
`{type:"tool_result", tool_use_id, content, is_error}`。此外每个带结果的 `user` 事件还有
一个结构化的 `toolUseResult` 字段（比 API 面的 content 更富）：

- Edit：`{filePath, oldString, newString, structuredPatch[], originalFile, replaceAll}`
- Write：`{type:"create"|"update", filePath, content, structuredPatch[]}`
- Bash：`{stdout, stderr, interrupted, isImage, ...}`
- Agent：`{status, agentId, agentType, content[], totalTokens, toolStats}`

### 可重建性结论（原生渲染的可行性边界）

| 能力 | 能否仅凭 jsonl 重建 | 依据 |
|---|---|---|
| **Edit diff** | ✅ 完全可以 | `toolUseResult` 带完整 `oldString`/`newString` + `structuredPatch`（带行号的 unified hunks），自包含，无需外部备份文件 |
| **Write diff** | ✅ create=全 `+`；update 有 structuredPatch | 同上 |
| **任务清单 (todos)** | ✅ 完全可以 | `task_reminder` attachment 每次快照带完整任务数组；TaskCreate/Update 提供增量 |
| **subagent 活动** | ✅ 可以（需 join） | 子 agent 消息写在 `<session-dir>/subagents/agent-<id>.jsonl`（`isSidechain:true`），用 `.meta.json` 的 `toolUseId` 与父 jsonl 的 tool_use 关联；父 jsonl 也有最终 result |
| **thinking 正文** | ❌ 不可 | 磁盘上恒为空串（加密）；只能显示「Thinking…」占位 |
| **逐 token 流式** | ❌ 不可 | 见下 |
| **待决 permission 弹窗** | ❌ 不可 | 见下 |

## 必须诚实的两个硬约束

### 控制难（显示易）

- **显示**（读会话）：干净。tail jsonl → 原生渲染。这正好命中痛点——「**强行看**非常
  丑陋」，痛在*看*不在*操作*。这一半几乎零代价。
- **控制**（批准 permission、发 prompt、回答 AskUserQuestion）：jsonl 是只读日志，**没有**
  配套的「文件式应答通道」。要从原生 UI 动作，只能把按键写回 zmx 的 pty（给 TUI 注入
  键击，比如批准就发 `1\r`）。这是 screen-scraping 式控制，不优雅但稳定、可优雅降级。

### 待决 permission 不在 transcript 里

⚠️ **transcript 没有「权限弹窗已展示 / 用户如何应答」的事件**。权限对话是终端进程里的
阻塞 UI，在用户应答前**不写任何东西到 jsonl**。transcript 只记录**结果**（下一个工具调用
成功、或会话停止），从不记录**待决的弹窗本身**。

**含义**：纯 tail jsonl 的原生视图**看不到待决审批**。这正是「第一刀只做只读视图、把需要
动作的地方一键翻回原始视图去点」这一设计的根本原因（详见 §分阶段落地）。

### 流式是消息级，不是 token 级

assistant 消息**一次性写入**（每个 `uuid` 唯一，无 partial 记录）。claude 会把多 block
响应拆成多条完整 API 记录（text 一条、紧跟 tool_use 一条）。file-tailer 只在整条 API
响应到达后才看到新 `assistant` 事件追加。

**含义**：原生视图是「整条消息刷出 + Thinking… 转圈」，**没有 TUI 那种逐字流式**。对移动端
而言消息级粒度其实更稳、更不晕，视为优点。想要逐 token 只能切 headless，而那会杀掉真 TUI。

## 架构：一个真相，两个读者

```
        ┌─────────────────────────────────────┐
        │  唯一真相:zmx 守护进程里那个活的       │
        │  claude 进程 (+ pty + ghostty-vt grid) │   ← 谁都不“拥有”它
        │  且实时写 ~/.claude/projects/<id>.jsonl │
        └───────┬───────────────────┬───────────┘
   重放 VT 快照 │                   │ 实时追加结构化事件
   (zmx Init/   │                   │ (jsonl)
    History)    ▼                   ▼
        ┌──────────────┐    ┌──────────────────────┐
        │ 原始视图       │    │ 原生视图               │
        │ ghostty 终端   │    │ tail jsonl → SwiftUI:  │
        │ (现状,真 TUI)  │    │ 气泡/diff/工具卡/清单   │
        └──────────────┘    └──────────────────────┘
              ▲                        │
              └── 需要动作时一键翻回 ────┘ (第一阶段)
```

三个组件：

1. **会话真相**：zmx + claude，照常跑，vvterm 不改其行为，只在启动时注入 `--session-id`。
2. **TranscriptObserver**（新）：host 上 tail `$UUID.jsonl`（增量读 + 解析），把事件流
   推给 iOS；或 iOS 端直接通过 SSH `tail -f` 远端文件后本地解析。
3. **ClaudeNativeView**（新，SwiftUI）：消费事件流，渲染原生卡片。

切换无损的根因：组件 2/3 都是**旁路读者**，不持有会话；原始视图是另一个读者（ghostty）。
切视图 = 换贴到屏幕上的渲染器，claude 进程毫不知情。

## VVTerm 代码接缝（落地点）

以下接缝来自对 vvterm 当前代码的实地勘查。注意分支差异：
- zmx 多路复用 + 会话绑定的类型在 `feat/zmx-session-binding-ssh-auth`（已合 main）。
- External I/O 字节流改造在 `feat/ghostty-external-io`（待 Mac 重建 xcframework）。
  本方案的「字节流 tap」依赖 External 分支的 `writeOutput` 接缝，故实现排期应在
  ghostty 分支合入之后，或基于其分支开发。

### (a) per-session 状态之家

`VVTerm/Features/TerminalSessions/Domain/ConnectionSession.swift` —
`struct ConnectionSession`（值类型，存活于 `ConnectionSessionManager.shared.sessions`
这个 `@Published` 数组）。已有先例字段 `var tmuxStatus: TmuxStatus`。新增：

```swift
// 视图模式（原始终端 / 原生 claude）
var claudeViewMode: ClaudeViewMode = .terminal   // enum { terminal, nativeClaude }

// 钉死的 claude 会话 id —— 用于确定性定位 transcript（事实 1.5）
var claudeSessionId: UUID?                        // 启动 claude 时 --session-id 注入
```

因为是值类型存于 `@Published` 数组，任意 session 变更都会触发 SwiftUI 重渲。绑定的
持久化可复用 zmx 分支已有的 `TmuxSessionBindingStore`（同一套「跨重启 hydrate/persist
会话绑定」机制，1fcd5a0 / ed04dc2）。

### (b) zmx 已落地的类型（复用，不重造）

`feat/zmx-session-binding-ssh-auth` 已提供：

- `Domain/TerminalMultiplexer.swift` — `enum TerminalMultiplexer { none, tmux, zmx }`，
  本方案据此判断「当前会话是否走 zmx」（仅 zmx/tmux 会话才谈得上持久化 + 旁路观察）。
- `Core/SSH/RemoteZmxCommandBuilder.swift` + `RemoteTmuxManager`（`.zmx(commandName:)`）—
  生成 zmx attach/create 命令的地方，**注入 `claude --session-id $UUID` 的最佳位置**。
- `Application/ConnectionSessionManager.swift` — `registerSSHClient(...)` 流程，
  会话生命周期编排点，原生视图的 observer 在此挂接。

### (c) 字节流 tap 点（旁路观察的备选通道）

主路径用 jsonl，但若要 VT 字节级旁路（事实 3）或做校验，tap 点在：

`VVTerm/Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift` —
`SSHConnectionRunner.run(...)` 的 `shouldContinueStreaming` 闭包，是唯一的 Swift 侧
入站字节 chokepoint（在 `terminal.writeOutput(data)` 把字节交给 ghostty C 库之前）：

```swift
shouldContinueStreaming: { data, terminal in
    // data: Data —— 原始 SSH 字节块,此处仍是 Swift 可见的拷贝
    terminal.writeOutput(data)   // ← 越过此行后字节归 Zig 终端状态机所有,Swift 无副本
    return true
}
```

⚠️ **硬约束**：一旦 `ghostty_surface_write_output` 被调用，字节由 Zig 终端状态机拥有，
Swift 侧无可读回的拷贝。任何字节级 tap 必须在 `writeOutput` **之前**插入。

出站（键击 → SSH）的 tap：`GhosttyTerminalView.writeCallback: ((Data) -> Void)?`。
原生视图激活时，可将其置 nil 以抑制键击转发（不销毁活终端 surface）。

### (d) UI toggle 插入点

vvterm 已有「视图切换器」基础设施 `ConnectionViewTab`（终端 / 文件浏览 等分段）。
新增一个 `.claude` tab 即可让切换控件在 iOS 导航栏 picker、iOS Zen Mode 面板、macOS
工具栏 picker **三处自动出现**：

- iOS 工具栏：`App/iOS/.../iOSContentView.swift` 的 `navigationToolbar` →
  `iOSNativeSegmentedPicker(tabs: viewTabConfig.currentVisibleTabs)`。
- iOS 内容分发：`iOSTerminalView.sessionPage(_:)` 的 ZStack，按 `effectiveViewSelection`
  分支；新增 `if effectiveViewSelection == "claude" { ClaudeNativeView(...) }`。
- macOS：`Features/TerminalSessions/UI/.../ConnectionTabsView.swift` 的
  `ConnectionTerminalContainer.viewPickerToolbarItem` + `contentLayer` ZStack。
- 注册可见性：`ViewTabConfigurationManager.currentVisibleTabs` —— 仅当检测到当前会话
  前台是 claude（见下）时才把 `.claude` 标为可见，避免在普通 SSH 会话里出现噪音 tab。

### (e) 「当前会话是否在跑 claude」的检测

判定 `.claude` tab 是否该出现：

1. 该会话的 `TerminalMultiplexer` 为 `.zmx`（或 `.tmux`）；且
2. 存在与之绑定的 `claudeSessionId`（说明是 vvterm 通过 `--session-id` 启动的 claude）；
   或
3. 兜底启发式：远端 `~/.claude/projects/<cwd-slug>/` 下存在 mtime 活跃、cwd 匹配的
   jsonl（适配「用户在 zmx 里自己手敲 `claude`」的情况——此时无注入 id，需按 cwd+mtime
   猜测，歧义风险见 §开放问题）。

最稳的是路径 2：由 vvterm 主动用 `--session-id` 启动 claude，从源头消除歧义。

## 控制通道：两条路与取舍

原生视图要「动手」（审批、发 prompt、回答问题）有两条根本不同的路：

### 路 A：PTY 键击注入（贴合本方案，推荐用于第二阶段）

把原生 UI 的动作翻译成键击，经 SSH/zmx 写回**正在运行的 claude TUI** 的 pty：

- 发 prompt：写入文本 + `\r`。
- 审批：检测到待决权限时（注意：待决态**不在 jsonl**，需靠原始 grid 的旁路观察或在
  原生侧维持一个「可能待决」推断），发对应数字键 `1\r` / `2\r`。
- 优雅降级：任何不确定的动作 → 一键翻回原始视图让用户手点。

优点：复用现有 SSH/zmx，零新依赖，**保留真 TUI**。缺点：screen-scraping 式，依赖 TUI
键位约定，权限待决态检测不可靠（因事实：待决不落 jsonl）。

### 路 B：headless `--input-format stream-json`（明确不在本方案内）

`claude --print --output-format stream-json --input-format stream-json
--permission-prompt-tool stdio` 可拿到结构化的 `can_use_tool` 控制请求，审批回写 stdin，
干净。但这要求**从启动就 headless**——**没有真 TUI 可切**，与本方案「无损切回原始
ghostty 视图」的核心目标冲突。故列为 Non-Goal，仅在此记录权衡，供未来「独立原生 CC
前端」产品参考。

> 结论：本方案显示走 jsonl（路无关），控制走路 A（PTY 注入）+ 一键回退兜底。

## 分阶段落地

### 第一刀：原生 = 只读美观视图（吃掉 ~90% 痛点，几乎不碰控制）

1. zmx 启动 claude 时注入 `--session-id $UUID`，写入 `ConnectionSession.claudeSessionId`。
2. 检测到会话前台是 claude → 在视图切换器显示 `.claude` tab。
3. `TranscriptObserver`：SSH `tail -f ~/.claude/projects/<slug>/$UUID.jsonl`（或 host
   侧增量读），解析事件流。冷启动先全量读一次重建历史，再切到增量 tail。
4. `ClaudeNativeView`（SwiftUI）：渲染对话气泡、Edit/Write diff 卡、Bash/工具卡、
   task_reminder 任务清单、折叠 thinking 占位、subagent 嵌套（join subagents/ 子文件）。
5. **任何需要动作的地方**（审批、输入框）给一颗按钮 → **一键翻回原始视图**去点。
   无损，因为翻回去 grid 是活的（zmx 重放）。

此阶段不写 pty，零控制风险，且完全规避「待决权限不在 jsonl」的问题（用户在原始视图里
看到并应答）。

### 第二刀（可选）：补齐原生侧操作

- 高频动作（发 prompt、批准/拒绝）用路 A 的 pty 键击注入，在原生视图内直接做。
- 失败 / 不确定 → 仍回退到原始视图。
- 待决权限态：用 zmx 旁路观察（事实 3，只读第二客户端拿 VT 流）检测原始 grid 上是否
  出现权限提示框，驱动原生审批卡的出现时机。

### 验证手段

- 单测：transcript 解析器对各 event type / tool input 形状的解码（用本机真实 jsonl
  样本作 fixture）。
- diff 重建：对 Edit 的 `structuredPatch` 渲染做快照测试。
- 端到端：真机 SSH 连一个跑着 claude 的 zmx 会话，原始 ⇄ 原生反复切，断言会话不中断、
  历史不丢、turn 不被打断。

## 前车之鉴：同类项目对照

调研了 2026 年中「把 coding-agent 会话渲染成非终端 / 原生 UI」的主要项目，提炼其传输
选择与教训。核心区别在**传输机制**。

| 项目 | 传输机制 | 原生渲染 | 审批处理 | 对本方案的启示 |
|---|---|---|---|---|
| **Anthropic Remote Control**（官方） | 本地 claude 出站 HTTPS 注册到云 relay，手机/浏览器经 relay 驱动**活的 TUI** | 全量（官方 app） | relay 转发，设备应答 | 唯一真·无损切换，但闭源 relay、需订阅、客户端是 Claude app（无法嵌入自有 app） |
| **Happy**（slopus/happy，~22k★） | 双模：本地态 tail `~/.claude/projects/*.jsonl` E2E 加密推 relay；远程态切 **ACP（headless stream-json）** | 全量原生（RN）：文字/thinking/工具卡/subagent/权限卡 | ACP `RequestPermission` over `--permission-prompt-tool stdio` | **切远程要重启 claude 进 SDK 模式**——非活 TUI 透明接管。证明「tail jsonl 做显示」可行 |
| **AgentAPI**（coder，~1.4k★） | 把 claude 跑在内存 PTY 里，**diff 屏幕快照**反推消息 | 浏览器，无结构化工具事件 | 文本注入 "y\n" | TUI 变动就坏；印证 screen-scraping 控制的脆弱 |
| **omnara** V1（已归档） | tail jsonl + 解析终端输出 | web/mobile | 监控输出 + 注入 stdin | **「随 claude 每次更新而崩，无法维护」而弃**——警示重写型/脆弱解析路线 |
| **claude-code-viewer**（d-kimuson） | 双模：tail jsonl（只读）+ Agent SDK（`canUseTool` 驱动） | web，diff/工具可视化 | SDK `canUseTool` + `Effect.Deferred`，最干净 | 订阅账号受 ToS 限制时**回退只读 jsonl tail** —— 与本方案第一刀同构 |
| **VibeTunnel** | PTY 转发 + Xterm.js | 浏览器终端（非原生） | 文本 | 技术上无损但仍是终端，非原生渲染 |

**横向结论**：

1. **没有任何开源项目实现了「活交互式 TUI → 原生 UI 的中途无损切换」**。要么像
   Remote Control 用闭源云 relay，要么像 Happy「切模式 = 重启进 headless」。
2. 一旦 claude 以交互 TUI 启动，它**不会同时**吐 stream-json；不重启就加不上结构化输出。
   ——这正是为什么本方案**不追求**在原生侧拿结构化控制流，而是「显示走 jsonl（免费已有），
   控制走 PTY 注入 + 回退原始视图」。
3. **本方案的独特点**：用 **zmx 持久化** 把「同一活会话」做实，使「原始 ⇄ 原生」成为
   *两个旁路读者之间的切换*，而非*会话的重启/接管*。这是 vvterm 现有资产（zmx 绑定 +
   SSH + ghostty）赋予的、别人没有的位置。

## 风险与权衡

| 风险 | 影响 | 缓解 |
|---|---|---|
| transcript 格式是私有的、随 CC 版本演进 | 解析器可能在 claude 升级后失配 | 解析器**宽容化**（未知 event/block 跳过不崩）；用真实 jsonl 做回归 fixture；只依赖稳定的核心字段（user/assistant/tool_use/tool_result/structuredPatch） |
| 待决权限不落 jsonl | 原生视图看不到「该批准了」 | 第一刀只读 + 一键回原始视图（用户在 TUI 里应答）；第二刀用 zmx VT 旁路观察推断待决态 |
| thinking 正文加密不可读 | 原生看不到思考内容 | 显示「Thinking…」折叠占位；这是 CC 的固有限制，非本方案缺陷 |
| 无逐 token 流式 | 原生视图非逐字出 | 消息级粒度对移动端更稳，接受为设计取舍；turn 进行中显示转圈 |
| 「用户手敲 claude」无注入 id | transcript 定位靠 cwd+mtime 猜测，可能歧义 | 优先由 vvterm 用 `--session-id` 启动；手敲场景做 best-effort + 让用户在多候选时确认 |
| 字节流 tap 依赖 External 分支 | 排期耦合 ghostty 分支 | 主路径（jsonl）不依赖字节 tap；字节级旁路为可选增强，可后置 |
| host 上 `~/.claude` 路径/权限差异 | tail 失败 | 启动时探测路径；失败则 `.claude` tab 不出现，静默回退纯终端 |

## 明确不做的事

- 不把 claude 改成 headless 跑（毁掉可切的原始 TUI 这一极）。
- 不接 Remote Control bridge（`@alpha`，第三方长期依赖不稳）。
- 不在 app 内重实现 agent loop（重写型死路，永远落后）。
- 第一阶段不做原生侧写操作（审批/发 prompt）。
- 不改 claude / zmx / ghostty 的会话行为；原生视图只读旁路。
- 不渲染逐 token 流式。

## 开放问题

1. **transcript 来源走哪条 SSH 通道**：复用主 shell 通道里 `tail -f`，还是另开一个
   exec 通道专跑 tail？后者更干净（不与交互 IO 抢字节）但多一个 channel。倾向另开。
2. **host 侧解析 vs iOS 侧解析**：在 host 上跑一个薄解析器只推增量结构化事件（省流量、
   省 iOS 解析），还是 iOS 直接 tail 原始 jsonl 本地解析（零 host 依赖）？倾向后者起步，
   host 解析作为优化。
3. **手敲 claude 的会话发现**：cwd+mtime 启发式在多会话同 cwd 时如何消歧？是否需要在
   zmx 层暴露「当前前台进程 + 其 --session-id」给 vvterm 探测？
4. **第二刀权限待决检测**的可靠性门槛：zmx VT 旁路观察 grid 文本匹配权限框，是否足够稳到
   敢在原生侧弹审批卡，还是永远保守地「回退原始视图」？
5. **历史很长时的冷启动**：4MB+ jsonl 全量解析的首屏延迟，是否需要分页 / 只渲染最近 N turn +
   懒加载更早历史。
6. **iOS 后台 / 断连**：tail 中断后如何无缝续读（jsonl 是 append-only，按字节 offset 续读
   即可，但要处理 host 侧 `--no-session-persistence` 或 compaction 边界）。

## 附录

### 关键 file:line 索引（实现时按此定位）

VVTerm（注意分支）:
- `Features/TerminalSessions/Domain/ConnectionSession.swift` — 加 `claudeViewMode` /
  `claudeSessionId`
- `Features/TerminalSessions/Domain/TerminalMultiplexer.swift` — `enum { none, tmux, zmx }`
- `Core/SSH/RemoteZmxCommandBuilder.swift` — 注入 `claude --session-id $UUID`
- `Features/TerminalSessions/Application/ConnectionSessionManager.swift` —
  `registerSSHClient(...)` 挂 observer
- `Features/TerminalSessions/Application/TmuxSessionBindingStore.swift` — 绑定持久化复用
- `Features/TerminalSessions/UI/Terminal/SSHTerminalWrapper.swift` —
  `SSHConnectionRunner.run` 的 `shouldContinueStreaming`（字节 tap，External 分支）
- `App/iOS/.../iOSContentView.swift` — `navigationToolbar` / `sessionPage(_:)`（toggle）
- `Features/TerminalSessions/UI/.../ConnectionTabsView.swift` — macOS picker / contentLayer
- `ConnectionViewTab` + `ViewTabConfigurationManager` — 加 `.claude` tab + 可见性

zmx（`~/projects/zmx`，仅供旁路观察实现参考）:
- `src/ipc.zig` — Tag 协议（Input/Output/Init/History/Info…），Header `{tag:u8,len:u32}`
- `src/main.zig` — `handleInit`/`handleOutput`（广播）/`handleHistory`/`daemonLoop`（ghostty-vt）
- `src/util.zig` — `serializeTerminalState` / `serializeTerminal` / `HistoryFormat`

claude transcript:
- `~/.claude/projects/<cwd-slug>/<session-id>.jsonl` — 主会话流
- `~/.claude/projects/<cwd-slug>/<session-id>/subagents/agent-<id>.{jsonl,meta.json}` — 子 agent
- `~/.claude/file-history/<session-id>/<backupFileName>` — 文件备份（diff 不依赖它，
  structuredPatch 自包含）

### 关键命令 / 旗标

- `claude --session-id <uuid>` — 钉死 transcript 文件名（确定性绑定）
- `claude --help` 确认存在：`--resume`/`--continue`/`--fork-session`/`--no-session-persistence`
- `zmx history <name> --vt|--html|--plain` — 一次性终端状态快照
- zmx 只读观察：连 socket，发 `Init`（用现有尺寸避免 resize），只收 `Output`，永不发 `Input`

### 参考来源

- Claude Code headless / stream-json：`claude --help`、`@anthropic-ai/claude-agent-sdk`
  类型定义（本机 0.3.177 实测）
- Remote Control：https://code.claude.com/docs/en/remote-control
- Happy：https://github.com/slopus/happy （`docs/permission-resolution.md`、ACP）
- AgentAPI：https://github.com/coder/agentapi
- omnara：https://github.com/omnara-ai/omnara （归档说明 + HN 44878650）
- claude-code-viewer：https://github.com/d-kimuson/claude-code-viewer （PR #174）
- stream-json 控制协议逆向：
  https://github.com/Roasbeef/claude-agent-sdk-go/blob/main/docs/cli-protocol.md



