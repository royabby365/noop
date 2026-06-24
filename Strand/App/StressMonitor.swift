import Foundation
import StrandAnalytics

/// Monitors stress state using HRV (RR intervals) and the StressOnsetDetector.
/// Handles both the legacy experimental nudge and the v5 L3 closed-loop check-in.
@MainActor
final class StressMonitor: ObservableObject {
    // MARK: - Published State
    
    @Published var stressNudgeCenter: StressNudgeCenter
    
    // MARK: - Dependencies
    
    private let behavior: BehaviorStore
    private let live: LiveState
    private let buzz: (UInt8) -> Void
    private let log: (String) -> Void
    private var canBuzz: () -> Bool
    
    // MARK: - Internal State
    
    private var rrBuf: [Int] = []
    private var stressState = BiofeedbackPrefs.loadStressState()
    private var hrvBaseline: Double = 0
    private var lastStressBuzzAt: Date = .distantPast
    
    // MARK: - Init
    
    init(
        behavior: BehaviorStore,
        live: LiveState,
        buzz: @escaping (UInt8) -> Void,
        log: @escaping (String) -> Void,
        canBuzz: @escaping () -> Bool
    ) {
        self.behavior = behavior
        self.live = live
        self.buzz = buzz
        self.log = log
        self.canBuzz = canBuzz
        self.stressNudgeCenter = StressNudgeCenter()
    }
    
    // MARK: - Public API
    
    /// Called from ingestHR when new RR samples arrive
    func ingestRR(_ rr: [Int]) {
        guard !rr.isEmpty else { return }
        rrBuf.append(contentsOf: rr.filter { $0 > 300 && $0 < 2000 })
        if rrBuf.count > 120 { rrBuf.removeFirst(rrBuf.count - 120) }
        evaluateStress()
    }
    
    // MARK: - Stress Evaluation
    
    private func evaluateStress() {
        // ── Legacy experimental nudge (behavior.stressNudge)
        if behavior.stressNudge, live.bonded, live.worn, rrBuf.count >= 20 {
            let rmssd = Self.rmssd(Array(rrBuf.suffix(60)))
            if rmssd > 0 {
                hrvBaseline = hrvBaseline == 0 ? rmssd : hrvBaseline * 0.98 + rmssd * 0.02
                if let hr = live.heartRate, hr >= 55, hr <= 100 {
                    let now = Date()
                    if rmssd < hrvBaseline * 0.6, now.timeIntervalSince(lastStressBuzzAt) > 900 {
                        lastStressBuzzAt = now
                        buzz(1)
                        log("Stress nudge — take a paced breath")
                    }
                }
            }
        }
        
        // ── v5 L3 closed-loop check-in (StressOnsetDetector)
        let cfg = BiofeedbackPrefs.stressConfig()
        guard cfg.enabled, live.bonded, live.worn else { return }
        
        let decision = StressOnsetDetector.evaluate(
            rrBuffer: rrBuf,
            currentHR: live.heartRate.map(Double.init),
            recentMotionG: nil,
            sessionActive: stressNudgeCenter.pending != nil,
            state: stressState,
            config: cfg,
            nowSec: Int(Date().timeIntervalSince1970),
            tzOffsetSec: TimeZone.current.secondsFromGMT())
        
        stressState = decision.nextState
        BiofeedbackPrefs.saveStressState(decision.nextState)
        
        guard decision.shouldNudge else { return }
        if canBuzz() { buzz(UInt8(clamping: decision.buzzLoops)) }
        stressNudgeCenter.present(fastRMSSD: decision.fastRMSSD, baselineRMSSD: decision.baselineRMSSD)
        log("Stress check-in — HRV dipped while still")
    }
    
    // MARK: - Static Helpers
    
    static func rmssd(_ rr: [Int]) -> Double {
        guard rr.count >= 2 else { return 0 }
        var sum = 0.0
        var n = 0
        for i in 1..<rr.count {
            let d = Double(rr[i] - rr[i - 1])
            sum += d * d
            n += 1
        }
        return n > 0 ? (sum / Double(n)).squareRoot() : 0
    }
}