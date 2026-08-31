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
        "hikvision": ["/Streaming/Channels/101", "/Streaming/Channels/102", "/h264/ch1/main/av_stream"],
        "dahua": ["/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"],
        "amcrest": ["/cam/realmonitor?channel=1&subtype=0", "/cam/realmonitor?channel=1&subtype=1"],
        "reolink": ["/h264Preview_01_main", "/h264Preview_01_sub", "/Preview_01_main"],
        "foscam": ["/videoMain", "/videoSub"],
        "axis": ["/axis-media/media.amp"],
        "tp-link": ["/stream1", "/stream2"],
        "tplink": ["/stream1", "/stream2"],
        "tapo": ["/stream1", "/stream2"],
        "uniview": ["/media/video1", "/media/video2"],
        "vivotek": ["/live.sdp"],
        "ubiquiti": ["/s0", "/s1"],
        "annke": ["/Streaming/Channels/101"],
        "swann": ["/cam/realmonitor?channel=1&subtype=0"]
    ]

    /// Tried when the manufacturer is unknown, or after its own paths fail.
    private static let generic = [
        "/Streaming/Channels/101",
        "/cam/realmonitor?channel=1&subtype=0",
        "/h264Preview_01_main",
        "/stream1",
        "/live",
        "/onvif1",
        "/live/ch0",
        "/videoMain",
        "/11",
        "/media/video1",
        "/axis-media/media.amp",
        "/live.sdp",
        "/video",
        "/ch0_0.h264",
        "/"
    ]

    /// Every stream URL worth trying for this camera, best guess first.
    static func candidates(for camera: Camera, credentials: CameraCredentials?) -> [URL] {
        // An address the user typed in is not a guess, so nothing is tried ahead
        // of it.
        if let override = camera.rtspURLOverride {
            return [authenticated(override, credentials: credentials)]
        }

        let port = camera.openPorts.contains(554) ? 554 : (camera.openPorts.first ?? 554)

        var paths: [String] = []
        if let manufacturer = camera.manufacturer?.lowercased() {
            for (vendor, vendorPaths) in byManufacturer where manufacturer.contains(vendor) {
                paths.append(contentsOf: vendorPaths)
            }
        }
        paths.append(contentsOf: generic)

        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return url(host: camera.host, port: port, path: path, credentials: credentials)
        }
    }

    /// Puts the user's credentials into a URL they typed without them.
    private static func authenticated(_ url: URL, credentials: CameraCredentials?) -> URL {
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
