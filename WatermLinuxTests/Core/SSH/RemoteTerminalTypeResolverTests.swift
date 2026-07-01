import XCTest
@testable import WatermSSHCoreLogic

final class RemoteTerminalTypeResolverTests: XCTestCase {
    private let posixEnvironment = RemoteEnvironment(
        platform: .linux,
        shellProfile: .posix(shellName: "zsh"),
        activeShellName: "zsh",
        powerShellExecutable: nil
    )

    func testResolveDefaultsToXterm256ColorWithoutRemoteTerminfoProbe() async {
        let executor = FakeExecutor(outputs: [
            .success("__WATERM_XTERM_GHOSTTY_OK__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: "xterm-ghostty|ghostty|Ghostty,\n\tcolors#256,\n"
        )

        XCTAssertEqual(terminalType, .xterm256Color)
        let commands = await executor.recordedCommands()
        XCTAssertEqual(commands, [])
    }

    func testResolveUsesGhosttyTerminfoWhenExplicitlyRequestedAndProbeSucceeds() async {
        let executor = FakeExecutor(outputs: [
            .success("__WATERM_XTERM_GHOSTTY_OK__")
        ])

        let terminalType = await RemoteTerminalTypeResolver.resolve(
            environment: posixEnvironment,
            execute: { command, timeout in
                try await executor.run(command: command, timeout: timeout)
            },
            terminfoSource: "xterm-ghostty|ghostty|Ghostty,\n\tcolors#256,\n",
            preference: .ghosttyTerminfo
        )

        let commands = await executor.recordedCommands()
        XCTAssertEqual(terminalType, .xtermGhostty)
        XCTAssertEqual(commands.count, 1)
        XCTAssertTrue(commands[0].contains("infocmp -x xterm-ghostty"))
    }
}

private actor FakeExecutor {
    private var outputs: [Result<String, Error>]
    private var commands: [String] = []

    init(outputs: [Result<String, Error>]) {
        self.outputs = outputs
    }

    func run(command: String, timeout _: Duration?) throws -> String {
        commands.append(command)
        guard !outputs.isEmpty else {
            XCTFail("Unexpected extra command: \(command)")
            return ""
        }
        switch outputs.removeFirst() {
        case .success(let output):
            return output
        case .failure(let error):
            throw error
        }
    }

    func recordedCommands() -> [String] {
        commands
    }
}
