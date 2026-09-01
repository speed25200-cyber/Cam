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
        // 0x400 is RTF_LLINFO, written as a literal because the header marks that
        // spelling deprecated in favour of RTF_LLDATA while keeping both at the
        // same value — depending on either name is the fragile choice.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, 0x400]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size > 0 else { return [] }

        let length = min(size, buffer.count)
        return buffer.withUnsafeBytes { raw -> [Neighbor] in
            var neighbors: [Neighbor] = []
            var offset = 0
            let headerSize = MemoryLayout<rt_msghdr>.size

            while offset + headerSize <= length {
                // `rtm_msglen` is the first field of the message header, and the
                // only one this needs: it says where the next message starts.
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard messageLength >= headerSize, offset + messageLength <= length else { break }

                // Two socket addresses follow the header — the destination, then
                // the link-layer address — each padded up to the platform's word
                // size, which is what the kernel's own SA_SIZE macro computes.
                let addressOffset = offset + headerSize
                let addressLength = Int(raw[addressOffset])
                let stride = MemoryLayout<Int>.size
                let padded = addressLength == 0 ? stride : 1 + ((addressLength - 1) | (stride - 1))
                let linkOffset = addressOffset + padded

                if linkOffset + 8 <= offset + messageLength,
                   let neighbor = parse(raw, addressOffset: addressOffset, linkOffset: linkOffset) {
                    neighbors.append(neighbor)
                }
                offset += messageLength
            }
            return neighbors
        }
    }

    /// Pulls one address pair out of the buffer by byte offset rather than by
    /// casting to `sockaddr_in` and `sockaddr_dl`. The layouts are fixed by the
    /// BSD ABI, and reading bytes sidesteps both the alignment question and the
    /// fixed-size C array that `sdl_data` imports as an unindexable tuple.
    private static func parse(
        _ raw: UnsafeRawBufferPointer,
        addressOffset: Int,
        linkOffset: Int
    ) -> Neighbor? {
        // sockaddr_in: length, family, port, then the four address bytes.
        guard addressOffset + 8 <= raw.count else { return nil }
        let host = "\(raw[addressOffset + 4]).\(raw[addressOffset + 5])."
            + "\(raw[addressOffset + 6]).\(raw[addressOffset + 7])"

        // sockaddr_dl: the interface name takes sdl_nlen bytes from offset 8, and
        // the hardware address is the sdl_alen bytes immediately after it.
        guard linkOffset + 8 <= raw.count else { return nil }
        let nameLength = Int(raw[linkOffset + 5])
        let macLength = Int(raw[linkOffset + 6])
        guard macLength == 6 else { return nil }

        let start = linkOffset + 8 + nameLength
        guard start + macLength <= raw.count else { return nil }

        let bytes = (0..<macLength).map { raw[start + $0] }
        // All zeroes is an entry the kernel has queued but not yet resolved.
        guard bytes.contains(where: { $0 != 0 }) else { return nil }

        return Neighbor(
            host: host,
            mac: bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        )
    }
}
