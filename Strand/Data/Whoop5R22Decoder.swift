import Foundation
import WhoopProtocol

/// WHOOP 5.0/MG R22 (type 0x2F) packet decoder
/// Decodes the deep biometric stream packets that the strap emits after the enable_r22 sequence
/// Based on judes.club documentation + community captures: HR at byte 14, accel x/y/z as float32 at 37/41/45
public enum Whoop5R22Decoder {
    
    /// Minimum length for a valid R22 frame (header + payload + CRC32)
    static let minFrameLength = 60
    
    /// R22 packet type identifier
    static let r22PacketType: UInt8 = 0x2F
    
    /// Decoded R22 biometric sample
    public struct R22Sample: Equatable, Sendable {
        public let timestamp: Date
        public let heartRate: Int?
        public let accelX: Float?
        public let accelY: Float?
        public let accelZ: Float?
        public let rawPayload: [UInt8]
        
        public var accelerationMagnitude: Float? {
            guard let x = accelX, let y = accelY, let z = accelZ else { return nil }
            return sqrt(x*x + y*y + z*z)
        }
    }
    
    /// Attempt to decode a WHOOP 5.0/MG type-0x2F frame
    /// - Parameter frame: Complete frame bytes (including 0xAA SOF, header, payload, CRC32)
    /// - Returns: Decoded R22Sample if successful, nil if not an R22 frame or decode failed
    public static func decode(_ frame: [UInt8]) -> R22Sample? {
        // Verify basic frame structure
        guard frame.count >= minFrameLength else { return nil }
        guard frame[0] == 0xAA else { return nil }
        
        // For WHOOP 5.0/MG frames, inner record starts at offset 8
        let innerStart = 8
        guard frame.count > innerStart else { return nil }
        
        let packetType = frame[innerStart]
        guard packetType == r22PacketType else { return nil }
        
        // Sequence byte at innerStart + 1
        let sequence = frame.count > innerStart + 1 ? frame[innerStart + 1] : 0
        
        // Payload starts at innerStart + 2 (type + seq)
        // For R22, the documented layout:
        // - heart_rate at byte 14 (from inner start)
        // - accel_x (float32 LE) at byte 37
        // - accel_y (float32 LE) at byte 41
        // - accel_z (float32 LE) at byte 45
        // - Additional biometric data in remaining payload
        
        let payloadStart = innerStart + 2
        let payloadEnd = frame.count - 4 // Remove CRC32 trailer
        guard payloadEnd > payloadStart else { return nil }
        
        let payload = Array(frame[payloadStart..<payloadEnd])
        
        // Need at least 46 bytes of payload for HR + accel
        guard payload.count >= 46 else { 
            // Frame is too short for full decode, but it's an R22 frame
            return R22Sample(
                timestamp: Date(),
                heartRate: nil,
                accelX: nil,
                accelY: nil,
                accelZ: nil,
                rawPayload: payload
            )
        }
        
        // Decode heart rate at payload offset 14 (1 byte, u8 bpm)
        let heartRate: Int?
        if payload.count > 14 {
            let hr = Int(payload[14])
            heartRate = (hr >= 30 && hr <= 220) ? hr : nil
        } else {
            heartRate = nil
        }
        
        // Decode accelerometer (float32 little-endian)
        let accelX = decodeFloat32(payload, offset: 37)
        let accelY = decodeFloat32(payload, offset: 41)
        let accelZ = decodeFloat32(payload, offset: 45)
        
        return R22Sample(
            timestamp: Date(),
            heartRate: heartRate,
            accelX: accelX,
            accelY: accelY,
            accelZ: accelZ,
            rawPayload: payload
        )
    }
    
    /// Decode float32 little-endian from byte array
    private static func decodeFloat32(_ bytes: [UInt8], offset: Int) -> Float? {
        guard offset + 3 < bytes.count else { return nil }
        let bits = UInt32(bytes[offset]) 
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }
    
    /// Check if a frame is a WHOOP 5.0/MG R22 packet (without full decode)
    public static func isR22Frame(_ frame: [UInt8]) -> Bool {
        guard frame.count > 8 else { return false }
        guard frame[0] == 0xAA else { return false }
        let innerStart = 8
        guard frame.count > innerStart else { return false }
        return frame[innerStart] == r22PacketType
    }
    
    /// Get human-readable description of R22 packet type
    public static func r22PacketTypeName(_ subType: UInt8) -> String {
        switch subType {
        case 1: return "R22 v1 - HR + Accel"
        case 2: return "R22 v2 - Extended"
        case 3: return "R22 v3 - HRV"
        case 4: return "R22 v4 - SpO2"
        case 5: return "R22 v5 - Temperature"
        case 6: return "R22 v6 - Motion"
        case 7: return "R22 v7 - Sleep"
        case 8: return "R22 v8 - Full"
        default: return "R22 unknown (0x\(String(format: "%02X", subType)))"
        }
    }
}