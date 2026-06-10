import Testing
@testable import VVTerm

struct RemoteZmxCommandBuilderTests {
    let b = RemoteZmxCommandBuilder()

    @Test func attachStartupExecsZmx() {
        let cmd = b.attachCommand(sessionName: "vvterm_dev", context: .startupExec)
        #expect(cmd.contains("exec"))
        #expect(cmd.contains("zmx"))
        #expect(cmd.contains("attach"))
        #expect(cmd.contains("vvterm_dev"))
    }

    @Test func attachInteractiveWrapsInShell() {
        let cmd = b.attachCommand(sessionName: "dev", context: .interactiveShell)
        #expect(cmd.hasPrefix("sh -lc"))
    }

    @Test func parsesShortListOneNamePerLine() {
        let sessions = b.parseSessionList("alpha\nbravo\n\ncharlie\n")
        #expect(sessions.map(\.name) == ["alpha", "bravo", "charlie"])
    }

    @Test func killUsesForce() {
        #expect(b.killSessionCommand(named: "dev").contains("kill"))
        #expect(b.killSessionCommand(named: "dev").contains("dev"))
    }
}
