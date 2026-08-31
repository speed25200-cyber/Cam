import Foundation

/// A camera discovered on the local network.
struct Camera: Identifiable, Hashable, Codable {
    enum Kind: String, Codable {
        case onvif      // Speaks ONVIF (device mgmt / media / PTZ / imaging services)
        case rtspGuess  // No ONVIF service found, but an RTSP-looking port answered
        case httpOnly   // Only a web UI port answered (vendor app required)
    }

    let id: String            // stable key, e.g. ip address
    var ipAddress: String
    var kind: Kind
    var onvifServiceURL: URL?     // XAddr from WS-Discovery / probing
    var manufacturer: String?
    var model: String?
    var firmwareVersion: String?
    var openPorts: [Int] = []
    var rtspURL: URL?
    var snapshotURL: URL?
    var hasPTZ: Bool = false
    var hasImagingService: Bool = false

    var displayName: String {
        if let manufacturer, let model {
            return "\(manufacturer) \(model)"
        }
        return manufacturer ?? "Caméra \(ipAddress)"
    }

    static func == (lhs: Camera, rhs: Camera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Credentials for one camera, stored in the Keychain — never in the model itself.
struct CameraCredentials: Codable {
    var username: String
    var password: String
}
