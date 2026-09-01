import Foundation
import Network

/// Asks a host what it is once ONVIF has declined to say.
///
/// Plenty of cameras never speak ONVIF — either the vendor never implemented it,
/// or it ships disabled — and they are exactly the ones a scan would otherwise
/// list as an anonymous open port. Two cheap questions recover most of them:
///
/// - **RTSP `OPTIONS`** is answered by every RTSP server, including the ones that
///   then demand credentials for anything else. A reply is proof of a video
///   stream, and its `Server` header is usually the product name.
/// - **HTTP on the admin port**, where the `Server` header, the authentication
///   realm and the page title carry the model. Vendors put recognisable names in
///   the realm — `IPCam Login`, `DS-2CD2042WD`, `Dahua RTSP Server` — because it
///   is what their own users see.
enum DeviceFingerprint {

    struct Identity: Equatable {
        /// The line worth showing: a `Server` header, a login realm, a page title.
        var banner: String?
        /// The reply proved a video stream is being served here.
        var servesVideo = false
        /// A manufacturer recognised inside the banner.
        var vendor: String?

        /// Whether anything here says "camera" rather than "some device".
        var identifiesACamera: Bool { servesVideo || vendor != nil }
    }

    // MARK: - RTSP

    /// Sends one `OPTIONS` request and reads the status line and headers.
    ///
    /// Any RTSP status counts, 401 included: a server that refuses the request is
    /// still a server, and refusing is what a correctly configured camera does.
    static func rtsp(host: String, port: UInt16, timeout: TimeInterval = 2.5) async -> Identity? {
        let request = [
            "OPTIONS rtsp://\(host):\(port)/ RTSP/1.0",
            "CSeq: 1",
            "User-Agent: CamControl",
            "",
            ""
        ].joined(separator: "\r\n")

        guard let data = await exchange(
            host: host,
            port: port,
            request: Data(request.utf8),
            timeout: timeout
        ) else { return nil }

        let reply = String(decoding: data, as: UTF8.self)
        guard reply.hasPrefix("RTSP/") else { return nil }

        let banner = headerValue("Server", in: reply) ?? realm(in: reply)
        return Identity(banner: banner, servesVideo: true, vendor: banner.flatMap(vendor(in:)))
    }

    // MARK: - HTTP

    /// Reads the identifying headers from a camera's web interface.
    ///
    /// A 401 is the interesting case rather than a failure, so no credentials are
    /// offered and no challenge is answered: the realm in the rejection is the
    /// most reliable model string a camera hands out unauthenticated.
    static func http(host: String, port: Int, timeout: TimeInterval = 2.5) async -> Identity? {
        guard let url = URL(string: "http://\(host):\(port)/") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("CamControl", forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }

        let server = http.value(forHTTPHeaderField: "Server")
        let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate").flatMap(realmValue(in:))
        let title = pageTitle(in: data)

        let banner = [challenge, server, title].compactMap { $0 }.first { !$0.isEmpty }
        let haystack = [server, challenge, title].compactMap { $0 }.joined(separator: " ")
        guard !haystack.isEmpty else { return nil }

        return Identity(
            banner: banner,
            servesVideo: false,
            vendor: vendor(in: haystack) ?? (looksLikeCamera(haystack) ? "Caméra" : nil)
        )
    }

    // MARK: - Recognition

    /// Manufacturer names as they actually appear in banners and login realms.
    /// Lower-cased needles, matched against a lower-cased haystack.
    private static let vendorSignatures: [(needle: String, name: String)] = [
        ("hikvision", "Hikvision"),
        ("ds-2cd", "Hikvision"),
        ("hilook", "HiLook"),
        ("ezviz", "EZVIZ"),
        ("dahua", "Dahua"),
        ("imou", "Imou"),
        ("amcrest", "Amcrest"),
        ("reolink", "Reolink"),
        ("foscam", "Foscam"),
        ("tp-link", "TP-Link"),
        ("tapo", "Tapo"),
        ("axis", "Axis"),
        ("vivotek", "Vivotek"),
        ("uniview", "Uniview"),
        ("milesight", "Milesight"),
        ("mobotix", "Mobotix"),
        ("hanwha", "Hanwha Vision"),
        ("wisenet", "Hanwha Vision"),
        ("bosch", "Bosch"),
        ("annke", "Annke"),
        ("swann", "Swann"),
        ("lorex", "Lorex"),
        ("ubnt", "Ubiquiti"),
        ("unifi", "Ubiquiti"),
        ("wyze", "Wyze"),
        ("tenvis", "Tenvis"),
        ("vstarcam", "VStarcam"),
        ("jovision", "Jovision"),
        ("sricam", "Sricam"),
        ("instar", "INSTAR"),
        ("geovision", "GeoVision"),
        ("tiandy", "Tiandy"),
        ("xiongmai", "XiongMai"),
        ("goahead", "XiongMai")
    ]

    /// Generic words that mean "video device" without naming a maker. Weaker
    /// evidence than a vendor name, and deliberately narrow: "web" or "server"
    /// would match half the printers on a network.
    private static let cameraWords = [
        "ipcam", "ip camera", "netcam", "webcam", "network camera",
        "ipc", "nvr", "dvr", "surveillance", "camera"
    ]

    static func vendor(in text: String) -> String? {
        let haystack = text.lowercased()
        return vendorSignatures.first { haystack.contains($0.needle) }?.name
    }

    static func looksLikeCamera(_ text: String) -> Bool {
        let haystack = text.lowercased()
        return cameraWords.contains { haystack.contains($0) }
    }

    // MARK: - Header parsing

    /// Reads one header out of a raw RTSP reply. RTSP headers follow HTTP's
    /// grammar, so this is the same `Name: value` split, case-insensitive.
    static func headerValue(_ name: String, in reply: String) -> String? {
        let prefix = (name + ":").lowercased()
        for line in reply.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            guard line.lowercased().hasPrefix(prefix) else { continue }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The realm from a `WWW-Authenticate` header anywhere in a raw reply.
    static func realm(in reply: String) -> String? {
        headerValue("WWW-Authenticate", in: reply).flatMap(realmValue(in:))
    }

    /// `Digest realm="Login to DS-2CD2042", nonce="…"` → `Login to DS-2CD2042`.
    static func realmValue(in header: String) -> String? {
        guard let range = header.range(of: "realm=", options: .caseInsensitive) else { return nil }
        var rest = header[range.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let value = String(rest[..<end])
            return value.isEmpty ? nil : value
        }
        let value = String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The `<title>` of a login page, which on many cameras is the model number.
    static func pageTitle(in data: Data) -> String? {
        // Only the head of the document: a login page puts its title in the first
        // few hundred bytes, and decoding a megabyte of MJPEG would be pointless.
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let contentStart = head[open.upperBound...].firstIndex(of: ">"),
              let close = head.range(of: "</title>", options: .caseInsensitive) else { return nil }
        let start = head.index(after: contentStart)
        guard start < close.lowerBound else { return nil }
        let title = head[start..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    // MARK: - Transport

    /// One request, one response, one connection. Deliberately raw rather than
    /// `URLSession`: RTSP is not HTTP, and no URL loading system will speak it.
    private static func exchange(
        host: String,
        port: UInt16,
        request: Data,
        timeout: TimeInterval
    ) async -> Data? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
        let box = ResumeBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                @Sendable func finish(_ value: Data?) {
                    guard box.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: value)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        connection.send(content: request, completion: .contentProcessed { error in
                            guard error == nil else { return finish(nil) }
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                                finish(data)
                            }
                        })
                    case .failed, .cancelled, .waiting:
                        finish(nil)
                    case .preparing, .setup:
                        break
                    @unknown default:
                        finish(nil)
                    }
                }
                connection.start(queue: fingerprintQueue)

                fingerprintQueue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private static let fingerprintQueue = DispatchQueue(
        label: "fingerprint",
        qos: .userInitiated,
        attributes: .concurrent
    )
}
