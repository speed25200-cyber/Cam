import SwiftUI

/// Home screen: the user's saved cameras.
///
/// Discovery deliberately lives on its own tab. Scanning is a setup act done a
/// handful of times; opening a camera is done every day, and putting the scan
/// controls here would push the cameras down the screen forever.
struct LibraryView: View {
    @Environment(CameraStore.self) private var store
    @Environment(ThumbnailStore.self) private var thumbnails
    @Environment(\.horizontalSizeClass) private var sizeClass

    @Binding var selectedTab: RootView.Tab

    @State private var path: [Camera] = []
    @State private var renameTarget: Camera?
    @State private var draftName = ""
    @State private var showsManualAdd = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.isEmpty {
                    emptyState
                } else {
                    cameraGrid
                }
            }
            .background(Theme.Palette.canvas.ignoresSafeArea())
            .navigationTitle("Caméras")
            .navigationDestination(for: Camera.self) { camera in
                PlayerView(camera: camera, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            selectedTab = .discover
                        } label: {
                            Label("Scanner le réseau", systemImage: "dot.radiowaves.left.and.right")
                        }
                        Button {
                            showsManualAdd = true
                        } label: {
                            Label("Ajouter par adresse IP", systemImage: "number")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Ajouter une caméra")
                }
            }
            .sheet(isPresented: $showsManualAdd) {
                ManualAddSheet { camera in
                    let saved = store.add(camera)
                    path.append(saved)
                }
            }
            .alert("Renommer", isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )) {
                TextField("Nom de la caméra", text: $draftName)
                Button("Annuler", role: .cancel) { renameTarget = nil }
                Button("Enregistrer") {
                    if let target = renameTarget { store.rename(target, to: draftName) }
                    renameTarget = nil
                }
            }
        }
    }

    // MARK: - Content

    private var cameraGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.lg) {
                ForEach(store.cameras) { camera in
                    Button {
                        Haptics.tap()
                        path.append(camera)
                    } label: {
                        CameraCardView(
                            camera: camera,
                            thumbnail: thumbnails.image(for: camera.id),
                            isReachable: isReachable(camera)
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            draftName = camera.customName ?? camera.displayName
                            renameTarget = camera
                        } label: {
                            Label("Renommer", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            withAnimation(Theme.Motion.snappy) { store.remove(camera) }
                        } label: {
                            Label("Oublier", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .scrollIndicators(.hidden)
    }

    private var columns: [GridItem] {
        // Two columns on iPad and landscape iPhone, one in portrait: a 16:9 card
        // narrower than about 300 points makes the preview useless.
        let count = sizeClass == .regular ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.lg), count: count)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "video.badge.waveform",
            title: "Aucune caméra",
            message: "Lancez un scan pour trouver les caméras présentes sur votre réseau WiFi, ou ajoutez-en une directement par son adresse IP.",
            actionTitle: "Scanner mon réseau"
        ) {
            selectedTab = .discover
        }
    }

    /// A camera not seen in the last day is shown as offline. Deliberately
    /// generous: marking a working camera offline is worse than being late to
    /// notice one that left.
    private func isReachable(_ camera: Camera) -> Bool {
        guard let lastSeen = camera.lastSeen else { return true }
        return Date().timeIntervalSince(lastSeen) < 86_400
    }
}
