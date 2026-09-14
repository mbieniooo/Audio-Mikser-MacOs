import Foundation

/// Per-app levels, persisted in UserDefaults as one JSON blob keyed by AppGroupKey.raw.
public final class Settings {
    public static let levelsKey = "appLevels"
    private let defaults: UserDefaults
    public private(set) var levels: [String: AppLevel] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    public func load() {
        guard let data = defaults.data(forKey: Self.levelsKey),
              let decoded = try? JSONDecoder().decode([String: AppLevel].self, from: data) else {
            levels = [:]
            return
        }
        levels = decoded
    }

    public func level(for key: AppGroupKey) -> AppLevel { levels[key.raw] ?? .full }

    public func set(_ level: AppLevel, for key: AppGroupKey) {
        if level.isFull { levels.removeValue(forKey: key.raw) } else { levels[key.raw] = level }
        save()
    }

    public func removeAll() {
        levels = [:]
        save()
    }

    private func save() {
        if levels.isEmpty {
            defaults.removeObject(forKey: Self.levelsKey)
        } else if let data = try? JSONEncoder().encode(levels) {
            defaults.set(data, forKey: Self.levelsKey)
        }
    }
}
