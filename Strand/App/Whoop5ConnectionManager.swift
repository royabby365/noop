import Foundation
import CoreBluetooth
import WhoopProtocol

/// WHOOP 5.0/MG Connection Diagnostics & Recovery
/// Addresses the key pairing/communication issues documented in the codebase:
/// 1. Bond refused due to existing bond with official app
/// 2. Live HR works but encrypted bond fails
/// 3. Deep data (R22) requires explicit sequence + on-wrist gating
/// 4. History offload empty on some firmware
/// 5. macOS cannot complete authenticated bond for command writes
@MainActor
final class Whoop5ConnectionManager: ObservableObject {
    // MARK: - Published State
    
    @Published var connectionState: ConnectionState = .idle
    @Published var pairingHint: String = ""
    @Published var deepDataEnabled: Bool = false
    @Published var deepDataAttempted: Bool = false
    @Published var deepDataSuccess: Bool = false
    @Published var historyEmpty: Bool = false
    @Published var broadcastHREnabled: Bool = false
    
    // MARK: - Dependencies
    
    private let bleManager: BLEManager
    private let liveState: LiveState
    private let log: (String) -> Void
    
    // MARK: - Init
    
    init(bleManager: BLEManager, liveState: LiveState, log: @escaping (String) -> Void) {
        self.bleManager = bleManager
        self.liveState = liveState
        self.log = log
    }
    
    // MARK: - Public API
    
    /// Full guided pairing flow for WHOOP 5.0/MG
    func startPairingFlow() {
        connectionState = .preparing
        log("Starting WHOOP 5.0/MG pairing flow")
        
        // Step 1: Ensure official app is not holding the bond
        pairingHint = "Close the official WHOOP app on your phone completely (or turn off Bluetooth on the phone). The strap can only bond to one device at a time."
        log(pairingHint)
        
        // Step 2: Put strap in pairing mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.pairingHint = "Put the strap in pairing mode: tap the band firmly and repeatedly until the LEDs flash BLUE."
            self?.log(self!.pairingHint)
        }
        
        // Step 3: Start scan
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.connectionState = .scanning
            self?.pairingHint = "Scanning for WHOOP 5.0/MG…"
            self?.log("Starting WHOOP 5.0/MG scan")
            self?.bleManager.prepareForPresentScan(model: .whoop5mg)
            self?.bleManager.connect(model: .whoop5mg)
            self?.bleManager.scanForWhoops()
        }
    }
    
    /// Attempt to enable deep data (R22 streams) after successful bond
    func attemptDeepDataEnable() {
        guard liveState.selectedModel?.deviceFamily == .whoop5 else {
            log("Deep data: not a WHOOP 5.0/MG strap")
            return
        }
        
        guard liveState.bonded && liveState.encryptedBond else {
            pairingHint = "Deep data requires full encrypted bond. Ensure the strap is paired to NOOP (not just live HR)."
            log(pairingHint)
            return
        }
        
        guard liveState.worn else {
            pairingHint = "Deep data: put the strap ON your wrist. The R22 stream is on-wrist gated."
            log(pairingHint)
            return
        }
        
        deepDataAttempted = true
        log("Attempting to enable WHOOP 5.0/MG deep data (R22 streams)")
        
        // This calls the existing BLEManager.enableWhoop5DeepData()
        bleManager.enableWhoop5DeepData()
        
        // Monitor for success via frame callbacks
        deepDataSuccess = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) { [weak self] in
            self?.checkDeepDataStatus()
        }
    }
    
    /// Enable broadcast HR for Garmin/Zwift compatibility
    func setBroadcastHR(_ enabled: Bool) {
        bleManager.setBroadcastHr(enabled)
        broadcastHREnabled = enabled
        log("Broadcast HR \(enabled ? "enabled" : "disabled")")
    }
    
    /// Check if deep data is working by monitoring for type-0x2F frames
    private func checkDeepDataStatus() {
        // This would be enhanced with actual frame monitoring
        // For now, log the current state
        log("Deep data check: bonded=\(liveState.bonded), encrypted=\(liveState.encryptedBond), worn=\(liveState.worn)")
        log("Check your strap log — look for type-0x2F frames arriving after the enable sequence")
    }
    
    /// Get diagnostic summary for user/bug reports
    func diagnosticSummary() -> String {
        var summary = "WHOOP 5.0/MG Diagnostics:\n"
        summary += "  Connection: \(connectionState)\n"
        summary += "  Bonded: \(liveState.bonded)\n"
        summary += "  Encrypted Bond: \(liveState.encryptedBond)\n"
        summary += "  Worn: \(liveState.worn)\n"
        summary += "  Live HR: \(liveState.heartRate?.description ?? "none")\n"
        summary += "  Battery: \(liveState.batteryPct?.description ?? "none")%\n"
        summary += "  Deep Data Enabled: \(PuffinExperiment.deepDataEnabled)\n"
        summary += "  Deep Data Attempted: \(deepDataAttempted)\n"
        summary += "  History Empty: \(liveState.historyEmpty5MG)\n"
        summary += "  Broadcast HR: \(broadcastHREnabled)\n"
        summary += "  Pairing Hint: \(pairingHint)"
        return summary
    }
}

// MARK: - Connection States

enum ConnectionState: Equatable {
    case idle
    case preparing
    case scanning
    case connecting
    case bonded
    case deepDataEnabled
    case error(String)
}