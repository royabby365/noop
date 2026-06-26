import Foundation
import WhoopProtocol
import StrandAnalytics

/// Pure decode→state router. Takes a COMPLETE (already reassembled) frame, decodes it with
/// WhoopProtocol.parseFrame, and updates LiveState. No CoreBluetooth — fully unit-testable.
@MainActor
public final class FrameRouter {
    private let state: LiveState
    /// Called when the strap pushes an EVENT packet (WHOOP's strap-as-clock catch-up signal). The
    /// BLEManager wires this to a rate-limited requestSync(.strap). nil in pure/unit contexts.
    var onSyncTrigger: (() -> Void)?
    /// Which family's framing to decode with. Set per connection by BLEManager. WHOOP 5.0/MG frames
    /// use the CRC16/offset-8 envelope; the biometric field decode for puffin is still a stub, so
    /// WHOOP 5 custom frames currently surface only their envelope (live HR/battery come from the
    /// standard 0x2A37/0x2A19 profiles instead).
    var family: DeviceFamily = .whoop4
    
    /// Optional logger for R22/deep-data telemetry
    var log: ((String) -> Void)?
    
    public init(state: LiveState) {
        self.state = state
    }

    /// Handle one complete frame (bytes including 0xAA SOF and the crc32 trailer).
    public func handle(frame: [UInt8]) {
        let parsed = parseFrame(frame, family: family)
        guard parsed.ok else { return }
        // Reject frames that failed their checksum — never let bad bytes drive state.
        if parsed.crcOK == false { return }

        // live perf: only republish when the value actually changed. The type-43 raw flood arrives
        // continuously and repeats the SAME frame type, and each `@Published` write fires
        // `objectWillChange` → a full LiveView.body re-eval (these frames are separate BLE
        // notifications, so SwiftUI can't coalesce them). Guarding collapses a steady flood to one
        // re-eval per genuine change instead of one per frame.
        if state.lastFrameType != parsed.typeName { state.lastFrameType = parsed.typeName }

        switch parsed.typeName {
        case "REALTIME_DATA", "REALTIME_RAW_DATA":
            // Reject 0 / out-of-range spikes from realtime streams; AppModel medians the rest.
            // Some firmware exposes live BPM only on the R10/R11 raw stream after acknowledging
            // BLE_REALTIME_HR_ON, so the UI can consume it even though persistence still ignores raw43.
            // live perf: skip the publish when HR is unchanged — the raw flood carries the same HR
            // byte across many frames, so an unguarded write re-renders the whole console for nothing.
            if let hr = parsed.parsed["heart_rate"]?.intValue, hr >= 30, hr <= 220, state.heartRate != hr {
                state.heartRate = hr
            }
            // The realtime stream usually reports rr_count=0; only update R-R when this frame
            // actually carries intervals, so we don't wipe R-R sourced from the 0x2A37 profile.
            // setRRIntervals also feeds the Live console's rolling rrRecent buffer.
            if let rr = parsed.parsed["rr_intervals"]?.intArrayValue, !rr.isEmpty {
                state.setRRIntervals(rr)
            }

        case "HISTORICAL_DATA":
            // WHOOP 5.0/MG historical biometric frames (type 47 / 0x2F) come through here
            // The schema decode handles known layouts (v18, v20, v21, v26)
            if family == .whoop5 {
                // Log R22 telemetry for deep-data monitoring
                let versionKey = parsed.parsed["hist_version"]?.intValue ?? -1
                log?("R22 historical frame: version=\(versionKey), fields=\(parsed.fields.count)")
            }

        case "COMMAND_RESPONSE":
            if let pct = parsed.parsed["battery_pct"]?.doubleValue {
                state.setBattery(pct)
            }
            // Advertising-name replies (WHOOP 4.0 / Harvard). GET (cmd 76) carries the current name in
            // its payload; SET (cmd 77) carries only a result byte. The schema has no field decode for
            // either, so pull them straight from the frame bytes. The COMMAND_RESPONSE inner is
            // [type,seq,cmd,origin_seq,result,payload…] starting at offset 4, with crc32 at `length`.
            if family == .whoop4, let cmd = parsed.cmdName {
                if cmd == "GET_ADVERTISING_NAME_HARVARD" {
                    if let name = Self.advertisingName(in: frame), !name.isEmpty {
                        state.advertisingName = name
                    }
                } else if cmd == "SET_ADVERTISING_NAME_HARVARD" {
                    state.renameStatus = Self.renameAck(for: Self.commandResultByte(in: frame))
                }
            }

        case "EVENT":
            if let ev = parsed.parsed["event"]?.stringValue {
                // #92: don't surface the live-HR stream toggle (BLE_REALTIME_HR_ON/OFF) in "Last
                // Event" — it's internal plumbing that fires on every connect and just confuses
                // users. Every other event (wrist, double-tap, battery, bonded…) still shows.
                if !ev.hasPrefix("BLE_REALTIME_HR") {
                    state.lastEvent = ev
                }
                // Strap-pushed event = "I may have new data" → kick a (rate-limited) sync.
                onSyncTrigger?()
                // Belt-and-suspenders: a BLE_BONDED event confirms the link is bonded.
                // (BLEManager also sets bonded=true when the confirmed write succeeds.)
                if ev.hasPrefix("BLE_BONDED") {
                    state.bonded = true
                }
                // BATTERY_LEVEL events carry the only charging flag the strap reports (wire
                // observation: u8 bit0, ~every 8 min on captured links). Flag only — battery %
                // keeps its family-specific source (#77). No freshness gate needed here: this
                // path never sees historical replay (backfill skips handle(frame:), see below).
                if ev.hasPrefix("BATTERY_LEVEL"),
                   let ch = parsed.parsed["battery_charging"]?.intValue {
                    state.charging = (ch != 0)
                }
                // Physical inputs the strap exposes — live only (this path never sees historical
                // replay, which goes through the Backfiller). Event strings are "NAME(rawValue)".
                if ev.hasPrefix("DOUBLE_TAP") {
                    state.onDoubleTap?()
                } else if ev.hasPrefix("WRIST_ON") {
                    if !state.worn { state.worn = true; state.onWristChange?(true) }
                } else if ev.hasPrefix("WRIST_OFF") {
                    if state.worn { state.worn = false; state.onWristChange?(false) }
                } else if ev.hasPrefix("STRAP_DRIVEN_ALARM_EXECUTED") {
                    // The strap fired its firmware smart alarm → re-arm the next day's instant (the
                    // alarm is a single absolute time with no recurrence). Belt-and-suspenders to the
                    // daily/foreground re-arm in AppModel, since this event isn't always observed.
                    state.onSmartAlarmFired?()
                }
            }

        default:
            // Check for WHOOP 5.0/MG R22 (type 0x2F) deep biometric packets
            if family == .whoop5, parsed.typeName == "0x2F" || parsed.typeName == "HISTORICAL_DATA" {
                // R22 deep-data frames come through as HISTORICAL_DATA (type 47) or raw 0x2F
                // The schema decode handles known layouts; unknown layouts reach here
                let histVersion = parsed.parsed["hist_version"]?.intValue ?? -1
                let fieldCount = parsed.fields.count
                log?("R22 historical frame: version=\(histVersion), fields=\(fieldCount)")
            }
            break
        }
    }

    // MARK: - Advertising-name decode (WHOOP 4.0 / Harvard)

    /// Offset of the inner `[type][seq][cmd][origin_seq][result][payload…]` in a WHOOP 4.0 frame:
    /// SOF(1) + length(2) + crc8(1). Mirrors `WhoopCommand.frame` / `parseFrame`.
    private static let whoop4InnerOffset = 4

    /// Extract the advertising name from a GET_ADVERTISING_NAME COMMAND_RESPONSE: printable ASCII from
    /// the payload that follows [type,seq,cmd,origin_seq,result] (payload starts at inner+5), up to the
    /// crc32 trailer at `length`. Mirrors the whoop-rename prototype's `extract_name`. nil if too short.
    static func advertisingName(in frame: [UInt8]) -> String? {
        guard frame.count > 2 else { return nil }
        let length = Int(frame[1]) | (Int(frame[2]) << 8)        // crc32 starts here
        let start = whoop4InnerOffset + 5                        // skip type,
