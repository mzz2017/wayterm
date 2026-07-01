import Foundation

protocol BiometricAuthServing {
    func availability() -> BiometricAvailability
    func authenticate(localizedReason: String, allowPasscodeFallback: Bool) async throws
    func cancelAuthentication()
}
