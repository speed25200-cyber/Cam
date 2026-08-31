import Foundation

/// Pan/Tilt/Zoom velocity vector for ONVIF ContinuousMove, components in -1...1.
struct PTZVector: Equatable {
    var pan: Double = 0
    var tilt: Double = 0
    var zoom: Double = 0

    static let stop = PTZVector(pan: 0, tilt: 0, zoom: 0)
    var isStopped: Bool { pan == 0 && tilt == 0 && zoom == 0 }
}

struct PTZPreset: Identifiable, Hashable {
    let token: String
    let name: String
    var id: String { token }
}
