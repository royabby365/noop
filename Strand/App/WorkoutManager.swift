import Foundation
import Combine
import WhoopStore
import StrandAnalytics

/// Manages manual workout tracking: start/end, GPS route recording, persistence, and rehydration.
/// Extracted from AppModel to reduce its responsibilities.
@MainActor
final class WorkoutManager: ObservableObject {
    // MARK: - Published State
    
    @Published var activeWorkout: ActiveWorkout?
    @Published var lastWorkout: WorkoutRow?
    @Published var activeWorkoutIsGps = false
    
    // MARK: - Dependencies
    
    private let repo: Repository
    private let profile: ProfileStore
    private let gpsRecorder: GpsWorkoutRecorder
    private let buzz: (UInt8) -> Void
    private let deviceId: String
    private let log: (String) -> Void
    
    // MARK: - Internal State
    
    private var realtimeWanters = 0
    private var startRealtimeHR: () -> Void
    private var stopRealtimeHR: () -> Void
    
    // MARK: - Init
    
    init(
        repo: Repository,
        profile: ProfileStore,
        gpsRecorder: GpsWorkoutRecorder,
        deviceId: String,
        buzz: @escaping (UInt8) -> Void,
        log: @escaping (String) -> Void,
        startRealtimeHR: @escaping () -> Void,
        stopRealtimeHR: @escaping () -> Void
    ) {
        self.repo = repo
        self.profile = profile
        self.gpsRecorder = gpsRecorder
        self.deviceId = deviceId
        self.buzz = buzz
        self.log = log
        self.startRealtimeHR = startRealtimeHR
        self.stopRealtimeHR = stopRealtimeHR
        
        // Rehydrate any in-flight workout from previous session
        rehydrateActiveWorkout()
    }
    
    // MARK: - Public API
    
    /// Begin a manually-tracked workout for the named sport.
    func startWorkout(sport: String = WorkoutCatalog.defaultSportName) {
        guard activeWorkout == nil else { return }
        lastWorkout = nil
        
        let name = sport.trimmingCharacters(in: .whitespaces)
        let resolved = name.isEmpty ? WorkoutCatalog.defaultSportName : name
        let started = Date()
        
        activeWorkout = ActiveWorkout(start: started, sport: resolved)
        
        // Arm GPS for distance sports
        activeWorkoutIsGps = WorkoutCatalog.sport(named: resolved)?.isDistanceSport ?? false
        if activeWorkoutIsGps {
            gpsRecorder.start(startMs: Int64(started.timeIntervalSince1970 * 1000))
        }
        
        // Make durable from first instant
        persistActiveWorkout()
        
        // Arm realtime HR if not already armed
        startRealtimeHR()
        
        buzz(1)
        log("Workout started: \(resolved)")
    }
    
    /// Finish the active workout: finalize GPS route, score HR window, save as WorkoutRow.
    func endWorkout() {
        guard let w = activeWorkout else { return }
        activeWorkout = nil
        let wasGps = activeWorkoutIsGps
        activeWorkoutIsGps = false
        
        // Drop durable snapshot immediately
        ActiveWorkoutPersistence.clear()
        
        var route: WorkoutRoute?
        if wasGps {
            gpsRecorder.stop()
            route = gpsRecorder.capturedRoute()
        }
        
        let samples = w.samples
        
        // Save when there's HR window OR real GPS route
        guard samples.count >= 2 || route != nil else { 
            lastWorkout = nil 
            stopRealtimeHR()
            return 
        }
        
        let end = Date()
        let avg = samples.isEmpty ? nil
            : Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
        let peak = samples.map(\.bpm).max()
        let strain = samples.count >= 2
            ? StrainScorer.strain(samples, maxHR: Double(profile.hrMax), sex: profile.sex) : nil
        
        // Estimate calories from captured HR window
        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex)
        let kcal = samples.count >= 2
            ? Calories.estimateBoutCalories(samples, profile: up, hrmax: Double(profile.hrMax), restingHR: nil).0
            : 0
        
        let startTs = Int(w.start.timeIntervalSince1970)
        let row = WorkoutRow(
            startTs: startTs, endTs: Int(end.timeIntervalSince1970),
            sport: w.sport, source: "manual", durationS: end.timeIntervalSince(w.start),
            energyKcal: kcal > 0 ? kcal : nil, avgHr: avg, maxHr: peak, strain: strain,
            distanceM: route?.distanceM, zonesJSON: nil, notes: nil)
        
        // Persist route polyline
        if let route { RouteStore.store(route, startTs: startTs, sport: w.sport) }
        
        lastWorkout = row
        buzz(2)
        log("Workout ended: \(w.sport), strain: \(strain?.description ?? "nil")")
        
        // Persist to store
        Task { [weak self] in
            guard let self else { return }
            if let store = await self.repo.storeHandle() {
                _ = try? await store.upsertWorkouts([row], deviceId: self.deviceId)
                await self.repo.refresh()
            }
        }
        
        stopRealtimeHR()
    }
    
    /// Append current smoothed BPM to active workout and recompute running strain.
    func captureWorkoutSample(bpm: Int) {
        guard var w = activeWorkout else { return }
        w.samples.append(HRSample(ts: Int(Date().timeIntervalSince1970), bpm: bpm))
        w.peakHr = max(w.peakHr, bpm)
        w.avgHr = Int((Double(w.samples.map(\.bpm).reduce(0, +)) / Double(w.samples.count)).rounded())
        w.liveStrain = StrainScorer.strain(w.samples, maxHR: Double(profile.hrMax), sex: profile.sex) ?? 0
        activeWorkout = w
        persistActiveWorkout()
    }
    
    // MARK: - Persistence
    
    private func persistActiveWorkout() {
        guard let w = activeWorkout else { return }
        ActiveWorkoutPersistence.store(
            ActiveWorkoutPersistence.Snapshot(
                startSec: Int(w.start.timeIntervalSince1970),
                sport: w.sport,
                samples: w.samples,
                avgHr: w.avgHr,
                peakHr: w.peakHr,
                liveStrain: w.liveStrain))
    }
    
    private func rehydrateActiveWorkout() {
        guard activeWorkout == nil, let snap = ActiveWorkoutPersistence.load() else { return }
        var w = ActiveWorkout(start: Date(timeIntervalSince1970: TimeInterval(snap.startSec)),
                              sport: snap.sport)
        w.samples = snap.samples
        w.avgHr = snap.avgHr
        w.peakHr = snap.peakHr
        w.liveStrain = snap.liveStrain
        activeWorkout = w
        log("Rehydrated active workout: \(snap.sport)")
    }
}