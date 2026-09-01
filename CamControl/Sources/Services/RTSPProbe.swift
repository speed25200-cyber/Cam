import Foundation

/// Asks a camera whether a given RTSP address actually carries video.
///
/// This replaces guessing by decoder. Handing VLC one candidate URL after
/// another and reading "did not play" as "wrong path" had two faults, and the
/// second one is what made a camera unwatchable:
///
/// - every wrong guess costs a full decoder timeout, so a fifteen-path walk
///   takes a minute of blank screen;
/// - a failure to play cannot distinguish a wrong path from a camera asking for
///   a password. Both look identical. So a camera whose credentials were simply
///   never entered walked the entire list and then reported "no stream found" —
///   the one answer that is certainly wrong, and the one that offers the user
///   nothing to do about it.
///
/// `DESCRIBE` settles both questions in a single round trip: 200 means this path
/// is the stream, 401 means the path may well be right and the credentials are
/// not. It is also the request every RTSP client sends first anyway, so a camera
/// that answers it is a camera that will play.
enum RTSPProbe {

    enum Reply: Equatable {
        /// This address serves video, with the credentials supplied.
        case ok
        /// The camera wants credentials it has not been given, or refused the
        /// ones it was. Every path answers this way when the password is the
        /// problem, so there is nothing to learn from trying the rest.
        case unauthorized
        /// A real RTSP answer, but not a stream: wrong path, or refused.
        case rejected
        /// Nothing answered.
        case noReply
    }

    /// Sends one `DESCRIBE`, answering the authentication challenge if there is
    /// one and credentials are available.
    static func describe(
        _ url: URL,
        credentials: CameraCredentials?,
        timeout: TimeInterval = 3
    ) async -> Reply {
        guard let host = url.host else { return .noReply }
        let port = url.port.flatMap { UInt16(exactly: $0) } ?? 554
        // The request line carries the address without credentials in it, which
        // is also what the digest is computed over.
        let target = withoutCredentials(url).absoluteString

        guard let first = await send(
            host: host, port: port, target: target,
            sequence: 1, authorization: nil, timeout: timeout
        ) else { return .noReply }

        guard let status = MessageHeaders.statusCode(in: first) else { return .noReply }
        if status == 200 { return .ok }
        guard status == 401 else { return .rejected }

        // 401 with nothing to offer is the end of it — but it is a useful end,
        // because it means a camera is there and only wants a password.
        guard let credentials, !credentials.username.isEmpty,
              let challenge = MessageHeaders.value("WWW-Authenticate", in: first),
              let authorization = WWWAuthenticate.authorization(
                  for: challenge,
                  method: "DESCRIBE",
                  target: target,
                  credentials: credentials
              )
        else { return .unauthorized }

        guard let second = await send(
            host: host, port: port, target: target,
            sequence: 2, authorization: authorization, timeout: timeout
        ) else { return .noReply }

        switch MessageHeaders.statusCode(in: second) {
        case 200: return .ok
        case 401: return .unauthorized
        case .some: return .rejected
        case nil: return .noReply
        }
    }

    // MARK: - Request

    private static func send(
        host: String,
        port: UInt16,
        target: String,
        sequence: Int,
        authorization: String?,
        timeout: TimeInterval
    ) async -> String? {
        var lines = [
            "DESCRIBE \(target) RTSP/1.0",
            "CSeq: \(sequence)",
            "Accept: application/sdp",
            "User-Agent: CamControl"
        ]
        if let authorization {
            lines.append("Authorization: \(authorization)")
        }
        lines.append(contentsOf: ["", ""])

        let request = Data(lines.joined(separator: "\r\n").utf8)
        guard let data = await TCPExchange.send(
            host: host,
            port: port,
            request: request,
            timeout: timeout
        ) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - URLs

    /// Strips the credentials a candidate URL carries for the decoder's benefit.
    /// They must not appear in the request line, and the digest is computed over
    /// the address without them.
    static func withoutCredentials(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user != nil || components.password != nil else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }
}
