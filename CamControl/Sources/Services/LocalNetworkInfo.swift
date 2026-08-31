import Foundation
import Network

/// Reads the iPhone/iPad's own WiFi interface address so we know which /24
/// subnet to scan — we only ever probe the network the device is currently on.
enum LocalNetworkInfo {

    /// Returns (myIPv4Address, subnetPrefixLength) for the active WiFi (en0) interface.
    static func currentWiFiIPv4() -> (address: String, prefix: Int)? {
        var address: String?
        var prefix: Int?

        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            // en0 is the WiFi interface on all iOS devices.
            guard name == "en0" else { continue }

            var addr = interface.ifa_addr.pointee
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostBuffer, socklen_t(hostBuffer.count),
                        nil, 0, NI_NUMERICHOST)
            address = String(cString: hostBuffer)

            if let netmask = interface.ifa_netmask {
                let maskAddr = netmask.pointee
                prefix = subnetPrefixLength(from: maskAddr)
            }
        }

        guard let address, let prefix else { return nil }
        return (address, prefix)
    }

    private static func subnetPrefixLength(from sockaddr: sockaddr) -> Int {
        var sockaddr = sockaddr
        let mask = withUnsafePointer(to: &sockaddr) { ptr -> UInt32 in
            ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        }
        return UInt32(bigEndian: mask).nonzeroBitCount
    }

    /// Enumerates every host address in the given /prefix subnet (excluding network/broadcast).
    static func hostAddresses(baseIP: String, prefix: Int) -> [String] {
        guard prefix >= 16, prefix < 31 else { return [] } // keep scans bounded (<=65534 hosts, practically we clamp below)
        let parts = baseIP.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return [] }
        let ipValue = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]

        let hostBits = 32 - prefix
        // Guard against scanning something absurd (e.g. a /16). Typical home WiFi is /24.
        let effectiveHostBits = min(hostBits, 10) // cap at 1022 hosts
        let mask: UInt32 = effectiveHostBits >= 32 ? 0 : ~UInt32(0) << effectiveHostBits
        let network = ipValue & mask
        let count = (1 << effectiveHostBits)

        var results: [String] = []
        results.reserveCapacity(count)
        for i in 1..<max(count - 1, 2) {
            let host = network + UInt32(i)
            let a = (host >> 24) & 0xFF
            let b = (host >> 16) & 0xFF
            let c = (host >> 8) & 0xFF
            let d = host & 0xFF
            results.append("\(a).\(b).\(c).\(d)")
        }
        return results
    }
}
