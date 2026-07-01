import Foundation

final class TmuxSessionBindingStore {
    private let defaults: UserDefaults
    private let key = "tmuxSessionBindings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allBindings() -> [String: TmuxSessionBinding] {
        guard let data = defaults.data(forKey: key),
              let map = try? JSONDecoder().decode([String: TmuxSessionBinding].self, from: data) else {
            return [:]
        }
        return map
    }

    func binding(for entityId: UUID) -> TmuxSessionBinding? {
        allBindings()[entityId.uuidString]
    }

    func set(_ binding: TmuxSessionBinding, for entityId: UUID) {
        var map = allBindings()
        map[entityId.uuidString] = binding
        save(map)
    }

    func remove(for entityId: UUID) {
        var map = allBindings()
        map.removeValue(forKey: entityId.uuidString)
        save(map)
    }

    private func save(_ map: [String: TmuxSessionBinding]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: key)
    }
}
