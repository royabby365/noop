import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign

// MARK: - Supporting Data Types
struct ImportedSleepFigures: Equatable {
    var performancePct: Double?
    var consistencyPct: Double?
    var needMin: Double?
    var debtMin: Double?
}

struct ResolvedMetricPoint: Equatable, Sendable {
    let day: String; let value: Double; let source: String; let sourceKey: String
}

struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    let source: String; let key: String
}

struct MetricSeriesResolution: Equatable, Sendable {
    let requestedSource: String
    let candidates: [MetricSourceCandidate]
    let points: [ResolvedMetricPoint]
}

struct SourcedDailyMetric: Equatable {
    let metric: DailyMetric
    let source: DailyMetricSource
}

enum DailyMetricSource: Equatable {
    case whoopImport, noopComputed, appleHealth, localCache
}

// MARK: - Logic Engine (Non-Isolated)
/// Pure, stateless algorithms. This is thread-safe and unit-testable.
struct RepositoryLogic {
    static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }
    
    // Add your original mergeDaily, mergeSleep, sourceRows, and computeFreshness implementations here.
    // They are now pure functions taking inputs and returning outputs.
}

// MARK: - Database Service (Thread-Safe Actor)
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
    
    func checkpointWAL() async throws {
        try await store?.checkpointWAL()
    }
}

// MARK: - Repository (MainActor Wrapper)
@MainActor
final class Repository: ObservableObject {
    private let store: RepositoryStore
    
    @Published var days: [DailyMetric] = []
    @Published var sleeps: [CachedSleepSession] = []
    @Published var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published var loaded = false
    @Published private(set) var freshness: RepositoryFreshness = .empty
    @Published private(set) var vitalRows: [SourcedDailyMetric] = []
    @Published private(set) var refreshSeq = 0
    
    private var refreshGen = 0
    let deviceId: String

    // FIX: Use nonisolated to allow access from any thread
    nonisolated static let appleHealthSource = "apple-health"
    static let whoopSource = "my-whoop"
    static let healthConnectSource = "health-connect"

    init(deviceId: String) {
        self.deviceId = device
