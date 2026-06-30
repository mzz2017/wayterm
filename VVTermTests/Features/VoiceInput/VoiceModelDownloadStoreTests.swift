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

    @Test
    func changingModelIdCancelsInFlightDownloadAndAllowsFreshDownload() async throws {
        // Given a same-kind model download is still running for the previously
        // selected model identity.
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

        let first = store.downloadModel(for: .whisper)
        await probe.waitForCount(1)

        // When settings selects a different model ID while that download is in
        // flight, then asks to download the newly selected model.
        store.setModelId("test/new-whisper", for: .whisper)
        for _ in 0..<20 where await probe.events().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let second = store.downloadModel(for: .whisper)
        try await Task.sleep(for: .milliseconds(20))
        await releaseFirstDownload.open()
        await first.value
        await second.value

        // Then the stale same-kind download is canceled and a fresh task starts
        // for the new model ID instead of reusing the old task keyed only by kind.
        #expect(
            await probe.events() == [
                "download-start:whisper:1",
                "download-cancel:whisper:1",
                "download-start:whisper:2"
            ],
            "Changing voice model ID should cancel stale same-kind download work and allow a fresh selected-model download."
        )
    }

    @Test
    func deinitCancelsTrackedDownloads() async {
        // Given a store-owned model download is still running.
        let probe = VoiceModelDownloadProbe()
        let releaseDownload = VoiceModelDownloadGate()
        var store: VoiceModelDownloadStore? = VoiceModelDownloadStore.makeForTesting(
            downloadAction: { kind in
                await probe.record("download-start:\(kind.rawValue)")
                await withTaskCancellationHandler {
                    await releaseDownload.wait()
                } onCancel: {
                    Task {
                        await probe.record("download-cancel:\(kind.rawValue)")
                    }
                }
            }
        )

        let task = store?.downloadModel(for: .whisper)
        await probe.waitForCount(1)

        // When the application-layer owner is released.
        store = nil
        await probe.waitForCount(2)
        await releaseDownload.open()
        await task?.value

        // Then the owner cancels tracked work instead of being kept alive by
        // its own task closure.
        #expect(
            await probe.events() == [
                "download-start:whisper",
                "download-cancel:whisper"
            ],
            "Dropping the voice model download store must cancel tracked work instead of keeping the owner alive."
        )
    }

    @Test
    func cancelAllAndWaitWaitsForTrackedDownloadCancellation() async {
        let probe = VoiceModelDownloadProbe()
        let releaseCancellation = VoiceModelDownloadGate()
        let neverFinishDownload = VoiceModelDownloadGate()
        let store = VoiceModelDownloadStore.makeForTesting(
            downloadAction: { kind in
                await probe.record("download-start:\(kind.rawValue)")
                await withTaskCancellationHandler {
                    await neverFinishDownload.wait()
                } onCancel: {
                    Task {
                        await probe.record("download-cancel:\(kind.rawValue)")
                        await releaseCancellation.wait()
                        await probe.record("download-cancel-finished:\(kind.rawValue)")
                        await neverFinishDownload.open()
                    }
                }
            }
        )

        // Given a tracked model download is running.
        let downloadTask = store.downloadModel(for: .whisper)
        await probe.waitForCount(1)

        // When app-level cleanup asks the owner to cancel everything and wait.
        let cleanupTask = Task {
            await store.cancelAllAndWait()
            await probe.record("cleanup-return")
        }
        await probe.waitForCount(2)

        // Then cleanup must not report completion until cancellation handlers exit.
        #expect(
            !(await probe.events()).contains("cleanup-return"),
            "Voice model cleanup must wait for tracked download cancellation to finish."
        )

        await releaseCancellation.open()
        await cleanupTask.value
        await downloadTask.value

        #expect(
            await probe.events() == [
                "download-start:whisper",
                "download-cancel:whisper",
                "download-cancel-finished:whisper",
                "cleanup-return"
            ],
            "App-level voice model cleanup should be awaitable across tracked download cancellation."
        )
    }

    @Test
    func clearAllStorageCancelsAndWaitsForTrackedDownloadsBeforeReturning() async {
        let probe = VoiceModelDownloadProbe()
        let releaseCancellation = VoiceModelDownloadGate()
        let neverFinishDownload = VoiceModelDownloadGate()
        let store = VoiceModelDownloadStore.makeForTesting(
            downloadAction: { kind in
                await probe.record("download-start:\(kind.rawValue)")
                await withTaskCancellationHandler {
                    await neverFinishDownload.wait()
                } onCancel: {
                    Task {
                        await probe.record("download-cancel:\(kind.rawValue)")
                        await releaseCancellation.wait()
                        await probe.record("download-cancel-finished:\(kind.rawValue)")
                        await neverFinishDownload.open()
                    }
                }
            }
        )

        // Given a large model download is still running when settings sends
        // destructive clear-all-storage intent.
        let downloadTask = store.downloadModel(for: .whisper)
        await probe.waitForCount(1)

        // When clear-all-storage starts.
        let clearTask = Task { @MainActor in
            await store.clearAllStorage()
            await probe.record("clear-return")
        }

        for _ in 0..<20 where (await probe.events()).count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Then the application-layer store must cancel tracked download work
        // and stay suspended until cancellation finishes, instead of deleting
        // the model root while URLSession-backed work keeps running.
        let eventsBeforeRelease = await probe.events()
        #expect(
            eventsBeforeRelease.contains("download-cancel:whisper"),
            "Clear-all-storage should cancel active voice model downloads before deleting storage."
        )
        #expect(
            !eventsBeforeRelease.contains("clear-return"),
            "Clear-all-storage should not return before tracked download cancellation has finished."
        )

        store.cancelDownload(for: .whisper)
        await releaseCancellation.open()
        await neverFinishDownload.open()
        await clearTask.value
        await downloadTask.value

        #expect(
            await probe.events() == [
                "download-start:whisper",
                "download-cancel:whisper",
                "download-cancel-finished:whisper",
                "clear-return"
            ],
            "Clear-all-storage should reuse the awaitable VoiceInput model teardown path."
        )
    }

    @Test
    func cancelAllAndWaitWaitsForModelManagerBackgroundTasks() async {
        let modelSizer = BlockingMLXModelSizer()
        let probe = VoiceModelDownloadProbe()
        let store = VoiceModelDownloadStore(
            settings: TranscriptionSettingsReader {
                TranscriptionSettingsSnapshot(
                    provider: .mlxWhisper,
                    whisperModelId: "test/whisper-background",
                    parakeetModelId: "test/parakeet-background",
                    languageCode: "en"
                )
            },
            modelSizeProvider: modelSizer
        )

        // Given refreshing model status has started owner-managed background
        // repo-size tasks for both model managers.
        store.refreshStatuses()
        await modelSizer.waitForCallCount(2)

        // When app-level cleanup asks the store to cancel all VoiceInput model work.
        let cleanupTask = Task {
            await store.cancelAllAndWait()
            await probe.record("cleanup-return")
        }
        for _ in 0..<20 where !(await probe.events()).contains("cleanup-return") {
            try? await Task.sleep(for: .milliseconds(10))
        }

        // Then cleanup must remain waitable until manager-owned background
        // tasks observe cancellation and exit.
        #expect(
            !(await probe.events()).contains("cleanup-return"),
            "Voice model cleanup must wait for manager-owned background tasks, not just download tasks."
        )

        await modelSizer.release()
        await cleanupTask.value
        #expect(
            await probe.events() == ["cleanup-return"],
            "Voice model cleanup should return only after background repo-size tasks have exited."
        )
    }

    @Test
    func modelManagerCleanupCancelsSessionAndBackgroundWork() throws {
        // Given MLXModelManager owns URLSession delegate downloads plus
        // background storage and repo-size tasks.
        let root = try sourceRoot()
        let modelManagerSource = try source(
            at: root.appendingPathComponent("VVTerm/Features/VoiceInput/Infrastructure/MLXModelManager.swift")
        )
        let cleanup = try sourceSlice(
            in: modelManagerSource,
            from: "func cleanup()",
            to: "static func isModelAvailable"
        )
        let deinitSlice = try sourceSlice(
            in: modelManagerSource,
            from: "deinit",
            to: "private struct HFModelInfo"
        )

        // Then explicit and fallback teardown paths cancel each owned resource.
        #expect(
            cleanup.contains("storageTask?.cancel()")
                && cleanup.contains("repoSizeTask?.cancel()")
                && cleanup.contains("cancelDownload()")
                && cleanup.contains("session.invalidateAndCancel()")
                && cleanup.contains("isCleanedUp = true"),
            "MLXModelManager cleanup must cancel background work, active downloads, its URLSession delegate resource, and close future work."
        )
        #expect(
            modelManagerSource.contains("func refreshStorageUsage() {\n        guard !isCleanedUp else { return }"),
            "Cleanup should prevent cancellation handlers from starting fresh storage work after teardown."
        )
        #expect(
            deinitSlice.contains("session?.invalidateAndCancel()"),
            "MLXModelManager deinit should invalidate URLSession to break delegate retention if explicit cleanup was missed."
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

private actor BlockingMLXModelSizer: MLXModelSizing {
    private var callCount = 0
    private var waiters: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func size(for modelId: String) async -> Int64? {
        callCount += 1
        resumeReadyWaiters()
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
        return 42
    }

    func waitForCallCount(_ expectedCount: Int) async {
        guard callCount < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }

    func release() {
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func resumeReadyWaiters() {
        guard !waiters.isEmpty else { return }
        var pending: [(expectedCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var ready: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters {
            if callCount >= waiter.expectedCount {
                ready.append(waiter.continuation)
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
        ready.forEach { $0.resume() }
    }
}

private func source(at url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

private func sourceSlice(in source: String, from start: String, to end: String) throws -> String {
    guard let startRange = source.range(of: start) else {
        throw VoiceModelDownloadSourceError.markerNotFound(start)
    }
    guard let endRange = source[startRange.lowerBound...].range(of: end) else {
        throw VoiceModelDownloadSourceError.markerNotFound(end)
    }
    return String(source[startRange.lowerBound..<endRange.lowerBound])
}

private func sourceRoot() throws -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.lastPathComponent != "VVTermTests" {
        let next = url.deletingLastPathComponent()
        if next.path == url.path {
            throw VoiceModelDownloadSourceError.sourceRootNotFound
        }
        url = next
    }
    return url.deletingLastPathComponent()
}

private enum VoiceModelDownloadSourceError: Error {
    case markerNotFound(String)
    case sourceRootNotFound
}
