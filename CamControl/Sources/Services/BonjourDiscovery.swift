import Foundation
import Network

/// Third detection channel: Bonjour / mDNS service browsing.
///
/// Worth having alongside WS-Discovery and the TCP sweep because the three fail
/// in different places. WS-Discovery dies on routers that drop multicast to
/// 239.255.255.250; the TCP sweep misses cameras on a non-standard port; Bonjour
/// finds anything that advertises itself, including cameras whose control port
/// is unusual. Needs no entitlement — the service types are declared in
/// `NSBonjourServices` and iOS handles the rest.
enum BonjourDiscovery {

    struct Hit: Hashable {
        let host: String
        let port: Int
        let serviceName: String
        let serviceType: String

        /// True for services that imply a video device rather than, say, a printer.
        var looksLikeCamera: Bool {
            serviceType.contains("onvif")
                || serviceType.contains("rtsp")
                || serviceType.contains("axis-video")
                || serviceType.contains("dataconnect")
        }
    }

    /// Service types cameras actually advertise. `_http._tcp` is included because
    /// many cameras announce only their web interface; those hits are still worth
    /// probing for ONVIF, they are just lower confidence.
    static let serviceTypes = [
        "_onvif._tcp",
        "_rtsp._tcp",
        "_axis-video._tcp",
        "_http._tcp"
    ]

    /// Browses every service type at once and streams what resolves.
    static func browse(timeout: TimeInterval = 5) -> AsyncStream<Hit> {
        AsyncStream { continuation in
            let coordinator = BrowseCoordinator(continuation: continuation)
            coordinator.start(types: serviceTypes, timeout: timeout)
            continuation.onTermination = { _ in coordinator.stop() }
        }
    }
}

/// Owns the browsers and the connections used to turn a service name into an
/// address, and guarantees the stream finishes exactly once.
private final class BrowseCoordinator: @unchecked Sendable {
    private let continuation: AsyncStream<BonjourDiscovery.Hit>.Continuation
    private let queue = DispatchQueue(label: "bonjour.discovery")
    private let lock = NSLock()

    private var browsers: [NWBrowser] = []
    private var resolvers: [NWConnection] = []
    private var seen = Set<String>()
    private var finished = false

    init(continuation: AsyncStream<BonjourDiscovery.Hit>.Continuation) {
        self.continuation = continuation
    }

    func start(types: [String], timeout: TimeInterval) {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false

        for type in types {
            let descriptor = NWBrowser.Descriptor.bonjour(type: type, domain: nil)
            let browser = NWBrowser(for: descriptor, using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results {
                    self?.resolve(result, serviceType: type)
                }
            }
            browser.start(queue: queue)
            lock.lock()
            browsers.append(browser)
            lock.unlock()
        }

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.stop()
        }
    }

    /// A browse result carries a service name, not an address. Opening a
    /// connection to the endpoint makes the stack resolve it, and the resolved
    /// address then appears on the connection's path.
    private func resolve(_ result: NWBrowser.Result, serviceType: String) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        let connection = NWConnection(to: result.endpoint, using: .tcp)
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        resolvers.append(connection)
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let endpoint = connection.currentPath?.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint,
                   let address = Self.ipv4String(from: host) {
                    self.emit(BonjourDiscovery.Hit(
                        host: address,
                        port: Int(port.rawValue),
                        serviceName: name,
                        serviceType: serviceType
                    ))
                }
                connection.cancel()
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Only IPv4 is useful here: the rest of the app addresses cameras by their
    /// v4 address, and a link-local v6 address cannot be merged with a sweep hit.
    private static func ipv4String(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            // `debugDescription` carries a %interface suffix on link-local addresses.
            return String("\(address)".split(separator: "%").first ?? "")
        case .name(let name, _):
            return LocalNetworkInfo.ipv4Value(name) != nil ? name : nil
        default:
            return nil
        }
    }

    private func emit(_ hit: BonjourDiscovery.Hit) {
        lock.lock()
        let isNew = !finished && seen.insert(hit.host).inserted
        lock.unlock()
        guard isNew else { return }
        continuation.yield(hit)
    }

    func stop() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let browsersToStop = browsers
        let resolversToCancel = resolvers
        browsers = []
        resolvers = []
        lock.unlock()

        browsersToStop.forEach { $0.cancel() }
        resolversToCancel.forEach { $0.cancel() }
        continuation.finish()
    }
}
