import Foundation
import Observation
import Photos
import UIKit

/// Transient message shown over the player.
struct Toast: Identifiable, Equatable {
    enum Tone { case neutral, success, warning, failure }

    let id = UUID()
    var message: String
    var systemImage: String
    var tone: Tone = .neutral
}

/// Everything the player screen needs for one camera: the connection lifecycle,
/// the live stream address, PTZ, imaging, snapshots.
///
/// One session per open camera. It owns the `ONVIFClient` actor and is the only
/// thing that talks to it, so the UI never awaits the network directly.
@Observable
@MainActor
final class CameraSession {

    // MARK: - Published state

    private(set) var camera: Camera
    private(set) var state: ConnectionState = .idle
    private(set) var streamURL: URL?
    private(set) var presets: [PTZPreset] = []
    private(set) var imagingOptions = ImagingOptions()
    private(set) var isApplyingImaging = false
    private(set) var isCapturing = false

    /// What was tried and what answered, in order.
    ///
    /// A camera that will not connect is the hardest thing to diagnose from the
    /// other end of the conversation: every cause — wrong address, closed port,
    /// missing password, a camera that simply has no RTSP — ends in the same
    /// black screen. This is the record that tells them apart, and the failure
    /// screen offers it.
    private(set) var diagnostics: [String] = []

    /// Hardware imaging values. Edited directly by the sliders; writes to the
    /// camera are debounced from `scheduleImagingWrite()`.
    var imaging = ImagingSettings()
    /// Client-side look. Applied instantly, never sent to the camera.
    var liveFilter = LiveFilterSettings.neutral
    var toast: Toast?

    var capabilities: Camera.Capabilities { camera.capabilities }
    var canControlPTZ: Bool { capabilities.hasPTZ }
    var canAdjustImaging: Bool { capabilities.hasImaging && imagingOptions.hasAnyControl }

    // MARK: - Dependencies

    private let store: CameraStore
    private var client: ONVIFClient?
    private var credentials: CameraCredentials?

    /// Candidate RTSP paths for a camera with no ONVIF, walked in order until
    /// one plays.
    private var streamCandidates: [URL] = []
    private var candidateIndex = 0

    private var connectTask: Task<Void, Never>?
    private var moveTask: Task<Void, Never>?
    private var pendingVector: PTZVector?
    private var imagingWriteTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(camera: Camera, store: CameraStore) {
        self.camera = camera
        self.store = store
        self.credentials = store.credentials(for: camera)
    }

    // No `deinit` cancelling the tasks: it would be nonisolated and cannot touch
    // this actor's state, and it could never run while a task is in flight
    // anyway — each task holds a strong reference to the session. Every task
    // here is finite, and `stop()` is the cancellation point, called by the
    // player when it disappears.

    // MARK: - Connection

    func start() {
        guard connectTask == nil else { return }
        connectTask = Task { await connect() }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        moveTask?.cancel()
        moveTask = nil
        imagingWriteTask?.cancel()
        imagingWriteTask = nil
        toastTask?.cancel()
        toastTask = nil
        streamURL = nil
        if state.isStreaming { state = .idle }
    }

    private func note(_ line: String) {
        diagnostics.append(line)
    }

    func retry() {
        connectTask?.cancel()
        connectTask = Task { await connect() }
    }

    func apply(credentials newCredentials: CameraCredentials) {
        credentials = newCredentials
        store.setCredentials(newCredentials, for: camera)
        Task { await client?.setCredentials(newCredentials) }
        retry()
    }

    private func connect() async {
        diagnostics = []
        note("Caméra \(camera.host)")
        note("Ports ouverts vus par le scan : \(camera.openPorts.isEmpty ? "aucun" : camera.openPorts.map(String.init).joined(separator: ", "))")
        if let mac = camera.macAddress { note("Adresse matérielle : \(mac)") }

        // Look for ONVIF again before falling back to guesswork. Discovery spends
        // a couple of seconds spread across a thousand addresses; this is one
        // camera with the user waiting on it, and it is worth more effort. ONVIF
        // hands over the exact stream address, which beats every guess that
        // follows — so a second look here is the difference between a camera that
        // works and one that is merely listed.
        if camera.onvifServiceURL == nil {
            state = .connecting(stage: .handshake)
            let ports = onvifCandidatePorts()
            note("Recherche ONVIF sur \(ports.map(String.init).joined(separator: ", "))")

            if let found = await ONVIFClient.discoverServiceURL(host: camera.host, ports: ports) {
                note("Service ONVIF trouvé : \(found.absoluteString)")
                camera.onvifServiceURL = found
                camera.kind = .onvif
                store.update(camera)
            } else {
                note("Aucun service ONVIF ne répond")
            }
            guard !Task.isCancelled else { return }
        }

        // A camera with no ONVIF service can still be watched if it exposes RTSP,
        // but only if we can find the right address on it.
        guard let serviceURL = camera.onvifServiceURL else {
            await searchForStream()
            return
        }

        state = .connecting(stage: .handshake)
        let client = self.client ?? ONVIFClient(deviceServiceURL: serviceURL, credentials: credentials)
        self.client = client

        // Try what we already know before asking the user anything. Most people
        // reuse one password across their cameras, and plenty of cameras answer
        // without any credentials at all, so the common case is no prompt.
        for candidate in credentialCandidates() {
            if Task.isCancelled { return }
            await client.setCredentials(candidate)
            note(candidate.map { "ONVIF, identifiant « \($0.username) »" } ?? "ONVIF sans identifiants")

            do {
                try await establish(with: client)
                note("Connecté · flux \(streamURL?.path ?? "?")")
                credentials = candidate
                if let candidate {
                    // Only a pair that actually worked gets persisted.
                    store.setCredentials(candidate, for: camera)
                    store.rememberAsDefault(candidate)
                }
                return
            } catch ONVIFError.unauthorized {
                note("→ identifiants refusés")
                continue
            } catch let error as ONVIFError {
                guard !Task.isCancelled else { return }
                note("→ \(error.localizedDescription)")
                state = .failed(message: error.localizedDescription, recovery: error.recoverySuggestion)
                return
            } catch {
                guard !Task.isCancelled else { return }
                note("→ \(error.localizedDescription)")
                state = .failed(message: error.localizedDescription, recovery: nil)
                return
            }
        }

        guard !Task.isCancelled else { return }
        note("Aucun identifiant accepté")
        state = .needsCredentials
    }

    /// Ports worth asking for ONVIF, most likely first.
    ///
    /// Every open port that could serve HTTP, then the conventional ONVIF ports
    /// whether or not the scan saw them — a closed port refuses instantly on a
    /// local network, so the ones that are wrong cost nothing worth counting.
    private func onvifCandidatePorts() -> [Int] {
        let open = camera.openPorts.filter { !PortScanner.nonHTTPPorts.contains($0) }
        return open + PortScanner.onvifPorts.filter { !open.contains($0) }
    }

    // MARK: - RTSP stream search

    /// Finds the address that actually carries video on a camera with no ONVIF.
    ///
    /// Runs the same credential cascade as the ONVIF path, and for the same
    /// reason: what the user already owns is tried before they are asked for
    /// anything. It costs one request per set — a camera that wants a password
    /// says so on the first address, whichever one that is.
    private func searchForStream() async {
        for candidate in credentialCandidates() {
            guard !Task.isCancelled else { return }
            if await walkPaths(with: candidate) == .settled { return }
        }
        guard !Task.isCancelled else { return }
        state = .needsCredentials
    }

    private enum PathSearchOutcome {
        /// The camera refused these credentials. Another set is worth trying.
        case credentialsRefused
        /// Nothing left to decide: the stream is playing, or a failure is set.
        case settled
    }

    /// Asks the camera about each candidate address in turn.
    ///
    /// Each one is put to the camera with `DESCRIBE` rather than handed to the
    /// decoder on spec. Guessing by decoder cost a full timeout per wrong guess,
    /// and — the part that made cameras unwatchable — it could not tell a wrong
    /// path from a camera asking for a password, because both simply fail to
    /// play. Cameras that only needed a password walked all fifteen addresses and
    /// were then told no stream existed.
    private func walkPaths(with credentials: CameraCredentials?) async -> PathSearchOutcome {
        let candidates = RTSPPathCatalog.candidates(for: camera, credentials: credentials)
        streamCandidates = candidates
        candidateIndex = 0

        guard !candidates.isEmpty else {
            state = .failed(
                message: ONVIFError.noServiceURL.localizedDescription,
                recovery: ONVIFError.noServiceURL.recoverySuggestion
            )
            return .settled
        }

        note(credentials.map { "Essai avec l'identifiant « \($0.username) »" } ?? "Essai sans identifiants")
        state = .connecting(stage: .searching)

        var cameraAnswered = false
        var openPorts = false
        // A port is checked once and the answer reused. Without this, a filtered
        // port costs the full timeout on every one of the forty addresses behind
        // it — minutes of waiting to learn one thing.
        var reachable: [Int: Bool] = [:]

        for (index, url) in candidates.enumerated() {
            guard !Task.isCancelled else { return .settled }
            candidateIndex = index

            let port = url.port ?? 554
            if reachable[port] == nil {
                let isOpen = await PortScanner.isOpen(host: camera.host, port: UInt16(port), timeout: 2)
                reachable[port] = isOpen
                note(isOpen ? "Port \(port) ouvert" : "Port \(port) fermé — adresses ignorées")
                openPorts = openPorts || isOpen
            }
            guard reachable[port] == true else { continue }

            switch await RTSPProbe.describe(url, credentials: credentials) {
            case .ok:
                note("\(describe(url)) → flux trouvé")
                // The address is known now, not guessed, so the decoder is never
                // asked to walk the rest of the list behind our back.
                streamCandidates = []
                candidateIndex = 0
                self.credentials = credentials
                if let credentials, !credentials.username.isEmpty {
                    store.setCredentials(credentials, for: camera)
                    store.rememberAsDefault(credentials)
                }
                streamURL = url
                state = .streaming
                return .settled

            case .unauthorized:
                note("\(describe(url)) → identifiants refusés")
                return .credentialsRefused

            case .rejected:
                cameraAnswered = true

            case .noReply:
                break
            }
        }

        guard !Task.isCancelled else { return .settled }
        note("\(candidates.count) adresses essayées, aucune acceptée")

        if !openPorts {
            state = .failed(
                message: "Aucun port vidéo ouvert sur cet appareil.",
                recovery: "Il est bien présent sur le réseau, mais ni le port 554 ni le 8554 ne répondent. Beaucoup de caméras grand public ne diffusent qu'à travers le cloud du fabricant et n'exposent aucun flux standard — dans ce cas, seule l'app du fabricant peut les afficher."
            )
            return .settled
        }

        if cameraAnswered {
            state = .failed(
                message: "Aucun flux vidéo trouvé sur cette caméra.",
                recovery: "Elle répond bien en RTSP, mais aucune des adresses habituelles ne fonctionne. Ajoutez-la à la main avec son adresse de flux exacte — elle se trouve dans son interface web ou son manuel."
            )
            return .settled
        }

        // The port is open but nothing answered a DESCRIBE. That may be the
        // camera, or it may be this probe: hand the list to the decoder and let
        // it try, which is what the app did before and occasionally works where a
        // hand-rolled request does not.
        note("Le port répond mais pas au protocole RTSP — essai par le décodeur")
        candidateIndex = 0
        streamURL = candidates.first
        state = .streaming
        return .settled
    }

    /// One candidate, written the way it is worth reading in the log: the port
    /// and path, without the credentials the URL carries for the decoder.
    private func describe(_ url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        let query = url.query.map { "?\($0)" } ?? ""
        return "\(port)\(url.path)\(query)"
    }

    /// Called by the player when a candidate produced no video.
    ///
    /// Only reached on the fallback above, where the camera never answered a
    /// `DESCRIBE` and the decoder is the last thing left to try.
    ///
    /// Returns false once the list is exhausted, so the player can stop showing
    /// "connecting" and say what actually happened.
    @discardableResult
    func tryNextStreamPath() -> Bool {
        guard !streamCandidates.isEmpty else { return false }
        let next = candidateIndex + 1
        guard next < streamCandidates.count else {
            state = .failed(
                message: "Aucun flux vidéo trouvé sur cette caméra.",
                recovery: "Elle n'expose pas ONVIF et aucune adresse RTSP courante ne répond. Activez ONVIF dans ses réglages, ou ajoutez-la manuellement avec son adresse de flux exacte."
            )
            return false
        }
        candidateIndex = next
        streamURL = streamCandidates[next]
        return true
    }

    /// True when this camera is being watched through guessed paths rather than
    /// an address the camera itself confirmed, so the UI can say what it is doing.
    var isUsingCandidatePaths: Bool { !streamCandidates.isEmpty }

    /// How far through the candidate list we are, for the progress read-out.
    var candidateProgress: (current: Int, total: Int) {
        (candidateIndex + 1, streamCandidates.count)
    }

    /// What to try, in order, before giving up and asking.
    ///
    /// Deliberately only ever three things the user already owns: this camera's
    /// saved pair, the pair that worked on another of their cameras, and no
    /// credentials at all. It is not a list of vendor default passwords — that
    /// would be a guessing tool, and it would be pointed at whatever network the
    /// phone happens to be on.
    private func credentialCandidates() -> [CameraCredentials?] {
        var candidates: [CameraCredentials?] = []
        if let credentials, !credentials.username.isEmpty {
            candidates.append(credentials)
        }
        if let shared = store.defaultCredentials,
           !shared.username.isEmpty,
           shared != credentials {
            candidates.append(shared)
        }
        candidates.append(nil)
        return candidates
    }

    /// One full connection attempt. Throws `.unauthorized` so the caller can move
    /// on to the next candidate.
    private func establish(with client: ONVIFClient) async throws {
        state = .connecting(stage: .capabilities)
        let connection = try await client.connect()
        guard !Task.isCancelled else { return }

        camera.capabilities = connection.capabilities
        store.update(camera)

        state = .connecting(stage: .stream)
        streamURL = try await client.streamURL()
        guard !Task.isCancelled else { return }
        state = .streaming

        // Non-essential extras: a camera that refuses them is still watchable,
        // so their failures never take the session out of `.streaming`.
        await loadPresets()
        await loadImaging()
        await refreshThumbnail()
    }

    private func loadPresets() async {
        guard capabilities.hasPTZ, let client else { return }
        presets = (try? await client.presets()) ?? []
    }

    private func loadImaging() async {
        guard capabilities.hasImaging, let client else { return }
        let options = (try? await client.imagingOptions()) ?? .permissive
        imagingOptions = options
        if let settings = try? await client.imagingSettings(options: options) {
            imaging = settings
        }
    }

    // MARK: - PTZ

    /// Feeds a new joystick velocity. Commands are coalesced: a drag emits
    /// dozens of updates per second and a camera answering each one would fall
    /// seconds behind the finger.
    func setJoystick(_ vector: PTZVector) {
        guard canControlPTZ else { return }
        pendingVector = vector
        guard moveTask == nil else { return }
        moveTask = Task { await pumpMoves() }
    }

    private func pumpMoves() async {
        while let vector = pendingVector, !Task.isCancelled {
            pendingVector = nil
            try? await client?.move(vector)
            try? await Task.sleep(for: .milliseconds(180))
        }
        moveTask = nil
    }

    /// Ends a PTZ gesture. The stop must always reach the camera — a dropped one
    /// leaves the motor running until it hits its own limit.
    func releaseJoystick() {
        guard canControlPTZ else { return }
        pendingVector = nil
        moveTask?.cancel()
        moveTask = nil
        Task { [client] in
            try? await client?.stopMove()
        }
    }

    func goto(preset: PTZPreset) {
        guard let client else { return }
        Task {
            do {
                try await client.gotoPreset(token: preset.token)
                show(Toast(message: "Position « \(preset.name) »", systemImage: "scope", tone: .success))
            } catch {
                show(Toast(message: "Déplacement refusé par la caméra", systemImage: "exclamationmark.triangle", tone: .failure))
            }
        }
    }

    func savePreset(named name: String) {
        guard let client else { return }
        Task {
            do {
                try await client.savePreset(name: name)
                await loadPresets()
                show(Toast(message: "Position enregistrée", systemImage: "bookmark.fill", tone: .success))
            } catch {
                show(Toast(message: "Enregistrement impossible", systemImage: "exclamationmark.triangle", tone: .failure))
            }
        }
    }

    func deletePreset(_ preset: PTZPreset) {
        guard let client else { return }
        Task {
            try? await client.removePreset(token: preset.token)
            await loadPresets()
        }
    }

    // MARK: - Imaging

    /// Queues a write to the camera. Debounced so dragging a slider produces one
    /// request when the finger settles rather than one per frame.
    func scheduleImagingWrite() {
        guard canAdjustImaging else { return }
        imagingWriteTask?.cancel()
        imagingWriteTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await writeImaging()
        }
    }

    private func writeImaging() async {
        guard let client else { return }
        isApplyingImaging = true
        defer { isApplyingImaging = false }
        do {
            try await client.applyImaging(imaging, options: imagingOptions)
        } catch {
            show(Toast(
                message: "La caméra a refusé ces réglages",
                systemImage: "slider.horizontal.3",
                tone: .warning
            ))
        }
    }

    func resetImaging() {
        imaging = ImagingSettings()
        scheduleImagingWrite()
    }

    // MARK: - Snapshots

    /// Saves a still to the photo library, with the live filter baked in so the
    /// saved image matches what is on screen.
    func captureSnapshot() async {
        guard let client else {
            show(Toast(message: "Instantané indisponible sur cette caméra", systemImage: "camera.badge.ellipsis", tone: .warning))
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        do {
            let data = try await client.snapshotData()
            ThumbnailStore.shared.store(data, for: camera.id)

            guard let image = UIImage(data: data) else {
                throw ONVIFError.malformedResponse("image illisible")
            }
            let rendered = LiveFilterRenderer.apply(liveFilter, to: image) ?? image

            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                show(Toast(
                    message: "Autorisez l'accès à Photos pour enregistrer",
                    systemImage: "photo.badge.exclamationmark",
                    tone: .warning
                ))
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: rendered)
            }
            show(Toast(message: "Instantané enregistré", systemImage: "checkmark.circle.fill", tone: .success))
        } catch {
            let message = (error as? ONVIFError)?.localizedDescription ?? "Instantané impossible"
            show(Toast(message: message, systemImage: "exclamationmark.triangle", tone: .failure))
        }
    }

    /// Refreshes the library card's still without touching the photo library.
    func refreshThumbnail() async {
        guard let client, capabilities.hasMedia else { return }
        guard let data = try? await client.snapshotData() else { return }
        ThumbnailStore.shared.store(data, for: camera.id)
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self.toast = nil
        }
    }
}
