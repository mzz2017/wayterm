//
//  ShellHandle.swift
//  Waterm
//
//  Started shell stream handle.
//

import Foundation

nonisolated struct ShellHandle {
    let id: UUID
    let stream: AsyncStream<Data>
    let transport: ShellTransport
    let fallbackReason: MoshFallbackReason?

    init(
        id: UUID,
        stream: AsyncStream<Data>,
        transport: ShellTransport = .ssh,
        fallbackReason: MoshFallbackReason? = nil
    ) {
        self.id = id
        self.stream = stream
        self.transport = transport
        self.fallbackReason = fallbackReason
    }
}
