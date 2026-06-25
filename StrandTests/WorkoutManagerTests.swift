import XCTest
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Tests for WorkoutManager - manual workout tracking, GPS, persistence, rehydration
final class WorkoutManagerTests: XCTestCase {
    
    private var repo: Repository!
    private var profile: ProfileStore!
    private var gpsRecorder: GpsWorkoutRecorder!
    private var buzzCalls: [(loops: UInt8)] = []
    private var logCalls: [String] = []
    private var startRealtimeCalls = 0
    private var stopRealtimeCalls = 0
    private var workoutManager: WorkoutManager!
    
    override func setUp() async throws {
        // Create minimal dependencies
        repo = Repository(deviceId: "test-device")
        profile = ProfileStore()
        profile.hrMax = 190
        profile.sex = .male
        profile.weightKg = 80
        profile.heightCm = 180
        profile.age = 30
        
        gpsRecorder = GpsWorkoutRecorder()
        
        buzzCalls = []
        logCalls = []
        startRealtimeCalls = 0
        stopRealtimeCalls = 0
        
        workoutManager = WorkoutManager(
            repo: repo,
            profile: profile,
            gpsRecorder: gpsRecorder,
            deviceId: "test-device",
            buzz: { [weak self] loops in self?.buzzCalls.append((loops: loops)) },
            log: { [weak self] msg in self?.logCalls.append(msg) },
            startRealtimeHR: { [weak self] in self?.startRealtimeCalls += 1 },
            stopRealtimeHR: { [weak self] in self?.stopRealtimeCalls += 1 }
        )
    }
    
    override func tearDown() {
        // Clean up any persisted state
        ActiveWorkoutPersistence.clear(from: UserDefaults.standard)
    }
    
    // MARK: - Workout Start/End Tests
    
    func testStartWorkoutCreatesActiveWorkout() {
        workoutManager.startWorkout(sport: "Tennis")
        
        XCTAssertNotNil(workoutManager.activeWorkout)
        XCTAssertEqual(workoutManager.activeWorkout?.sport, "Tennis")
        XCTAssertEqual(buzzCalls.count, 1)
        XCTAssertEqual(buzzCalls.first?.loops, 1)
        XCTAssertTrue(logCalls.contains { $0.contains("Workout started: Tennis") })
        XCTAssertEqual(startRealtimeCalls, 1)
    }
    
    func testStartWorkoutDefaultsToOther() {
        workoutManager.startWorkout(sport: "")
        
        XCTAssertEqual(workoutManager.activeWorkout?.sport, WorkoutCatalog.defaultSportName)
    }
    
    func testStartWorkoutArmsGPSForDistanceSports() {
        workoutManager.startWorkout(sport: "Run")
        
        XCTAssertTrue(workoutManager.activeWorkoutIsGps)
    }
    
    func testStartWorkoutDoesNotArmGPSForNonDistanceSports() {
        workoutManager.startWorkout(sport: "Yoga")
        
        XCTAssertFalse(workoutManager.activeWorkoutIsGps)
    }
    
    func testEndWorkoutSavesWorkoutRow() async {
        workoutManager.startWorkout(sport: "Run")
        
        // Simulate some HR samples
        workoutManager.captureWorkoutSample(bpm: 140)
        workoutManager.captureWorkoutSample(bpm: 155)
        workoutManager.captureWorkoutSample(bpm: 165)
        
        await MainActor.run {
            workoutManager.endWorkout()
        }
        
        // Allow async persistence to complete
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertNotNil(workoutManager.lastWorkout)
        XCTAssertEqual(workoutManager.lastWorkout?.sport, "Run")
        XCTAssertEqual(buzzCalls.last?.loops, 2)
        XCTAssertTrue(logCalls.contains { $0.contains("Workout ended: Run") })
        XCTAssertEqual(stopRealtimeCalls, 1)
    }
    
    func testEndWorkoutWithNoSamplesReturnsNil() async {
        workoutManager.startWorkout(sport: "Yoga")
        // No HR samples captured
        
        await MainActor.run {
            workoutManager.endWorkout()
        }
        
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        XCTAssertNil(workoutManager.lastWorkout)
    }
    
    // MARK: - Persistence Tests
    
    func testPersistAndRehydrateActiveWorkout() {
        workoutManager.startWorkout(sport: "Tennis")
        workoutManager.captureWorkoutSample(bpm: 130)
        workoutManager.captureWorkoutSample(bpm: 145)
        
        // Create a fresh manager to test rehydration
        let newManager = WorkoutManager(
            repo: repo,
            profile: profile,
            gpsRecorder: GpsWorkoutRecorder(),
            deviceId: "test-device",
            buzz: { _ in },
            log: { _ in },
            startRealtimeHR: {},
            stopRealtimeHR: {}
        )
        
        XCTAssertNotNil(newManager.activeWorkout)
        XCTAssertEqual(newManager.activeWorkout?.sport, "Tennis")
        XCTAssertEqual(newManager.activeWorkout?.samples.count, 2)
        XCTAssertEqual(newManager.activeWorkout?.avgHr, 138) // (130+145)/2
        XCTAssertEqual(newManager.activeWorkout?.peakHr, 145)
    }
    
    func testPersistClearsOnEndWorkout() async {
        workoutManager.startWorkout(sport: "Run")
        workoutManager.captureWorkoutSample(bpm: 150)
        
        await MainActor.run {
            workoutManager.endWorkout()
        }
        
        // Verify persistence was cleared
        let reloaded = ActiveWorkoutPersistence.load(from: UserDefaults.standard)
        XCTAssertNil(reloaded)
    }
    
    // MARK: - Live Strain Calculation Tests
    
    func testLiveStrainUpdatesWithEachSample() {
        workoutManager.startWorkout(sport: "Run")
        
        workoutManager.captureWorkoutSample(bpm: 120)
        let strain1 = workoutManager.activeWorkout?.liveStrain ?? 0
        
        workoutManager.captureWorkoutSample(bpm: 140)
        let strain2 = workoutManager.activeWorkout?.liveStrain ?? 0
        
        workoutManager.captureWorkoutSample(bpm: 160)
        let strain3 = workoutManager.activeWorkout?.liveStrain ?? 0
        
        // Strain should increase with higher HR
        XCTAssertLessThan(strain1, strain2)
        XCTAssertLessThan(strain2, strain3)
    }
    
    // MARK: - Average/Peak HR Tests
    
    func testAvgAndPeakHRUpdateCorrectly() {
        workoutManager.startWorkout(sport: "Run")
        
        workoutManager.captureWorkoutSample(bpm: 130)
        workoutManager.captureWorkoutSample(bpm: 150)
        workoutManager.captureWorkoutSample(bpm: 170)
        
        XCTAssertEqual(workoutManager.activeWorkout?.avgHr, 150) // (130+150+170)/3
        XCTAssertEqual(workoutManager.activeWorkout?.peakHr, 170)
    }
}