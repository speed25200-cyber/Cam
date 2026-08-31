import SwiftUI

struct RootView: View {
    enum Tab: String, Hashable {
        case library, discover, settings
    }

    @Environment(CameraStore.self) private var store
    @State private var selectedTab: Tab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(selectedTab: $selectedTab)
                .tabItem { Label("Caméras", systemImage: "video.fill") }
                .tag(Tab.library)

            DiscoveryView()
                .tabItem { Label("Découvrir", systemImage: "dot.radiowaves.left.and.right") }
                .tag(Tab.discover)

            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        .tint(Theme.Palette.accent)
        .task {
            // First launch lands on discovery: an empty library is a dead end,
            // and finding the cameras is the only thing worth doing there.
            if store.isEmpty { selectedTab = .discover }
        }
    }
}
