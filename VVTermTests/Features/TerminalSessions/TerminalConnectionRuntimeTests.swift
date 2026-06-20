import Foundation
import XCTest
@testable import VVTerm

// Test Context:
// These tests protect the first application-layer owner for terminal SSH
// lifecycles. The runtime must own a client and make close operations await the
// underlying shell close and disconnect before returning.
//
// Fakes and assumptions: RecordingTerminalSSHClient is an actor fake that
// records method ordering only. It does not open sockets, allocate libssh2
// resources, or run a terminal stream. Update these tests only if the runtime
// lifecycle contract intentionally changes.
final class TerminalConnectionRuntimeTests: XCTestCase {
    func testCloseWaitsForShellCloseAndDisconnect() async {
        let fake = RecordingTerminalSSHClient()
        let runtime = TerminalConnectionRuntime(entityId: .session(UUID()), clientFactory: { fake })

        await runtime.open(configuration: .testing)
        await runtime.close(mode: .fullDisconnect)

        let events = await fake.events
        XCTAssertEqual(events, ["connect", "startShell", "closeShell", "disconnect"])
    }
}

private actor RecordingTerminalSSHClient: TerminalConnectionClient {
    private(set) var events: [String] = []
    private let shellId = UUID()

    func connect() async throws {
        events.append("connect")
    }

    func startShell() async throws -> UUID {
        events.append("startShell")
        return shellId
    }

    func closeShell(_ shellId: UUID) async {
        events.append("closeShell")
    }

    func disconnect() async {
        events.append("disconnect")
    }

    func write(_ data: Data, to shellId: UUID) async throws {
        events.append("write")
    }

    func resize(cols: Int, rows: Int, for shellId: UUID) async throws {
        events.append("resize")
    }
}
