import Foundation
import Testing

// Test Context:
// Core/SSH owns transport-level connection primitives. Servers owns saved
// product metadata and may adapt Server into SSHConnectionTarget at the feature
// boundary. Update these tests only if SSH transport ownership intentionally
// moves into the Servers feature or Core is allowed to depend on Server domain
// models again.

struct CoreSSHDomainBoundaryTests {
    @Test
    func coreSSHDoesNotExposeServerDomainConnectionAPI() throws {
        let root = try sourceRoot()
        let coreDirectories = [
            root.appendingPathComponent("VVTerm/Core/SSH"),
            root.appendingPathComponent("VVTerm/Core/Network/Cloudflare")
        ]
        let forbiddenShapes = [
            "Server?",
            "Server,",
            "server: Server",
            "to server: Server",
            "connectedServer",
            "func connect(to server",
            "func connect(server:"
        ]

        for directory in coreDirectories {
            for swiftFile in try swiftFiles(in: directory) {
                let source = try source(at: swiftFile)
                for forbiddenShape in forbiddenShapes {
                    #expect(
                        !source.contains(forbiddenShape),
                        "Core SSH/Cloudflare code should use SSHConnectionTarget, not Servers domain shape \(forbiddenShape), in \(swiftFile.lastPathComponent)."
                    )
                }
            }
        }
    }

    @Test
    func sshConnectionPrimitivesAreOwnedByCoreSSH() throws {
        let root = try sourceRoot()
        let serverSource = try source(at: root.appendingPathComponent("VVTerm/Features/Servers/Domain/Server.swift"))
        let targetSource = try source(at: root.appendingPathComponent("VVTerm/Core/SSH/SSHConnectionTarget.swift"))

        let primitiveDeclarations = [
            "enum SSHConnectionMode",
            "enum CloudflareAccessMode",
            "enum AuthMethod",
            "struct ServerCredentials",
            "struct SSHConnectionTarget"
        ]

        for declaration in primitiveDeclarations {
            #expect(
                targetSource.contains(declaration),
                "Core/SSH should own connection primitive \(declaration)."
            )
        }

        let forbiddenServerOwnedPrimitives = primitiveDeclarations.dropLast()
        for declaration in forbiddenServerOwnedPrimitives {
            #expect(
                !serverSource.contains(declaration),
                "Server domain should compose Core SSH primitive \(declaration), not own it."
            )
        }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
            let parent = url.deletingLastPathComponent()
            if parent == url {
                throw CocoaError(.fileNoSuchFile)
            }
            url = parent
        }
        return url.deletingLastPathComponent()
    }
}
