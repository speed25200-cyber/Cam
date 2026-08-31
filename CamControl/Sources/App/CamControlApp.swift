import SwiftUI

@main
struct CamControlApp: App {
    @State private var store = CameraStore()
    @State private var thumbnails = ThumbnailStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(thumbnails)
                .tint(Theme.Palette.accent)
        }
    }
}
