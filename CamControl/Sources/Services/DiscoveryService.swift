import Foundation
import Observation

/// Finds cameras on the current subnet and publishes them as they are found.
///
/// Four channels run against the network, because each one is blind somewhere
/// the others are not:
///
/// - **WS-Discovery** — a multicast probe ONVIF cameras answer in about a
///   second. Silent on any router that drops multicast, and on cameras whose
///   discovery service is switched off.
/// - **Bonjour** — finds whatever advertises itself, including cameras sitting
///   on a port nobody would think to scan.
/// - **Address resolution** — every device that speaks IP on this segment,
///   whether or not it opens a single port, plus its manufacturer.
/// - **TCP sweep** — the fallback that needs nothing from the camera except an
///   open port, run wide over the whole subnet and then deep on whatever
///   answered.
///
/// Anything still unidentified afterwards is asked directly, in RTSP and in
/// HTTP, what it is. Results from every channel merge by host address, so a
/// camera found four times appears once.
@Observable
@MainActor
final class DiscoveryService {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case mapping
        case sweeping
        case identifying
        case finished(found: Int)
        case failed(reason: String, recovery: String)

        var isRunning: Bool {
            switch self {
            case .preparing, .listening, .mapping, .sweeping, .identifying: return true
            case .idle, .finished, .failed: return false
            }
        }

        var headline: String {
            switch self {
            case .idle: return "Prêt à scanner"
            case .preparing: return "Détection de votre réseau…"
            case .listening: return "Appel des caméras ONVIF…"
            case .mapping: return "Recensement des appareils…"
            case .sweeping: return "Analyse du réseau…"
            case .identifying: return "Identification des appareils…"
            case .finished(let found):
                return found == 0 ? "Aucune caméra trouvée" : "\(found) appareil\(found > 1 ? "s" : "") trouvé\(found > 1 ? "s" : "")"
            case .failed(let reason, _): return reason
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var results: [Camera] = []
    /// Network label shown in the UI, e.g. "192.168.1.x".
    private(set) var subnetLabel: String?

    private var task: Task<Void, Never>?

    /// Hosts probed in parallel. Tuned for a phone radio: higher saturates the
    /// WiFi chip and makes every probe time out, lower leaves the sweep crawling.
    private let concurrency = 24

    /// Addresses that proved a device is there — resolved at layer 2, or answered
    /// a port. Only these get the long port list and the fingerprint probes.
    private var liveHosts: Set<String> = []

    var hasResults: Bool { !results.isEmpty }

    // MARK: - Control

    func start() {
        guard !phase.isRunning else { return }
        task?.cancel()
        results = []
        liveHosts = []
        progress = 0
        phase = .preparing
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        if phase.isRunning {
            phase = .finished(found: results.count)
        }
    }

    // MARK: - Pipeline

    private func run() async {
        guard let interface = LocalNetworkInfo.currentInterface() else {
            phase = .failed(
                reason: "Réseau WiFi introuvable",
                recovery: "Connectez l'appareil au WiFi sur lequel se trouvent vos caméras, puis relancez le scan."
            )
            return
        }
        guard LocalNetworkInfo.isPrivate(interface.address) else {
            phase = .failed(
                reason: "Réseau non privé",
                recovery: "CamControl ne scanne que les réseaux locaux privés. Connectez-vous à votre WiFi domestique."
            )
            return
        }

        let hosts = LocalNetworkInfo.hostAddresses(
            address: interface.address,
            prefixLength: interface.prefixLength
        )
        guard !hosts.isEmpty else {
            phase = .failed(
                reason: "Sous-réseau illisible",
                recovery: "Le masque de sous-réseau signalé par le routeur est inhabituel. Ajoutez la caméra manuellement par son adresse IP."
            )
            return
        }

        let components = interface.address.split(separator: ".")
        if components.count == 4 {
            subnetLabel = "\(components[0]).\(components[1]).\(components[2]).x"
        }

        phase = .listening
        // Both announcement channels first: they answer in about a second, so
        // the list is rarely empty by the time the slower sweep gets going.
        let announcementTask = Task { await listenForAnnouncements() }
        let bonjourTask = Task { await listenForBonjour() }

        phase = .mapping
        await mapNeighbors(hosts: hosts)
        guard !Task.isCancelled else { return }

        phase = .sweeping
        await sweep(hosts: hosts)
        await announcementTask.value
        await bonjourTask.value
        guard !Task.isCancelled else { return }

        // The sweep itself resolved every address it touched, so the table is far
        // fuller now than it was before it ran. Reading it again attaches a
        // manufacturer to hosts the first pass had not reached yet.
        mergeNeighbors(NeighborTable.read())

        phase = .identifying
        await identifyAll()

        guard !Task.isCancelled else { return }
        progress = 1
        phase = .finished(found: results.count)
    }

    /// Consumes WS-Discovery replies, adding each camera the moment it answers.
    private func listenForAnnouncements() async {
        for await hit in ONVIFDiscovery.probe(timeout: 4) {
            guard !Task.isCancelled else { return }
            var camera = Camera(
                host: hit.host,
                onvifServiceURL: hit.serviceURL,
                kind: .onvif,
                manufacturer: hit.name,
                model: hit.hardware,
                lastSeen: Date()
            )
            camera.openPorts = hit.serviceURL.port.map { [$0] } ?? []
            upsert(camera)
        }
    }

    /// Consumes Bonjour advertisements. These carry no ONVIF endpoint, only an
    /// address and a port, so they seed a candidate that the identify pass then
    /// probes properly.
    private func listenForBonjour() async {
        for await hit in BonjourDiscovery.browse(timeout: 5) {
            guard !Task.isCancelled else { return }
            guard LocalNetworkInfo.isPrivate(hit.host) else { continue }
            upsert(Camera(
                host: hit.host,
                kind: hit.looksLikeCamera ? .rtsp : .unknown,
                openPorts: [hit.port],
                lastSeen: Date()
            ))
        }
    }

    /// Provokes address resolution across the subnet, then reads the result.
    ///
    /// A second of waiting buys the whole device list. Everything after this
    /// knows which addresses are worth spending TCP handshakes on, which is what
    /// lets the sweep try fifteen extra ports without taking fifteen times longer.
    private func mapNeighbors(hosts: [String]) async {
        let addresses = hosts
        await Task.detached(priority: .userInitiated) {
            NeighborTable.prime(hosts: addresses)
        }.value

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard !Task.isCancelled else { return }
        mergeNeighbors(NeighborTable.read())
        progress = max(progress, 0.05)
    }

    /// Folds the resolution table into the results.
    ///
    /// A device that answered resolution but opened no port is listed only when
    /// its hardware address belongs to a company that sells nothing but cameras.
    /// Without that rule the screen fills with every phone, laptop and television
    /// in the house, and the cameras — the entire point — get lost in it.
    private func mergeNeighbors(_ neighbors: [NeighborTable.Neighbor]) {
        for neighbor in neighbors {
            guard LocalNetworkInfo.isPrivate(neighbor.host) else { continue }
            liveHosts.insert(neighbor.host)

            let vendor = MACVendors.lookup(neighbor.mac)
            let existing = results.first { $0.host == neighbor.host }
            guard existing != nil || vendor?.makesOnlyCameras == true else { continue }

            upsert(Camera(
                host: neighbor.host,
                // The hardware address names a company; the camera names itself.
                // Offer the first only when the second has said nothing, or a
                // "Hikvision DS-2CD2042WD" read over ONVIF would be flattened
                // back to plain "Hikvision" by the next pass over the table.
                manufacturer: existing?.manufacturer == nil ? vendor?.name : nil,
                macAddress: neighbor.mac,
                lastSeen: Date()
            ))
        }
    }

    /// TCP sweep in two passes: a short port list over the whole subnet, then the
    /// long list over the addresses that turned out to hold something.
    private func sweep(hosts: [String]) async {
        // Known-live addresses go first, so the cameras usually appear on screen
        // within a second or two of the sweep starting. Partitioned rather than
        // sorted, which would scramble the outward-from-here order inside each
        // half — `sorted` is not stable.
        let live = hosts.filter { liveHosts.contains($0) }
        let rest = hosts.filter { !liveHosts.contains($0) }
        await probe(hosts: live + rest, ports: PortScanner.commonPorts, from: 0.05, to: 0.6)
        guard !Task.isCancelled else { return }

        let deep = hosts.filter { liveHosts.contains($0) }
        await probe(hosts: deep, ports: PortScanner.extendedPorts, from: 0.6, to: 0.85)
    }

    /// One sweep pass, with a bounded number of in-flight probes.
    private func probe(hosts: [String], ports: [UInt16], from: Double, to: Double) async {
        guard !hosts.isEmpty else {
            progress = max(progress, to)
            return
        }
        let total = Double(hosts.count)
        var completed = 0.0

        await withTaskGroup(of: (String, [Int]).self) { group in
            var iterator = hosts.makeIterator()

            func enqueueNext() {
                guard !Task.isCancelled, let host = iterator.next() else { return }
                group.addTask {
                    (host, await PortScanner.openPorts(host: host, ports: ports))
                }
            }

            for _ in 0..<concurrency { enqueueNext() }

            for await (host, openPorts) in group {
                completed += 1
                progress = min(from + (to - from) * (completed / total), to)

                if !openPorts.isEmpty {
                    liveHosts.insert(host)
                    upsert(Camera(
                        host: host,
                        kind: openPorts.contains { PortScanner.rtspPorts.contains($0) } ? .rtsp : .unknown,
                        openPorts: openPorts,
                        lastSeen: Date()
                    ))
                }
                enqueueNext()
            }
        }
    }

    /// Asks every candidate what it is. Runs a few at a time: each probe may try
    /// several endpoint paths, and cameras are slow to answer when hit in bulk.
    private func identifyAll() async {
        let candidates = results
        guard !candidates.isEmpty else { return }
        let total = Double(candidates.count)
        var completed = 0.0

        await withTaskGroup(of: Camera?.self) { group in
            var iterator = candidates.makeIterator()

            func enqueueNext() {
                guard !Task.isCancelled, let camera = iterator.next() else { return }
                group.addTask { await Self.identify(camera) }
            }

            for _ in 0..<6 { enqueueNext() }

            for await identified in group {
                completed += 1
                progress = min(0.85 + 0.15 * (completed / total), 0.99)
                if let identified { upsert(identified) }
                enqueueNext()
            }
        }
    }

    /// Resolves what a candidate is: ONVIF first, then RTSP, then its web
    /// interface. Returns `nil` only when nothing new was learned.
    private nonisolated static func identify(_ camera: Camera) async -> Camera? {
        if let onvif = await identifyONVIF(camera) { return onvif }
        guard !Task.isCancelled else { return nil }
        return await fingerprint(camera)
    }

    private nonisolated static func identifyONVIF(_ camera: Camera) async -> Camera? {
        var camera = camera

        if camera.onvifServiceURL == nil {
            // Probe every open port that could plausibly serve HTTP, not just the
            // conventional ones: plenty of cameras are configured onto an
            // arbitrary port, and the port is already known to be open here, so
            // trying it costs one request.
            let ports = camera.openPorts
                .filter { !PortScanner.nonHTTPPorts.contains($0) }
                .sorted { lhs, rhs in
                    // Conventional ports first, so the usual case stays fast.
                    let lhsRank = PortScanner.onvifPorts.firstIndex(of: lhs) ?? Int.max
                    let rhsRank = PortScanner.onvifPorts.firstIndex(of: rhs) ?? Int.max
                    return lhsRank == rhsRank ? lhs < rhs : lhsRank < rhsRank
                }
            guard !ports.isEmpty else { return nil }
            camera.onvifServiceURL = await ONVIFClient.discoverServiceURL(host: camera.host, ports: ports)
        }
        guard let serviceURL = camera.onvifServiceURL else { return nil }

        let client = ONVIFClient(deviceServiceURL: serviceURL, timeout: 4)
        guard let info = try? await client.deviceInformation() else {
            // Endpoint exists but will not identify itself unauthenticated —
            // still an ONVIF device, just one that needs credentials first.
            camera.kind = .onvif
            return camera
        }
        camera.kind = .onvif
        camera.manufacturer = info.manufacturer ?? camera.manufacturer
        camera.model = info.model ?? camera.model
        camera.firmwareVersion = info.firmwareVersion
        camera.serialNumber = info.serialNumber
        return camera
    }

    /// Last resort for the cameras that never implemented ONVIF, or shipped with
    /// it disabled. Asks the RTSP port and then the web interface directly, which
    /// is what turns "192.168.1.52, port 8080 open" into "Foscam".
    private nonisolated static func fingerprint(_ camera: Camera) async -> Camera? {
        var camera = camera
        var learnedSomething = false

        for port in camera.openPorts where PortScanner.rtspPorts.contains(port) {
            guard let number = UInt16(exactly: port),
                  let result = await DeviceFingerprint.rtsp(host: camera.host, port: number) else { continue }
            camera.kind = .rtsp
            camera.manufacturer = camera.manufacturer ?? result.vendor
            camera.model = camera.model ?? result.banner
            learnedSomething = true
            break
        }
        guard !Task.isCancelled else { return learnedSomething ? camera : nil }

        // The web interface is worth asking even when RTSP already answered: the
        // login realm names the model far more often than the RTSP banner does.
        for port in camera.openPorts where !PortScanner.nonHTTPPorts.contains(port) {
            guard let result = await DeviceFingerprint.http(host: camera.host, port: port) else { continue }
            guard result.identifiesACamera else { continue }
            camera.manufacturer = camera.manufacturer ?? result.vendor
            camera.model = camera.model ?? result.banner
            learnedSomething = true
            break
        }

        return learnedSomething ? camera : nil
    }

    // MARK: - Merging

    /// Adds or updates a camera, keeping the list ordered: controllable devices
    /// first, then by address, so the useful results stay at the top as the
    /// sweep fills in the rest.
    private func upsert(_ camera: Camera) {
        if let index = results.firstIndex(where: { $0.host == camera.host }) {
            results[index] = results[index].merging(discovered: camera)
        } else {
            results.append(camera)
        }
        results.sort { lhs, rhs in
            if lhs.kind != rhs.kind {
                return rank(lhs.kind) < rank(rhs.kind)
            }
            let lhsValue = LocalNetworkInfo.ipv4Value(lhs.host) ?? 0
            let rhsValue = LocalNetworkInfo.ipv4Value(rhs.host) ?? 0
            return lhsValue < rhsValue
        }
    }

    private func rank(_ kind: Camera.Kind) -> Int {
        switch kind {
        case .onvif: return 0
        case .rtsp: return 1
        case .unknown: return 2
        }
    }
}
