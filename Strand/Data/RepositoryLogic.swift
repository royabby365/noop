import Foundation

/// Pure logic for merging, resolving, and calculating state.
/// Stateless and non-isolated. Use this for Unit Tests.
enum RepositoryLogic {
    static func mergeDaily(imported: [DailyMetric], computed: [DailyMetric], userEditedDays: Set<String>) -> [DailyMetric] {
        // Implementation of your existing mergeDaily logic here
        // (Accepts arrays as inputs, returns array as output)
        return [] // Replace with your merge implementation
    }

    static func mergeSleep(imported: [CachedSleepSession], computed: [CachedSleepSession]) -> [CachedSleepSession] {
        // Implementation of mergeSleep logic
        return []
    }

    static func sourceRows(imported: [DailyMetric], computed: [DailyMetric], apple: [DailyMetric]) -> [SourcedDailyMetric] {
        // Implementation of sourceRows logic
        return []
    }

    static func computeFreshness(imported: [DailyMetric], computed: [DailyMetric], apple: [DailyMetric], 
                                 importedSleeps: [CachedSleepSession], computedSleeps: [CachedSleepSession]) -> RepositoryFreshness {
        // Implementation of freshness counts
        return RepositoryFreshness()
    }

    static func resolveToday(days: [DailyMetric], logicalKey: String, localKey: String) -> DailyMetric? {
        if localKey != logicalKey,
           let localRow = days.last(where: { $0.day == localKey && $0.totalSleepMin != nil }) {
            return localRow
        }
        return days.last(where: { $0.day == logicalKey })
    }
}
