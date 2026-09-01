import Foundation

/// Stream paths to try on a camera that does not answer ONVIF.
///
/// Without ONVIF there is no way to *ask* a camera where its stream lives, and
/// `rtsp://host:554/` on its own works on almost nothing. Every vendor uses its
/// own path, so the player walks this list until one produces video. The list is
/// ordered by how common each path is, and reordered when the manufacturer is
/// known, so the usual case connects on the first try.
///
/// This is path discovery on a device the user picked, not credential guessing:
/// whatever credentials are used are the ones the user already provided.
enum RTSPPathCatalog {

    /// Paths keyed by the manufacturer string cameras report, lowercased.
    private static let byManufacturer: [String: [String]] = [
        "hikvision": ["/Streaming/Channels/101", "/Streaming/Channels/102", "/h264/ch1/main/av_stream", "/ISAPI/Streaming/Channels/101"],
        "hilook": ["/Streaming/Channels/101", "/Streaming/Channels/102"],
        "ezviz": ["/h264/ch1/main/av_stream", "/Streaming/Channels/101"],
        "annke": ["/Streaming/Channels/101", "/Streaming/Channels/102"],
        "tiandy": ["/Streaming/Channels/101"],
        "dahua": ["/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"],
        "amcrest": ["/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"],
        "imou": ["/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"],
        "lorex": ["/cam/realmonitor?channel=1&subtype=0", "/Streaming/Channels/101"],
        "swann": ["/cam/realmonitor?channel=1&subtype=0"],
        "reolink": ["/h264Preview_01_main", "/h264Preview_01_sub", "/Preview_01_main"],
        "foscam": ["/videoMain", "/videoSub"],
        "axis": ["/axis-media/media.amp", "/axis-media/media.amp?videocodec=h264"],
        "tp-link": ["/stream1", "/stream2"],
        "tplink": ["/stream1", "/stream2"],
        "tapo": ["/stream1", "/stream2"],
        "uniview": ["/media/video1", "/media/video2", "/unicast/c1/s0/live"],
        "vivotek": ["/live.sdp", "/live2.sdp"],
        "ubiquiti": ["/s0", "/s1"],
        "milesight": ["/main", "/sub"],
        "hanwha": ["/profile1/media.smp", "/profile2/media.smp"],
        "bosch": ["/rtsp_tunnel"],
        "geovision": ["/CH001.sdp"],
        "mobotix": ["/cam0_0", "/control/faststream.jpg"],
        "instar": ["/11", "/12"],
        "vstarcam": ["/udp/av0_0", "/tcp/av0_0"],
        "jovision": ["/live/ch0", "/profile1"],
        "xiongmai": ["/user=admin&password=&channel=1&stream=0.sdp", "/live/ch00_0"],
        "sricam": ["/onvif1", "/onvif2"],
        "wyze": ["/live"],
        "trendnet": ["/play1.sdp", "/play2.sdp"],
        "d-link": ["/live1.sdp", "/play1.sdp"],
        "zmodo": ["/live/ch00_0"]
    ]

    /// Tried when the manufacturer is unknown, or after its own paths fail.
    ///
    /// Much longer than it used to be, and deliberately so: each entry now costs
    /// one `DESCRIBE` — a single round trip on a local network — rather than a
    /// full decoder timeout. What was unaffordable at ten seconds a guess is
    /// nothing at fifty milliseconds, and breadth here is exactly what makes an
    /// unlabelled camera work.
    private static let generic = [
        // The four families that between them cover most cameras sold.
        "/Streaming/Channels/101",
        "/cam/realmonitor?channel=1&subtype=0",
        "/h264Preview_01_main",
        "/stream1",
        // Widely reused by white-label firmware.
        "/live",
        "/onvif1",
        "/live/ch0",
        "/live/ch00_0",
        "/videoMain",
        "/11",
        "/media/video1",
        "/axis-media/media.amp",
        "/live.sdp",
        "/video",
        "/ch0_0.h264",
        "/user=admin&password=&channel=1&stream=0.sdp",
        // Second streams, which some cameras expose when the first is in use.
        "/Streaming/Channels/102",
        "/cam/realmonitor?channel=1&subtype=1",
        "/h264Preview_01_sub",
        "/stream2",
        "/12",
        "/live/ch1",
        // The long tail, in rough order of how often it turns up.
        "/h264/ch1/main/av_stream",
        "/live/main",
        "/live/0",
        "/0",
        "/1",
        "/ch01/0",
        "/av0_0",
        "/media/video0",
        "/stream0",
        "/profile1",
        "/profile1/media.smp",
        "/videostream.asf",
        "/h264",
        "/mpeg4",
        "/play1.sdp",
        "/nphMpeg4/g726-640x480",
        "/unicast/c1/s0/live",
        "/rtsp_tunnel",
        "/"
    ]

    /// Every stream URL worth trying for this camera, best guess first.
    ///
    /// `ports` overrides the ports to build for. The caller knows which ones
    /// actually answered an RTSP request, which beats anything inferred here.
    static func candidates(
        for camera: Camera,
        credentials: CameraCredentials?,
        ports overridePorts: [Int]? = nil
    ) -> [URL] {
        // An address the user typed in is not a guess, so nothing is tried ahead
        // of it.
        if let override = camera.rtspURLOverride {
            return [authenticated(override, credentials: credentials)]
        }

        // Only ports that carry RTSP. Never simply the first open port: a camera
        // with just its web port open would otherwise be asked for video on port
        // 80, which answers nothing. When the scan saw neither RTSP port — which
        // happens on a camera found only by its hardware address — both are
        // worth offering, because the caller checks a port is open before
        // spending anything on the addresses behind it.
        let found = camera.openPorts.filter { PortScanner.rtspPorts.contains($0) }
        let ports = overridePorts ?? (found.isEmpty ? PortScanner.rtspPorts : found)

        var paths: [String] = []
        if let manufacturer = camera.manufacturer?.lowercased() {
            for (vendor, vendorPaths) in byManufacturer where manufacturer.contains(vendor) {
                paths.append(contentsOf: vendorPaths)
            }
        }
        paths.append(contentsOf: generic)

        var seenPaths = Set<String>()
        let distinct = paths.filter { seenPaths.insert($0).inserted }

        // Port-major, so the whole list is tried on the likeliest port before
        // anything is spent on the alternate one.
        return ports.flatMap { port in
            distinct.compactMap { url(host: camera.host, port: port, path: $0, credentials: credentials) }
        }
    }

    /// Puts the user's credentials into a URL they typed without them.
    static func authenticated(_ url: URL, credentials: CameraCredentials?) -> URL {
        guard let credentials, !credentials.username.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil else { return url }
        components.user = credentials.username
        components.password = credentials.password
        return components.url ?? url
    }

    private static func url(
        host: String,
        port: Int,
        path: String,
        credentials: CameraCredentials?
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "rtsp"
        components.host = host
        components.port = port
        // The query has to be split out, or URLComponents percent-encodes the
        // "?" and Dahua cameras answer 404 to the resulting path.
        if let separator = path.firstIndex(of: "?") {
            components.path = String(path[path.startIndex..<separator])
            components.query = String(path[path.index(after: separator)...])
        } else {
            components.path = path
        }
        if let credentials, !credentials.username.isEmpty {
            components.user = credentials.username
            components.password = credentials.password
        }
        return components.url
    }
}
