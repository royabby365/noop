import Foundation

actor RepositoryStore {
    private var store: WhoopStore?
    private let deviceId: String
    private var computedDeviceId: String { deviceId + "-noop" }

    init(deviceId: String) { self.deviceId = deviceId }

    func ensureStore() throws -> WhoopStore {
        if let store = store { return store }
        let path = try StorePaths.defaultDatabasePath()
        let s = try WhoopStore(path: path)
        try s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        self.store = s
        return s
    }
    
    // Fetch methods moved here
    func fetchDailyMetrics(from: String, to: String) async throws -> (imported: [DailyMetric], computed: [DailyMetric], apple: [DailyMetric]) {
        let store = try ensureStore()
        return (
            (try? await store.dailyMetrics(deviceId: deviceId, from: from, to: to)) ?? [],
            (try? await store.dailyMetrics(deviceId: computedDeviceId, from: from, to: to)) ?? [],
            (try? await store.dailyMetrics(deviceId: Repository.appleHealthSource, from: from, to: to)) ?? []
        )
    }
    
    func fetchSleep(from: Int, to: Int) async throws -> (imported: [CachedSleepSession], computed: [CachedSleepSession]) {
        let store = try ensureStore()
        return (
            (try? await store.sleepSessions(deviceId: deviceId, from: from, to: to, limit: Thresholds.maxSleepSessionsPerQuery)) ?? [],
            (try? await store.sleepSessions(deviceId: computedDeviceId, from: from, to: to, limit: Thresholds.maxSleepSessionsPerQuery)) ?? []
        )
    }
}
