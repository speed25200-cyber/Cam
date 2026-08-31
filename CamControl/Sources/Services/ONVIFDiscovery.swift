import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Best-effort ONVIF WS-Discovery: sends a UDP Probe to the standard discovery
/// multicast address (239.255.255.250:3702) and collects the unicast ProbeMatch
/// replies cameras send back to our source port. Implemented with plain POSIX
/// sockets (rather than Network.framework's NWMulticastGroup) because sending a
/// one-shot probe and listening for unicast replies on the same socket does not
/// require joining the multicast group, so it works without any special
/// entitlement — this is purely a fast-path bonus; `NetworkScanner`'s TCP sweep
/// finds the same cameras either way if this returns nothing.
enum ONVIFDiscovery {

    struct Hit {
        let ipAddress: String
        let serviceURL: URL
    }

    static func probe(timeout: TimeInterval) async -> [Hit] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runProbe(timeout: timeout))
            }
        }
    }

    private static func runProbe(timeout: TimeInterval) -> [Hit] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }

        var broadcastEnable: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking-ish reads via a receive timeout, so we can poll until `timeout` elapses.
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var localAddr = sockaddr_in()
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_addr.s_addr = INADDR_ANY
        localAddr.sin_port = 0 // let the OS pick an ephemeral port for replies
        let bindResult = withUnsafePointer(to: &localAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = UInt16(3702).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &destAddr.sin_addr)

        let messageID = "uuid:\(UUID().uuidString)"
        let probeData = Data(buildProbeMessage(messageID: messageID).utf8)

        let sendResult = probeData.withUnsafeBytes { buffer -> Int in
            withUnsafePointer(to: &destAddr) { destPtr -> Int in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, buffer.baseAddress, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sendResult > 0 else { return [] }

        var hits: [String: Hit] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 8192)

        while Date() < deadline {
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received: Int = withUnsafeMutablePointer(to: &fromAddr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(sock, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard received > 0 else { continue } // timeout tick or transient error; keep polling until deadline
            let data = Data(bytes: buffer, count: received)
            guard let xml = String(data: data, encoding: .utf8), let hit = parseProbeMatch(xml: xml) else { continue }
            hits[hit.ipAddress] = hit
        }

        return Array(hits.values)
    }

    private static func buildProbeMessage(messageID: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" \
        xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" \
        xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
          <e:Header>
            <w:MessageID>\(messageID)</w:MessageID>
            <w:To e:mustUnderstand="1">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
            <w:Action e:mustUnderstand="1">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
          </e:Header>
          <e:Body>
            <d:Probe>
              <d:Types>dn:NetworkVideoTransmitter</d:Types>
            </d:Probe>
          </e:Body>
        </e:Envelope>
        """
    }

    private static func parseProbeMatch(xml: String) -> Hit? {
        guard let range = xml.range(of: "<d:XAddrs>") ?? xml.range(of: "<XAddrs>") else { return nil }
        let after = xml[range.upperBound...]
        guard let end = after.range(of: "</") else { return nil }
        let raw = after[..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstAddr = raw.split(separator: " ").first, let url = URL(string: String(firstAddr)) else { return nil }
        guard let host = url.host else { return nil }
        return Hit(ipAddress: host, serviceURL: url)
    }
}
