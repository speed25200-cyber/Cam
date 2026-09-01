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
        /// Present on the network, but nothing it answered identified it as a
        /// camera this app can drive.
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
                return "Cet appareil est bien présent sur le réseau, mais il ne répond ni en ONVIF ni en RTSP. Si c'est une caméra, passez par l'app du fabricant, ou saisissez son adresse RTSP à la main."
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
    /// Hardware address, when the network stack resolved one. Its first bytes
    /// name the manufacturer, which is often all that identifies a camera that
    /// answers nothing else.
    var macAddress: String?

    /// User-chosen name. Takes precedence over anything the camera reports.
    var customName: String?
    var openPorts: [Int] = []
    /// Exact stream address, when the user supplied one. Takes precedence over
    /// every guessed path — it is the only thing that rescues a camera whose
    /// vendor uses a path nobody else does. Named for RTSP because that is what
    /// it was, but an `http://` address for a multipart or still-image endpoint
    /// is equally welcome; the name is kept so saved libraries still decode.
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
        macAddress: String? = nil,
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
        self.macAddress = macAddress
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


    // MARK: - Merging

    /// True when `other` is physically the same camera as this one.
    func matches(_ other: Camera) -> Bool {
        if let lhs = serialNumber, let rhs = other.serialNumber, !lhs.isEmpty, !rhs.isEmpty {
            return lhs == rhs
        }
        // A hardware address outlives a DHCP lease, so it settles the question
        // for the many cameras that report no serial number at all.
        if let lhs = macAddress, let rhs = other.macAddress, !lhs.isEmpty, !rhs.isEmpty {
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
        result.macAddress = discovered.macAddress ?? macAddress
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
            || macAddress != other.macAddress
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
