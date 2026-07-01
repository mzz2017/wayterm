import Foundation

enum BiometryKind: Equatable {
    case none
    case touchID
    case faceID

    var displayName: String {
        switch self {
        case .none:
            return String(localized: "Biometric Authentication")
        case .touchID:
            return String(localized: "Touch ID")
        case .faceID:
            return String(localized: "Face ID")
        }
    }
}

enum BiometricAvailability: Equatable {
    case available(BiometryKind)
    case unavailable(String)
}

enum BiometricAuthError: LocalizedError {
    case cancelled
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .unavailable(let message):
            return message
        case .failed(let message):
            return message
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self {
            return true
        }
        return false
    }
}
