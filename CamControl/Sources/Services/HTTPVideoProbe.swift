import Foundation

/// Finds a picture on a camera that serves no RTSP at all.
///
/// A large share of consumer cameras — older Foscam, D-Link, TP-Link, and most
/// of the unbranded ones — never implemented RTSP. They put the video on their
/// web port instead, as an endless multipart JPEG stream, and where even that is
/// missing they still answer with a single still image. Looking only for RTSP
/// declares those cameras unwatchable when their own web page shows them fine.
///
/// Three things are worth finding, in descending order:
///
/// - **MJPEG** (`multipart/x-mixed-replace`) — a real moving picture the decoder
///   plays exactly like a stream.
/// - **HLS** — the same, for the few cameras that offer it.
/// - **A still image** — not video, and never presented as though it were, but a
///   picture refreshed a few times a second is what the camera's own interface
///   does, and it is the difference between seeing the room and seeing nothing.
enum HTTPVideoProbe {

    enum Content: Equatable {
        /// An endless multipart stream of JPEG frames.
        case motionJPEG
        /// An HLS playlist.
        case playlist
        /// One still image, meant to be fetched again.
        case stillImage

        var isMoving: Bool { self != .stillImage }
    }

    enum Reply: Equatable {
        case found(Content)
        /// The camera wants credentials it has not been given, or refused them.
        case unauthorized
        /// Answered, but with something that is not a picture.
        case notAPicture
        case noReply
    }

    /// Fetches just far enough into a response to read its headers.
    ///
    /// Raw rather than `URLSession` for one specific reason: an MJPEG response
    /// never ends. A URL loading task would sit there accumulating frames until
    /// it timed out, and report failure for the very thing being looked for.
    /// Reading one bufferful gives the status line and the content type, which is
    /// the whole question.
    static func fetch(
        _ url: URL,
        credentials: CameraCredentials?,
        timeout: TimeInterval = 3
    ) async -> Reply {
        guard let host = url.host else { return .noReply }
        let port = url.port.flatMap { UInt16(exactly: $0) } ?? 80
        let target = requestTarget(of: url)

        guard let first = await send(
            host: host, port: port, target: target,
            authorization: nil, timeout: timeout
        ) else { return .noReply }

        guard let status = MessageHeaders.statusCode(in: first) else { return .noReply }
        if let content = classify(first, status: status) { return .found(content) }
        guard status == 401 else { return .notAPicture }

        guard let credentials, !credentials.username.isEmpty,
              let challenge = MessageHeaders.value("WWW-Authenticate", in: first),
              let authorization = WWWAuthenticate.authorization(
                  for: challenge,
                  method: "GET",
                  target: target,
                  credentials: credentials
              )
        else { return .unauthorized }

        guard let second = await send(
            host: host, port: port, target: target,
            authorization: authorization, timeout: timeout
        ) else { return .noReply }

        guard let retried = MessageHeaders.statusCode(in: second) else { return .noReply }
        if let content = classify(second, status: retried) { return .found(content) }
        return retried == 401 ? .unauthorized : .notAPicture
    }

    /// What the response is, judging by its declared type. Only a 200 counts: a
    /// camera's 404 page is `text/html` and a redirect carries no picture.
    static func classify(_ reply: String, status: Int) -> Content? {
        guard status == 200 else { return nil }
        guard let type = MessageHeaders.value("Content-Type", in: reply)?.lowercased() else { return nil }

        if type.contains("multipart") { return .motionJPEG }
        if type.contains("mpegurl") { return .playlist }
        if type.contains("image/jpeg") || type.contains("image/jpg") { return .stillImage }
        // Anything else claiming to be video plays too; VLC is not fussy.
        if type.hasPrefix("video/") { return .motionJPEG }
        return nil
    }

    /// The request-URI for an HTTP request line — path and query, never the
    /// whole address. The digest is computed over this same string.
    static func requestTarget(of url: URL) -> String {
        let path = url.path.isEmpty ? "/" : url.path
        return url.query.map { "\(path)?\($0)" } ?? path
    }

    private static func send(
        host: String,
        port: UInt16,
        target: String,
        authorization: String?,
        timeout: TimeInterval
    ) async -> String? {
        var lines = [
            "GET \(target) HTTP/1.1",
            "Host: \(host):\(port)",
            "User-Agent: CamControl",
            "Accept: */*",
            // Asking the camera to hang up means a still image arrives complete
            // and a stream is not held open once its headers have been read.
            "Connection: close"
        ]
        if let authorization {
            lines.append("Authorization: \(authorization)")
        }
        lines.append(contentsOf: ["", ""])

        guard let data = await TCPExchange.send(
            host: host,
            port: port,
            request: Data(lines.joined(separator: "\r\n").utf8),
            timeout: timeout
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Addresses worth trying on a camera's web port.
///
/// Every entry here is a path some shipping camera actually serves. Ordered by
/// how often it turns up, and moving pictures ahead of still ones so a camera
/// that offers both is never reduced to the lesser of the two.
enum HTTPVideoCatalog {

    /// Multipart JPEG and playlist addresses — a real moving picture.
    static let movingPaths = [
        "/videostream.cgi",                                   // Foscam and its many clones
        "/video.cgi",
        "/mjpg/video.mjpg",                                   // Axis, and everything that copied it
        "/axis-cgi/mjpg/video.cgi",
        "/cgi-bin/mjpg/video.cgi?channel=0&subtype=1",        // Dahua
        "/ISAPI/Streaming/channels/101/httpPreview",          // Hikvision
        "/cgi-bin/viewer/video.jpg",                          // Vivotek
        "/videostream.asf",
        "/video.mjpg",
        "/mjpeg",
        "/video/mjpg.cgi",
        "/live/0/mjpeg.jpg",
        "/nphMotionJpeg?Resolution=640x480&Quality=Standard", // Panasonic
        "/goform/video",
        "/hls/stream.m3u8",
        "/live/stream.m3u8",
        "/video"
    ]

    /// Still-image addresses, the last thing worth trying.
    static let stillPaths = [
        "/snapshot.cgi",
        "/cgi-bin/snapshot.cgi",
        "/tmpfs/auto.jpg",                                    // Dahua and much white-label firmware
        "/tmpfs/snap.jpg",
        "/snap.jpg",
        "/image.jpg",
        "/image/jpeg.cgi",
        "/jpg/image.jpg",
        "/axis-cgi/jpg/image.cgi",
        "/ISAPI/Streaming/channels/101/picture",              // Hikvision
        "/cgi-bin/api.cgi?cmd=Snap&channel=0",                // Reolink
        "/onvif-http/snapshot?Profile_1",
        "/cgi-bin/currentpic.cgi",
        "/webcapture.jpg?command=snap&channel=1",
        "/snapshot",
        "/capture"
    ]

    /// Every address worth trying on one port, moving pictures first.
    static func candidates(host: String, port: Int, credentials: CameraCredentials?) -> [URL] {
        (movingPaths + stillPaths).compactMap {
            url(host: host, port: port, path: $0, credentials: credentials)
        }
    }

    private static func url(
        host: String,
        port: Int,
        path: String,
        credentials: CameraCredentials?
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        // Split, or URLComponents percent-encodes the "?" and the camera answers
        // 404 to a path that now contains a literal question mark.
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
