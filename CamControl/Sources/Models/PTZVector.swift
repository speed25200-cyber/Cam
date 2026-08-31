import CoreGraphics
import Foundation

/// Pan/tilt/zoom velocity for ONVIF `ContinuousMove`. Each component is a
/// normalized speed in -1...1, where the sign is the direction and the magnitude
/// is how fast the motor should run.
struct PTZVector: Equatable {
    var pan: Double = 0
    var tilt: Double = 0
    var zoom: Double = 0

    init(pan: Double = 0, tilt: Double = 0, zoom: Double = 0) {
        self.pan = PTZVector.clamp(pan)
        self.tilt = PTZVector.clamp(tilt)
        self.zoom = PTZVector.clamp(zoom)
    }

    /// No movement on any axis.
    static let stop = PTZVector()

    var isStopped: Bool { magnitude < 0.001 }
    var magnitude: Double { max(abs(pan), max(abs(tilt), abs(zoom))) }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }

    /// Maps a joystick displacement to a velocity.
    ///
    /// The response is squared so small movements near the centre are gentle and
    /// precise while the edge of the pad still gives full motor speed — a linear
    /// mapping makes framing a distant subject almost impossible. Tilt is inverted
    /// because screen coordinates grow downward while ONVIF tilt grows upward.
    static func fromJoystick(offset: CGSize, radius: CGFloat) -> PTZVector {
        guard radius > 0 else { return .stop }
        let normalizedX = Double(offset.width / radius)
        let normalizedY = Double(offset.height / radius)
        return PTZVector(
            pan: response(normalizedX),
            tilt: -response(normalizedY)
        )
    }

    private static func response(_ value: Double) -> Double {
        let clamped = clamp(value)
        return clamped * abs(clamped)
    }

    /// Clamps a raw drag to the pad's circle so the knob never leaves the ring.
    static func constrain(offset: CGSize, radius: CGFloat) -> CGSize {
        let distance = sqrt(offset.width * offset.width + offset.height * offset.height)
        guard distance > radius, distance > 0 else { return offset }
        let scale = radius / distance
        return CGSize(width: offset.width * scale, height: offset.height * scale)
    }
}

/// A saved PTZ position on the camera itself.
struct PTZPreset: Identifiable, Hashable, Codable {
    let token: String
    var name: String
    var id: String { token }
}
