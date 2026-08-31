import SwiftUI

/// Network scan screen.
///
/// Results stream in while the sweep is still running, so a camera found in the
/// first second can be added without waiting for the remaining 250 addresses.
struct DiscoveryView: View {
    @Environment(CameraStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var discovery = DiscoveryService()
    @State private var addedIDs: Set<String> = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    header
                    if discovery.hasResults {
                        resultsSection
                    } else if case .failed(_, let recovery) = discovery.phase {
                        failureCard(recovery: recovery)
                    } else if !discovery.phase.isRunning {
                        introCard
                    }
                    privacyNote
                }
                .padding(Theme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Découvrir")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if discovery.phase.isRunning {
                        Button("Arrêter") { discovery.stop() }
                            .foregroundStyle(Theme.Palette.danger)
                    } else {
                        Button("Scanner") { start() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .onChange(of: discovery.phase) { _, phase in
                if case .finished(let found) = phase {
                    store.reconcile(with: discovery.results)
                    if found > 0 { Haptics.success() }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Theme.Spacing.lg) {
            RadarView(
                progress: discovery.progress,
                blips: discovery.results.map(\.host),
                isActive: discovery.phase.isRunning
            )
            .frame(maxWidth: 260)
            .padding(.top, Theme.Spacing.sm)

            VStack(spacing: Theme.Spacing.xs) {
                Text(discovery.phase.headline)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.opacity)

                if let subnet = discovery.subnetLabel {
                    Text("Réseau \(subnet)")
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .animation(Theme.Motion.resolve(Theme.Motion.gentle, reduced: reduceMotion), value: discovery.phase)

            if discovery.phase.isRunning {
                ProgressView(value: discovery.progress)
                    .tint(Theme.Palette.accent)
                    .frame(maxWidth: 260)
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                title: "Appareils trouvés",
                subtitle: "\(discovery.results.count) sur votre réseau"
            )

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(discovery.results) { camera in
                    DiscoveredRow(
                        camera: camera,
                        isSaved: store.isSaved(camera) || addedIDs.contains(camera.host),
                        onAdd: { add(camera) }
                    )
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .animation(Theme.Motion.resolve(Theme.Motion.snappy, reduced: reduceMotion), value: discovery.results)
        }
    }

    // MARK: - Cards

    private var introCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Comment ça marche")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)

            step(
                number: 1,
                title: "Appel ONVIF",
                detail: "Un message multicast demande aux caméras de se signaler. Les modèles compatibles répondent en une seconde."
            )
            step(
                number: 2,
                title: "Balayage du réseau",
                detail: "Les adresses de votre sous-réseau sont testées sur les ports habituels des caméras IP."
            )
            step(
                number: 3,
                title: "Identification",
                detail: "Chaque appareil trouvé est interrogé pour connaître sa marque, son modèle et ses capacités."
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .cardSurface()
    }

    private func step(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text("\(number)")
                .font(Theme.Typography.micro)
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.Palette.accentGradient, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failureCard(recovery: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("Scan impossible", systemImage: "wifi.exclamationmark")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.warning)
            Text(recovery)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .cardSurface()
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("Le scan reste strictement sur le réseau local auquel cet appareil est connecté. Aucune donnée ne sort de votre réseau. N'utilisez CamControl que sur vos propres caméras.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.Spacing.xs)
    }

    // MARK: - Actions

    private func start() {
        addedIDs.removeAll()
        Haptics.tap()
        discovery.start()
    }

    private func add(_ camera: Camera) {
        store.add(camera)
        addedIDs.insert(camera.host)
        Haptics.success()
    }
}

/// One discovered device.
struct DiscoveredRow: View {
    let camera: Camera
    let isSaved: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.sm) {
                    Text(camera.host)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    StatusBadge(camera.kind.label, tint: tint)
                }
            }

            Spacer(minLength: 0)

            if isSaved {
                Label("Ajoutée", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.Palette.success)
                    .accessibilityLabel("Déjà dans votre bibliothèque")
            } else {
                Button("Ajouter", action: onAdd)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Palette.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(Theme.Spacing.md)
        .cardSurface(radius: Theme.Radius.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(camera.displayName), \(camera.host), \(camera.kind.label)")
    }

    private var icon: String {
        switch camera.kind {
        case .onvif: return "video.fill"
        case .rtsp: return "play.rectangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch camera.kind {
        case .onvif: return Theme.Palette.accent
        case .rtsp: return Theme.Palette.warning
        case .unknown: return Theme.Palette.textTertiary
        }
    }
}
