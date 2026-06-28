import Foundation

extension Server {
    var sshConnectionTarget: SSHConnectionTarget {
        SSHConnectionTarget(
            host: host,
            port: port,
            username: username,
            connectionMode: connectionMode,
            authMethod: authMethod,
            cloudflareAccessMode: cloudflareAccessMode,
            cloudflareTeamDomainOverride: cloudflareTeamDomainOverride
        )
    }
}
