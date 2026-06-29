import Foundation

// AVAudioEngine tap callbacks are synchronous and may arrive off the main
// actor. This registry lets AudioCaptureService own and await the main-actor
// buffer updates that were queued by those callbacks before stop/cancel returns.
nonisolated final class AudioBufferUpdateTaskRegistry: @unchecked Sendable {
    private let registry = AsyncCallbackTaskRegistry()

    @discardableResult
    func track(_ operation: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        registry.trackMainActor(operation)
    }

    func tasks() -> [Task<Void, Never>] {
        registry.tasks()
    }

    func waitForAll() async {
        await registry.waitForAll()
    }
}
