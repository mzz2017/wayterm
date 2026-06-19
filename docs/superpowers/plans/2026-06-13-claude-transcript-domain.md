# Claude Transcript Domain 解析层 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Claude Code 的 `.jsonl` transcript 解析成强类型 Swift 事件模型，并从中重建 diff / 任务清单 / subagent 关联——纯 Foundation，可在 Linux 上 `swift test`。

**Architecture:** 一个独立的、零平台依赖的 Swift Package（`ClaudeTranscriptKit`），只 `import Foundation`。它消费 transcript 的一行（一个 JSON 对象）→ 产出一个 `TranscriptEvent` 枚举；并提供把事件流投影成「对话项」「diff」「任务清单」「subagent join」的纯函数。**不含**任何 SwiftUI / UIKit / SSH / ghostty 代码——那些属于后续 Mac-only 阶段。本包是「第一刀」里唯一能在本机 TDD 跑到绿的部分。

**Tech Stack:** Swift 6.3.2（本机开源工具链已验证可 `swift test`）、Swift Package Manager、Foundation `Codable` / `JSONDecoder`、XCTest。

**关键约束（硬性）：**
- 本包**只能** `import Foundation`。任何 `import SwiftUI/UIKit/AppKit` 都会破坏 Linux 构建，禁止。
- 解析器必须**宽容**：未知 `type` / 未知 content block / 未知 attachment 子类型 → 归入 `.unknown(raw:)`，**绝不抛错、绝不崩**。transcript 格式是私有且随 CC 版本演进的（见 spec 风险表）。
- 仅依赖 spec 已验证为稳定的核心字段：`type` / `uuid` / `parentUuid` / `timestamp` / `message.content[]` / `tool_use` / `tool_result` / `toolUseResult.structuredPatch`。
- 所有形状均已对真实 jsonl 实测（见 spec §Transcript 事件→原生 UI 映射）。

**实测确认的形状（计划据此编写，勿凭记忆改动）：**
- 顶层 `type`：`user` / `assistant` / `system` / `attachment` / `queue-operation` / `file-history-snapshot` / `mode` / `permission-mode` / `ai-title` / `last-prompt` 等。
- `assistant.message.content[]` block：`text` / `thinking`（`thinking` 字段恒为空串，仅 `signature` 有值）/ `tool_use`（`{id,name,input}`）。
- `user.message.content`：string，或 `tool_result` 列表 `{type,tool_use_id,content,is_error?}`。
  - `tool_result.content` 既可能是 **string** 也可能是 **数组**（`[{type:"text",text:…}]`）——必须两者都解。
  - `is_error` 可能**缺省**（视为 false）、true、false。
- `toolUseResult.structuredPatch[]`：`{oldStart,oldLines,newStart,newLines,lines:[String]}`，`lines` 每条以 `+`/`-`/` ` 前缀。**自包含，diff 无需外部备份文件。**
- `attachment.type`：含 `task_reminder`，其 `content[]` 每项 `{id,subject,description,activeForm,status,blocks,blockedBy}`。
- 工具 input 形状（实测）：`Edit{file_path,old_string,new_string,replace_all}`、`Write{file_path,content}`、`Bash{command,description,timeout?}`、`Read{file_path,offset?,limit?}`、`Agent{description,subagent_type,prompt}`、`TaskCreate{subject,description,activeForm}`、`TaskUpdate{taskId,status,…}`、`Skill{skill,args?}`。
- `timestamp`：ISO-8601 UTC 毫秒，如 `2026-06-10T18:58:32.421Z`。

---

## 文件结构

新增一个独立 SwiftPM 包，放在仓库的 `Packages/ClaudeTranscriptKit/`（与现有 Xcode 工程并存；后续在 Mac 上由 Xcode 以本地 package 形式引用，本机用 `swift test` 直接跑）。

```
Packages/ClaudeTranscriptKit/
├── Package.swift
├── Sources/ClaudeTranscriptKit/
│   ├── TranscriptEvent.swift        # 顶层事件枚举 + 解码入口（宽容）
│   ├── ContentBlock.swift           # assistant/user 的 content block 模型
│   ├── ToolUse.swift                # tool_use 名称 + 强类型 input 投影
│   ├── ToolResult.swift             # tool_result（content 多态）+ toolUseResult
│   ├── StructuredPatch.swift        # diff hunk 模型 + 行分类（+/-/ctx）
│   ├── TaskItem.swift               # task_reminder / TaskCreate-Update 任务项
│   ├── TranscriptStream.swift       # 多行 → [TranscriptEvent]，宽容跳过坏行
│   └── ConversationProjection.swift # 事件流 → 对话项 / 配对 tool_use↔result
└── Tests/ClaudeTranscriptKitTests/
    ├── Fixtures/                    # 从真实 jsonl 裁剪的最小样本（脱敏）
    ├── TranscriptEventTests.swift
    ├── ToolUseTests.swift
    ├── ToolResultTests.swift
    ├── StructuredPatchTests.swift
    ├── TaskItemTests.swift
    ├── TranscriptStreamTests.swift
    └── ConversationProjectionTests.swift
```

每个文件一个清晰职责；文件间通过值类型接口通信，可独立理解与测试。

---

## Task 1: 包脚手架 + 宽容解码入口

**Files:**
- Create: `Packages/ClaudeTranscriptKit/Package.swift`
- Create: `Packages/ClaudeTranscriptKit/Sources/ClaudeTranscriptKit/TranscriptEvent.swift`
- Test: `Packages/ClaudeTranscriptKit/Tests/ClaudeTranscriptKitTests/TranscriptEventTests.swift`

- [ ] **Step 1: 写 Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeTranscriptKit",
    products: [
        .library(name: "ClaudeTranscriptKit", targets: ["ClaudeTranscriptKit"]),
    ],
    targets: [
        .target(name: "ClaudeTranscriptKit"),
        .testTarget(
            name: "ClaudeTranscriptKitTests",
            dependencies: ["ClaudeTranscriptKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 2: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class TranscriptEventTests: XCTestCase {
    func testKnownTypeDecodesToCase() {
        let line = #"{"type":"assistant","uuid":"a1","parentUuid":"p0","timestamp":"2026-06-10T18:58:32.421Z","message":{"content":[]}}"#
        let ev = TranscriptEvent(jsonLine: line)
        guard case .assistant(let a) = ev else { return XCTFail("expected .assistant, got \(String(describing: ev))") }
        XCTAssertEqual(a.uuid, "a1")
        XCTAssertEqual(a.parentUuid, "p0")
    }

    func testUnknownTypeIsToleratedNotNil() {
        let line = #"{"type":"some-future-type","uuid":"x"}"#
        let ev = TranscriptEvent(jsonLine: line)
        guard case .unknown = ev else { return XCTFail("unknown type must map to .unknown") }
    }

    func testGarbageLineReturnsNil() {
        XCTAssertNil(TranscriptEvent(jsonLine: "not json at all"))
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter TranscriptEventTests`
Expected: FAIL（`TranscriptEvent` 未定义 / 无 `init(jsonLine:)`）

- [ ] **Step 4: 写最小实现**

```swift
import Foundation

/// 一条 transcript 行（一个 JSON 对象）解码后的强类型事件。
/// 宽容原则:未知 type → .unknown;非法 JSON → init 返回 nil。
public enum TranscriptEvent {
    case user(UserEvent)
    case assistant(AssistantEvent)
    case system(SystemEvent)
    case attachment(AttachmentEvent)
    case unknown(type: String?, raw: [String: Any])

    public init?(jsonLine: String) {
        guard let data = jsonLine.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        self.init(object: obj)
    }

    init(object obj: [String: Any]) {
        let type = obj["type"] as? String
        switch type {
        case "user":      self = .user(UserEvent(object: obj))
        case "assistant": self = .assistant(AssistantEvent(object: obj))
        case "system":    self = .system(SystemEvent(object: obj))
        case "attachment":self = .attachment(AttachmentEvent(object: obj))
        default:          self = .unknown(type: type, raw: obj)
        }
    }
}

/// 所有「消息类」事件共享的线程/时间元信息。
public struct EventMeta: Equatable {
    public let uuid: String?
    public let parentUuid: String?
    public let timestamp: String?
    init(object obj: [String: Any]) {
        uuid = obj["uuid"] as? String
        parentUuid = obj["parentUuid"] as? String
        timestamp = obj["timestamp"] as? String
    }
}

public struct AssistantEvent: Equatable {
    public let uuid: String?
    public let parentUuid: String?
    public let timestamp: String?
    // content blocks 在 Task 2 填充;此处先占位空数组
    init(object obj: [String: Any]) {
        let m = EventMeta(object: obj)
        uuid = m.uuid; parentUuid = m.parentUuid; timestamp = m.timestamp
    }
}

public struct UserEvent: Equatable {
    public let uuid: String?
    public let timestamp: String?
    init(object obj: [String: Any]) {
        let m = EventMeta(object: obj); uuid = m.uuid; timestamp = m.timestamp
    }
}

public struct SystemEvent: Equatable {
    public let subtype: String?
    init(object obj: [String: Any]) { subtype = obj["subtype"] as? String }
}

public struct AttachmentEvent: Equatable {
    public let attachmentType: String?
    init(object obj: [String: Any]) {
        attachmentType = (obj["attachment"] as? [String: Any])?["type"] as? String
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter TranscriptEventTests`
Expected: PASS（3 tests）

- [ ] **Step 6: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): tolerant TranscriptEvent decode entry point"
```

## Task 2: assistant content blocks（text / thinking / tool_use）

**Files:**
- Create: `Packages/ClaudeTranscriptKit/Sources/ClaudeTranscriptKit/ContentBlock.swift`
- Modify: `Packages/ClaudeTranscriptKit/Sources/ClaudeTranscriptKit/TranscriptEvent.swift`（给 `AssistantEvent` 加 `blocks`）
- Test: `Packages/ClaudeTranscriptKit/Tests/ClaudeTranscriptKitTests/ContentBlockTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class ContentBlockTests: XCTestCase {
    func testTextBlock() {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"text","text":"hello"}]}}"#
        guard case .assistant(let a) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertEqual(a.blocks, [.text("hello")])
    }

    func testThinkingBlockEmptyBodyButFlagged() {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"thinking","thinking":"","signature":"sig123"}]}}"#
        guard case .assistant(let a) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        // thinking 正文恒为空(加密),只标记存在
        XCTAssertEqual(a.blocks, [.thinking])
    }

    func testToolUseBlock() {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls","description":"list"}}]}}"#
        guard case .assistant(let a) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        guard case .toolUse(let tu) = a.blocks.first else { return XCTFail("expected tool_use") }
        XCTAssertEqual(tu.id, "t1")
        XCTAssertEqual(tu.name, "Bash")
    }

    func testUnknownBlockTolerated() {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"future_block"}]}}"#
        guard case .assistant(let a) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertEqual(a.blocks, [.unknown("future_block")])
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ContentBlockTests`
Expected: FAIL（`blocks` 不存在 / `ContentBlock` 未定义）

- [ ] **Step 3: 写 ContentBlock.swift**

```swift
import Foundation

/// assistant 消息里的一个 content block。
/// thinking 正文在磁盘上恒为空串,故不携带文本,只作存在标记。
public enum ContentBlock: Equatable {
    case text(String)
    case thinking
    case toolUse(ToolUse)
    case unknown(String)   // 未知 block 的 type 字符串

    init(object b: [String: Any]) {
        switch b["type"] as? String {
        case "text":     self = .text(b["text"] as? String ?? "")
        case "thinking": self = .thinking
        case "tool_use": self = .toolUse(ToolUse(object: b))
        case let other:  self = .unknown(other ?? "")
        }
    }

    /// 解析一个 content 值(可能是 [[String:Any]]),坏元素跳过。
    static func parseList(_ content: Any?) -> [ContentBlock] {
        guard let arr = content as? [[String: Any]] else { return [] }
        return arr.map { ContentBlock(object: $0) }
    }
}
```

- [ ] **Step 4: 修改 AssistantEvent 加 blocks**

把 `TranscriptEvent.swift` 中的 `AssistantEvent` 替换为：

```swift
public struct AssistantEvent: Equatable {
    public let uuid: String?
    public let parentUuid: String?
    public let timestamp: String?
    public let blocks: [ContentBlock]
    init(object obj: [String: Any]) {
        let m = EventMeta(object: obj)
        uuid = m.uuid; parentUuid = m.parentUuid; timestamp = m.timestamp
        let message = obj["message"] as? [String: Any]
        blocks = ContentBlock.parseList(message?["content"])
    }
}
```

注：`ToolUse` 在 Task 3 定义。为让本 Task 4 步先编译，**临时**在 ContentBlock.swift 末尾加一个占位：

```swift
// TEMP 占位,Task 3 会用完整定义替换本文件之外的 ToolUse.swift
public struct ToolUse: Equatable {
    public let id: String?
    public let name: String?
    init(object b: [String: Any]) {
        id = b["id"] as? String
        name = b["name"] as? String
    }
}
```

- [ ] **Step 5: 运行确认通过**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ContentBlockTests`
Expected: PASS（4 tests）

- [ ] **Step 6: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): parse assistant content blocks (text/thinking/tool_use)"
```

---

## Task 3: tool_use 强类型 input 投影

**Files:**
- Create: `Packages/ClaudeTranscriptKit/Sources/ClaudeTranscriptKit/ToolUse.swift`
- Modify: `ContentBlock.swift`（删掉 Task 2 的 TEMP 占位 `ToolUse`）
- Test: `Packages/ClaudeTranscriptKit/Tests/ClaudeTranscriptKitTests/ToolUseTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class ToolUseTests: XCTestCase {
    private func toolUse(_ json: String) -> ToolUse? {
        let line = #"{"type":"assistant","uuid":"a","message":{"content":[\#(json)]}}"#
        guard case .assistant(let a) = TranscriptEvent(jsonLine: line),
              case .toolUse(let tu) = a.blocks.first else { return nil }
        return tu
    }

    func testEditInput() {
        let tu = toolUse(#"{"type":"tool_use","id":"t","name":"Edit","input":{"file_path":"/a.swift","old_string":"foo","new_string":"bar","replace_all":false}}"#)
        guard case .edit(let e)? = tu?.input else { return XCTFail("expected .edit") }
        XCTAssertEqual(e.filePath, "/a.swift")
        XCTAssertEqual(e.oldString, "foo")
        XCTAssertEqual(e.newString, "bar")
        XCTAssertEqual(e.replaceAll, false)
    }

    func testBashInput() {
        let tu = toolUse(#"{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls -la","description":"list"}}"#)
        guard case .bash(let b)? = tu?.input else { return XCTFail("expected .bash") }
        XCTAssertEqual(b.command, "ls -la")
        XCTAssertEqual(b.description, "list")
    }

    func testWriteInput() {
        let tu = toolUse(#"{"type":"tool_use","id":"t","name":"Write","input":{"file_path":"/n.txt","content":"hi"}}"#)
        guard case .write(let w)? = tu?.input else { return XCTFail("expected .write") }
        XCTAssertEqual(w.filePath, "/n.txt")
        XCTAssertEqual(w.content, "hi")
    }

    func testUnknownToolKeepsNameAndRawInput() {
        let tu = toolUse(#"{"type":"tool_use","id":"t","name":"FutureTool","input":{"x":1}}"#)
        XCTAssertEqual(tu?.name, "FutureTool")
        guard case .other? = tu?.input else { return XCTFail("unknown tool → .other") }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ToolUseTests`
Expected: FAIL（`ToolUse.input` / `ToolInput` 未定义）

- [ ] **Step 3: 删除占位、写 ToolUse.swift**

先从 `ContentBlock.swift` 末尾删掉 Task 2 的 TEMP `struct ToolUse`。然后创建：

```swift
import Foundation

/// 一个 tool_use block:工具名 + 强类型 input 投影。
public struct ToolUse: Equatable {
    public let id: String?
    public let name: String?
    public let input: ToolInput?

    init(object b: [String: Any]) {
        id = b["id"] as? String
        let name = b["name"] as? String
        self.name = name
        input = ToolInput(name: name, raw: b["input"] as? [String: Any] ?? [:])
    }
}

/// 已知工具的强类型 input;未知工具归 .other(保留原始字典)。
public enum ToolInput: Equatable {
    case edit(Edit)
    case write(Write)
    case bash(Bash)
    case read(Read)
    case other

    public struct Edit: Equatable {
        public let filePath: String?, oldString: String?, newString: String?, replaceAll: Bool?
    }
    public struct Write: Equatable { public let filePath: String?, content: String? }
    public struct Bash: Equatable { public let command: String?, description: String? }
    public struct Read: Equatable { public let filePath: String?, offset: Int?, limit: Int? }

    init?(name: String?, raw r: [String: Any]) {
        switch name {
        case "Edit":
            self = .edit(.init(filePath: r["file_path"] as? String,
                               oldString: r["old_string"] as? String,
                               newString: r["new_string"] as? String,
                               replaceAll: r["replace_all"] as? Bool))
        case "Write":
            self = .write(.init(filePath: r["file_path"] as? String, content: r["content"] as? String))
        case "Bash":
            self = .bash(.init(command: r["command"] as? String, description: r["description"] as? String))
        case "Read":
            self = .read(.init(filePath: r["file_path"] as? String,
                               offset: r["offset"] as? Int, limit: r["limit"] as? Int))
        default:
            self = .other
        }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ToolUseTests`
Expected: PASS（4 tests）；同时跑全量 `swift test` 确认 Task 2 未回归。

- [ ] **Step 5: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): strongly-typed tool_use input projection"
```

## Task 4: tool_result（content 多态 + is_error 缺省）

**Files:**
- Create: `Sources/ClaudeTranscriptKit/ToolResult.swift`
- Modify: `TranscriptEvent.swift`（`UserEvent` 加 `toolResults` 与 `text`）
- Test: `Tests/ClaudeTranscriptKitTests/ToolResultTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class ToolResultTests: XCTestCase {
    func testStringContent() {
        let line = #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"done","is_error":false}]}}"#
        guard case .user(let u) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertEqual(u.toolResults.first?.toolUseId, "t1")
        XCTAssertEqual(u.toolResults.first?.text, "done")
        XCTAssertEqual(u.toolResults.first?.isError, false)
    }

    func testArrayContentFlattenedToText() {
        let line = #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}]}}"#
        guard case .user(let u) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertEqual(u.toolResults.first?.text, "line1\nline2")
        XCTAssertEqual(u.toolResults.first?.isError, false) // 缺省视为 false
    }

    func testPlainHumanPrompt() {
        let line = #"{"type":"user","uuid":"u","message":{"content":"hello there"}}"#
        guard case .user(let u) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertEqual(u.text, "hello there")
        XCTAssertTrue(u.toolResults.isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ToolResultTests`
Expected: FAIL（`toolResults` / `ToolResult` 未定义）

- [ ] **Step 3: 写 ToolResult.swift**

```swift
import Foundation

public struct ToolResult: Equatable {
    public let toolUseId: String?
    public let text: String       // string 或 [{text}] 数组都归一成纯文本
    public let isError: Bool      // 缺省 → false

    init(object b: [String: Any]) {
        toolUseId = b["tool_use_id"] as? String
        isError = b["is_error"] as? Bool ?? false
        if let s = b["content"] as? String {
            text = s
        } else if let arr = b["content"] as? [[String: Any]] {
            text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            text = ""
        }
    }
}
```

- [ ] **Step 4: 修改 UserEvent**

把 `TranscriptEvent.swift` 的 `UserEvent` 替换为：

```swift
public struct UserEvent: Equatable {
    public let uuid: String?
    public let timestamp: String?
    public let text: String?                 // 人类 prompt(content 为 string 时)
    public let toolResults: [ToolResult]     // content 为 tool_result 列表时
    init(object obj: [String: Any]) {
        let m = EventMeta(object: obj); uuid = m.uuid; timestamp = m.timestamp
        let content = (obj["message"] as? [String: Any])?["content"]
        if let s = content as? String {
            text = s; toolResults = []
        } else if let arr = content as? [[String: Any]] {
            text = nil
            toolResults = arr.filter { $0["type"] as? String == "tool_result" }
                             .map { ToolResult(object: $0) }
        } else {
            text = nil; toolResults = []
        }
    }
}
```

- [ ] **Step 5: 运行确认通过 + 全量回归**

Run: `cd Packages/ClaudeTranscriptKit && swift test`
Expected: 全绿（含前序 Task）

- [ ] **Step 6: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): tool_result with polymorphic content + default is_error"
```

---

## Task 5: structuredPatch → diff hunk 模型

**Files:**
- Create: `Sources/ClaudeTranscriptKit/StructuredPatch.swift`
- Modify: `TranscriptEvent.swift`（`UserEvent` 加 `structuredPatch`，从 `toolUseResult` 取）
- Test: `Tests/ClaudeTranscriptKitTests/StructuredPatchTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class StructuredPatchTests: XCTestCase {
    func testHunkLinesClassified() {
        let line = #"{"type":"user","uuid":"u","toolUseResult":{"structuredPatch":[{"oldStart":1,"oldLines":2,"newStart":1,"newLines":2,"lines":[" ctx","-gone","+added"]}]},"message":{"content":[]}}"#
        guard case .user(let u) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        let hunk = u.structuredPatch.first!
        XCTAssertEqual(hunk.oldStart, 1)
        XCTAssertEqual(hunk.newLines, 2)
        XCTAssertEqual(hunk.lines, [.context(" ctx"), .removed("gone"), .added("added")])
    }

    func testNoPatchIsEmpty() {
        let line = #"{"type":"user","uuid":"u","message":{"content":[]}}"#
        guard case .user(let u) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertTrue(u.structuredPatch.isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter StructuredPatchTests`
Expected: FAIL（`structuredPatch` / `DiffHunk` 未定义）

- [ ] **Step 3: 写 StructuredPatch.swift**

```swift
import Foundation

public struct DiffHunk: Equatable {
    public let oldStart: Int, oldLines: Int, newStart: Int, newLines: Int
    public let lines: [DiffLine]
}

/// 一条 diff 行,按首字符分类(去掉前缀字符,保留内容)。
public enum DiffLine: Equatable {
    case context(String)   // " " 前缀
    case added(String)     // "+" 前缀
    case removed(String)   // "-" 前缀

    init(raw: String) {
        guard let first = raw.first else { self = .context(""); return }
        let body = String(raw.dropFirst())
        switch first {
        case "+": self = .added(body)
        case "-": self = .removed(body)
        default:  self = .context(raw)   // 保留 context 原样(含前导空格)
        }
    }
}

enum StructuredPatch {
    static func parse(_ tur: Any?) -> [DiffHunk] {
        guard let dict = tur as? [String: Any],
              let arr = dict["structuredPatch"] as? [[String: Any]] else { return [] }
        return arr.map { h in
            DiffHunk(
                oldStart: h["oldStart"] as? Int ?? 0,
                oldLines: h["oldLines"] as? Int ?? 0,
                newStart: h["newStart"] as? Int ?? 0,
                newLines: h["newLines"] as? Int ?? 0,
                lines: (h["lines"] as? [String] ?? []).map { DiffLine(raw: $0) }
            )
        }
    }
}
```

注：测试里 `.context(" ctx")` 与 `.removed("gone")` 的期望——context 保留原始串、removed/added 去掉首字符,与 `DiffLine.init` 一致。

- [ ] **Step 4: 给 UserEvent 加 structuredPatch**

在 `UserEvent` 的 `init` 末尾(属性声明里）加：

```swift
    public let structuredPatch: [DiffHunk]
    // ...在 init 内:
    structuredPatch = StructuredPatch.parse(obj["toolUseResult"])
```

- [ ] **Step 5: 运行确认通过 + 全量回归**

Run: `cd Packages/ClaudeTranscriptKit && swift test`
Expected: 全绿

- [ ] **Step 6: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): reconstruct diff hunks from structuredPatch"
```

---

## Task 6: task_reminder → 任务清单项

**Files:**
- Create: `Sources/ClaudeTranscriptKit/TaskItem.swift`
- Modify: `TranscriptEvent.swift`（`AttachmentEvent` 加 `taskItems`）
- Test: `Tests/ClaudeTranscriptKitTests/TaskItemTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class TaskItemTests: XCTestCase {
    func testTaskReminderParsed() {
        let line = #"{"type":"attachment","uuid":"x","attachment":{"type":"task_reminder","content":[{"id":"1","subject":"Do X","description":"d","activeForm":"Doing X","status":"in_progress","blocks":["2"],"blockedBy":[]}]}}"#
        guard case .attachment(let at) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        let t = at.taskItems.first!
        XCTAssertEqual(t.id, "1")
        XCTAssertEqual(t.subject, "Do X")
        XCTAssertEqual(t.status, .inProgress)
        XCTAssertEqual(t.blocks, ["2"])
    }

    func testNonTaskAttachmentEmpty() {
        let line = #"{"type":"attachment","uuid":"x","attachment":{"type":"date_change","newDate":"2026-06-13"}}"#
        guard case .attachment(let at) = TranscriptEvent(jsonLine: line) else { return XCTFail() }
        XCTAssertTrue(at.taskItems.isEmpty)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter TaskItemTests`
Expected: FAIL

- [ ] **Step 3: 写 TaskItem.swift**

```swift
import Foundation

public struct TaskItem: Equatable {
    public enum Status: String { case pending, inProgress = "in_progress", completed, deleted, unknown }
    public let id: String?
    public let subject: String?
    public let description: String?
    public let activeForm: String?
    public let status: Status
    public let blocks: [String]
    public let blockedBy: [String]

    init(object o: [String: Any]) {
        id = o["id"] as? String
        subject = o["subject"] as? String
        description = o["description"] as? String
        activeForm = o["activeForm"] as? String
        status = Status(rawValue: (o["status"] as? String) ?? "") ?? .unknown
        blocks = o["blocks"] as? [String] ?? []
        blockedBy = o["blockedBy"] as? [String] ?? []
    }

    static func parse(attachment a: [String: Any]) -> [TaskItem] {
        guard a["type"] as? String == "task_reminder",
              let arr = a["content"] as? [[String: Any]] else { return [] }
        return arr.map { TaskItem(object: $0) }
    }
}
```

- [ ] **Step 4: 给 AttachmentEvent 加 taskItems**

把 `AttachmentEvent` 替换为：

```swift
public struct AttachmentEvent: Equatable {
    public let attachmentType: String?
    public let taskItems: [TaskItem]
    init(object obj: [String: Any]) {
        let a = obj["attachment"] as? [String: Any] ?? [:]
        attachmentType = a["type"] as? String
        taskItems = TaskItem.parse(attachment: a)
    }
}
```

（`TaskItem.Status` 需 `Equatable`：`enum Status: String, Equatable`。）

- [ ] **Step 5: 运行确认通过 + 回归**

Run: `cd Packages/ClaudeTranscriptKit && swift test`
Expected: 全绿

- [ ] **Step 6: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): extract task list from task_reminder attachments"
```

---

## Task 7: 多行流解析（宽容跳过坏行）

**Files:**
- Create: `Sources/ClaudeTranscriptKit/TranscriptStream.swift`
- Test: `Tests/ClaudeTranscriptKitTests/TranscriptStreamTests.swift` + `Fixtures/sample.jsonl`

- [ ] **Step 1: 造 fixture**

`Tests/ClaudeTranscriptKitTests/Fixtures/sample.jsonl`（脱敏最小样本，3 行 + 1 空行 + 1 坏行）：

```
{"type":"user","uuid":"u1","message":{"content":"hi"}}

not-json-garbage
{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"hello"}]}}
{"type":"future","uuid":"z1"}
```

- [ ] **Step 2: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class TranscriptStreamTests: XCTestCase {
    func testParsesGoodLinesSkipsBad() {
        let url = Bundle.module.url(forResource: "sample", withExtension: "jsonl", subdirectory: "Fixtures")!
        let text = try! String(contentsOf: url, encoding: .utf8)
        let events = TranscriptStream.parse(text: text)
        // 4 个有效 JSON 行(空行+garbage 跳过),含 1 个 .unknown
        XCTAssertEqual(events.count, 3)
        if case .user = events[0] {} else { XCTFail("0 should be user") }
        if case .assistant = events[1] {} else { XCTFail("1 should be assistant") }
        if case .unknown = events[2] {} else { XCTFail("2 should be unknown") }
    }
}
```

- [ ] **Step 3: 写 TranscriptStream.swift**

```swift
import Foundation

public enum TranscriptStream {
    /// 把整段 transcript 文本(多行)解析成事件序列。
    /// 空行与非法 JSON 行被静默跳过(宽容原则)。
    public static func parse(text: String) -> [TranscriptEvent] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { TranscriptEvent(jsonLine: String($0)) }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter TranscriptStreamTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): tolerant multi-line stream parser"
```

---

## Task 8: 对话投影（配对 tool_use ↔ tool_result）

**Files:**
- Create: `Sources/ClaudeTranscriptKit/ConversationProjection.swift`
- Test: `Tests/ClaudeTranscriptKitTests/ConversationProjectionTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import XCTest
@testable import ClaudeTranscriptKit

final class ConversationProjectionTests: XCTestCase {
    func testToolUsePairedWithResult() {
        let lines = [
            #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","uuid":"u","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"out","is_error":false}]}}"#,
        ].joined(separator: "\n")
        let proj = ConversationProjection(events: TranscriptStream.parse(text: lines))
        XCTAssertEqual(proj.resultText(forToolUseId: "t1"), "out")
        XCTAssertEqual(proj.isError(forToolUseId: "t1"), false)
    }

    func testMissingResultReturnsNil() {
        let lines = #"{"type":"assistant","uuid":"a","message":{"content":[{"type":"tool_use","id":"t9","name":"Bash","input":{}}]}}"#
        let proj = ConversationProjection(events: TranscriptStream.parse(text: lines))
        XCTAssertNil(proj.resultText(forToolUseId: "t9"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd Packages/ClaudeTranscriptKit && swift test --filter ConversationProjectionTests`
Expected: FAIL

- [ ] **Step 3: 写 ConversationProjection.swift**

```swift
import Foundation

/// 把事件流投影成便于渲染的查询结构:按 tool_use_id 索引结果。
public struct ConversationProjection {
    public let events: [TranscriptEvent]
    private let resultsById: [String: ToolResult]

    public init(events: [TranscriptEvent]) {
        self.events = events
        var map: [String: ToolResult] = [:]
        for e in events {
            if case .user(let u) = e {
                for r in u.toolResults { if let id = r.toolUseId { map[id] = r } }
            }
        }
        resultsById = map
    }

    public func resultText(forToolUseId id: String) -> String? { resultsById[id]?.text }
    public func isError(forToolUseId id: String) -> Bool? { resultsById[id]?.isError }
}
```

- [ ] **Step 4: 运行确认通过 + 全量回归**

Run: `cd Packages/ClaudeTranscriptKit && swift test`
Expected: 全绿（8 个 Task 的所有测试）

- [ ] **Step 5: 提交**

```bash
git add Packages/ClaudeTranscriptKit
git commit -m "feat(transcript): conversation projection pairing tool_use with results"
```

---

## Self-Review（计划自审结论）

**Spec 覆盖：** 本计划只实现 spec「第一刀」里的 Domain 解析层（事件 taxonomy、tool input、diff、todo、subagent 关联的基础查询）。**显式不覆盖**（留 Mac/后续阶段）：TranscriptObserver（SSH tail）、ClaudeNativeView（SwiftUI）、`--session-id` 启动注入、`.claude` tab、控制通道。这与 AskUserQuestion 决定一致。

**subagent join 说明：** Task 8 提供按 id 的结果配对，是 subagent 关联的基础。完整的 `subagents/agent-<id>.jsonl` 跨文件 join 依赖文件系统读取（非纯字符串），归入后续 Observer 阶段；本包只做单文件内的事件投影，保持零 IO、可纯测。

**占位扫描：** 无 TBD/TODO。Task 2 的 `ToolUse` TEMP 占位在 Task 3 Step 3 明确删除并替换——这是有意的编译过渡，非遗留占位。

**类型一致性：** `ToolUse`（Task 2 占位 → Task 3 完整）、`ToolResult`（Task 4）、`DiffHunk`/`DiffLine`（Task 5）、`TaskItem`（Task 6）命名跨 Task 一致；`UserEvent` 在 Task 1/4/5 逐步加字段，每次给出完整替换体。

**宽容性贯穿：** 未知 type→`.unknown`、未知 block→`.unknown(String)`、未知工具→`.other`、坏行→跳过、缺省 is_error→false，与 spec 风险表「解析器宽容化」一致。

---

## Execution Handoff

计划已存于 `docs/superpowers/plans/2026-06-13-claude-transcript-domain.md`，两种执行方式：

1. **Subagent-Driven（推荐）** — 每个 Task 派新 subagent，Task 间我审查，快速迭代。
2. **Inline Execution** — 本会话内分批执行，带检查点。

因为本包能在这台机器上真 `swift test`，两种都可全程验证到绿。


