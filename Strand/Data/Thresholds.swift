import Foundation

/// Centralized thresholds and configuration constants for NOOP.
/// Replaces magic numbers scattered across detectors, engines, and policies.
/// Keeping these in one place makes tuning easier and behavior more transparent.
enum Thresholds {
    
    // MARK: - BLE / Connection
    
    /// MarginalRadioDetector: consecutive arm-then-quick-timeout cycles before fallback
    static let marginalRadioTripThreshold = 2
    /// MarginalRadioDetector: timeout window after arming to count as "quick"
    static let marginalRadioQuickTimeoutWindow: TimeInterval = 20
    
    /// PostBondTimeoutLoopDetector: consecutive bond-then-quick-timeout cycles before surfacing re-pair guide
    static let postBondLoopTripThreshold = 2
    /// PostBondTimeoutLoopDetector: timeout window after bonding to count as "quick"
    static let postBondLoopQuickTimeoutWindow: TimeInterval = 8
    
    /// EmptySyncTracker: consecutive console-only completed syncs before clock-lost banner
    static let emptySyncTrackerThreshold = 3
    
    /// Whoop5EmptyOffloadTracker: consecutive empty 5/MG offloads before marking history-empty
    static let whoop5EmptyOffloadQuietThreshold = 2
    
    /// BackfillContinuation: max consecutive auto-continues per connection
    static let backfillContinuationMaxAutoContinues = 6
    /// BackfillContinuation: how far ahead strap must be (seconds) to continue
    static let backfillContinuationBehindGapSeconds = 300
    
    /// BackfillPolicy: minimum seconds between periodic offload triggers
    static let backfillPeriodicFloorSeconds = 900
    
    /// Keep-alive timer interval (re-arm realtime, poll battery)
    static let keepAliveIntervalSeconds = 30
    /// Periodic backfill timer interval
    static let backfillIntervalSeconds = 900
    
    /// Scan fallback delay (rotate between WHOOP families if none found)
    static let scanFallbackDelaySeconds: TimeInterval = 8
    
    /// Deep packet live cooldown (treat type-0x2F as trailing historical after backfill)
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    
    /// Inactivity lookback on each offload completion (seconds)
    static let inactivityLookbackSeconds = 4 * 3600
    
    /// StuckStrapDetector: seconds of frozen frontier before flagging
    static let stuckStrapAfterSeconds = 600
    /// StuckStrapDetector: gap threshold (seconds) to consider strap "behind"
    static let stuckStrapBehindGapSeconds = 300
    
    /// Max consecutive failed connect attempts before backing off
    static let maxFailedConnectAttempts = 5
    
    // MARK: - Analytics / Scoring
    
    /// Minimum nights for HRV baseline to be usable
    static let hrvBaselineMinNights = 3
    /// Recovery baseline window (days) for personal norms
    static let recoveryBaselineWindowDays = 28
    /// Max history days for effort rescore / timestamp heal
    static let maxHistoryDaysForRescore = 4000
    
    /// AnalyticsEngine: default analysis window (days)
    static let analyzeRecentDefaultDays = 21
    
    // MARK: - UI / Display
    
    /// Max history messages in AI Coach context window
    static let aiCoachMaxHistoryMessages = 10
    
    /// Backfill drain batch size (frames per main-actor slice)
    static let backfillDrainBatchSize = 12
    
    /// Log time format for strap log (HH:mm:ss)
    static let logTimeFormat = "HH:mm:ss"
    
    // MARK: - HR Smoothing
    
    /// HR smoothing window duration (seconds)
    static let hrSmoothingWindowSeconds: TimeInterval = 10
    /// Max samples in HR smoothing window
    static let hrSmoothingMaxSamples = 40
    /// Plausible HR range (bpm)
    static let hrPlausibleRange = 30...220
    
    // MARK: - Smart Alarm
    
    /// Logical day rollover hour (04:00 local)
    static let logicalDayRolloverHour = 4
    
    // MARK: - Battery
    
    /// Low battery warning threshold (%)
    static let batteryLowThreshold = 20
    /// Full charge notification threshold (%)
    static let batteryFullThreshold = 95
    
    // MARK: - Stress / Biofeedback
    
    /// Stress onset detector: RR buffer size
    static let stressRRBufferSize = 120
    /// Stress onset detector: minimum RR samples to evaluate
    static let stressMinRRSamples = 30
    
    // MARK: - Import / Sync
    
    /// Max sleep sessions to fetch in one query
    static let maxSleepSessionsPerQuery = 4000
    /// Max daily metrics to fetch in one query
    static let maxDailyMetricsPerQuery = 4000
    
    // MARK: - Demo / Testing
    
    /// Demo seeder: synthetic data days
    static let demoSeedDays = 30
}