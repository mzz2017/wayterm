import Foundation

enum TerminalAccessoryItemRef: Codable, Hashable {
    case system(TerminalAccessorySystemActionID)
    case custom(UUID)

    private enum CodingKeys: String, CodingKey {
        case kind
        case systemID
        case customActionID
        case snippetID
    }

    private enum Kind: String, Codable {
        case system
        case custom
        case snippet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)

        switch kind {
        case .system:
            let id = try container.decode(TerminalAccessorySystemActionID.self, forKey: .systemID)
            self = .system(id)
        case .custom:
            let id = try container.decode(UUID.self, forKey: .customActionID)
            self = .custom(id)
        case .snippet:
            let id = try container.decode(UUID.self, forKey: .snippetID)
            self = .custom(id)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .system(let id):
            try container.encode(Kind.system, forKey: .kind)
            try container.encode(id, forKey: .systemID)
        case .custom(let id):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(id, forKey: .customActionID)
        }
    }
}

struct TerminalAccessoryCustomAction: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var kind: TerminalAccessoryCustomActionKind
    var commandContent: String
    var commandSendMode: TerminalSnippetSendMode
    var shortcutKey: TerminalAccessoryShortcutKey
    var shortcutModifiers: TerminalAccessoryShortcutModifiers
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        kind: TerminalAccessoryCustomActionKind,
        commandContent: String = "",
        commandSendMode: TerminalSnippetSendMode = .insert,
        shortcutKey: TerminalAccessoryShortcutKey = .a,
        shortcutModifiers: TerminalAccessoryShortcutModifiers = .none,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.commandContent = commandContent
        self.commandSendMode = commandSendMode
        self.shortcutKey = shortcutKey
        self.shortcutModifiers = shortcutModifiers
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }

    var detailText: String {
        switch kind {
        case .command:
            return commandSendMode.title
        case .shortcut:
            return shortcutModifiers.displayTitle(for: shortcutKey.title)
        }
    }
}

struct TerminalSnippet: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var sendMode: TerminalSnippetSendMode
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        sendMode: TerminalSnippetSendMode,
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.sendMode = sendMode
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    var isDeleted: Bool {
        deletedAt != nil
    }
}

struct TerminalAccessoryLayout: Codable, Equatable {
    var version: Int
    var activeItems: [TerminalAccessoryItemRef]
    var updatedAt: Date
}

struct TerminalAccessoryProfile: Codable, Equatable {
    var schemaVersion: Int
    var layout: TerminalAccessoryLayout
    var customActions: [TerminalAccessoryCustomAction]
    var updatedAt: Date
    var lastWriterDeviceId: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case layout
        case customActions
        case snippets
        case updatedAt
        case lastWriterDeviceId
    }

    init(
        schemaVersion: Int,
        layout: TerminalAccessoryLayout,
        customActions: [TerminalAccessoryCustomAction],
        updatedAt: Date,
        lastWriterDeviceId: String
    ) {
        self.schemaVersion = schemaVersion
        self.layout = layout
        self.customActions = customActions
        self.updatedAt = updatedAt
        self.lastWriterDeviceId = lastWriterDeviceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        layout = try container.decodeIfPresent(TerminalAccessoryLayout.self, forKey: .layout)
            ?? TerminalAccessoryLayout(version: 1, activeItems: Self.defaultActiveItems, updatedAt: .distantPast)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        lastWriterDeviceId = try container.decodeIfPresent(String.self, forKey: .lastWriterDeviceId) ?? DeviceIdentity.id

        if let actions = try container.decodeIfPresent([TerminalAccessoryCustomAction].self, forKey: .customActions) {
            customActions = actions
        } else {
            let legacySnippets = try container.decodeIfPresent([TerminalSnippet].self, forKey: .snippets) ?? []
            customActions = legacySnippets.map(\.asCustomAction)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(layout, forKey: .layout)
        try container.encode(customActions, forKey: .customActions)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastWriterDeviceId, forKey: .lastWriterDeviceId)
    }
}

extension TerminalAccessoryProfile {
    static let schemaVersion = 2
    static let recordType = "UserPreference"
    static let recordName = "terminalAccessory.v1"
    static let defaultsKey = CloudKitSyncConstants.terminalAccessoryProfileStorageKey

    static let minActiveItems = 4
    static let maxActiveItems = 28
    static let maxCustomActions = 100
    static let maxCustomActionTitleLength = 24
    static let maxCommandContentLength = 2048

    static let defaultActiveItems: [TerminalAccessoryItemRef] = [
        .system(.escape),
        .system(.tab),
        .system(.arrowUp),
        .system(.arrowDown),
        .system(.arrowLeft),
        .system(.arrowRight),
        .system(.backspace),
        .system(.ctrlC),
        .system(.ctrlD),
        .system(.ctrlZ),
        .system(.ctrlL),
        .system(.home),
        .system(.end),
        .system(.pageUp),
        .system(.pageDown)
    ]

    static var defaultValue: TerminalAccessoryProfile {
        TerminalAccessoryProfile(
            schemaVersion: schemaVersion,
            layout: TerminalAccessoryLayout(
                version: 1,
                activeItems: defaultActiveItems,
                updatedAt: .distantPast
            ),
            customActions: [],
            updatedAt: .distantPast,
            lastWriterDeviceId: DeviceIdentity.id
        )
    }

    static var availableSystemActions: [TerminalAccessorySystemActionID] {
        TerminalAccessorySystemActionID.allCases.filter { $0 != .unknown }
    }

    func normalized() -> TerminalAccessoryProfile {
        var customActionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in customActions {
            let normalizedAction = action.normalized()
            if let existing = customActionsByID[normalizedAction.id] {
                if normalizedAction.updatedAt > existing.updatedAt {
                    customActionsByID[normalizedAction.id] = normalizedAction
                }
            } else {
                customActionsByID[normalizedAction.id] = normalizedAction
            }
        }

        let normalizedActions = customActionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let limitedActiveActionIDs = Set(
            normalizedActions
                .filter { !$0.isDeleted }
                .prefix(Self.maxCustomActions)
                .map(\.id)
        )

        let normalizedAndLimitedActions = normalizedActions.filter {
            $0.isDeleted || limitedActiveActionIDs.contains($0.id)
        }

        let activeActionIDs = Set(normalizedAndLimitedActions.filter { !$0.isDeleted }.map(\.id))

        var seenItems = Set<TerminalAccessoryItemRef>()
        var normalizedItems: [TerminalAccessoryItemRef] = []

        for item in layout.activeItems {
            switch item {
            case .system(let actionID):
                guard actionID != .unknown else { continue }
            case .custom(let actionID):
                guard activeActionIDs.contains(actionID) else { continue }
            }

            guard !seenItems.contains(item) else { continue }
            seenItems.insert(item)
            normalizedItems.append(item)
        }

        if normalizedItems.count > Self.maxActiveItems {
            normalizedItems = Array(normalizedItems.prefix(Self.maxActiveItems))
        }

        if normalizedItems.count < Self.minActiveItems {
            normalizedItems = Self.defaultActiveItems
        }

        return TerminalAccessoryProfile(
            schemaVersion: max(Self.schemaVersion, schemaVersion),
            layout: TerminalAccessoryLayout(
                version: max(1, layout.version),
                activeItems: normalizedItems,
                updatedAt: layout.updatedAt
            ),
            customActions: Array(normalizedAndLimitedActions),
            updatedAt: updatedAt,
            lastWriterDeviceId: lastWriterDeviceId.isEmpty ? DeviceIdentity.id : lastWriterDeviceId
        )
    }

    static func merged(local: TerminalAccessoryProfile, remote: TerminalAccessoryProfile) -> TerminalAccessoryProfile {
        let normalizedLocal = local.normalized()
        let normalizedRemote = remote.normalized()

        let mergedLayout: TerminalAccessoryLayout
        if normalizedLocal.layout.updatedAt >= normalizedRemote.layout.updatedAt {
            mergedLayout = normalizedLocal.layout
        } else {
            mergedLayout = normalizedRemote.layout
        }

        var actionsByID: [UUID: TerminalAccessoryCustomAction] = [:]
        for action in normalizedRemote.customActions {
            actionsByID[action.id] = action
        }

        for action in normalizedLocal.customActions {
            if let existing = actionsByID[action.id] {
                if action.updatedAt >= existing.updatedAt {
                    actionsByID[action.id] = action
                }
            } else {
                actionsByID[action.id] = action
            }
        }

        let mergedActions = actionsByID.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        let mergedUpdatedAt = max(
            normalizedLocal.updatedAt,
            normalizedRemote.updatedAt,
            mergedLayout.updatedAt,
            mergedActions.first?.updatedAt ?? .distantPast
        )

        let writerDeviceID: String
        if mergedUpdatedAt == normalizedLocal.updatedAt {
            writerDeviceID = normalizedLocal.lastWriterDeviceId
        } else if mergedUpdatedAt == normalizedRemote.updatedAt {
            writerDeviceID = normalizedRemote.lastWriterDeviceId
        } else if mergedLayout.updatedAt == normalizedLocal.layout.updatedAt {
            writerDeviceID = normalizedLocal.lastWriterDeviceId
        } else {
            writerDeviceID = normalizedRemote.lastWriterDeviceId
        }

        return TerminalAccessoryProfile(
            schemaVersion: max(normalizedLocal.schemaVersion, normalizedRemote.schemaVersion, Self.schemaVersion),
            layout: mergedLayout,
            customActions: Array(mergedActions),
            updatedAt: mergedUpdatedAt,
            lastWriterDeviceId: writerDeviceID
        )
        .normalized()
    }
}

private extension TerminalAccessoryCustomAction {
    func normalized() -> TerminalAccessoryCustomAction {
        let sanitizedTitle: String
        let sanitizedCommandContent: String

        if isDeleted {
            sanitizedTitle = ""
            sanitizedCommandContent = ""
        } else {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            sanitizedTitle = String(trimmedTitle.prefix(TerminalAccessoryProfile.maxCustomActionTitleLength))
            if kind == .command {
                sanitizedCommandContent = String(commandContent.prefix(TerminalAccessoryProfile.maxCommandContentLength))
            } else {
                sanitizedCommandContent = ""
            }
        }

        return TerminalAccessoryCustomAction(
            id: id,
            title: sanitizedTitle,
            kind: kind,
            commandContent: sanitizedCommandContent,
            commandSendMode: commandSendMode,
            shortcutKey: shortcutKey,
            shortcutModifiers: shortcutModifiers,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}

private extension TerminalSnippet {
    var asCustomAction: TerminalAccessoryCustomAction {
        TerminalAccessoryCustomAction(
            id: id,
            title: title,
            kind: .command,
            commandContent: content,
            commandSendMode: sendMode,
            shortcutKey: .a,
            shortcutModifiers: .none,
            updatedAt: updatedAt,
            deletedAt: deletedAt
        )
    }
}
