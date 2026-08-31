import Foundation
import Observation

/// Finds cameras on the current subnet and publishes them as they are found.
///
/// Two techniques run at once: a WS-Discovery multicast probe, which compliant
/// cameras answer within a second, and a TCP sweep of the subnet, which finds
/// everything else including cameras on networks that drop multicast. Results
/// from both are merged by host address, so a camera found twice appears once.
@Observable
@MainActor
final class DiscoveryService {

    enum Phase: Equatable {
        case idle
        case preparing
        case listening
        case sweeping
        case identifying
        case finished(found: Int)
        case failed(reason: String, recovery: String)

        var isRunning: Bool {
            switch self {
            case .preparing, .listening, .sweeping, .identifying: return true
            case .idle, .finished, .failed: return false
            }
        }

        var headline: String {
            switch self {
            case .idle: return "Prêt à scanner"
            case .preparing: return "Détection de votre réseau…"
            case .listening: return "Appel des caméras ONVIF…"
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

    var hasResults: Bool { !results.isEmpty }

    // MARK: - Control

    func start() {
        guard !phase.isRunning else { return }
        task?.cancel()
        results = []
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

        phase = .sweeping
        await sweep(hosts: hosts)
        await announcementTask.value
        await bonjourTask.value

        guard !Task.isCancelled else { return }

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

    /// TCP sweep with a bounded number of in-flight probes.
    private func sweep(hosts: [String]) async {
        let total = Double(hosts.count)
        var completed = 0.0

        await withTaskGroup(of: (String, [Int]).self) { group in
            var iterator = hosts.makeIterator()

            func enqueueNext() {
                guard !Task.isCancelled, let host = iterator.next() else { return }
                group.addTask {
                    (host, await PortScanner.openPorts(host: host, ports: PortScanner.cameraPorts))
                }
            }

            for _ in 0..<concurrency { enqueueNext() }

            for await (host, openPorts) in group {
                completed += 1
                progress = min(completed / total, 0.98)

                if !openPorts.isEmpty {
                    upsert(Camera(
                        host: host,
                        kind: openPorts.contains(554) ? .rtsp : .unknown,
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
        await withTaskGroup(of: Camera?.self) { group in
            var iterator = candidates.makeIterator()

            func enqueueNext() {
                guard !Task.isCancelled, let camera = iterator.next() else { return }
                group.addTask { await Self.identify(camera) }
            }

            for _ in 0..<6 { enqueueNext() }

            for await identified in group {
                if let identified { upsert(identified) }
                enqueueNext()
            }
        }
    }

    /// Resolves a candidate's ONVIF endpoint (if any) and reads its identity.
    private nonisolated static func identify(_ camera: Camera) async -> Camera? {
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
