import Foundation

struct SSHShellRegistry {
    struct Generation: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    struct Registration: Sendable {
        let serverId: UUID
        let client: SSHClient
        let shellId: UUID
        let transport: ShellTransport
        let fallbackReason: MoshFallbackReason?
    }

    struct StartContext: Sendable {
        let startedAt: Date
        let client: SSHClient
        let serverId: UUID
        let generation: Generation
    }

    struct RegisterResult: Sendable {
        let accepted: Bool
        let staleIncomingShell: (client: SSHClient, shellId: UUID)?
        let replacedShell: (client: SSHClient, shellId: UUID)?
        let rejectedShellToClose: (client: SSHClient, shellId: UUID)?
    }

    struct StartResult: Sendable {
        let started: Bool
        let staleContext: StartContext?
        let generation: Generation
    }

    struct InFlightResult: Sendable {
        let inFlight: Bool
        let staleContext: StartContext?
    }

    struct CloseResult: Sendable {
        let registration: Registration?
        let pendingStart: StartContext?
    }

    private(set) var registrations: [UUID: Registration] = [:]
    private(set) var startsInFlight: [UUID: StartContext] = [:]
    private var generations: [UUID: Generation] = [:]
    private let staleThreshold: TimeInterval

    init(staleThreshold: TimeInterval) {
        self.staleThreshold = staleThreshold
    }

    mutating func register(
        client: SSHClient,
        shellId: UUID,
        for entityId: UUID,
        serverId: UUID,
        transport: ShellTransport,
        fallbackReason: MoshFallbackReason?,
        generation: Generation? = nil
    ) -> RegisterResult {
        let shellToReject = (client: client, shellId: shellId)

        if let generation {
            guard let context = startsInFlight[entityId],
                  context.generation == generation,
                  ObjectIdentifier(context.client) == ObjectIdentifier(client) else {
                return RegisterResult(
                    accepted: false,
                    staleIncomingShell: shellToReject,
                    replacedShell: nil,
                    rejectedShellToClose: shellToReject
                )
            }
        } else if let context = startsInFlight[entityId],
                  ObjectIdentifier(context.client) != ObjectIdentifier(client) {
            return RegisterResult(
                accepted: false,
                staleIncomingShell: shellToReject,
                replacedShell: nil,
                rejectedShellToClose: shellToReject
            )
        }

        startsInFlight.removeValue(forKey: entityId)
        let newRegistration = Registration(
            serverId: serverId,
            client: client,
            shellId: shellId,
            transport: transport,
            fallbackReason: fallbackReason
        )
        let replaced = registrations.updateValue(newRegistration, forKey: entityId)
        return RegisterResult(
            accepted: true,
            staleIncomingShell: nil,
            replacedShell: replaced.map { (client: $0.client, shellId: $0.shellId) },
            rejectedShellToClose: nil
        )
    }

    mutating func closeEntity(_ entityId: UUID) -> CloseResult {
        generations[entityId] = Generation(rawValue: currentGeneration(for: entityId).rawValue &+ 1)
        let pendingStart = startsInFlight.removeValue(forKey: entityId)
        let registration = registrations.removeValue(forKey: entityId)
        return CloseResult(registration: registration, pendingStart: pendingStart)
    }

    mutating func unregister(for entityId: UUID) -> CloseResult {
        closeEntity(entityId)
    }

    mutating func tryBeginStart(
        for entityId: UUID,
        serverId: UUID,
        client: SSHClient,
        now: Date = Date()
    ) -> StartResult {
        let generation = currentGeneration(for: entityId)

        if registrations[entityId] != nil {
            return StartResult(started: false, staleContext: nil, generation: generation)
        }

        if let context = startsInFlight[entityId] {
            if now.timeIntervalSince(context.startedAt) < staleThreshold {
                return StartResult(started: false, staleContext: nil, generation: generation)
            }
            startsInFlight.removeValue(forKey: entityId)
            startsInFlight[entityId] = StartContext(
                startedAt: now,
                client: client,
                serverId: serverId,
                generation: generation
            )
            return StartResult(started: true, staleContext: context, generation: generation)
        }

        startsInFlight[entityId] = StartContext(
            startedAt: now,
            client: client,
            serverId: serverId,
            generation: generation
        )
        return StartResult(started: true, staleContext: nil, generation: generation)
    }

    mutating func finishStart(for entityId: UUID, client: SSHClient, generation: Generation? = nil) {
        guard let context = startsInFlight[entityId] else { return }
        guard ObjectIdentifier(context.client) == ObjectIdentifier(client) else { return }
        if let generation {
            guard context.generation == generation else { return }
        }
        startsInFlight.removeValue(forKey: entityId)
    }

    mutating func isStartInFlight(for entityId: UUID, now: Date = Date()) -> InFlightResult {
        guard let context = startsInFlight[entityId] else {
            return InFlightResult(inFlight: false, staleContext: nil)
        }

        if now.timeIntervalSince(context.startedAt) >= staleThreshold {
            startsInFlight.removeValue(forKey: entityId)
            return InFlightResult(inFlight: false, staleContext: context)
        }

        return InFlightResult(inFlight: true, staleContext: nil)
    }

    func registration(for entityId: UUID) -> Registration? {
        registrations[entityId]
    }

    func shellId(for entityId: UUID) -> UUID? {
        registrations[entityId]?.shellId
    }

    func client(for entityId: UUID) -> SSHClient? {
        registrations[entityId]?.client
    }

    func hasOtherRegistrations(using client: SSHClient, excluding entityId: UUID) -> Bool {
        let identifier = ObjectIdentifier(client)
        return registrations.contains { registration in
            registration.key != entityId && ObjectIdentifier(registration.value.client) == identifier
        }
    }

    func hasClientReferences(_ client: SSHClient) -> Bool {
        hasActiveRegistration(using: client) || hasPendingStart(using: client)
    }

    func hasActiveRegistration(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return registrations.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func hasPendingStart(using client: SSHClient) -> Bool {
        let identifier = ObjectIdentifier(client)
        return startsInFlight.values.contains { ObjectIdentifier($0.client) == identifier }
    }

    func firstRegisteredClient(for serverId: UUID) -> SSHClient? {
        registrations.values.first(where: { $0.serverId == serverId })?.client
    }

    func firstRegistration(for serverId: UUID) -> Registration? {
        registrations.values.first { $0.serverId == serverId }
    }

    func firstPendingClient(for serverId: UUID) -> SSHClient? {
        startsInFlight.values.first(where: { $0.serverId == serverId })?.client
    }

    mutating func removeAll() {
        registrations.removeAll()
        startsInFlight.removeAll()
        generations.removeAll()
    }

    private func currentGeneration(for entityId: UUID) -> Generation {
        generations[entityId] ?? Generation(rawValue: 0)
    }
}
