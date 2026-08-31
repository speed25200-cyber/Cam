import Foundation

/// Talks ONVIF to exactly one camera.
///
/// An actor because a camera is a single serialized resource: the PTZ pad, the
/// imaging sliders and the snapshot button all fire concurrently from the UI, and
/// the negotiated state (service URLs, profile token, clock offset) must not be
/// read while another task is still filling it in.
actor ONVIFClient {

    // MARK: - Namespaces

    private enum NS {
        static let device = "http://www.onvif.org/ver10/device/wsdl"
        static let media = "http://www.onvif.org/ver10/media/wsdl"
        static let ptz = "http://www.onvif.org/ver20/ptz/wsdl"
        static let imaging = "http://www.onvif.org/ver20/imaging/wsdl"
    }

    /// Result of a successful `connect()`.
    struct Connection: Equatable {
        var capabilities: Camera.Capabilities
        var profileToken: String
        var profileName: String?
        var videoSourceToken: String?
    }

    struct DeviceInformation: Equatable {
        var manufacturer: String?
        var model: String?
        var firmwareVersion: String?
        var serialNumber: String?
    }

    // MARK: - State

    private let deviceServiceURL: URL
    private var credentials: CameraCredentials?

    private var mediaURL: URL?
    private var ptzURL: URL?
    private var imagingURL: URL?
    private var profileToken: String?
    private var videoSourceToken: String?

    /// Difference between the camera's clock and ours. The WS-Security digest is
    /// rejected when `Created` drifts more than a few minutes from device time,
    /// and consumer cameras with no NTP server are routinely years off.
    private var clockOffset: TimeInterval = 0

    private let session: URLSession
    private let authDelegate: AuthChallengeHandler

    init(deviceServiceURL: URL, credentials: CameraCredentials? = nil, timeout: TimeInterval = 8) {
        self.deviceServiceURL = deviceServiceURL
        self.credentials = credentials

        let handler = AuthChallengeHandler(credentials: credentials)
        self.authDelegate = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: handler, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func setCredentials(_ credentials: CameraCredentials?) {
        self.credentials = credentials
        authDelegate.update(credentials: credentials)
    }

    // MARK: - Transport

    private func send(
        to url: URL,
        action: String,
        body: String,
        authenticated: Bool = true
    ) async throws -> SOAPNode {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/soap+xml; charset=utf-8; action=\"\(action)\"",
            forHTTPHeaderField: "Content-Type"
        )
        let header: String = {
            guard authenticated, let credentials, !credentials.username.isEmpty else { return "" }
            return SOAPXML.securityHeader(
                username: credentials.username,
                password: credentials.password,
                clockOffset: clockOffset
            )
        }()
        request.httpBody = SOAPXML.envelope(header: header, body: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost:
                throw ONVIFError.timedOut
            case .userAuthenticationRequired:
                throw ONVIFError.unauthorized
            default:
                throw ONVIFError.malformedResponse(error.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw ONVIFError.malformedResponse("réponse non HTTP")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ONVIFError.unauthorized
        }

        guard let root = SOAPXML.parse(data) else {
            // A 500 with an unparseable body is far more informative as a status code.
            if !(200..<300).contains(http.statusCode) {
                throw ONVIFError.httpStatus(http.statusCode)
            }
            throw ONVIFError.malformedResponse("XML invalide")
        }

        if let reason = SOAPXML.faultReason(in: root) {
            throw SOAPXML.isAuthenticationFault(reason) ? ONVIFError.unauthorized : ONVIFError.soapFault(reason)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ONVIFError.httpStatus(http.statusCode)
        }
        return root
    }

    // MARK: - Handshake

    /// Reads the camera's clock so every later digest carries a timestamp the
    /// device considers valid. Unauthenticated by specification, and a failure
    /// here is not fatal — it just leaves the offset at zero.
    func synchronizeClock() async {
        let body = "<GetSystemDateAndTime xmlns=\"\(NS.device)\"/>"
        guard let root = try? await send(
            to: deviceServiceURL,
            action: "\(NS.device)/GetSystemDateAndTime",
            body: body,
            authenticated: false
        ) else { return }

        guard let utc = root.first("UTCDateTime"),
              let date = utc.first("Date"), let time = utc.first("Time"),
              let year = date.doubleValue("Year"), let month = date.doubleValue("Month"),
              let day = date.doubleValue("Day"), let hour = time.doubleValue("Hour"),
              let minute = time.doubleValue("Minute") else { return }

        var components = DateComponents()
        components.year = Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(time.doubleValue("Second") ?? 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard let deviceDate = calendar.date(from: components) else { return }
        clockOffset = deviceDate.timeIntervalSinceNow
    }

    /// `GetDeviceInformation` — tried without credentials first, since most
    /// cameras answer it openly and it is how a device is identified during a
    /// scan, before the user has entered anything.
    func deviceInformation() async throws -> DeviceInformation {
        let body = "<GetDeviceInformation xmlns=\"\(NS.device)\"/>"
        let action = "\(NS.device)/GetDeviceInformation"
        let root: SOAPNode
        do {
            root = try await send(to: deviceServiceURL, action: action, body: body, authenticated: false)
        } catch ONVIFError.unauthorized where credentials != nil {
            root = try await send(to: deviceServiceURL, action: action, body: body, authenticated: true)
        }
        return DeviceInformation(
            manufacturer: root.value("Manufacturer"),
            model: root.value("Model"),
            firmwareVersion: root.value("FirmwareVersion"),
            serialNumber: root.value("SerialNumber")
        )
    }

    /// Resolves service endpoints and the first usable video profile.
    func connect() async throws -> Connection {
        await synchronizeClock()
        try await loadServiceEndpoints()
        return try await loadProfile()
    }

    /// Discovers per-service endpoints. `GetServices` is the modern call and
    /// reports Media2-capable devices correctly; `GetCapabilities` is the
    /// fallback for older firmware that never implemented it.
    private func loadServiceEndpoints() async throws {
        if await loadFromGetServices() { return }
        try await loadFromGetCapabilities()
    }

    private func loadFromGetServices() async -> Bool {
        let body = """
        <GetServices xmlns="\(NS.device)"><IncludeCapability>false</IncludeCapability></GetServices>
        """
        guard let root = try? await send(to: deviceServiceURL, action: "\(NS.device)/GetServices", body: body) else {
            return false
        }
        var found = false
        for service in root.all("Service") {
            guard let namespace = service.value("Namespace"),
                  let address = service.value("XAddr").flatMap(normalizeServiceURL) else { continue }
            if namespace.contains("/media/wsdl") || namespace.contains("/media2/wsdl") {
                // Prefer ver10 Media: ver20 renames GetStreamUri's parameters and
                // not every device that advertises Media2 implements it fully.
                if mediaURL == nil || namespace.contains("/media/wsdl") { mediaURL = address }
                found = true
            } else if namespace.contains("/ptz/wsdl") {
                ptzURL = address
                found = true
            } else if namespace.contains("/imaging/wsdl") {
                imagingURL = address
                found = true
            }
        }
        return found && mediaURL != nil
    }

    private func loadFromGetCapabilities() async throws {
        let body = """
        <GetCapabilities xmlns="\(NS.device)"><Category>All</Category></GetCapabilities>
        """
        let root = try await send(to: deviceServiceURL, action: "\(NS.device)/GetCapabilities", body: body)
        guard let capabilities = root.first("Capabilities") else {
            throw ONVIFError.malformedResponse("capacités absentes")
        }
        mediaURL = capabilities.first("Media")?.value("XAddr").flatMap(normalizeServiceURL)
        ptzURL = capabilities.first("PTZ")?.value("XAddr").flatMap(normalizeServiceURL)
        imagingURL = capabilities.first("Imaging")?.value("XAddr").flatMap(normalizeServiceURL)
        guard mediaURL != nil else { throw ONVIFError.unsupported("Le service Media ONVIF") }
    }

    /// Cameras behind NAT, or simply misconfigured, advertise service URLs
    /// pointing at an address we cannot reach (their WAN IP, or 127.0.0.1).
    /// The host we already reached is authoritative, so only the path is kept.
    private func normalizeServiceURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        let advertisedHost = components.host
        if advertisedHost != deviceServiceURL.host {
            components.scheme = deviceServiceURL.scheme
            components.host = deviceServiceURL.host
            components.port = deviceServiceURL.port
        }
        return components.url
    }

    private func loadProfile() async throws -> Connection {
        guard let mediaURL else { throw ONVIFError.unsupported("Le service Media ONVIF") }
        let body = "<GetProfiles xmlns=\"\(NS.media)\"/>"
        let root = try await send(to: mediaURL, action: "\(NS.media)/GetProfiles", body: body)

        let profiles = root.all("Profiles")
        guard let profile = profiles.first(where: { $0.attributes["token"] != nil }),
              let token = profile.attributes["token"] else {
            throw ONVIFError.noVideoProfile
        }
        profileToken = token
        videoSourceToken = profile.first("VideoSourceConfiguration")?.value("SourceToken")

        // A PTZ or Imaging endpoint is only usable if this profile is actually
        // wired to the corresponding configuration; advertising the service is
        // not the same as the stream supporting it.
        let profileHasPTZ = profile.first("PTZConfiguration") != nil
        let capabilities = Camera.Capabilities(
            hasMedia: true,
            hasPTZ: ptzURL != nil && profileHasPTZ,
            hasImaging: imagingURL != nil && videoSourceToken != nil
        )

        return Connection(
            capabilities: capabilities,
            profileToken: token,
            profileName: profile.value("Name"),
            videoSourceToken: videoSourceToken
        )
    }

    // MARK: - Media

    /// RTSP address of the live stream, with credentials embedded so the player
    /// can authenticate the stream on its own.
    func streamURL() async throws -> URL {
        guard let mediaURL, let profileToken else { throw ONVIFError.noVideoProfile }
        let body = """
        <GetStreamUri xmlns="\(NS.media)">\
        <StreamSetup>\
        <tt:Stream>RTP-Unicast</tt:Stream>\
        <tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>\
        </StreamSetup>\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        </GetStreamUri>
        """
        let root = try await send(to: mediaURL, action: "\(NS.media)/GetStreamUri", body: body)
        guard let raw = root.value("Uri") else { throw ONVIFError.malformedResponse("URI de flux absente") }
        return try authenticatedStreamURL(from: raw)
    }

    private func authenticatedStreamURL(from raw: String) throws -> URL {
        guard var components = URLComponents(string: raw) else {
            throw ONVIFError.malformedResponse("URI de flux invalide")
        }
        if components.host != deviceServiceURL.host {
            components.host = deviceServiceURL.host
        }
        if let credentials, !credentials.username.isEmpty {
            components.user = credentials.username
            components.password = credentials.password
        }
        guard let url = components.url else {
            throw ONVIFError.malformedResponse("URI de flux invalide")
        }
        return url
    }

    func snapshotURL() async throws -> URL {
        guard let mediaURL, let profileToken else { throw ONVIFError.noVideoProfile }
        let body = """
        <GetSnapshotUri xmlns="\(NS.media)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        </GetSnapshotUri>
        """
        let root = try await send(to: mediaURL, action: "\(NS.media)/GetSnapshotUri", body: body)
        guard let raw = root.value("Uri"), var components = URLComponents(string: raw) else {
            throw ONVIFError.unsupported("L'instantané JPEG")
        }
        if components.host != deviceServiceURL.host {
            components.host = deviceServiceURL.host
            components.port = deviceServiceURL.port
        }
        guard let url = components.url else { throw ONVIFError.unsupported("L'instantané JPEG") }
        return url
    }

    /// Fetches a JPEG still. Authentication is left to the session delegate so
    /// both Basic and Digest work — cameras are split roughly evenly between them.
    func snapshotData() async throws -> Data {
        let url = try await snapshotURL()
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // Some firmware only honours Basic when it is offered pre-emptively.
        if let credentials, !credentials.username.isEmpty,
           let encoded = "\(credentials.username):\(credentials.password)".data(using: .utf8) {
            request.setValue("Basic \(encoded.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw ONVIFError.unauthorized }
            guard (200..<300).contains(http.statusCode) else { throw ONVIFError.httpStatus(http.statusCode) }
        }
        guard !data.isEmpty else { throw ONVIFError.malformedResponse("instantané vide") }
        return data
    }

    // MARK: - PTZ

    func move(_ vector: PTZVector) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.unsupported("Le PTZ") }
        let body = """
        <ContinuousMove xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        <Velocity>\
        <tt:PanTilt x="\(format(vector.pan))" y="\(format(vector.tilt))"/>\
        <tt:Zoom x="\(format(vector.zoom))"/>\
        </Velocity>\
        </ContinuousMove>
        """
        _ = try await send(to: ptzURL, action: "\(NS.ptz)/ContinuousMove", body: body)
    }

    func stopMove() async throws {
        guard let ptzURL, let profileToken else { return }
        let body = """
        <Stop xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        <PanTilt>true</PanTilt><Zoom>true</Zoom>\
        </Stop>
        """
        _ = try await send(to: ptzURL, action: "\(NS.ptz)/Stop", body: body)
    }

    func presets() async throws -> [PTZPreset] {
        guard let ptzURL, let profileToken else { return [] }
        let body = """
        <GetPresets xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        </GetPresets>
        """
        let root = try await send(to: ptzURL, action: "\(NS.ptz)/GetPresets", body: body)
        return root.all("Preset").compactMap { node in
            guard let token = node.attributes["token"] else { return nil }
            return PTZPreset(token: token, name: node.value("Name") ?? "Position \(token)")
        }
    }

    func gotoPreset(token: String) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.unsupported("Le PTZ") }
        let body = """
        <GotoPreset xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        <PresetToken>\(SOAPXML.escape(token))</PresetToken>\
        </GotoPreset>
        """
        _ = try await send(to: ptzURL, action: "\(NS.ptz)/GotoPreset", body: body)
    }

    @discardableResult
    func savePreset(name: String) async throws -> String? {
        guard let ptzURL, let profileToken else { throw ONVIFError.unsupported("Le PTZ") }
        let body = """
        <SetPreset xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        <PresetName>\(SOAPXML.escape(name))</PresetName>\
        </SetPreset>
        """
        let root = try await send(to: ptzURL, action: "\(NS.ptz)/SetPreset", body: body)
        return root.value("PresetToken")
    }

    func removePreset(token: String) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.unsupported("Le PTZ") }
        let body = """
        <RemovePreset xmlns="\(NS.ptz)">\
        <ProfileToken>\(SOAPXML.escape(profileToken))</ProfileToken>\
        <PresetToken>\(SOAPXML.escape(token))</PresetToken>\
        </RemovePreset>
        """
        _ = try await send(to: ptzURL, action: "\(NS.ptz)/RemovePreset", body: body)
    }

    // MARK: - Imaging

    /// Reads the ranges this camera actually accepts. Written back values outside
    /// them are rejected outright by most firmware, which is why the UI's 0...1
    /// is only converted at the last moment, here.
    func imagingOptions() async throws -> ImagingOptions {
        guard let imagingURL, let videoSourceToken else { throw ONVIFError.unsupported("Le réglage d'image") }
        let body = """
        <GetOptions xmlns="\(NS.imaging)">\
        <VideoSourceToken>\(SOAPXML.escape(videoSourceToken))</VideoSourceToken>\
        </GetOptions>
        """
        let root = try await send(to: imagingURL, action: "\(NS.imaging)/GetOptions", body: body)
        guard let options = root.first("ImagingOptions") else { return .permissive }

        func range(_ name: String) -> ImagingRange? {
            guard let node = options.first(name),
                  let minimum = node.doubleValue("Min"),
                  let maximum = node.doubleValue("Max") else { return nil }
            return ImagingRange(minimum: minimum, maximum: maximum)
        }

        let irModes = options.all("IrCutFilterModes")
            .compactMap { ImagingSettings.IRCutMode(rawValue: $0.trimmedText) }

        return ImagingOptions(
            brightness: range("Brightness"),
            contrast: range("Contrast"),
            colorSaturation: range("ColorSaturation"),
            sharpness: range("Sharpness"),
            supportsBacklightCompensation: options.first("BacklightCompensation") != nil,
            supportsWideDynamicRange: options.first("WideDynamicRange") != nil,
            irCutModes: irModes.isEmpty ? ImagingSettings.IRCutMode.allCases : irModes
        )
    }

    func imagingSettings(options: ImagingOptions) async throws -> ImagingSettings {
        guard let imagingURL, let videoSourceToken else { throw ONVIFError.unsupported("Le réglage d'image") }
        let body = """
        <GetImagingSettings xmlns="\(NS.imaging)">\
        <VideoSourceToken>\(SOAPXML.escape(videoSourceToken))</VideoSourceToken>\
        </GetImagingSettings>
        """
        let root = try await send(to: imagingURL, action: "\(NS.imaging)/GetImagingSettings", body: body)
        guard let node = root.first("ImagingSettings") else {
            throw ONVIFError.malformedResponse("réglages d'image absents")
        }

        var settings = ImagingSettings()
        if let value = node.doubleValue("Brightness") {
            settings.brightness = (options.brightness ?? .standard).normalize(value)
        }
        if let value = node.doubleValue("Contrast") {
            settings.contrast = (options.contrast ?? .standard).normalize(value)
        }
        if let value = node.doubleValue("ColorSaturation") {
            settings.colorSaturation = (options.colorSaturation ?? .standard).normalize(value)
        }
        if let value = node.doubleValue("Sharpness") {
            settings.sharpness = (options.sharpness ?? .standard).normalize(value)
        }
        // These are wrapper elements, so the mode has to be read from the child —
        // reading the wrapper's own text yields whitespace.
        if let mode = node.first("BacklightCompensation")?.value("Mode") {
            settings.backlightCompensation = mode.uppercased() == "ON"
        }
        if let mode = node.first("WideDynamicRange")?.value("Mode") {
            settings.wideDynamicRange = mode.uppercased() == "ON"
        }
        if let raw = node.value("IrCutFilter"), let mode = ImagingSettings.IRCutMode(rawValue: raw.uppercased()) {
            settings.irCutFilter = mode
        }
        return settings
    }

    /// Writes settings back, emitting only the fields this camera advertised.
    /// Sending an unsupported field makes many devices reject the whole request.
    func applyImaging(_ settings: ImagingSettings, options: ImagingOptions) async throws {
        guard let imagingURL, let videoSourceToken else { throw ONVIFError.unsupported("Le réglage d'image") }

        var fields = ""
        if let range = options.brightness {
            fields += "<tt:Brightness>\(format(range.denormalize(settings.brightness)))</tt:Brightness>"
        }
        if let range = options.colorSaturation {
            fields += "<tt:ColorSaturation>\(format(range.denormalize(settings.colorSaturation)))</tt:ColorSaturation>"
        }
        if let range = options.contrast {
            fields += "<tt:Contrast>\(format(range.denormalize(settings.contrast)))</tt:Contrast>"
        }
        if let range = options.sharpness {
            fields += "<tt:Sharpness>\(format(range.denormalize(settings.sharpness)))</tt:Sharpness>"
        }
        if options.supportsBacklightCompensation {
            fields += "<tt:BacklightCompensation><tt:Mode>\(settings.backlightCompensation ? "ON" : "OFF")</tt:Mode></tt:BacklightCompensation>"
        }
        if options.supportsWideDynamicRange {
            fields += "<tt:WideDynamicRange><tt:Mode>\(settings.wideDynamicRange ? "ON" : "OFF")</tt:Mode></tt:WideDynamicRange>"
        }
        if options.irCutModes.contains(settings.irCutFilter) {
            fields += "<tt:IrCutFilter>\(settings.irCutFilter.rawValue)</tt:IrCutFilter>"
        }
        guard !fields.isEmpty else { return }

        let body = """
        <SetImagingSettings xmlns="\(NS.imaging)">\
        <VideoSourceToken>\(SOAPXML.escape(videoSourceToken))</VideoSourceToken>\
        <ImagingSettings>\(fields)</ImagingSettings>\
        <ForcePersistence>true</ForcePersistence>\
        </SetImagingSettings>
        """
        _ = try await send(to: imagingURL, action: "\(NS.imaging)/SetImagingSettings", body: body)
    }

    // MARK: - Helpers

    /// ONVIF numeric fields must be plain decimals: a locale-formatted "0,5" or
    /// an exponent form like "1e-05" is rejected by most parsers.
    private nonisolated func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    /// Probes the conventional ONVIF endpoints on a host, in the order cameras
    /// most commonly use them. Returns the first that answers as a real device.
    static func discoverServiceURL(host: String, ports: [Int]) async -> URL? {
        let paths = ["/onvif/device_service", "/onvif/device", "/onvif/services"]
        for port in ports {
            for path in paths {
                guard let url = URL(string: "http://\(host):\(port)\(path)") else { continue }
                let client = ONVIFClient(deviceServiceURL: url, timeout: 3)
                if (try? await client.deviceInformation()) != nil {
                    return url
                }
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }
}

/// Answers HTTP auth challenges for both SOAP calls and snapshot fetches.
///
/// URLSession negotiates Digest itself once a credential is supplied, which is
/// the only reason snapshots work on the many cameras that refuse Basic.
private final class AuthChallengeHandler: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: CameraCredentials?

    init(credentials: CameraCredentials?) {
        self.credentials = credentials
    }

    func update(credentials: CameraCredentials?) {
        lock.lock()
        defer { lock.unlock() }
        self.credentials = credentials
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodNTLM else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Retrying the same rejected password loops until the camera locks out.
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.lock()
        let current = credentials
        lock.unlock()

        guard let current, !current.username.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(
            user: current.username,
            password: current.password,
            persistence: .forSession
        ))
    }
}
