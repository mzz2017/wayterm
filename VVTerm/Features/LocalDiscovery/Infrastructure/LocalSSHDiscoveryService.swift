import Foundation
import Network
import Darwin

enum LocalSSHDiscoverySourceStatus: Sendable {
    case bonjourStarted
    case bonjourFinished
    case probeStarted
    case probeFinished
}

enum LocalSSHDiscoveryEvent: Sendable {
    case scanningStarted
    case sourceStatus(LocalSSHDiscoverySourceStatus)
    case hostFound(DiscoveredSSHHost)
    case permissionDenied
    case failed(String)
    case scanningFinished
}

struct LocalSSHDiscoveryProbeResult: Sendable {
    let host: String
    let latencyMs: Int
}

struct LocalSSHDiscoveryServiceDependencies: Sendable {
    let bonjourTypes: [String]
    let scanDuration: TimeInterval
    let serviceResolveTimeout: TimeInterval
    let portScanTimeout: TimeInterval
    let portScanConcurrency: Int
    let localSubnetCandidates: @MainActor @Sendable () -> [String]
    let probeSSHHost: @Sendable (String, TimeInterval) async -> LocalSSHDiscoveryProbeResult?

    static let live = LocalSSHDiscoveryServiceDependencies(
        bonjourTypes: ["_ssh._tcp.", "_sftp-ssh._tcp."],
        scanDuration: 6,
        serviceResolveTimeout: 2,
        portScanTimeout: 0.35,
        portScanConcurrency: 24,
        localSubnetCandidates: {
            LocalSSHDiscoveryService.localSubnetCandidates()
        },
        probeSSHHost: { host, timeout in
            await LocalSSHDiscoveryService.probeSSHHost(host, timeout: timeout)
        }
    )
}

@MainActor
final class LocalSSHDiscoveryService: NSObject {
    private let dependencies: LocalSSHDiscoveryServiceDependencies

    private var streamContinuation: AsyncStream<LocalSSHDiscoveryEvent>.Continuation?
    private var activeScanID: UUID?
    private var browsers: [NetServiceBrowser] = []
    private var browserScanIDs: [ObjectIdentifier: UUID] = [:]
    private var servicesByName: [String: NetService] = [:]
    private var serviceScanIDs: [ObjectIdentifier: UUID] = [:]
    private var seenServices: Set<String> = []
    private var probeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        self.dependencies = .live
        super.init()
    }

    init(dependencies: LocalSSHDiscoveryServiceDependencies) {
        self.dependencies = dependencies
        super.init()
    }

    func startScan() -> AsyncStream<LocalSSHDiscoveryEvent> {
        stopScan()
        let scanID = UUID()
        activeScanID = scanID

        return AsyncStream { continuation in
            streamContinuation = continuation

            emit(.scanningStarted, scanID: scanID)
            startBonjourBrowsing(scanID: scanID)
            startPortScanning(scanID: scanID)
            startTimeoutTimer(scanID: scanID)
        }
    }

    func stopScan() {
        activeScanID = nil

        timeoutTask?.cancel()
        timeoutTask = nil

        probeTask?.cancel()
        probeTask = nil

        for browser in browsers {
            browser.delegate = nil
            browser.stop()
        }
        browsers.removeAll()
        browserScanIDs.removeAll()

        for service in servicesByName.values {
            service.delegate = nil
            service.stop()
        }
        servicesByName.removeAll()
        serviceScanIDs.removeAll()
        seenServices.removeAll()

        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func startTimeoutTimer(scanID: UUID) {
        let duration = dependencies.scanDuration
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.finishScan(scanID: scanID)
        }
    }

    private func finishScan(scanID: UUID) {
        guard isCurrentScan(scanID) else { return }
        emit(.sourceStatus(.bonjourFinished), scanID: scanID)
        emit(.sourceStatus(.probeFinished), scanID: scanID)
        emit(.scanningFinished, scanID: scanID)
        stopScan()
    }

    private func emit(_ event: LocalSSHDiscoveryEvent, scanID: UUID? = nil) {
        if let scanID, !isCurrentScan(scanID) {
            return
        }
        streamContinuation?.yield(event)
    }

    private func isCurrentScan(_ scanID: UUID?) -> Bool {
        guard let scanID, let activeScanID else { return false }
        return scanID == activeScanID
    }

    private func startBonjourBrowsing(scanID: UUID) {
        emit(.sourceStatus(.bonjourStarted), scanID: scanID)
        guard !dependencies.bonjourTypes.isEmpty else {
            emit(.sourceStatus(.bonjourFinished), scanID: scanID)
            return
        }

        for serviceType in dependencies.bonjourTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browserScanIDs[ObjectIdentifier(browser)] = scanID
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
        }
    }

    private func startPortScanning(scanID: UUID) {
        emit(.sourceStatus(.probeStarted), scanID: scanID)

        let timeout = dependencies.portScanTimeout
        let concurrency = max(1, dependencies.portScanConcurrency)
        let localSubnetCandidates = dependencies.localSubnetCandidates
        let probeSSHHost = dependencies.probeSSHHost

        probeTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            let candidates = localSubnetCandidates()

            guard !candidates.isEmpty else {
                emit(.sourceStatus(.probeFinished), scanID: scanID)
                return
            }

            var startIndex = 0
            while startIndex < candidates.count {
                if Task.isCancelled {
                    break
                }

                let endIndex = min(startIndex + concurrency, candidates.count)
                let chunk = Array(candidates[startIndex..<endIndex])

                await withTaskGroup(of: (host: String, latencyMs: Int)?.self) { group in
                    for host in chunk {
                        group.addTask {
                            guard let result = await probeSSHHost(host, timeout) else {
                                return nil
                            }
                            return (host: result.host, latencyMs: result.latencyMs)
                        }
                    }

                    for await result in group {
                        guard self.isCurrentScan(scanID) else { continue }
                        guard let found = result else { continue }
                        let discovered = DiscoveredSSHHost(
                            displayName: found.host,
                            host: found.host,
                            port: 22,
                            sources: [.portScan],
                            latencyMs: found.latencyMs
                        )
                        self.emit(.hostFound(discovered), scanID: scanID)
                    }
                }

                startIndex = endIndex
            }

            emit(.sourceStatus(.probeFinished), scanID: scanID)
        }
    }

    nonisolated static func probeSSHHost(
        _ host: String,
        timeout: TimeInterval
    ) async -> LocalSSHDiscoveryProbeResult? {
        let startedAt = Date()
        let isReachable = await checkReachability(host: host, port: 22, timeout: timeout)
        guard isReachable else { return nil }

        let latencyMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        return LocalSSHDiscoveryProbeResult(host: host, latencyMs: latencyMs)
    }

    nonisolated private static func checkReachability(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }

            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            let connection = NWConnection(to: endpoint, using: .tcp)
            let queue = DispatchQueue(label: "com.vivy.vvterm.discovery.probe.\(host)")
            var completed = false

            let complete: (Bool) -> Void = { ready in
                guard !completed else { return }
                completed = true
                continuation.resume(returning: ready)
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    complete(true)
                case .failed, .cancelled:
                    complete(false)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                complete(false)
            }

            connection.start(queue: queue)
        }
    }

    nonisolated static func localSubnetCandidates() -> [String] {
        var interfacePointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfacePointer) == 0, let first = interfacePointer else {
            return []
        }
        defer { freeifaddrs(interfacePointer) }

        var selectedAddress: UInt32?
        var selectedMask: UInt32?

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee

            guard let address = entry.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = entry.ifa_netmask else {
                pointer = entry.ifa_next
                continue
            }

            let flags = Int32(entry.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                pointer = entry.ifa_next
                continue
            }

            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }

            let hostOrderAddress = UInt32(bigEndian: ipv4.sin_addr.s_addr)
            let hostOrderMask = UInt32(bigEndian: mask.sin_addr.s_addr)
            guard hostOrderAddress != 0, hostOrderMask != 0 else {
                pointer = entry.ifa_next
                continue
            }

            selectedAddress = hostOrderAddress
            selectedMask = hostOrderMask

            if let name = String(validatingUTF8: entry.ifa_name), name.hasPrefix("en") {
                break
            }

            pointer = entry.ifa_next
        }

        guard let address = selectedAddress, let mask = selectedMask else {
            return []
        }

        return enumerateHosts(address: address, netmask: mask)
    }

    nonisolated private static func enumerateHosts(address: UInt32, netmask: UInt32) -> [String] {
        let prefixLength = netmask.nonzeroBitCount

        if prefixLength < 24 {
            let sliceMask: UInt32 = 0xFFFFFF00
            let sliceNetwork = address & sliceMask
            return hosts(in: sliceNetwork, broadcast: sliceNetwork | 0x000000FF, excluding: address)
        }

        let network = address & netmask
        let broadcast = network | ~netmask
        return hosts(in: network, broadcast: broadcast, excluding: address)
    }

    nonisolated private static func hosts(
        in network: UInt32,
        broadcast: UInt32,
        excluding currentAddress: UInt32
    ) -> [String] {
        guard broadcast > network + 1 else { return [] }

        let start = network + 1
        let end = broadcast - 1
        guard end >= start else { return [] }

        var result: [String] = []
        result.reserveCapacity(Int(end - start + 1))

        for ip in start...end where ip != currentAddress {
            result.append(ipv4String(fromHostOrderAddress: ip))
        }
        return result
    }

    nonisolated private static func ipv4String(fromHostOrderAddress address: UInt32) -> String {
        var networkOrderAddress = in_addr(s_addr: address.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let pointer = inet_ntop(
            AF_INET,
            &networkOrderAddress,
            &buffer,
            socklen_t(INET_ADDRSTRLEN)
        )
        return pointer == nil ? "" : String(cString: buffer)
    }

    nonisolated private static func sanitizedLocalHostName(from serviceName: String) -> String {
        let normalized = serviceName
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .lowercased()
        return normalized.isEmpty ? serviceName : normalized
    }
}

// MARK: - NetServiceBrowserDelegate

extension LocalSSHDiscoveryService: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let scanID = browserScanIDs[ObjectIdentifier(browser)]
        guard isCurrentScan(scanID) else { return }
        let errorCode = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        // Policy denied values seen from local-network restricted states.
        if errorCode == -65570 || errorCode == -72008 {
            emit(.permissionDenied, scanID: scanID)
        }
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let scanID = browserScanIDs[ObjectIdentifier(browser)]
        guard isCurrentScan(scanID) else { return }
        let key = "\(service.name)|\(service.type)|\(service.domain)"
        guard seenServices.insert(key).inserted else { return }

        service.delegate = self
        servicesByName[key] = service
        serviceScanIDs[ObjectIdentifier(service)] = scanID
        service.resolve(withTimeout: dependencies.serviceResolveTimeout)
    }
}

// MARK: - NetServiceDelegate

extension LocalSSHDiscoveryService: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let scanID = serviceScanIDs[ObjectIdentifier(sender)]
        guard isCurrentScan(scanID) else { return }
        let hostName = sender.hostName?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedHost: String
        if let hostName, !hostName.isEmpty {
            resolvedHost = hostName
        } else {
            let fallback = Self.sanitizedLocalHostName(from: sender.name)
            resolvedHost = "\(fallback).local"
        }

        let port = sender.port > 0 ? sender.port : 22
        let discovered = DiscoveredSSHHost(
            displayName: sender.name.isEmpty ? resolvedHost : sender.name,
            host: resolvedHost,
            port: port,
            sources: [.bonjour]
        )
        emit(.hostFound(discovered), scanID: scanID)

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        serviceScanIDs[ObjectIdentifier(sender)] = nil
        sender.stop()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let scanID = serviceScanIDs[ObjectIdentifier(sender)]
        guard isCurrentScan(scanID) else { return }
        let fallback = Self.sanitizedLocalHostName(from: sender.name)
        let fallbackHost = "\(fallback).local"
        let port = sender.port > 0 ? sender.port : 22
        let discovered = DiscoveredSSHHost(
            displayName: sender.name.isEmpty ? fallbackHost : sender.name,
            host: fallbackHost,
            port: port,
            sources: [.bonjour]
        )
        emit(.hostFound(discovered), scanID: scanID)

        let key = "\(sender.name)|\(sender.type)|\(sender.domain)"
        servicesByName[key] = nil
        serviceScanIDs[ObjectIdentifier(sender)] = nil
        sender.stop()
    }
}
