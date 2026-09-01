import Foundation
import Network

/// One request, one response, one connection.
///
/// Deliberately raw rather than `URLSession`: the protocols that need this —
/// RTSP above all — are not HTTP, and no URL loading system will speak them.
enum TCPExchange {

    /// Sends `request` and returns the first response bytes, or `nil` if the host
    /// never answered. The reply is capped at one read: everything this is used
    /// for needs only the status line and headers, which arrive together.
    static func send(
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
                            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
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
                connection.start(queue: queue)

                queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// One shared queue: a queue per connection would spawn a thread per probe.
    private static let queue = DispatchQueue(
        label: "tcp.exchange",
        qos: .userInitiated,
        attributes: .concurrent
    )
}

/// Header parsing shared by everything here that speaks an HTTP-shaped protocol.
///
/// RTSP borrows HTTP's message grammar wholesale, so one parser serves both.
enum MessageHeaders {

    /// The numeric status from a status line such as `RTSP/1.0 401 Unauthorized`.
    static func statusCode(in reply: String) -> Int? {
        guard let line = reply.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0].hasPrefix("RTSP/") || fields[0].hasPrefix("HTTP/") else { return nil }
        return Int(fields[1])
    }

    /// One header's value, matched case-insensitively as the grammar requires.
    static func value(_ name: String, in reply: String) -> String? {
        let prefix = (name + ":").lowercased()
        for line in reply.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            guard line.lowercased().hasPrefix(prefix) else { continue }
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One comma-separated parameter out of a header, quoted or bare:
    /// `Digest realm="IP Camera", nonce="a1b2"` → `parameter("nonce", …)` is `a1b2`.
    ///
    /// Matched at a token boundary, because the names overlap: a plain substring
    /// search for `nonce=` also finds the `cnonce=` in a digest response, and
    /// would hand back a client nonce as if it were the server's.
    static func parameter(_ name: String, in header: String) -> String? {
        let needle = name + "="
        var from = header.startIndex

        while let range = header.range(of: needle, options: .caseInsensitive, range: from..<header.endIndex) {
            from = range.upperBound

            if range.lowerBound > header.startIndex {
                let previous = header[header.index(before: range.lowerBound)]
                guard !previous.isLetter, !previous.isNumber, previous != "-", previous != "_" else { continue }
            }

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
        return nil
    }
}
