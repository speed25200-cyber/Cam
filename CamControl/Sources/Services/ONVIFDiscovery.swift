import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// WS-Discovery probe — the standard way ONVIF cameras announce themselves.
///
/// A UDP `Probe` goes to the discovery multicast group and compliant cameras
/// answer by unicast within a second or two, which finds them far faster than a
/// TCP sweep can. Implemented on BSD sockets rather than `NWConnectionGroup`
/// because sending to a multicast group and reading unicast replies on the same
/// ephemeral port does not require *joining* the group, and so needs no multicast
/// entitlement from Apple.
///
/// Results stream out as they arrive; the TCP sweep finds the same cameras
/// anyway if this yields nothing (some routers drop multicast entirely).
enum ONVIFDiscovery {

    struct Hit: Hashable {
        let host: String
        let serviceURL: URL
        let scopes: [String]

        /// Vendor hint parsed from the ONVIF scope list, e.g.
        /// `onvif://www.onvif.org/name/Reolink`, so a device can be labelled
        /// before anyone has entered credentials.
        var name: String? { scopeValue(prefix: "onvif://www.onvif.org/name/") }
        var hardware: String? { scopeValue(prefix: "onvif://www.onvif.org/hardware/") }

        private func scopeValue(prefix: String) -> String? {
            guard let scope = scopes.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            let raw = String(scope.dropFirst(prefix.count))
            return raw.removingPercentEncoding ?? raw
        }
    }

    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: UInt16 = 3702

    /// Streams every distinct camera that answers within `timeout`.
    static func probe(timeout: TimeInterval = 4) -> AsyncStream<Hit> {
        AsyncStream { continuation in
            let worker = DispatchQueue(label: "onvif.discovery", qos: .userInitiated)
            let cancelled = CancellationFlag()

            worker.async {
                run(timeout: timeout, cancelled: cancelled) { hit in
                    continuation.yield(hit)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in cancelled.cancel() }
        }
    }

    // MARK: - Socket work

    private static func run(timeout: TimeInterval, cancelled: CancellationFlag, onHit: (Hit) -> Void) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var broadcast: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &broadcast, socklen_t(MemoryLayout<Int32>.size))
        // One hop is enough for the local segment and keeps the probe off any
        // uplink; the default of 1 is not guaranteed on every stack.
        var ttl: UInt8 = 1
        setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        // Poll in short slices so cancellation is honoured promptly.
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var localAddress = sockaddr_in()
        localAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddress.sin_family = sa_family_t(AF_INET)
        localAddress.sin_addr.s_addr = INADDR_ANY
        localAddress.sin_port = 0
        let bound = withUnsafePointer(to: &localAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastAddress, &destination.sin_addr)

        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let deadline = Date().addingTimeInterval(timeout)
        // UDP has no retransmission; a single dropped probe would hide a camera
        // for the whole scan, so the probe is repeated on a short cadence.
        var nextProbe = Date.distantPast
        var probesSent = 0

        while Date() < deadline, !cancelled.isCancelled {
            if probesSent < 3, Date() >= nextProbe {
                sendProbe(descriptor: descriptor, destination: &destination)
                probesSent += 1
                nextProbe = Date().addingTimeInterval(0.9)
            }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    recvfrom(descriptor, &buffer, buffer.count, 0, addressPointer, &sourceLength)
                }
            }
            guard received > 0 else { continue }

            let payload = Data(bytes: buffer, count: received)
            guard let hit = parseProbeMatch(payload), !seen.contains(hit.host) else { continue }
            seen.insert(hit.host)
            onHit(hit)
        }
    }

    private static func sendProbe(descriptor: Int32, destination: inout sockaddr_in) {
        let message = Data(probeMessage().utf8)
        _ = message.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    sendto(
                        descriptor,
                        raw.baseAddress,
                        raw.count,
                        0,
                        addressPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    private static func probeMessage() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl">\
        <e:Header>\
        <w:MessageID>urn:uuid:\(UUID().uuidString)</w:MessageID>\
        <w:To e:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>\
        <w:Action e:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>\
        </e:Header>\
        <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>\
        </e:Envelope>
        """
    }

    /// Reads the first reachable `XAddrs` entry out of a ProbeMatch.
    static func parseProbeMatch(_ data: Data) -> Hit? {
        guard let root = SOAPXML.parse(data), let match = root.first("ProbeMatch") else { return nil }
        guard let addresses = match.value("XAddrs") else { return nil }
        let scopes = (match.value("Scopes") ?? "")
            .split(separator: " ")
            .map(String.init)

        // A camera with several NICs lists them all; take the first that parses
        // and is not a loopback or unspecified address.
        for candidate in addresses.split(separator: " ") {
            guard let url = URL(string: String(candidate)), let host = url.host else { continue }
            guard host != "127.0.0.1", host != "0.0.0.0" else { continue }
            return Hit(host: host, serviceURL: url, scopes: scopes)
        }
        return nil
    }
}

/// Thread-safe flag letting the async stream's termination handler stop the
/// blocking socket loop running on its own queue.
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
