import Foundation

/// Talks ONVIF SOAP to a single camera: device info, media profiles/URIs,
/// PTZ movement, and the Imaging service (brightness/contrast/saturation/
/// sharpness/IR-cut/WDR — the "filtre caméra" hardware controls).
///
/// ONVIF services live at different URLs which we discover from the device
/// service's GetCapabilities response; we cache them on first use.
final class ONVIFClient {
    enum ONVIFError: Error { case noServiceURL, http(Int), malformedResponse, unauthorized }

    let camera: Camera
    private var credentials: CameraCredentials?
    private var mediaURL: URL?
    private var ptzURL: URL?
    private var imagingURL: URL?
    private var profileToken: String?
    private var videoSourceToken: String?

    init(camera: Camera, credentials: CameraCredentials? = nil) {
        self.camera = camera
        self.credentials = credentials
    }

    func updateCredentials(_ credentials: CameraCredentials) {
        self.credentials = credentials
    }

    // MARK: - Low-level SOAP call

    private func call(_ url: URL, action: String, body: String, authenticated: Bool) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 6

        let header: String
        if authenticated, let credentials {
            header = SOAPXML.securityHeader(username: credentials.username, password: credentials.password)
        } else {
            header = ""
        }
        request.httpBody = SOAPXML.envelope(header: header, body: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ONVIFError.malformedResponse }
        guard let text = String(data: data, encoding: .utf8) else { throw ONVIFError.malformedResponse }

        if http.statusCode == 401 { throw ONVIFError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw ONVIFError.http(http.statusCode) }
        return text
    }

    /// Tries the ONVIF default device-service path on common ports; used when
    /// WS-Discovery didn't answer (multicast unavailable) but a port scan found
    /// an HTTP-looking service.
    static func probeDefaultServiceURL(ip: String) async -> URL? {
        for port in [80, 8080, 8000] {
            guard let url = URL(string: "http://\(ip):\(port)/onvif/device_service") else { continue }
            let client = ONVIFClient(camera: Camera(id: ip, ipAddress: ip, kind: .onvif, onvifServiceURL: url))
            if (try? await client.fetchDeviceInfoUnauthenticated()) != nil {
                return url
            }
        }
        return nil
    }

    // MARK: - Device management

    struct DeviceInfo { let manufacturer: String?; let model: String?; let firmwareVersion: String? }

    /// GetDeviceInformation without auth headers — most cameras answer this one
    /// unauthenticated just to advertise themselves; if not, we retry with credentials.
    func fetchDeviceInfoUnauthenticated() async throws -> DeviceInfo {
        guard let url = camera.onvifServiceURL else { throw ONVIFError.noServiceURL }
        let body = """
        <GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>
        """
        let xml: String
        do {
            xml = try await call(url, action: "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation", body: body, authenticated: false)
        } catch ONVIFError.unauthorized where credentials != nil {
            xml = try await call(url, action: "http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation", body: body, authenticated: true)
        }
        return DeviceInfo(
            manufacturer: SOAPXML.firstValue(xml, tag: "Manufacturer"),
            model: SOAPXML.firstValue(xml, tag: "Model"),
            firmwareVersion: SOAPXML.firstValue(xml, tag: "FirmwareVersion")
        )
    }

    /// Discovers Media/PTZ/Imaging service URLs via GetCapabilities. Call once
    /// credentials are known, before using any of the calls below.
    func loadCapabilities() async throws {
        guard let url = camera.onvifServiceURL else { throw ONVIFError.noServiceURL }
        let body = """
        <GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl">
          <Category>All</Category>
        </GetCapabilities>
        """
        let xml = try await call(url, action: "http://www.onvif.org/ver10/device/wsdl/GetCapabilities", body: body, authenticated: true)
        mediaURL = SOAPXML.firstValue(xml, tag: "XAddr").flatMap(URL.init(string:))

        // Media, PTZ, Imaging each have their own <XAddr> inside their own block; grab per-block.
        if let mediaBlock = SOAPXML.allBlocks(xml, tag: "Media").first ?? SOAPXML.allBlocks(xml, tag: "Media2").first {
            mediaURL = SOAPXML.firstValue(mediaBlock, tag: "XAddr").flatMap(URL.init(string:)) ?? mediaURL
        }
        if let ptzBlock = SOAPXML.allBlocks(xml, tag: "PTZ").first {
            ptzURL = SOAPXML.firstValue(ptzBlock, tag: "XAddr").flatMap(URL.init(string:))
        }
        if let imagingBlock = SOAPXML.allBlocks(xml, tag: "Imaging").first {
            imagingURL = SOAPXML.firstValue(imagingBlock, tag: "XAddr").flatMap(URL.init(string:))
        }
        try await loadFirstProfile()
    }

    // MARK: - Media

    private func loadFirstProfile() async throws {
        guard let mediaURL else { return }
        let body = """
        <GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>
        """
        let xml = try await call(mediaURL, action: "http://www.onvif.org/ver10/media/wsdl/GetProfiles", body: body, authenticated: true)
        guard let firstProfile = SOAPXML.allBlocks(xml, tag: "Profiles").first else { return }
        profileToken = SOAPXML.firstAttribute(firstProfile, tag: "Profiles", attribute: "token")
            ?? extractTokenFallback(xml: xml)
        videoSourceToken = SOAPXML.firstValue(firstProfile, tag: "SourceToken")
    }

    private func extractTokenFallback(xml: String) -> String? {
        SOAPXML.firstAttribute(xml, tag: "Profiles", attribute: "token")
    }

    func fetchStreamURL() async throws -> URL {
        guard let mediaURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl">
          <StreamSetup>
            <Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>
            <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>
          </StreamSetup>
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
        </GetStreamUri>
        """
        let xml = try await call(mediaURL, action: "http://www.onvif.org/ver10/media/wsdl/GetStreamUri", body: body, authenticated: true)
        guard let uriString = SOAPXML.firstValue(xml, tag: "Uri"), var components = URLComponents(string: uriString) else {
            throw ONVIFError.malformedResponse
        }
        // Embed credentials in the RTSP URL so the player can authenticate the stream itself.
        if let credentials {
            components.user = credentials.username
            components.password = credentials.password
        }
        guard let url = components.url else { throw ONVIFError.malformedResponse }
        return url
    }

    func fetchSnapshotURL() async throws -> URL {
        guard let mediaURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <GetSnapshotUri xmlns="http://www.onvif.org/ver10/media/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
        </GetSnapshotUri>
        """
        let xml = try await call(mediaURL, action: "http://www.onvif.org/ver10/media/wsdl/GetSnapshotUri", body: body, authenticated: true)
        guard let uriString = SOAPXML.firstValue(xml, tag: "Uri"), let url = URL(string: uriString) else {
            throw ONVIFError.malformedResponse
        }
        return url
    }

    // MARK: - PTZ

    var supportsPTZ: Bool { ptzURL != nil && profileToken != nil }

    func ptzContinuousMove(_ vector: PTZVector) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <ContinuousMove xmlns="http://www.onvif.org/ver10/ptz/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
          <Velocity>
            <PanTilt xmlns="http://www.onvif.org/ver10/schema" x="\(vector.pan)" y="\(vector.tilt)"/>
            <Zoom xmlns="http://www.onvif.org/ver10/schema" x="\(vector.zoom)"/>
          </Velocity>
        </ContinuousMove>
        """
        _ = try await call(ptzURL, action: "http://www.onvif.org/ver10/ptz/wsdl/ContinuousMove", body: body, authenticated: true)
    }

    func ptzStop() async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <Stop xmlns="http://www.onvif.org/ver10/ptz/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
          <PanTilt>true</PanTilt>
          <Zoom>true</Zoom>
        </Stop>
        """
        _ = try await call(ptzURL, action: "http://www.onvif.org/ver10/ptz/wsdl/Stop", body: body, authenticated: true)
    }

    func fetchPresets() async throws -> [PTZPreset] {
        guard let ptzURL, let profileToken else { return [] }
        let body = """
        <GetPresets xmlns="http://www.onvif.org/ver10/ptz/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
        </GetPresets>
        """
        let xml = try await call(ptzURL, action: "http://www.onvif.org/ver10/ptz/wsdl/GetPresets", body: body, authenticated: true)
        return SOAPXML.allBlocks(xml, tag: "Preset").compactMap { block in
            guard let token = SOAPXML.firstAttribute(block, tag: "Preset", attribute: "token") else { return nil }
            let name = SOAPXML.firstValue(block, tag: "Name") ?? token
            return PTZPreset(token: token, name: name)
        }
    }

    func gotoPreset(token: String) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <GotoPreset xmlns="http://www.onvif.org/ver10/ptz/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
          <PresetToken>\(SOAPXML.xmlEscape(token))</PresetToken>
        </GotoPreset>
        """
        _ = try await call(ptzURL, action: "http://www.onvif.org/ver10/ptz/wsdl/GotoPreset", body: body, authenticated: true)
    }

    func setPreset(name: String) async throws {
        guard let ptzURL, let profileToken else { throw ONVIFError.malformedResponse }
        let body = """
        <SetPreset xmlns="http://www.onvif.org/ver10/ptz/wsdl">
          <ProfileToken>\(SOAPXML.xmlEscape(profileToken))</ProfileToken>
          <PresetName>\(SOAPXML.xmlEscape(name))</PresetName>
        </SetPreset>
        """
        _ = try await call(ptzURL, action: "http://www.onvif.org/ver10/ptz/wsdl/SetPreset", body: body, authenticated: true)
    }

    // MARK: - Imaging ("filtre caméra": brightness/contrast/saturation/sharpness/IR/WDR)

    var supportsImaging: Bool { imagingURL != nil && videoSourceToken != nil }

    func fetchImagingSettings() async throws -> ImagingSettings {
        guard let imagingURL, let videoSourceToken else { throw ONVIFError.malformedResponse }
        let body = """
        <GetImagingSettings xmlns="http://www.onvif.org/ver20/imaging/wsdl">
          <VideoSourceToken>\(SOAPXML.xmlEscape(videoSourceToken))</VideoSourceToken>
        </GetImagingSettings>
        """
        let xml = try await call(imagingURL, action: "http://www.onvif.org/ver20/imaging/wsdl/GetImagingSettings", body: body, authenticated: true)
        var settings = ImagingSettings()
        if let v = SOAPXML.firstValue(xml, tag: "Brightness"), let d = Double(v) { settings.brightness = normalize(d) }
        if let v = SOAPXML.firstValue(xml, tag: "ColorSaturation"), let d = Double(v) { settings.colorSaturation = normalize(d) }
        if let v = SOAPXML.firstValue(xml, tag: "Contrast"), let d = Double(v) { settings.contrast = normalize(d) }
        if let v = SOAPXML.firstValue(xml, tag: "Sharpness"), let d = Double(v) { settings.sharpness = normalize(d) }
        if let v = SOAPXML.firstValue(xml, tag: "BacklightCompensation") { settings.backlightCompensation = SOAPXML.firstValue(v, tag: "Mode") == "ON" }
        if let v = SOAPXML.firstValue(xml, tag: "WideDynamicRange") { settings.wideDynamicRange = SOAPXML.firstValue(v, tag: "Mode") == "ON" }
        if let v = SOAPXML.firstValue(xml, tag: "IrCutFilter"), let mode = ImagingSettings.IRCutMode(rawValue: v) { settings.irCutFilter = mode }
        return settings
    }

    /// ONVIF ranges are typically 0...100; the UI works in 0...1, so we scale both ways.
    private func normalize(_ value: Double) -> Double { min(max(value / 100.0, 0), 1) }
    private func denormalize(_ value: Double) -> Double { min(max(value, 0), 1) * 100.0 }

    func applyImagingSettings(_ settings: ImagingSettings) async throws {
        guard let imagingURL, let videoSourceToken else { throw ONVIFError.malformedResponse }
        let body = """
        <SetImagingSettings xmlns="http://www.onvif.org/ver20/imaging/wsdl">
          <VideoSourceToken>\(SOAPXML.xmlEscape(videoSourceToken))</VideoSourceToken>
          <ImagingSettings xmlns:tt="http://www.onvif.org/ver10/schema">
            <tt:Brightness>\(denormalize(settings.brightness))</tt:Brightness>
            <tt:ColorSaturation>\(denormalize(settings.colorSaturation))</tt:ColorSaturation>
            <tt:Contrast>\(denormalize(settings.contrast))</tt:Contrast>
            <tt:Sharpness>\(denormalize(settings.sharpness))</tt:Sharpness>
            <tt:BacklightCompensation><tt:Mode>\(settings.backlightCompensation ? "ON" : "OFF")</tt:Mode></tt:BacklightCompensation>
            <tt:WideDynamicRange><tt:Mode>\(settings.wideDynamicRange ? "ON" : "OFF")</tt:Mode></tt:WideDynamicRange>
            <tt:IrCutFilter>\(settings.irCutFilter.rawValue)</tt:IrCutFilter>
          </ImagingSettings>
          <ForcePersistence>true</ForcePersistence>
        </SetImagingSettings>
        """
        _ = try await call(imagingURL, action: "http://www.onvif.org/ver20/imaging/wsdl/SetImagingSettings", body: body, authenticated: true)
    }
}
