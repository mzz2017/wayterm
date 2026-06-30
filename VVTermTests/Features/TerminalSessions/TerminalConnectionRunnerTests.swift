import XCTest
@testable import VVTerm

// Test Context:
// These tests protect terminal SSH runner retry policy and surface-boundary
// behavior without opening a real network connection or terminal. The runner
// owns attempt ordering for UI-created terminal connections; deterministic SSH
// failures such as authentication errors must not be retried because repeated
// auth attempts can trigger server-side penalties and surface misleading SSH
// errors. The runner must also remain executable with a fake
// TerminalConnectionSurface; treat failures here as regressions unless the
// runner/surface boundary is intentionally redesigned.
//
// Fakes and assumptions: TerminalConnectionRunnerProbe is a test-only fake that
// returns configured errors from each attempt and records the final user-facing
// state. Update these tests only if VVTerm intentionally changes its retry
// policy for non-retryable SSHError cases. The surface-boundary fake below is a
// MainActor object that records terminal I/O only; it does not create a
// GhosttyTerminalView or open a network connection.
final class TerminalConnectionRunnerTests: XCTestCase {
    func testNonRetryableAuthenticationFailureDoesNotRetry() async {
        let probe = TerminalConnectionRunnerProbe(errors: [SSHError.authenticationFailed])

        await TerminalConnectionRunner.runForTesting(
            onAttempt: { _ in },
            performAttempt: { attempt in
                try await probe.performAttempt(attempt)
            },
            onFailure: { error in
                await probe.recordFailure(error)
            }
        )

        let attempts = await probe.attempts
        XCTAssertEqual(attempts, 1)

        let finalState = await probe.finalState
        XCTAssertEqual(finalState, ConnectionState.failed("Authentication failed"))
    }

    @MainActor
    func testSurfaceBoundaryReadsSizeStreamsOutputAndReportsExitWithFakeSurface() async {
        let output = Data("hello from remote\n".utf8)
        let shellId = UUID()
        let surface = RecordingTerminalConnectionSurface(
            size: TerminalConnectionSurfaceSize(columns: 132, rows: 43)
        )
        let surfaceHandle = TerminalConnectionSurfaceHandle(surface: surface)
        let probe = TerminalConnectionRunnerSurfaceProbe()
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(output)
            continuation.finish()
        }

        await TerminalConnectionRunner.run(
            terminal: surfaceHandle,
            logger: nil,
            onAttempt: { attempt in
                await probe.recordAttempt(attempt)
            },
            connect: {
                await probe.recordConnect()
            },
            startShell: { cols, rows, startupCommand in
                await probe.recordShellStart(cols: cols, rows: rows, startupCommand: startupCommand)
                return ShellHandle(id: shellId, stream: stream)
            },
            closeShell: { closedShellId in
                await probe.recordClosedShell(closedShellId)
            },
            startupPlan: {
                (command: "printf ready", skipTmuxLifecycle: true)
            },
            registerShell: { shell, skipTmuxLifecycle in
                await probe.recordShellRegistration(
                    shellId: shell.id,
                    skipTmuxLifecycle: skipTmuxLifecycle
                )
                return true
            },
            onBeforeShellStart: { cols, rows in
                await probe.recordBeforeShellStart(cols: cols, rows: rows)
            },
            onShellStarted: { terminal, startedShellId in
                probe.shellStartedWithExpectedSurfaceSize = terminal.connectionSurfaceSize() == TerminalConnectionSurfaceSize(
                    columns: 132,
                    rows: 43
                )
                probe.startedShellId = startedShellId
            },
            onTitleChange: { _ in },
            shouldContinueStreaming: { data, terminal in
                terminal.writeConnectionOutput(data)
                return true
            },
            shouldResetClient: { _ in false },
            resetConnection: {
                await probe.recordReset()
            },
            onProcessExit: {
                await probe.recordProcessExit()
            },
            onFailure: { error, _ in
                XCTFail("Expected successful fake surface run, got \(error)")
            }
        )

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1], "Runner should perform one successful attempt.")
        XCTAssertEqual(snapshot.connectCount, 1, "Runner should use the injected connection operation.")
        XCTAssertEqual(snapshot.shellStartSizes, [TerminalConnectionSurfaceSize(columns: 132, rows: 43)])
        XCTAssertEqual(snapshot.startupCommands, ["printf ready"])
        XCTAssertEqual(snapshot.beforeShellStartSizes, [TerminalConnectionSurfaceSize(columns: 132, rows: 43)])
        XCTAssertEqual(snapshot.registeredShellIds, [shellId])
        XCTAssertEqual(snapshot.skipTmuxLifecycleValues, [true])
        XCTAssertEqual(snapshot.closedShellIds, [])
        XCTAssertEqual(snapshot.resetCount, 0)
        XCTAssertEqual(snapshot.processExitCount, 1)

        XCTAssertEqual(probe.startedShellId, shellId)
        XCTAssertEqual(probe.shellStartedWithExpectedSurfaceSize, true)
        XCTAssertEqual(surface.writtenData, [output], "Runner should stream shell bytes through the surface protocol.")
        XCTAssertEqual(surface.exitCodes, [0], "Runner should report external process exit through the surface protocol.")
    }

    @MainActor
    func testSurfaceDisappearingAfterConnectPreventsShellStart() async {
        let shellId = UUID()
        var isSurfaceAvailable = true
        let surfaceHandle = TerminalConnectionSurfaceHandle(
            availabilityProvider: { isSurfaceAvailable },
            sizeProvider: {
                isSurfaceAvailable ? TerminalConnectionSurfaceSize(columns: 132, rows: 43) : nil
            },
            outputWriter: { _ in
                XCTFail("Closed terminal surface must not receive shell output.")
            },
            exitReporter: { _ in
                XCTFail("Closed terminal surface must not receive process exit.")
            }
        )
        let probe = TerminalConnectionRunnerSurfaceProbe()
        let stream = AsyncStream<Data> { continuation in
            continuation.finish()
        }

        await TerminalConnectionRunner.run(
            terminal: surfaceHandle,
            logger: nil,
            onAttempt: { attempt in
                await probe.recordAttempt(attempt)
            },
            connect: {
                await probe.recordConnect()
                isSurfaceAvailable = false
            },
            startShell: { cols, rows, startupCommand in
                await probe.recordShellStart(cols: cols, rows: rows, startupCommand: startupCommand)
                return ShellHandle(id: shellId, stream: stream)
            },
            closeShell: { closedShellId in
                await probe.recordClosedShell(closedShellId)
            },
            startupPlan: {
                (command: "printf ready", skipTmuxLifecycle: true)
            },
            registerShell: { shell, skipTmuxLifecycle in
                await probe.recordShellRegistration(
                    shellId: shell.id,
                    skipTmuxLifecycle: skipTmuxLifecycle
                )
                return true
            },
            onBeforeShellStart: { cols, rows in
                await probe.recordBeforeShellStart(cols: cols, rows: rows)
            },
            onShellStarted: { _, startedShellId in
                probe.startedShellId = startedShellId
            },
            onTitleChange: { _ in },
            shouldContinueStreaming: { _, _ in true },
            shouldResetClient: { _ in false },
            resetConnection: {
                await probe.recordReset()
            },
            onProcessExit: {
                await probe.recordProcessExit()
            },
            onFailure: { error, _ in
                XCTFail("Closed terminal surface should stop runtime start without failure, got \(error)")
            }
        )

        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.attempts, [1], "Runner should observe the original attach attempt.")
        XCTAssertEqual(snapshot.connectCount, 1, "Runner may finish an in-flight connect before seeing surface close.")
        XCTAssertEqual(snapshot.shellStartSizes, [], "Runner must not start a shell after the surface is unavailable.")
        XCTAssertEqual(snapshot.beforeShellStartSizes, [], "Runner must not publish shell-start sizing for a closed surface.")
        XCTAssertEqual(snapshot.registeredShellIds, [], "Runner must not register shell ownership after surface close.")
        XCTAssertEqual(snapshot.closedShellIds, [], "No shell should exist to close when surface disappears before start.")
        XCTAssertEqual(snapshot.processExitCount, 0, "Closed surface should not receive a synthetic process exit.")
        XCTAssertNil(probe.startedShellId)
    }

    @MainActor
    func testSurfaceHandleRoutesCallbacksToLatestResolvedSurface() {
        let firstSurface = RecordingTerminalConnectionSurface(
            size: TerminalConnectionSurfaceSize(columns: 80, rows: 24)
        )
        let secondSurface = RecordingTerminalConnectionSurface(
            size: TerminalConnectionSurfaceSize(columns: 120, rows: 40)
        )
        var currentSurface: RecordingTerminalConnectionSurface? = firstSurface
        let output = Data("latest surface\n".utf8)

        // Given a long-running terminal runner owns a sendable surface handle
        // whose concrete UIView-backed surface can be replaced by later UI
        // attach intent for the same terminal entity.
        let surfaceHandle = TerminalConnectionSurfaceHandle(
            availabilityProvider: { currentSurface != nil },
            sizeProvider: { currentSurface?.connectionSurfaceSize() },
            outputWriter: { currentSurface?.writeConnectionOutput($0) },
            exitReporter: { currentSurface?.connectionSurfaceExited($0) }
        )

        XCTAssertTrue(surfaceHandle.isAvailable())
        XCTAssertEqual(surfaceHandle.connectionSurfaceSize(), TerminalConnectionSurfaceSize(columns: 80, rows: 24))

        // When a newer surface becomes the current owner before stream output
        // arrives.
        currentSurface = secondSurface
        surfaceHandle.writeConnectionOutput(output)
        surfaceHandle.connectionSurfaceExited(0)

        // Then shell output and exit notifications go to the latest surface,
        // not the stale surface that existed when the runner was created.
        XCTAssertEqual(firstSurface.writtenData, [])
        XCTAssertEqual(firstSurface.exitCodes, [])
        XCTAssertEqual(secondSurface.writtenData, [output])
        XCTAssertEqual(secondSurface.exitCodes, [0])
        XCTAssertEqual(surfaceHandle.connectionSurfaceSize(), TerminalConnectionSurfaceSize(columns: 120, rows: 40))

        currentSurface = nil
        XCTAssertFalse(surfaceHandle.isAvailable())
    }
}

private actor TerminalConnectionRunnerProbe {
    private let errors: [Error]
    private(set) var attempts = 0
    private(set) var finalState: ConnectionState?

    init(errors: [Error]) {
        self.errors = errors
    }

    func performAttempt(_ attempt: Int) async throws {
        attempts += 1
        guard attempt <= errors.count else { return }
        throw errors[attempt - 1]
    }

    func recordFailure(_ error: Error) {
        finalState = .failed(error.localizedDescription)
    }
}

@MainActor
private final class RecordingTerminalConnectionSurface: TerminalConnectionSurface {
    private let size: TerminalConnectionSurfaceSize?
    private(set) var writtenData: [Data] = []
    private(set) var exitCodes: [UInt32] = []

    init(size: TerminalConnectionSurfaceSize?) {
        self.size = size
    }

    func connectionSurfaceSize() -> TerminalConnectionSurfaceSize? {
        size
    }

    func writeConnectionOutput(_ data: Data) {
        writtenData.append(data)
    }

    func connectionSurfaceExited(_ exitCode: UInt32) {
        exitCodes.append(exitCode)
    }
}

private actor TerminalConnectionRunnerSurfaceProbe {
    struct Snapshot {
        var attempts: [Int]
        var connectCount: Int
        var shellStartSizes: [TerminalConnectionSurfaceSize]
        var startupCommands: [String?]
        var beforeShellStartSizes: [TerminalConnectionSurfaceSize]
        var registeredShellIds: [UUID]
        var skipTmuxLifecycleValues: [Bool]
        var closedShellIds: [UUID]
        var resetCount: Int
        var processExitCount: Int
    }

    private var attempts: [Int] = []
    private var connectCount = 0
    private var shellStartSizes: [TerminalConnectionSurfaceSize] = []
    private var startupCommands: [String?] = []
    private var beforeShellStartSizes: [TerminalConnectionSurfaceSize] = []
    private var registeredShellIds: [UUID] = []
    private var skipTmuxLifecycleValues: [Bool] = []
    private var closedShellIds: [UUID] = []
    private var resetCount = 0
    private var processExitCount = 0

    @MainActor var startedShellId: UUID?
    @MainActor var shellStartedWithExpectedSurfaceSize: Bool?

    func recordAttempt(_ attempt: Int) {
        attempts.append(attempt)
    }

    func recordConnect() {
        connectCount += 1
    }

    func recordShellStart(cols: Int, rows: Int, startupCommand: String?) {
        shellStartSizes.append(TerminalConnectionSurfaceSize(columns: cols, rows: rows))
        startupCommands.append(startupCommand)
    }

    func recordBeforeShellStart(cols: Int, rows: Int) {
        beforeShellStartSizes.append(TerminalConnectionSurfaceSize(columns: cols, rows: rows))
    }

    func recordShellRegistration(shellId: UUID, skipTmuxLifecycle: Bool) {
        registeredShellIds.append(shellId)
        skipTmuxLifecycleValues.append(skipTmuxLifecycle)
    }

    func recordClosedShell(_ shellId: UUID) {
        closedShellIds.append(shellId)
    }

    func recordReset() {
        resetCount += 1
    }

    func recordProcessExit() {
        processExitCount += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(
            attempts: attempts,
            connectCount: connectCount,
            shellStartSizes: shellStartSizes,
            startupCommands: startupCommands,
            beforeShellStartSizes: beforeShellStartSizes,
            registeredShellIds: registeredShellIds,
            skipTmuxLifecycleValues: skipTmuxLifecycleValues,
            closedShellIds: closedShellIds,
            resetCount: resetCount,
            processExitCount: processExitCount
        )
    }
}
