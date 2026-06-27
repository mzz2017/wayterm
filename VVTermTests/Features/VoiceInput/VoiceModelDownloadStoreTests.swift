import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect VoiceInput model download lifecycle ownership. Settings UI
// may send download/cancel/model-selection intent, but an application-layer store
// must own and track the download tasks so view recreation cannot drop critical
// URLSession-backed work. Fakes record ordering and cancellation only; they do
// not perform network, filesystem, MLX, or Hugging Face operations. Update this
// context only when voice model download ownership intentionally moves to a
// different application-layer owner or the download/cancel intent contract
// changes.
@Suite(.serialized)
@MainActor
struct VoiceModelDownloadStoreTests {
    @Test
    func modelManagersUseInjectedSettingsSnapshot() {
        // Given a settings snapshot with non-default model identities.
        let store = VoiceModelDownloadStore(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: .mlxWhisper,
                    whisperModelId: "test/custom-whisper",
                    parakeetModelId: "test/custom-parakeet",
                    languageCode: "en"
                )
            }
        )

        // Then model managers are configured from injected settings, not globals.
        #expect(
            store.whisperManager.modelId == "test/custom-whisper",
            "Whisper model manager should use the injected settings snapshot."
        )
        #expect(
            store.parakeetManager.modelId == "test/custom-parakeet",
            "Parakeet model manager should use the injected settings snapshot."
        )
    }

    @Test
    func duplicateDownloadIntentSharesTrackedTask() async {
        // Given a voice model download has started and is still running.
        let probe = VoiceModelDownloadProbe()
        let releaseDownload = VoiceModelDownloadGate()
        let store = VoiceModelDownloadStore.makeForTesting(
            downloadAction: { kind in
                await probe.record("download-start:\(kind.rawValue)")
                await releaseDownload.wait()
                await probe.record("download-end:\(kind.rawValue)")
            }
        )

        // When settings sends duplicate download intent for the same model
        // kind before the first operation completes.
        let first = store.downloadModel(for: .whisper)
        let second = store.downloadModel(for: .whisper)
        await probe.waitForCount(1)

        // Then only one application-owned task runs, and both callers wait on
        // the same tracked work.
        #expect(await probe.events() == ["download-start:whisper"])
        await releaseDownload.open()
        await first.value
        await second.value
        #expect(
            await probe.events() == ["download-start:whisper", "download-end:whisper"],
            "Duplicate voice model download intent must share one tracked task."
        )
    }

    @Test
    func cancelDownloadClearsTrackedTaskAndAllowsImmediateRetry() async throws {
        // Given a voice model download is blocked in the application-layer
        // owner.
        let probe = VoiceModelDownloadProbe()
        let releaseFirstDownload = VoiceModelDownloadGate()
        let store = VoiceModelDownloadStore.makeForTesting(
            downloadAction: { kind in
                let attempt = await probe.recordDownloadStart(kind.rawValue)
                await withTaskCancellationHandler {
                    if attempt == 1 {
                        await releaseFirstDownload.wait()
                    }
                } onCancel: {
                    Task {
                        await probe.record("download-cancel:\(kind.rawValue):\(attempt)")
                    }
                }
            }
        )

        // When settings sends cancel intent.
        let first = store.downloadModel(for: .parakeetTDT)
        await probe.waitForCount(1)
        store.cancelDownload(for: .parakeetTDT)
        await probe.waitForCount(2)

        // Then retry intent can start a new application-owned task immediately
        // instead of reusing the canceled in-flight task.
        let retry = store.downloadModel(for: .parakeetTDT)
        try await Task.sleep(for: .milliseconds(20))
        await releaseFirstDownload.open()
        await first.value
        await retry.value
        #expect(
            await probe.events() == [
                "download-start:parakeetTDT:1",
                "download-cancel:parakeetTDT:1",
                "download-start:parakeetTDT:2"
            ],
            "Canceling a voice model download must clear the tracked task immediately so retry starts fresh work."
        )
    }
}

private actor VoiceModelDownloadProbe {
    private var recordedEvents: [String] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        resumeReadyContinuations()
    }

    func recordDownloadStart(_ kind: String) -> Int {
        let attempt = recordedEvents.filter { $0.hasPrefix("download-start:\(kind):") }.count + 1
        record("download-start:\(kind):\(attempt)")
        return attempt
    }

    func events() -> [String] {
        recordedEvents
    }

    func waitForCount(_ count: Int) async {
        if recordedEvents.count >= count { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        if recordedEvents.count < count {
            await waitForCount(count)
        }
    }

    private func resumeReadyContinuations() {
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }
}

private actor VoiceModelDownloadGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let ready = continuations
        continuations.removeAll()
        for continuation in ready {
            continuation.resume()
        }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}
