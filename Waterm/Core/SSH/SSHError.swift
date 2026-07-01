//
//  SSHError.swift
//  Waterm
//
//  Shared SSH error model and retry policy.
//

import Foundation

enum SSHError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authenticationFailed
    case tailscaleAuthenticationNotAccepted
    case cloudflareConfigurationRequired(String)
    case cloudflareAuthenticationFailed(String)
    case cloudflareTunnelFailed(String)
    case moshServerMissing
    case moshBootstrapFailed(String)
    case moshSessionFailed(String)
    case timeout
    case channelOpenFailed
    case shellRequestFailed
    case hostKeyVerificationFailed
    case socketError(String)
    case libssh2(LibSSH2RawError)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .authenticationFailed: return "Authentication failed"
        case .tailscaleAuthenticationNotAccepted:
            return "\(String(localized: "Tailscale SSH authentication was not accepted by the server.")) \(String(localized: "This app currently supports direct tailnet connections only (no userspace proxy fallback)."))"
        case .cloudflareConfigurationRequired(let message):
            return String(format: String(localized: "Cloudflare configuration error: %@"), message)
        case .cloudflareAuthenticationFailed(let message):
            return String(format: String(localized: "Cloudflare authentication failed: %@"), message)
        case .cloudflareTunnelFailed(let message):
            return String(format: String(localized: "Cloudflare tunnel failed: %@"), message)
        case .moshServerMissing:
            return String(localized: "mosh-server is not installed on the remote host")
        case .moshBootstrapFailed(let msg):
            return "Mosh bootstrap failed: \(msg)"
        case .moshSessionFailed(let msg):
            return "Mosh session failed: \(msg)"
        case .timeout: return "Connection timed out"
        case .channelOpenFailed: return "Failed to open channel"
        case .shellRequestFailed: return "Failed to request shell"
        case .hostKeyVerificationFailed:
            return "Host key verification failed. Trust this host key only if you recognize the server."
        case .socketError(let msg): return "Socket error: \(msg)"
        case .libssh2(let error):
            let detail = error.message ?? "code \(error.code)"
            return "libssh2 \(error.operation.rawValue) failed: \(detail)"
        case .unknown(let msg): return "Unknown error: \(msg)"
        }
    }

    /// Whether a connection attempt that failed with this error should be retried.
    /// Auth/host-key/tailscale failures are deterministic - retrying only piles up
    /// failed-auth events and triggers sshd penalty boxing.
    var isRetryable: Bool {
        switch self {
        case .authenticationFailed,
             .hostKeyVerificationFailed,
             .tailscaleAuthenticationNotAccepted:
            return false
        default:
            return true
        }
    }
}
