import Foundation

enum ServerFormValidationPolicy {
    static func isValid(draft: ServerFormDraft) -> Bool {
        !draft.name.isEmpty
            && !draft.host.isEmpty
            && ServerPortValidator.normalizedPort(from: draft.port) != nil
            && hasValidCredentials(draft: draft)
    }

    static func hasValidCredentials(draft: ServerFormDraft) -> Bool {
        guard draft.connectionMode != .tailscale else {
            return true
        }

        if draft.connectionMode == .cloudflare {
            switch draft.cloudflareAccessMode {
            case .oauth:
                break
            case .serviceToken:
                guard isPresent(draft.cloudflareClientID),
                      isPresent(draft.cloudflareClientSecret) else {
                    return false
                }
            }
        }

        switch draft.authMethod {
        case .password:
            return !draft.password.isEmpty
        case .sshKey:
            return !draft.sshKey.isEmpty
        case .sshKeyWithPassphrase:
            return !draft.sshKey.isEmpty && !draft.sshPassphrase.isEmpty
        }
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
