import Foundation
import CoreLocation

/// Manages GPS route recording for distance-type workouts.
/// Wraps GpsWorkoutRecorder and provides a clean interface.
@MainActor
final class GPSManager: ObservableObject {
    // MARK: - Published State
    
    @Published var isRecording = false
    @Published var currentRoute: WorkoutRoute?
    
    // MARK: - Internal
    
    private let gpsRecorder = GpsWorkoutRecorder()
    private var isArmedForSport = false
    
    // MARK: - Public API
    
    /// Arm GPS recording for a distance-type sport (run/ride/walk/hike)
    func armIfDistanceSport(_ sport: String) {
        isArmedForSport = WorkoutCatalog.sport(named: sport)?.isDistanceSport ?? false
    }
    
    /// Start GPS recording at workout start
    func start(startMs: Int64) {
        guard isArmedForSport else { return }
        isRecording = true
        gpsRecorder.start(startMs: startMs)
    }
    
    /// Stop GPS recording and capture the route
    func stop() -> WorkoutRoute? {
        guard isArmedForSport else { return nil }
        isRecording = false
        gpsRecorder.stop()
        let route = gpsRecorder.capturedRoute()
        currentRoute = route
        return route
    }
    
    /// Check if currently recording a GPS route
    var isActive: Bool {
        isArmedForSport && isRecording
    }
}