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

    deinit {
        connectTask?.cancel()
        moveTask?.cancel()
        imagingWriteTask?.cancel()
        toastTask?.cancel()
    }

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
        streamURL = nil
        if state.isStreaming { state = .idle }
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
        // A camera with no ONVIF service can still be watched if it exposes RTSP,
        // but only if we can find the right path on it.
        guard camera.isControllable, let serviceURL = camera.onvifServiceURL else {
            startPathSearch()
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

            do {
                try await establish(with: client)
                credentials = candidate
                if let candidate {
                    // Only a pair that actually worked gets persisted.
                    store.setCredentials(candidate, for: camera)
                    store.rememberAsDefault(candidate)
                }
                return
            } catch ONVIFError.unauthorized {
                continue
            } catch let error as ONVIFError {
                guard !Task.isCancelled else { return }
                state = .failed(message: error.localizedDescription, recovery: error.recoverySuggestion)
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(message: error.localizedDescription, recovery: nil)
                return
            }
        }

        guard !Task.isCancelled else { return }
        state = .needsCredentials
    }

    // MARK: - RTSP path search

    /// Starts walking the candidate stream paths for a camera with no ONVIF.
    private func startPathSearch() {
        streamCandidates = RTSPPathCatalog.candidates(for: camera, credentials: credentials)
        candidateIndex = 0
        guard let first = streamCandidates.first else {
            state = .failed(
                message: ONVIFError.noServiceURL.localizedDescription,
                recovery: ONVIFError.noServiceURL.recoverySuggestion
            )
            return
        }
        streamURL = first
        state = .streaming
    }

    /// Called by the player when a candidate produced no video.
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
    /// an address ONVIF gave us, so the UI can explain what it is doing.
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
