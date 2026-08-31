import Foundation

/// A camera the app knows about, either just discovered or saved to the library.
///
/// Identity is a local `UUID` rather than the IP address: home routers hand out
/// DHCP leases that change, and a saved camera must survive that without losing
/// its name, credentials or presets. Re-discovery matches an existing entry by
/// serial number when the camera reports one, and falls back to the host address.
struct Camera: Identifiable, Hashable, Codable {

    enum Kind: String, Codable, CaseIterable {
        /// Speaks ONVIF — full control available (stream, PTZ, imaging, snapshots).
        case onvif
        /// An RTSP port answered but no ONVIF service replied: stream-only.
        case rtsp
        /// Only a web/admin port answered. Almost always needs the vendor's own app.
        case unknown

        var label: String {
            switch self {
            case .onvif: return "ONVIF"
            case .rtsp: return "RTSP"
            case .unknown: return "Inconnu"
            }
        }

        var explanation: String {
            switch self {
            case .onvif:
                return "Caméra standard ONVIF : flux, PTZ et réglages d'image pilotables depuis l'app."
            case .rtsp:
                return "Un port vidéo RTSP répond, mais la caméra n'expose pas ONVIF. Le flux peut fonctionner, pas les commandes."
            case .unknown:
                return "Cet appareil répond sur un port web mais ne s'annonce ni en ONVIF ni en RTSP. Utilisez l'app du fabricant."
            }
        }
    }

    /// What the camera told us it can do, read once from `GetCapabilities`.
    struct Capabilities: Hashable, Codable {
        var hasMedia = false
        var hasPTZ = false
        var hasImaging = false

        static let none = Capabilities()
    }

    let id: UUID
    var host: String
    var onvifServiceURL: URL?
    var kind: Kind

    var manufacturer: String?
    var model: String?
    var firmwareVersion: String?
    var serialNumber: String?

    /// User-chosen name. Takes precedence over anything the camera reports.
    var customName: String?
    var openPorts: [Int] = []
    var rtspURLOverride: URL?
    var capabilities: Capabilities = .none

    /// True once the user has added it to the library; discovery-only entries are false.
    var isSaved = false
    var lastSeen: Date?

    init(
        id: UUID = UUID(),
        host: String,
        onvifServiceURL: URL? = nil,
        kind: Kind = .unknown,
        manufacturer: String? = nil,
        model: String? = nil,
        firmwareVersion: String? = nil,
        serialNumber: String? = nil,
        customName: String? = nil,
        openPorts: [Int] = [],
        rtspURLOverride: URL? = nil,
        capabilities: Capabilities = .none,
        isSaved: Bool = false,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.host = host
        self.onvifServiceURL = onvifServiceURL
        self.kind = kind
        self.manufacturer = manufacturer
        self.model = model
        self.firmwareVersion = firmwareVersion
        self.serialNumber = serialNumber
        self.customName = customName
        self.openPorts = openPorts
        self.rtspURLOverride = rtspURLOverride
        self.capabilities = capabilities
        self.isSaved = isSaved
        self.lastSeen = lastSeen
    }

    // MARK: - Presentation

    var displayName: String {
        if let customName, !customName.trimmingCharacters(in: .whitespaces).isEmpty {
            return customName
        }
        switch (manufacturer, model) {
        case let (manufacturer?, model?): return "\(manufacturer) \(model)"
        case let (manufacturer?, nil): return manufacturer
        case let (nil, model?): return model
        case (nil, nil): return "Caméra \(host)"
        }
    }

    /// Subtitle line: model when we have one and the name already shows the brand,
    /// otherwise the address — never both, to keep cards to two lines.
    var subtitle: String {
        if customName != nil, let manufacturer {
            return model.map { "\(manufacturer) \($0) · \(host)" } ?? "\(manufacturer) · \(host)"
        }
        return host
    }

    /// Keychain account key. Tied to the stable id so renaming or a DHCP change
    /// never orphans stored credentials.
    var credentialsKey: String { id.uuidString }

    var isControllable: Bool { kind == .onvif }

    /// Best-effort stream address for cameras that never answered ONVIF.
    var fallbackStreamURL: URL? {
        rtspURLOverride ?? (openPorts.contains(554) ? URL(string: "rtsp://\(host):554/") : nil)
    }

    // MARK: - Merging

    /// True when `other` is physically the same camera as this one.
    func matches(_ other: Camera) -> Bool {
        if let lhs = serialNumber, let rhs = other.serialNumber, !lhs.isEmpty, !rhs.isEmpty {
            return lhs == rhs
        }
        return host == other.host
    }

    /// Folds a fresh discovery result into a saved entry, keeping everything the
    /// user owns (name, id) and taking everything the network just told us.
    func merging(discovered: Camera) -> Camera {
        var result = self
        result.host = discovered.host
        result.onvifServiceURL = discovered.onvifServiceURL ?? onvifServiceURL
        result.kind = discovered.kind == .unknown ? kind : discovered.kind
        result.manufacturer = discovered.manufacturer ?? manufacturer
        result.model = discovered.model ?? model
        result.firmwareVersion = discovered.firmwareVersion ?? firmwareVersion
        result.serialNumber = discovered.serialNumber ?? serialNumber
        result.openPorts = discovered.openPorts.isEmpty ? openPorts : discovered.openPorts
        result.lastSeen = discovered.lastSeen ?? Date()
        return result
    }

    /// Whether anything the network can tell us about this camera has changed.
    ///
    /// `==` deliberately compares identity only, so that a camera stays the same
    /// row in a list while its details are still filling in. This is the separate
    /// question of whether an update is worth persisting.
    func differsInDeviceData(from other: Camera) -> Bool {
        host != other.host
            || kind != other.kind
            || onvifServiceURL != other.onvifServiceURL
            || manufacturer != other.manufacturer
            || model != other.model
            || firmwareVersion != other.firmwareVersion
            || serialNumber != other.serialNumber
            || openPorts != other.openPorts
            || capabilities != other.capabilities
    }

    static func == (lhs: Camera, rhs: Camera) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Credentials for one camera. Only ever written to the Keychain.
struct CameraCredentials: Codable, Equatable {
    var username: String
    var password: String
}
