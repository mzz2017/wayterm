import Foundation
import Testing
@testable import Waterm

// Test Context:
// MLXModelManager owns model-download state for VoiceInput. Model selection can
// change while a download is suspended or being canceled; a stale operation must
// not write ready/failed/progress state for the newly selected model. Fakes here
// do not touch network or filesystem payloads; they only control the async
// operation boundary where a live URLSession-backed download would suspend.
// Update these tests only if download state ownership intentionally moves out of
// MLXModelManager.
@Suite(.serialized)
@MainActor
struct MLXModelManagerLifecycleTests {
    @Test
    func canceledOldModelDownloadCannotMarkNewModelReadyWhenItReturnsLate() async {
        let probe = MLXModelDownloadProbe()
        let releaseDownload = MLXModelDownloadGate()
        let manager = MLXModelManager(
            kind: .whisper,
            modelId: "test/old-whisper",
            downloadOperation: { context in
                await probe.record("download-start:\(context.modelId)")
                await releaseDownload.wait()
                await probe.record("download-return:\(context.modelId)")
            }
        )

        // Given a model download has started for the previously selected model.
        let downloadTask = Task { @MainActor in
            await manager.downloadModel()
        }
        #expect(
            await waitForProbeCount(probe, 1),
            "The fake download operation should start before the test cancels it."
        )

        // When settings selects a new model and cancels the stale download, but
        // the old async operation still returns later.
        manager.modelId = "test/new-whisper"
        manager.cancelDownload()
        await releaseDownload.open()
        await downloadTask.value

        // Then the stale operation must not write ready state for the new model.
        #expect(
            await probe.events() == [
                "download-start:test/old-whisper",
                "download-return:test/old-whisper"
            ],
            "The fake should prove the old download returned after cancellation."
        )
        #expect(
            manager.state == .idle,
            "A canceled old model download must not mark the newly selected model ready when it returns late."
        )
    }

    @Test
    func failedPartialDownloadDirectoryIsNotReportedAvailable() async {
        let modelId = "test/partial-whisper-\(UUID().uuidString)"
        let modelDirectory = MLXModelManager.modelDirectory(for: .whisper, modelId: modelId)
        defer {
            try? FileManager.default.removeItem(at: modelDirectory)
        }

        let manager = MLXModelManager(
            kind: .whisper,
            modelId: modelId,
            downloadOperation: { context in
                let directory = MLXModelManager.modelDirectory(for: context.kind, modelId: context.modelId)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: directory.appendingPathComponent("config.json"))
                try Data("partial weights".utf8).write(to: directory.appendingPathComponent("model.safetensors"))
                throw NSError(
                    domain: "MLXModelManagerLifecycleTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "simulated partial download failure"]
                )
            }
        )

        // Given a model download writes enough files to satisfy the old
        // availability heuristic, but does not finish the full download.
        await manager.downloadModel()

        // Then later availability checks must not treat the partial directory as
        // an installed model.
        #expect(
            !MLXModelManager.isModelAvailable(kind: .whisper, modelId: modelId),
            "Failed partial downloads must not be reported as available models."
        )
    }
}

private actor MLXModelDownloadProbe {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }

    func count() -> Int {
        recordedEvents.count
    }
}

private func waitForProbeCount(_ probe: MLXModelDownloadProbe, _ count: Int) async -> Bool {
    for _ in 0..<100 {
        if await probe.count() >= count {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

private actor MLXModelDownloadGate {
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
