//
//  SSHKeyboardInteractiveAuth.swift
//  VVTerm
//
//  libssh2 keyboard-interactive authentication callback support.
//

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

func keyboardInteractivePassword(
    from abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> String? {
    guard let abstract, let contextPointer = abstract.pointee else { return nil }
    let context = Unmanaged<KeyboardInteractiveContext>.fromOpaque(contextPointer).takeUnretainedValue()
    return context.password()
}

nonisolated(unsafe) let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?,  // name
    Int32,                   // name_len
    UnsafePointer<CChar>?,  // instruction
    Int32,                   // instruction_len
    Int32,                   // num_prompts
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?,  // prompts
    UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,  // responses
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?  // abstract
) -> Void = { name, nameLen, instruction, instructionLen, numPrompts, prompts, responses, abstract in
    guard numPrompts > 0, let responses, let password = keyboardInteractivePassword(from: abstract) else {
        return
    }

    for index in 0..<Int(numPrompts) {
        let passwordData = password.utf8CString
        let length = passwordData.count - 1

        let responseBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
        passwordData.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            responseBuffer.initialize(from: baseAddress, count: length)
        }
        responseBuffer[length] = 0

        responses[index].text = responseBuffer
        responses[index].length = UInt32(length)
    }
}
