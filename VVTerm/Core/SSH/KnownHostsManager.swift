import Foundation
import os.log

final class KnownHostsManager: @unchecked Sendable {
    static let shared = KnownHostsManager()

    nonisolated struct Entry: Codable, Equatable, Sendable {
        let host: String
        let port: Int
        let fingerprint: String
        let keyType: Int
        let addedAt: Date
        var lastSeenAt: Date

        var id: String { "\(host):\(port)" }
    }

    private let storageKey = "vvterm.knownHosts"
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "KnownHosts")
    private let lock = NSLock()

    private init() {}

    func entry(for host: String, port: Int) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[hostKey(host: host, port: port)]
    }

    func updateSeen(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        if var entry = entries[key] {
            entry.lastSeenAt = Date()
            entries[key] = entry
            saveAll(entries)
        }
    }

    func save(entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        entries[entry.id] = entry
        saveAll(entries)
    }

    func remove(host: String, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        guard entries.removeValue(forKey: key) != nil else { return }
        saveAll(entries)
        logger.info("Removed known host entry for \(host):\(port)")
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
        logger.info("Removed all known host entries")
    }

    func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return loadAll().values.sorted { lhs, rhs in
            if lhs.host == rhs.host {
                return lhs.port < rhs.port
            }
            return lhs.host < rhs.host
        }
    }

    private func hostKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private func loadAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private func saveAll(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            logger.error("Failed to encode known hosts store")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

actor KnownHostsStore {
    static let shared = KnownHostsStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "KnownHosts")

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "vvterm.knownHosts"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func entry(for host: String, port: Int) -> KnownHostsManager.Entry? {
        loadAll()[hostKey(host: host, port: port)]
    }

    func updateSeen(host: String, port: Int) {
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        guard var entry = entries[key] else { return }
        entry.lastSeenAt = Date()
        entries[key] = entry
        saveAll(entries)
    }

    func save(entry: KnownHostsManager.Entry) {
        var entries = loadAll()
        entries[entry.id] = entry
        saveAll(entries)
    }

    func remove(host: String, port: Int) {
        var entries = loadAll()
        let key = hostKey(host: host, port: port)
        guard entries.removeValue(forKey: key) != nil else { return }
        saveAll(entries)
        logger.info("Removed known host entry for \(host):\(port)")
    }

    func removeAll() {
        defaults.removeObject(forKey: storageKey)
        logger.info("Removed all known host entries")
    }

    func entries() -> [KnownHostsManager.Entry] {
        loadAll().values.sorted { lhs, rhs in
            if lhs.host == rhs.host {
                return lhs.port < rhs.port
            }
            return lhs.host < rhs.host
        }
    }

    private func hostKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private func loadAll() -> [String: KnownHostsManager.Entry] {
        guard let data = defaults.data(forKey: storageKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: KnownHostsManager.Entry].self, from: data)) ?? [:]
    }

    private func saveAll(_ entries: [String: KnownHostsManager.Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else {
            logger.error("Failed to encode known hosts store")
            return
        }
        defaults.set(data, forKey: storageKey)
    }
}

nonisolated enum KnownHostVerificationResult: Equatable, Sendable {
    case trusted(fingerprint: String)
    case newHost(fingerprint: String)
    case changed(knownFingerprint: String, presentedFingerprint: String)
}

nonisolated struct KnownHostVerificationService: Sendable {
    let store: KnownHostsStore

    init(store: KnownHostsStore = .shared) {
        self.store = store
    }

    func verify(
        host: String,
        port: Int,
        fingerprint: String,
        keyType: Int
    ) async throws -> KnownHostVerificationResult {
        if let entry = await store.entry(for: host, port: port) {
            guard entry.fingerprint == fingerprint else {
                return .changed(
                    knownFingerprint: entry.fingerprint,
                    presentedFingerprint: fingerprint
                )
            }
            await store.updateSeen(host: host, port: port)
            return .trusted(fingerprint: fingerprint)
        }

        return .newHost(fingerprint: fingerprint)
    }

    func trust(
        host: String,
        port: Int,
        fingerprint: String,
        keyType: Int
    ) async {
        let entry = KnownHostsManager.Entry(
            host: host,
            port: port,
            fingerprint: fingerprint,
            keyType: keyType,
            addedAt: Date(),
            lastSeenAt: Date()
        )
        await store.save(entry: entry)
    }
}
