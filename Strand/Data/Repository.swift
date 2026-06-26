import Foundation
import Combine
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign

// MARK: - Core Support Models
public struct ImportedSleepFigures: Equatable {
    public var performancePct: Double?   // "sleep_performance", 0–100
    public var consistencyPct: Double?   // "sleep_consistency", 0–100
    public var needMin: Double?          // "sleep_need_min", minutes
    public var debtMin: Double?          // "sleep_debt_min", minutes
    public init() {}
}

public struct ResolvedMetricPoint: Equatable, Sendable {
    public let day: String
    public let value: Double
    public let source: String
    public let sourceKey: String
}

public struct MetricSourceCandidate: Equatable, Hashable, Sendable {
    public let source: String
    public let key: String
}

public struct MetricSeriesResolution: Equatable, Sendable {
    public let requestedSource: String
    public let candidates: [MetricSourceCandidate]
    public let points: [ResolvedMetricPoint]
}

public enum DailyMetricSource: Equatable {
    case whoopImport
    case noopComputed
    case appleHealth
    case localCache
}

public struct SourcedDailyMetric: Equatable {
    public let metric: DailyMetric
    public let source: DailyMetricSource
}

// MARK: - Main Actor Read Model Wrapper
@MainActor
public final class Repository: ObservableObject {
    private let store: RepositoryStore
    
    @Published public var days: [DailyMetric] = []
    @Published public var sleeps: [CachedSleepSession] = []
    @Published public var importedSleep: [String: ImportedSleepFigures] = [:]
    @Published public var loaded = false
    @Published public private(set) var freshness: RepositoryFreshness = .empty
    @Published public private(set) var vitalRows: [SourcedDailyMetric] = []
    @Published public private(set) var refreshSeq = 0
    
    private var refreshGen = 0
    public let deviceId: String

    nonisolated public static let appleHealthSource = "apple-health"
    public static let whoopSource = "my-whoop"
    public static let healthConnectSource = "health-connect"

    public init(deviceId: String) {
        self.deviceId = deviceId
        self.store = RepositoryStore(deviceId: deviceId)
    }

    public var today: DailyMetric? {
        let now = Date()
        return RepositoryLogic.resolveToday(
            days: days,
            logicalKey: Repository.logicalDayKey(now),
            localKey: Repository.localDayKey(now)
        )
    }

    public var week: [DailyMetric] {
        let cutoff = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
        return days.filter { $0.day >= cutoff }
    }

    public func refresh(days nDays: Int = Thresholds.maxHistoryDaysForRescore) async {
        refreshGen &+= 1
        let myGen = refreshGen
        
        let now = Date()
        let fromDay = Self.dayString(now.addingTimeInterval(-Double(nDays) * 86_400))
        let toDay = Self.dayString(now.addingTimeInterval(86_400))
        
        do {
            let (imported, computed, apple, impSleep, compSleep) = try await store.fetchMetricsAndCaches(from: fromDay, to: toDay)
            
            let results = await Task.detached(priority: .userInitiated) {
                let userEdited = RepositoryLogic.userEditedDays(compSleep)
                return (
                    mergedDays: RepositoryLogic.mergeDaily(imported: imported, computed: computed, userEditedDays: userEdited),
                    mergedSleeps: RepositoryLogic.mergeSleep(imported: impSleep, computed: compSleep),
                    sourced: RepositoryLogic.sourceRows(imported: imported, computed: computed, apple: apple),
                    fresh: RepositoryLogic.computeFreshness(imported: imported, computed: computed, apple: apple, importedSleeps: impSleep, computedSleeps: compSleep)
                )
            }.value

            guard myGen == refreshGen else { return }
            
            self.days = results.mergedDays
            self.sleeps = results.mergedSleeps
            self.vitalRows = results.sourced
            self.freshness = results.fresh
            self.refreshSeq += 1
            self.loaded = true
            
        } catch {
            NSLog("Repository refresh failed: \(error)")
        }
    }

    // MARK: - Global Structural Date Engines
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    
    public static func localDayKey(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    public static func dayString(_ date: Date) -> String { dayKeyFormatter.string(from: date) }
    
    public static func logicalDayKey(_ now: Date) -> String {
        localDayKey(now.addingTimeInterval(-Double(Thresholds.logicalDayRolloverHour) * 3_600))
    }

    public func storeHandle() async -> WhoopStore? { try? await store.ensureStore() }
    public func checkpointForBackup() async -> Bool { 
        _ = try? await store.checkpointWAL()
        return true 
    }
}
