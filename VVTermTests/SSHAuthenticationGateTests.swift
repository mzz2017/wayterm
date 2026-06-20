import XCTest
@testable import VVTerm

// Test Context:
// These tests protect SSHAuthenticationGate's per-server authentication
// serialization rule. Same-key authentication must not overlap, while unrelated
// keys may proceed in parallel. Update these tests only if public-key auth no
// longer needs a per-key serialization gate.

final class SSHAuthenticationGateTests: XCTestCase {
    func testSameKeyOperationsDoNotOverlap() async {
        let gate = SSHAuthenticationGate()
        let probe = AuthGateProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try? await gate.withExclusiveAccess(for: "server-key") {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(50))
                        await probe.leave()
                    }
                }
            }
        }

        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 1)
    }

    func testDifferentKeyOperationsCanOverlap() async {
        let gate = SSHAuthenticationGate()
        let probe = AuthGateProbe()

        await withTaskGroup(of: Void.self) { group in
            for key in ["server-a", "server-b"] {
                group.addTask {
                    try? await gate.withExclusiveAccess(for: key) {
                        await probe.enter()
                        try? await Task.sleep(for: .milliseconds(50))
                        await probe.leave()
                    }
                }
            }
        }

        let maxActive = await probe.maxActive
        XCTAssertGreaterThan(maxActive, 1)
    }
}

private actor AuthGateProbe {
    private var activeCount = 0
    private(set) var maxActive = 0

    func enter() {
        activeCount += 1
        maxActive = max(maxActive, activeCount)
    }

    func leave() {
        activeCount -= 1
    }
}
