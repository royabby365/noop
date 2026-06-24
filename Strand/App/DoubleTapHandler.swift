import Foundation

/// Handles physical double-tap gestures on the strap and the resulting actions.
/// Manages moments, sleep marks, and Mac action execution.
@MainActor
final class DoubleTapHandler: ObservableObject {
    // MARK: - Published State
    
    @Published var moments: [Date] = []
    @Published var sleepMarks: [Date] = []
    
    // MARK: - Dependencies
    
    private let behavior: BehaviorStore
    private let live: LiveState
    private let buzz: (UInt8) -> Void
    private let log: (String) -> Void
    private let runMacAction: (MacActionKind, String) -> Void
    private let markSleepMetric: (Date) -> Void
    
    // MARK: - Internal State
    
    private var lastDoubleTapAt: Date = .distantPast
    
    // MARK: - Init
    
    init(
        behavior: BehaviorStore,
        live: LiveState,
        buzz: @escaping (UInt8) -> Void,
        log: @escaping (String) -> Void,
        runMacAction: @escaping (MacActionKind, String) -> Void,
        markSleepMetric: @escaping (Date) -> Void
    ) {
        self.behavior = behavior
        self.live = live
        self.buzz = buzz
        self.log = log
        self.runMacAction = runMacAction
        self.markSleepMetric = markSleepMetric
        
        // Load persisted state
        loadPersistedState()
        
        // Set up live state callbacks
        live.onDoubleTap = { [weak self] in self?.handleDoubleTap() }
        live.onWristChange = { [weak self] worn in self?.handleWristChange(worn) }
    }
    
    // MARK: - Public API
    
    func markMoment(at date: Date = Date()) {
        moments.append(date)
        if moments.count > 500 { moments.removeFirst(moments.count - 500) }
        UserDefaults.standard.set(moments.map(\.timeIntervalSince1970), forKey: "moments")
        buzz(1)
        log("Moment marked")
    }
    
    func markSleep(at date: Date = Date()) {
        sleepMarks.append(date)
        if sleepMarks.count > 500 { sleepMarks.removeFirst(sleepMarks.count - 500) }
        UserDefaults.standard.set(sleepMarks.map(\.timeIntervalSince1970), forKey: "sleepMarks")
        buzz(1)
        
        let hhmm = DateFormatter()
        hhmm.locale = Locale(identifier: "en_US_POSIX")
        hhmm.dateFormat = "HH:mm"
        log("Sleep mark @ \(hhmm.string(from: date))")
        
        // Also persist as typed metric-series row
        markSleepMetric(date)
    }
    
    // MARK: - Internal Handlers
    
    private func handleDoubleTap() {
        let now = Date()
        guard now.timeIntervalSince(lastDoubleTapAt) > 1.2 else { return }
        lastDoubleTapAt = now
        
        log("Double-tap → \(behavior.doubleTapAction.label)")
        runMacAction(behavior.doubleTapAction, behavior.doubleTapShortcut)
    }
    
    private func handleWristChange(_ worn: Bool) {
        if worn {
            if !behavior.wristOnShortcut.isEmpty { 
                runMacAction(.runShortcut, behavior.wristOnShortcut) 
            }
        } else {
            #if os(macOS)
            if behavior.autoLockOnWristOff {
                runMacAction(.lockScreen, "")
            }
            #endif
            if !behavior.wristOffShortcut.isEmpty { 
                runMacAction(.runShortcut, behavior.wristOffShortcut) 
            }
        }
    }
    
    // MARK: - Persistence
    
    private func loadPersistedState() {
        moments = (UserDefaults.standard.array(forKey: "moments") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
        sleepMarks = (UserDefaults.standard.array(forKey: "sleepMarks") as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
    }
    
    // MARK: - Static Helpers
    
    static var localeUses24HourClock: Bool {
        let fmt = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h"
        return !fmt.contains("a")
    }
}