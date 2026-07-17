import Foundation

enum SharedSnapshotStore {
    static let suiteName = "group.ad.neko.when"
    private static let snapshotsKey = "usageSnapshots.v1"

    static func load() -> [UsageSnapshot] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: snapshotsKey) else { return [] }
        return (try? JSONDecoder().decode([UsageSnapshot].self, from: data)) ?? []
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: snapshotsKey)
    }
}
