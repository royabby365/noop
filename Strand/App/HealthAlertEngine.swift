import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Evaluates illness/strain early-warning signals from daily metrics and journal confounders.
/// Runs the IllnessSignalEngine and publishes the result + legacy healthAlert banner.
@MainActor
final class HealthAlertEngine: ObservableObject {
    // MARK: - Published State
    
    @Published var healthAlert: String?
    @Published var illnessSignal: IllnessSignalEngine.Result?
    
    // MARK: - Dependencies
    
    private let behavior: BehaviorStore
    private let repo: Repository
    private let log: (String) -> Void
    
    // MARK: - Init
    
    init(behavior: BehaviorStore, repo: Repository, log: @escaping (String) -> Void) {
        self.behavior = behavior
        self.repo = repo
        self.log = log
    }
    
    // MARK: - Public API
    
    /// Called when daily metrics change (from repo.$days)
    func evaluateIllness(_ days: [DailyMetric]) {
        guard behavior.illnessWatch, days.count >= 14 else {
            healthAlert = nil
            illnessSignal = nil
            return
        }
        
        Task { [weak self] in
            guard let self else { return }
            await self.applyIllnessSignal(days)
        }
    }
    
    // MARK: - Internal
    
    private func applyIllnessSignal(_ days: [DailyMetric]) async {
        // Read recent journal entries for confounder context
        let recentDays = Set(days.suffix(2).map(\.day))
        let journal = await repo.journalEntries(days: 7)
        
        var ctxAlcohol = false
        var ctxHardWorkout = false
        var ctxAlreadyUnwell = false
        
        for e in journal where e.answeredYes && recentDays.contains(e.day) {
            let q = e.question.lowercased()
            if q.contains("alcohol") || q.contains("drink") { ctxAlcohol = true }
            if q.contains("workout") || q.contains("train") || q.contains("exercise") { ctxHardWorkout = true }
            if q.contains("sick") || q.contains("ill") || q.contains("unwell") { ctxAlreadyUnwell = true }
        }
        
        await MainActor.run {
            self.processEngineResult(
                days: days,
                alcohol: ctxAlcohol,
                hardOrLateWorkout: ctxHardWorkout,
                alreadyUnwell: ctxAlreadyUnwell
            )
        }
    }
    
    private func processEngineResult(
        days: [DailyMetric],
        alcohol: Bool,
        hardOrLateWorkout: Bool,
        alreadyUnwell: Bool
    ) {
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))
        
        func mean(_ vals: [Double]) -> Double? {
            vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
        }
        func rm(_ kp: (DailyMetric) -> Double?) -> Double? {
            mean(recent.compactMap(kp))
        }
        
        func signal(_ kp: (DailyMetric) -> Double?, cfgKey: String, illnessUp: Bool) -> (IllnessSignalEngine.SignalReading, Bool)? {
            guard let cfg = Baselines.metricCfg[cfgKey], let recentMean = rm(kp) else { return nil }
            let state = Baselines.foldHistory(base.map(kp), cfg: cfg)
            guard state.usable else { return (IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false), false) }
            let dev = Baselines.deviation(recentMean, state: state)
            let z = illnessUp ? dev.z : -dev.z
            return (IllnessSignalEngine.SignalReading(zIllnessward: z), state.trusted)
        }
        
        let rhr = signal({ $0.restingHr.map(Double.init) }, cfgKey: "resting_hr", illnessUp: true)
        let hrv = signal({ $0.avgHrv }, cfgKey: "hrv", illnessUp: false)
        let resp = signal({ $0.respRateBpm }, cfgKey: "resp", illnessUp: true)
        
        var skin: (IllnessSignalEngine.SignalReading, Bool)? = nil
        if let recentSkin = rm({ $0.skinTempDevC }) {
            let z = recentSkin / 0.3
            skin = (IllnessSignalEngine.SignalReading(zIllnessward: z), true)
        }
        
        let result = IllnessSignalEngine.evaluate(
            signals: (rhr: rhr, hrv: hrv, resp: resp, skin: skin),
            confounder: (alcohol: alcohol, hardOrLateWorkout: hardOrLateWorkout, alreadyUnwell: alreadyUnwell)
        )
        
        illnessSignal = result
        healthAlert = result.bannerText
        
        if let alert = healthAlert {
            log("Health alert: \(alert)")
        }
    }
}
