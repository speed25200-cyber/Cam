import SwiftUI

/// Immersive single-camera screen: live video, PTZ, imaging and capture.
///
/// The video is the whole screen and every control floats over it, auto-hiding
/// after a few seconds — the picture is the reason the screen exists, and chrome
/// that permanently occupies a third of it is chrome that shrinks the picture.
struct PlayerView: View {
    @State private var session: CameraSession
    private let store: CameraStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var playback: PlaybackStatus = .idle
    @State private var aspectRatio: CGFloat = 16.0 / 9.0
    @State private var showsHUD = true
    @State private var hudTask: Task<Void, Never>?

    @State private var showsPTZ = false
    @State private var activeSheet: Sheet?
    @State private var isMuted = true

    // Digital zoom, useful on fixed cameras that have no optical zoom at all.
    @State private var zoomScale: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var committedPan: CGSize = .zero

    private enum Sheet: String, Identifiable {
        case credentials, controls, presets, info
        var id: String { rawValue }
    }

    init(camera: Camera, store: CameraStore) {
        self.store = store
        _session = State(initialValue: CameraSession(camera: camera, store: store))
    }

    var body: some View {
        ZStack {
            Theme.Palette.videoScrim.ignoresSafeArea()
            videoLayer
            statusLayer
            if showsHUD { hudLayer.transition(.opacity) }
            if showsPTZ, session.canControlPTZ { ptzLayer.transition(.move(edge: .bottom).combined(with: .opacity)) }
            toastLayer
        }
        .background(Color.black)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!showsHUD)
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(showsHUD ? .automatic : .hidden)
        .contentShape(Rectangle())
        .onTapGesture { toggleHUD() }
        .sheet(item: $activeSheet, content: sheet(for:))
        .task {
            session.start()
            scheduleHUDHide()
        }
        .onDisappear {
            hudTask?.cancel()
            session.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding leaves the decoder running and the camera streaming,
            // which drains both batteries for a picture nobody can see.
            switch phase {
            case .background: session.stop()
            case .active where session.state == .idle: session.start()
            default: break
            }
        }
        .onChange(of: session.state) { _, state in
            if state == .needsCredentials { activeSheet = .credentials }
        }
    }

    // MARK: - Video

    private var videoLayer: some View {
        GeometryReader { geometry in
            VideoSurface(
                url: session.streamURL,
                isMuted: isMuted,
                onStatusChange: { playback = $0 },
                onAspectRatioChange: { aspectRatio = $0 }
            )
            .aspectRatio(aspectRatio, contentMode: .fit)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .liveLook(session.liveFilter)
            .scaleEffect(zoomScale)
            .offset(panOffset)
            .clipped()
            .gesture(zoomGesture)
            .simultaneousGesture(panGesture)
            .accessibilityLabel("Flux vidéo de \(session.camera.displayName)")
        }
        .ignoresSafeArea()
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoomScale = min(max(committedZoom * value.magnification, 1), 4)
            }
            .onEnded { _ in
                committedZoom = zoomScale
                if zoomScale <= 1.01 {
                    // Snap back cleanly so the frame cannot be left slightly
                    // off-centre at 1x, which looks like a rendering bug.
                    withAnimation(Theme.Motion.resolve(Theme.Motion.snappy, reduced: reduceMotion)) {
                        zoomScale = 1
                        panOffset = .zero
                    }
                    committedZoom = 1
                    committedPan = .zero
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale > 1.01 else { return }
                panOffset = CGSize(
                    width: committedPan.width + value.translation.width,
                    height: committedPan.height + value.translation.height
                )
            }
            .onEnded { _ in committedPan = panOffset }
    }

    // MARK: - Status overlays

    @ViewBuilder
    private var statusLayer: some View {
        switch session.state {
        case .connecting(let stage):
            connectingOverlay(stage: stage)
        case .needsCredentials:
            messageOverlay(
                icon: "key.horizontal.fill",
                title: "Identifiants requis",
                message: "Cette caméra demande un nom d'utilisateur et un mot de passe ONVIF.",
                actionTitle: "Se connecter"
            ) { activeSheet = .credentials }
        case .failed(let message, let recovery):
            messageOverlay(
                icon: "exclamationmark.triangle.fill",
                title: message,
                message: recovery ?? "",
                actionTitle: "Réessayer"
            ) { session.retry() }
        case .streaming:
            if playback == .stalled || playback == .ended {
                messageOverlay(
                    icon: "wifi.exclamationmark",
                    title: "Signal interrompu",
                    message: "La caméra a cessé d'envoyer des images.",
                    actionTitle: "Reconnecter"
                ) { session.retry() }
            } else if playback == .opening || playback == .buffering {
                bufferingOverlay
            }
        case .idle:
            EmptyView()
        }
    }

    private func connectingOverlay(stage: ConnectionState.Stage) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView().controlSize(.large).tint(.white)
            Text(stage.rawValue)
                .font(Theme.Typography.callout)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(Theme.Spacing.xl)
        .glassControl(radius: Theme.Radius.lg)
        .transition(.opacity)
    }

    private var bufferingOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .padding(Theme.Spacing.lg)
            .glassControl(radius: Theme.Radius.lg)
    }

    private func messageOverlay(
        icon: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            Button(actionTitle, action: action)
                .buttonStyle(AccentButtonStyle())
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 340)
        .glassControl(radius: Theme.Radius.lg)
        .padding(Theme.Spacing.xl)
    }

    // MARK: - HUD

    private var hudLayer: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            CircularIconButton(systemImage: "chevron.left", size: 40) { dismiss() }
                .accessibilityLabel("Retour")

            VStack(alignment: .leading, spacing: 2) {
                Text(session.camera.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(session.camera.host)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer(minLength: 0)

            if playback.isLive { LiveIndicator() }

            CircularIconButton(systemImage: "info.circle", size: 40) { activeSheet = .info }
                .accessibilityLabel("Informations sur la caméra")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                .padding(.horizontal, -Theme.Spacing.xl)
                .padding(.top, -60)
        )
    }

    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            CircularIconButton(
                systemImage: session.isCapturing ? "hourglass" : "camera.fill",
                size: 48
            ) {
                Task { await session.captureSnapshot() }
            }
            .disabled(session.isCapturing)
            .accessibilityLabel("Prendre un instantané")

            if session.canControlPTZ {
                CircularIconButton(
                    systemImage: "dpad.fill",
                    size: 48,
                    isActive: showsPTZ
                ) {
                    withAnimation(Theme.Motion.resolve(Theme.Motion.snappy, reduced: reduceMotion)) {
                        showsPTZ.toggle()
                    }
                }
                .accessibilityLabel(showsPTZ ? "Masquer les commandes d'orientation" : "Afficher les commandes d'orientation")
            }

            CircularIconButton(systemImage: "camera.filters", size: 48) { activeSheet = .controls }
                .accessibilityLabel("Image et filtres")

            if !session.presets.isEmpty {
                CircularIconButton(systemImage: "bookmark.fill", size: 48) { activeSheet = .presets }
                    .accessibilityLabel("Positions enregistrées")
            }

            Spacer(minLength: 0)

            CircularIconButton(
                systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                size: 48
            ) {
                isMuted.toggle()
            }
            .accessibilityLabel(isMuted ? "Activer le son" : "Couper le son")
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - PTZ

    private var ptzLayer: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: Theme.Spacing.lg) {
                PTZJoystick(
                    onChange: { session.setJoystick($0) },
                    onRelease: { session.releaseJoystick() }
                )
                Spacer(minLength: 0)
                ZoomRocker(
                    onChange: { session.setJoystick(PTZVector(zoom: $0)) },
                    onRelease: { session.releaseJoystick() }
                )
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, 96)
        }
    }

    // MARK: - Toast

    private var toastLayer: some View {
        VStack {
            Spacer()
            if let toast = session.toast {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: toast.systemImage)
                    Text(toast.message).font(Theme.Typography.callout)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .glassControl()
                .padding(.bottom, 140)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.resolve(Theme.Motion.snappy, reduced: reduceMotion), value: session.toast)
        .allowsHitTesting(false)
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheet(for sheet: Sheet) -> some View {
        switch sheet {
        case .credentials:
            CredentialsSheet(
                cameraName: session.camera.displayName,
                existing: store.credentials(for: session.camera)
            ) { credentials in
                session.apply(credentials: credentials)
            }
        case .controls:
            ImageControlsSheet(session: session)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        case .presets:
            PresetsSheet(session: session)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        case .info:
            CameraInfoSheet(camera: session.camera, playback: playback, store: store)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - HUD visibility

    private func toggleHUD() {
        withAnimation(Theme.Motion.resolve(Theme.Motion.snappy, reduced: reduceMotion)) {
            showsHUD.toggle()
        }
        if showsHUD { scheduleHUDHide() } else { hudTask?.cancel() }
    }

    /// Fades the chrome out after a few idle seconds, but never while a control
    /// that lives in it is in use.
    private func scheduleHUDHide() {
        hudTask?.cancel()
        hudTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled, activeSheet == nil, !showsPTZ else { return }
            withAnimation(Theme.Motion.resolve(Theme.Motion.gentle, reduced: reduceMotion)) {
                showsHUD = false
            }
        }
    }
}
