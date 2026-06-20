import Foundation

actor SSHAuthenticationGate {
    static let shared = SSHAuthenticationGate()

    private var activeKeys: Set<String> = []
    private var waitersByKey: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withExclusiveAccess<T>(
        for key: String,
        operation: () async throws -> T
    ) async rethrows -> T {
        await acquire(key)
        do {
            let result = try await operation()
            release(key)
            return result
        } catch {
            release(key)
            throw error
        }
    }

    private func acquire(_ key: String) async {
        if activeKeys.insert(key).inserted {
            return
        }

        await withCheckedContinuation { continuation in
            waitersByKey[key, default: []].append(continuation)
        }
    }

    private func release(_ key: String) {
        guard var waiters = waitersByKey[key], !waiters.isEmpty else {
            activeKeys.remove(key)
            return
        }

        let next = waiters.removeFirst()
        if waiters.isEmpty {
            waitersByKey.removeValue(forKey: key)
        } else {
            waitersByKey[key] = waiters
        }
        next.resume()
    }
}
