import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Works out which subnet the device is on, so probing stays strictly inside the
/// network the user is already connected to.
enum LocalNetworkInfo {

    struct Interface: Equatable {
        var name: String
        var address: String
        var prefixLength: Int
    }

    /// The active WiFi interface, or `nil` when the device is not on WiFi.
    ///
    /// `en0` is WiFi on every iOS device; `en1`/`en2` appear on iPads with
    /// Ethernet adapters, which is a perfectly normal way to reach cameras.
    static func currentInterface() -> Interface? {
        let candidates = activeIPv4Interfaces()
        for name in ["en0", "en1", "en2"] {
            if let match = candidates.first(where: { $0.name == name && isPrivate($0.address) }) {
                return match
            }
        }
        return candidates.first(where: { isPrivate($0.address) })
    }

    static func activeIPv4Interfaces() -> [Interface] {
        var results: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return results }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else { continue }
            // Skip interfaces that are down or are loopback.
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }

            var address = addressPointer.pointee
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                &address,
                socklen_t(addressPointer.pointee.sa_len),
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }

            let prefix = interface.ifa_netmask.map { prefixLength(from: $0.pointee) } ?? 24
            results.append(Interface(
                name: String(cString: interface.ifa_name),
                address: String(cString: buffer),
                prefixLength: prefix
            ))
        }
        return results
    }

    private static func prefixLength(from address: sockaddr) -> Int {
        var address = address
        let mask = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
        }
        return UInt32(bigEndian: mask).nonzeroBitCount
    }

    /// RFC 1918 plus link-local. A public address means the device is not behind
    /// a home router, and sweeping that range would be scanning strangers.
    static func isPrivate(_ address: String) -> Bool {
        guard let value = ipv4Value(address) else { return false }
        let octet1 = (value >> 24) & 0xFF
        let octet2 = (value >> 16) & 0xFF
        if octet1 == 10 { return true }
        if octet1 == 172, (16...31).contains(octet2) { return true }
        if octet1 == 192, octet2 == 168 { return true }
        if octet1 == 169, octet2 == 254 { return true }
        return false
    }

    // MARK: - Subnet math

    static func ipv4Value(_ address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func ipv4String(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// Every host address in the interface's subnet, excluding the network and
    /// broadcast addresses and the device's own address.
    ///
    /// The sweep is capped at a /22 (1022 hosts): a phone joined to a corporate
    /// /16 would otherwise queue 65 000 connections, and no home camera lives
    /// outside the first few hundred addresses of its own subnet anyway. Results
    /// are ordered outward from the device's own address, because a router hands
    /// out neighbouring leases and the cameras are usually found in seconds.
    static func hostAddresses(address: String, prefixLength: Int, maximumHosts: Int = 1022) -> [String] {
        guard let value = ipv4Value(address), prefixLength >= 8, prefixLength <= 30 else { return [] }

        let hostBits = min(32 - prefixLength, Int(log2(Double(maximumHosts + 2)).rounded(.up)))
        guard hostBits >= 1 else { return [] }

        let mask: UInt32 = hostBits >= 32 ? 0 : ~UInt32(0) << UInt32(hostBits)
        let network = value & mask
        let total = UInt32(1) << UInt32(hostBits)
        guard total > 2 else { return [] }

        let ownOffset = value &- network
        let offsets = (1...(total - 2))
            .filter { $0 != ownOffset }
            .sorted { lhs, rhs in
                let lhsDistance = lhs > ownOffset ? lhs - ownOffset : ownOffset - lhs
                let rhsDistance = rhs > ownOffset ? rhs - ownOffset : ownOffset - rhs
                return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
            }

        return offsets.map { ipv4String(network + $0) }
    }
}
