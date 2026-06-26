import Foundation
import WhoopStore
import WhoopProtocol

public actor RepositoryStore {
    private var store: WhoopStore?
    private let deviceId: String
    private var computedDeviceId: String { deviceId + "-noop" }

    public init(deviceId: String) { self.deviceId = deviceId }

    public func ensureStore() throws -> WhoopStore {
        if let store = store { return store }
        let path = try StorePaths.defaultDatabasePath()
        let s = try WhoopStore(path: path)
        try s.upsertDevice(id: deviceId, mac: nil, name: "WHOOP")
        self.store = s
        return s
    }
    
    public func fetchMetricsAndCaches(from fromDay: String, to toDay: String) async throws -> (
        imported: [DailyMetric],
        computed: [DailyMetric],
        apple: [DailyMetric],
        impSleep: [CachedSleepSession],
        compSleep: [CachedSleepSession]
    ) {
        let db = try ensureStore()
        
        let imported = (try? await db.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)) ?? []
        let computed = (try? await db.dailyMetrics(deviceId: computedDeviceId, from: fromDay, to: toDay)) ?? []
        let apple = (try? await db.dailyMetrics(deviceId: "apple-health", from: fromDay, to: toDay)) ?? []
        
        let nowTs = Int(Date().timeIntervalSince1970)
        let lo = nowTs - (400 * 86_400) // matches history scan bounds safely
        let hi = nowTs + 86_400
        
        let impSleep = (try? await db.sleepSessions(deviceId: deviceId, from: lo, to: hi, limit: Thresholds.maxSleepSessionsPerQuery)) ?? []
        let compSleep = (try? await db.sleepSessions(deviceId: computedDeviceId, from: lo, to: hi, limit: Thresholds.maxSleepSessionsPerQuery)) ?? []
        
        return (imported, computed, apple, impSleep, compSleep)
    }
    
    public func checkpointWAL() throws {
        // structural backup logic wrapper
    }
}
