import Foundation
import Combine

/// Manages the strap's firmware smart alarm: arming, disarming, daily re-arm, and firing callbacks.
/// Extracted from AppModel to separate concerns.
@MainActor
final class AlarmManager: ObservableObject {
    // MARK: - Published State
    
    @Published var nextAlarmDate: Date?
    
    // MARK: - Dependencies
    
    private let behavior: BehaviorStore
    private let live: LiveState
    private let ble: BLEManager
    private let log: (String) -> Void
    private let postSmartAlarm: () -> Void
    
    // MARK: - Internal
    
    private var rearmTimer: Timer?
    
    // MARK: - Init
    
    init(
        behavior: BehaviorStore,
        live: LiveState,
        ble: BLEManager,
        log: @escaping (String) -> Void,
        postSmartAlarm: @escaping () -> Void
    ) {
        self.behavior = behavior
        self.live = live
        self.ble = ble
        self.log = log
        self.postSmartAlarm = postSmartAlarm
        
        setupBindings()
        scheduleDailyRearm()
    }
    
    // MARK: - Setup
    
    private func setupBindings() {
        // Re-arm on (re)bond
        live.$bonded
            .removeDuplicates()
            .sink { [weak self] bonded in
                guard let self, bonded, self.behavior.smartAlarmEnabled else { return }
                self.applySmartAlarm()
            }
            .store(in: &cancellables)
        
        // Handle strap alarm fired callback
        live.onSmartAlarmFired = { [weak self] in
            guard let self, self.behavior.smartAlarmEnabled else { return }
            self.postSmartAlarm()
            self.applySmartAlarm()
        }
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Public API
    
    /// Apply or clear the smart alarm based on current settings
    func applySmartAlarm() {
        guard behavior.smartAlarmEnabled else { 
            ble.disableStrapAlarm()
            nextAlarmDate = nil
            return 
        }
        
        guard let next = Self.nextSmartAlarmDate(
            minutes: behavior.smartAlarmMinutes,
            weekdays: behavior.smartAlarmWeekdays
        ) else {
            ble.disableStrapAlarm()
            nextAlarmDate = nil
            return
        }
        
        nextAlarmDate = next
        ble.armStrapAlarm(at: next)
        log("Smart alarm armed for \(next)")
    }
    
    /// Disable the smart alarm
    func disable() {
        behavior.smartAlarmEnabled = false
        ble.disableStrapAlarm()
        nextAlarmDate = nil
        rearmTimer?.invalidate()
        rearmTimer = nil
    }
    
    // MARK: - Daily Re-arm
    
    private func scheduleDailyRearm() {
        rearmTimer?.invalidate()
        
        let cal = Calendar.current
        guard let firstFire = cal.nextDate(after: Date(),
                                           matching: DateComponents(hour: 0, minute: 1, second: 0),
                                           matchingPolicy: .nextTime) else { return }
        
        let timer = Timer(fire: firstFire, interval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applySmartAlarm() }
        }
        
        RunLoop.main.add(timer, forMode: .common)
        rearmTimer = timer
    }
    
    // MARK: - Static Helpers
    
    /// Compute the next fire date for the smart alarm, honouring weekday selection
    nonisolated static func nextSmartAlarmDate(
        minutes: Int,
        weekdays: Set<Int>,
        from now: Date = Date(),
        calendar cal: Calendar = .current
    ) -> Date? {
        let valid = weekdays.filter { (1...7).contains($0) }
        if !weekdays.isEmpty && valid.isEmpty { return nil }
        
        let hour = minutes / 60
        let minute = minutes % 60
        
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: now),
                  let fire = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
            else { continue }
            if fire <= now { continue }
            if weekdays.isEmpty { return fire }
            if valid.contains(cal.component(.weekday, from: fire)) { return fire }
        }
        return nil
    }
}