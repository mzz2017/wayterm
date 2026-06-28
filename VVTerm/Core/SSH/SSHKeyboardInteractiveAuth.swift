//
//  SSHKeyboardInteractiveAuth.swift
//  VVTerm
//
//  libssh2 keyboard-interactive authentication callback support.
//

import Darwin
import Foundation

/// Per-session storage for keyboard-interactive password used by the C callback.
/// This avoids cross-session password races when multiple auth flows run concurrently.
final class KeyboardInteractiveContext: @unchecked Sendable {
    private nonisolated(unsafe) var _password: String?
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func setPassword(_ password: String?) {
        lock.lock()
        defer { lock.unlock() }
        _password = password
    }

    nonisolated func password() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return _password
    }
}

nonisolated func keyboardInteractivePassword(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> String? {
    guard let abstract, let contextPointer = abstract.pointee else { return nil }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    return context.password()
}

nonisolated func keyboardInteractiveCallback(
    _ name: UnsafePointer<CChar>?,
    _ nameLength: Int32,
    _ instruction: UnsafePointer<CChar>?,
    _ instructionLength: Int32,
    _ promptCount: Int32,
    _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
    _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) {
    KeyboardInteractiveCallbackOwner.respond(
        name,
        nameLength,
        instruction,
        instructionLength,
        promptCount,
        prompts,
        responses,
        abstract
    )
}

enum KeyboardInteractiveCallbackOwner {
    nonisolated static func respond(
        _ name: UnsafePointer<CChar>?,
        _ nameLength: Int32,
        _ instruction: UnsafePointer<CChar>?,
        _ instructionLength: Int32,
        _ promptCount: Int32,
        _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,
        _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
        _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    ) {
        guard promptCount > 0, let responses, let password = keyboardInteractivePassword(from: abstract) else {
            return
        }

        for index in 0..<Int(promptCount) {
            let passwordData = Array(password.utf8CString)
            let length = passwordData.count - 1
            guard let rawBuffer = Darwin.malloc(passwordData.count) else { continue }
            let responseBuffer = rawBuffer.assumingMemoryBound(to: CChar.self)
            passwordData.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                responseBuffer.initialize(from: baseAddress, count: passwordData.count)
            }

            responses[index].text = responseBuffer
            responses[index].length = UInt32(length)
        }
    }
}
