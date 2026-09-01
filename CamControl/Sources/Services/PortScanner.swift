import Foundation
import Network

/// Short-lived TCP connection attempts used to find which hosts on the subnet
/// have a camera-shaped port open.
enum PortScanner {

    /// Tried against every address in the subnet. Deliberately short — this set
    /// runs a thousand times over, and each extra port is another thousand
    /// connection attempts contending for one radio. Between them these four
    /// catch the overwhelming majority of cameras at their factory settings.
    static let commonPorts: [UInt16] = [80, 554, 8000, 8080]

    /// Tried only against addresses already known to hold a device — one that
    /// answered address resolution, or answered on a common port. That is a few
    /// dozen hosts rather than a thousand, so this list can afford to be long,
    /// which is what finds the cameras somebody moved off the default port.
    static let extendedPorts: [UInt16] = [
        88,       // Foscam, Amcrest
        443,      // HTTPS admin
        1935,     // RTMP
        2020,     // ONVIF on several white-label firmwares
        5000,     // assorted
        7001,     // recorders
        8081, 8090, 8888,   // alternate HTTP admin
        8443,     // alternate HTTPS
        8554,     // alternate RTSP — very common on a second stream
        8899,     // XiongMai / Sricam ONVIF
        9000,     // assorted
        34567,    // XiongMai dvrip
        37777     // Dahua
    ]

    /// Ports that make a host worth a full ONVIF probe, most likely first.
    static let onvifPorts: [Int] = [80, 8000, 8080, 8899, 2020, 8081, 8090, 88]

    /// Ports that never speak plain HTTP, so an ONVIF probe against them is
    /// wasted: RTSP and the vendor binary protocols answer nothing a SOAP
    /// request would recognise, and the TLS ports need a scheme this does not use.
    static let nonHTTPPorts: Set<Int> = [554, 8554, 1935, 37777, 34567, 443, 8443]

    /// Ports that carry an RTSP server, in the order worth trying.
    static let rtspPorts: [Int] = [554, 8554]

    /// Returns the subset of `ports` that accept a connection on `host`.
    static func openPorts(host: String, ports: [UInt16], timeout: TimeInterval = 0.6) async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask {
                    await isOpen(host: host, port: port, timeout: timeout) ? Int(port) : nil
                }
            }
            var open: [Int] = []
            for await result in group {
                if let result { open.append(result) }
            }
            return open.sorted()
        }
    }

    /// One connection attempt.
    ///
    /// `.waiting` is treated as a closed port and resolved immediately: it means
    /// the stack got a refusal or found the host unreachable and would otherwise
    /// retry until the deadline. Resolving early is what keeps a 254-address
    /// sweep to a few seconds instead of a few minutes.
    static func isOpen(host: String, port: UInt16, timeout: TimeInterval = 0.6) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }

        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        if let tcp = parameters.defaultProtocolStack.internetProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(timeout.rounded(.up))
            tcp.noDelay = true
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: endpointPort,
            using: parameters
        )
        let box = ResumeBox()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                @Sendable func finish(_ value: Bool) {
                    guard box.claim() else { return }
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: value)
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(true)
                    case .failed, .cancelled, .waiting:
                        finish(false)
                    case .preparing, .setup:
                        break
                    @unknown default:
                        finish(false)
                    }
                }
                connection.start(queue: scanQueue)

                scanQueue.asyncAfter(deadline: .now() + timeout) { finish(false) }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// One shared queue: a queue per connection would spawn thousands of threads
    /// during a sweep.
    private static let scanQueue = DispatchQueue(label: "portscanner", qos: .userInitiated, attributes: .concurrent)
}

/// Guarantees a continuation is resumed exactly once across the several paths
/// (ready, failure, timeout, cancellation) that race to finish a network probe.
///
/// Shared with `DeviceFingerprint`, which runs the same race.
final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
