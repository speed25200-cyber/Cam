import Foundation
import Network

/// Scans the phone's own WiFi subnet for hosts with ports commonly used by
/// IP cameras, then hands each live host off to `ONVIFClient` for identification.
/// Only ever touches the local subnet the device is currently connected to.
@MainActor
final class NetworkScanner: ObservableObject {

    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var cameras: [Camera] = []
    @Published var statusMessage: String = ""

    /// Ports worth probing: ONVIF/HTTP admin (80, 8000, 8080, 8899), RTSP (554),
    /// and a few vendor-specific ones (37777 Dahua, 9000 Hikvision).
    private let candidatePorts: [UInt16] = [80, 8080, 8000, 8899, 554, 37777, 9000, 443]
    private var scanTask: Task<Void, Never>?

    func startScan() {
        guard !isScanning else { return }
        scanTask?.cancel()
        cameras = []
        isScanning = true
        progress = 0
        statusMessage = "Recherche de votre réseau WiFi…"

        scanTask = Task { await runScan() }
    }

    func stopScan() {
        scanTask?.cancel()
        isScanning = false
    }

    private func runScan() async {
        guard let (myIP, prefix) = LocalNetworkInfo.currentWiFiIPv4() else {
            statusMessage = "Impossible de détecter le réseau WiFi. Vérifiez que le WiFi est activé."
            isScanning = false
            return
        }

        let hosts = LocalNetworkInfo.hostAddresses(baseIP: myIP, prefix: prefix)
        guard !hosts.isEmpty else {
            statusMessage = "Sous-réseau introuvable."
            isScanning = false
            return
        }

        statusMessage = "Analyse de \(hosts.count) adresses sur votre réseau…"

        // Also fire a best-effort ONVIF WS-Discovery multicast probe in parallel —
        // it answers instantly for compliant cameras when multicast is permitted.
        async let discovered = ONVIFDiscovery.probe(timeout: 2.5)

        let total = hosts.count
        var completedCount = 0
        var found: [Camera] = []

        await withTaskGroup(of: (String, [Int]).self) { group in
            let concurrency = 32
            var iterator = hosts.makeIterator()
            let ports = candidatePorts

            func addNext() {
                if let host = iterator.next() {
                    group.addTask { (host, await Self.openPorts(for: host, ports: ports)) }
                }
            }
            for _ in 0..<concurrency { addNext() }

            for await (host, ports) in group {
                completedCount += 1
                progress = Double(completedCount) / Double(total)
                if !ports.isEmpty {
                    found.append(Camera(id: host, ipAddress: host, kind: .httpOnly, openPorts: ports))
                }
                if !Task.isCancelled { addNext() }
            }
        }

        let onvifHits = await discovered
        var merged: [String: Camera] = Dictionary(uniqueKeysWithValues: found.map { ($0.ipAddress, $0) })

        for hit in onvifHits {
            var cam = merged[hit.ipAddress] ?? Camera(id: hit.ipAddress, ipAddress: hit.ipAddress, kind: .onvif)
            cam.kind = .onvif
            cam.onvifServiceURL = hit.serviceURL
            merged[hit.ipAddress] = cam
        }

        // Identify remaining candidates: try ONVIF over HTTP (default path) even
        // without a multicast reply, then fall back to "RTSP looks reachable".
        statusMessage = "Identification des caméras…"
        var results: [Camera] = []
        for var cam in merged.values.sorted(by: { $0.ipAddress < $1.ipAddress }) {
            if Task.isCancelled { break }
            if cam.onvifServiceURL == nil, cam.openPorts.contains(where: { $0 == 80 || $0 == 8080 || $0 == 8000 }) {
                if let guessed = await ONVIFClient.probeDefaultServiceURL(ip: cam.ipAddress) {
                    cam.onvifServiceURL = guessed
                    cam.kind = .onvif
                }
            }
            if cam.onvifServiceURL != nil {
                if let info = try? await ONVIFClient(camera: cam).fetchDeviceInfoUnauthenticated() {
                    cam.manufacturer = info.manufacturer
                    cam.model = info.model
                    cam.firmwareVersion = info.firmwareVersion
                }
            } else if cam.openPorts.contains(554) {
                cam.kind = .rtspGuess
                cam.rtspURL = URL(string: "rtsp://\(cam.ipAddress):554/")
            }
            results.append(cam)
        }

        cameras = results
        statusMessage = results.isEmpty
            ? "Aucune caméra trouvée sur ce réseau."
            : "\(results.count) appareil(s) trouvé(s)."
        isScanning = false
    }

    /// Attempts a short TCP connection to each candidate port; returns the ones that accept.
    private static func openPorts(for host: String, ports: [UInt16]) async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask { await isPortOpen(host: host, port: port) ? Int(port) : nil }
            }
            var open: [Int] = []
            for await result in group {
                if let result { open.append(result) }
            }
            return open.sorted()
        }
    }

    private static func isPortOpen(host: String, port: UInt16, timeoutMS: Int = 400) async -> Bool {
        await withCheckedContinuation { continuation in
            let params = NWParameters.tcp
            params.prohibitedInterfaceTypes = [.cellular, .other]
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                continuation.resume(returning: false)
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
            var didResume = false
            let lock = NSLock()
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resumeOnce(true)
                case .failed, .cancelled: resumeOnce(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(timeoutMS)) {
                resumeOnce(false)
            }
        }
    }
}
