import Foundation
import SwiftUI

nonisolated struct ServerEnvironment: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var shortName: String
    var colorHex: String
    var isBuiltIn: Bool

    init(
        id: UUID = UUID(),
        name: String,
        shortName: String,
        colorHex: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.colorHex = colorHex
        self.isBuiltIn = isBuiltIn
    }

    var color: Color {
        Color.fromHex(colorHex)
    }

    var displayName: String {
        guard isBuiltIn else { return name }
        switch id {
        case ServerEnvironment.production.id:
            return String(localized: "Production")
        case ServerEnvironment.staging.id:
            return String(localized: "Staging")
        case ServerEnvironment.development.id:
            return String(localized: "Development")
        default:
            return name
        }
    }

    var displayShortName: String {
        guard isBuiltIn else { return shortName }
        switch id {
        case ServerEnvironment.production.id:
            return String(localized: "Prod")
        case ServerEnvironment.staging.id:
            return String(localized: "Stag")
        case ServerEnvironment.development.id:
            return String(localized: "Dev")
        default:
            return shortName
        }
    }

    static let production = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Production",
        shortName: "Prod",
        colorHex: "#34C759",
        isBuiltIn: true
    )

    static let staging = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "Staging",
        shortName: "Stag",
        colorHex: "#FF9500",
        isBuiltIn: true
    )

    static let development = ServerEnvironment(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Development",
        shortName: "Dev",
        colorHex: "#007AFF",
        isBuiltIn: true
    )

    static let builtInEnvironments: [ServerEnvironment] = [.production, .staging, .development]
}
