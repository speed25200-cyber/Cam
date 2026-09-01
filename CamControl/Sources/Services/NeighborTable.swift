import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Reads the kernel's address-resolution table: every device this phone has
/// exchanged a link-layer frame with on the current network.
///
/// This is the one channel the other three cannot substitute for. WS-Discovery
/// needs the camera to implement it, Bonjour needs it to advertise itself, and
/// the TCP sweep needs an open port — a camera can decline all three and still
/// be sitting on the network answering its owner's app. Address resolution is
/// not optional: anything that speaks IP on this segment has to answer it, so it
/// shows up here whatever else it refuses.
///
/// It also hands back the hardware address, and with it the manufacturer.
enum NeighborTable {

    struct Neighbor: Hashable {
        let host: String
        let mac: String
    }

    /// Sends one byte of UDP to every address, so the kernel is forced to resolve
    /// each one before it can transmit.
    ///
    /// Nothing listens on the discard port and no reply is expected — the point
    /// is the resolution the kernel performs first, which is what fills the table
    /// `read()` then walks. Cheap enough to fire at a whole subnet: a datagram
    /// carries no connection state, so a thousand of them cost a few
    /// milliseconds where a thousand TCP handshakes cost tens of seconds.
    static func prime(hosts: [String], port: UInt16 = 9) {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var payload: [UInt8] = [0]
        for host in hosts {
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &destination.sin_addr) == 1 else { continue }

            _ = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                    sendto(
                        descriptor,
                        &payload,
                        payload.count,
                        0,
                        addressPointer,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    /// Every resolved IPv4 neighbour currently in the table.
    ///
    /// Best-effort throughout: an empty array means only that this channel found
    /// nothing, and discovery carries on with the other three. Nothing here is
    /// allowed to fail loudly, because a kernel that declines to hand over the
    /// table is a perfectly normal thing for it to do.
    static func read() -> [Neighbor] {
        // Routing table, IPv4, filtered to entries carrying a link-layer address.
        // 0x400 is RTF_LLINFO, written as a literal because it lives in
        // net/route.h, which the Darwin module does not export to Swift on iOS.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else { return [] }

        let length = min(size, buffer.count)
        return buffer.withUnsafeBytes { raw -> [Neighbor] in
            var neighbors: [Neighbor] = []
            var offset = 0

            while offset + minimumMessageLength <= length {
                // Every routing message opens with its own length. Read a byte at
                // a time rather than as a `UInt16`: Darwin is little-endian on
                // both architectures it ships on, and this needs no alignment
                // guarantee about where the kernel put the message.
                let messageLength = Int(raw[offset]) | (Int(raw[offset + 1]) << 8)
                guard messageLength >= minimumMessageLength,
                      offset + messageLength <= length else { break }

                if let neighbor = parse(raw, from: offset, to: offset + messageLength) {
                    neighbors.append(neighbor)
                }
                offset += messageLength
            }
            return neighbors
        }
    }

    /// A floor on the fixed header the kernel puts in front of every routing
    /// message. Used twice: to keep the walk moving forward, and to start the
    /// search below past the bytes that cannot hold an address anyway.
    private static let minimumMessageLength = 32

    /// Finds the address pair inside one routing message.
    ///
    /// The two socket addresses sit immediately after a fixed header — but that
    /// header is `struct rt_msghdr`, declared in net/route.h, which the Darwin
    /// module does not export to Swift on iOS. Restating its layout here would
    /// compile and then break silently the day Apple adds a field, so instead the
    /// pair is found by its own shape: a sixteen-byte IPv4 address followed, at
    /// the kernel's own alignment, by a link-layer address. Two address families
    /// agreeing in exactly the right two places is not something the bytes of a
    /// header stumble into.
    private static func parse(_ raw: UnsafeRawBufferPointer, from start: Int, to end: Int) -> Neighbor? {
        let addressLength = 16  // sizeof(struct sockaddr_in)
        // The kernel's own SA_SIZE: round up to the platform's word.
        let word = MemoryLayout<Int>.size
        let padded = 1 + ((addressLength - 1) | (word - 1))

        var index = start + minimumMessageLength
        while index + padded + 8 <= end {
            defer { index += 1 }

            guard raw[index] == UInt8(addressLength),
                  raw[index + 1] == UInt8(AF_INET) else { continue }

            let link = index + padded
            guard raw[link + 1] == UInt8(AF_LINK), raw[link] >= 8 else { continue }

            // sockaddr_dl: the interface name takes sdl_nlen bytes from offset 8,
            // and the hardware address is the sdl_alen bytes immediately after it.
            let nameLength = Int(raw[link + 5])
            let macLength = Int(raw[link + 6])
            guard macLength == 6, link + 8 + nameLength + macLength <= end else { continue }

            let macStart = link + 8 + nameLength
            let bytes = (0..<macLength).map { raw[macStart + $0] }
            // All zeroes is an entry the kernel has queued but not yet resolved.
            guard bytes.contains(where: { $0 != 0 }) else { continue }

            return Neighbor(
                host: "\(raw[index + 4]).\(raw[index + 5]).\(raw[index + 6]).\(raw[index + 7])",
                mac: bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            )
        }
        return nil
    }
}
