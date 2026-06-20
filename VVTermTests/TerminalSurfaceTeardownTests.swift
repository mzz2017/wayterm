import Foundation
import Testing
@testable import VVTerm

@Suite(.serialized)
struct TerminalSurfaceTeardownTests {
    @Test
    func detachedSurfaceSchedulesNativeFreeWithoutRunningItInline() async throws {
        let recorder = TerminalSurfaceTeardownRecorder()
        let scheduler = TerminalSurfaceTeardownQueue(
            enqueue: { operation in
                recorder.enqueued += 1
                recorder.operation = operation
            }
        )

        let handle = Ghostty.Surface.NativeHandle(
            rawValue: nil,
            callbackContext: nil,
            freeNativeSurface: { recorder.freed += 1 }
        )

        handle.scheduleFree(on: scheduler)

        #expect(recorder.enqueued == 1)
        #expect(recorder.freed == 0)

        recorder.operation?()
        #expect(recorder.freed == 1)
    }
}

private final class TerminalSurfaceTeardownRecorder: @unchecked Sendable {
    var enqueued = 0
    var freed = 0
    var operation: (@Sendable () -> Void)?
}
