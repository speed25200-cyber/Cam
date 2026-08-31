import SwiftUI

/// Home screen: scans the current WiFi network for cameras and lists what it finds.
struct ScanView: View {
    @StateObject private var scanner = NetworkScanner()

    var body: some View {
        NavigationStack {
            List {
                if scanner.isScanning {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scanner.statusMessage).font(.subheadline)
                                ProgressView(value: scanner.progress)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else if !scanner.statusMessage.isEmpty {
                    Section { Text(scanner.statusMessage).foregroundStyle(.secondary) }
                }

                if !scanner.cameras.isEmpty {
                    Section("Appareils trouvés sur votre WiFi") {
                        ForEach(scanner.cameras) { camera in
                            NavigationLink(value: camera) {
                                CameraRowView(camera: camera)
                            }
                        }
                    }
                }
            }
            .navigationDestination(for: Camera.self) { camera in
                CameraDetailView(camera: camera)
            }
            .navigationTitle("CamControl")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        scanner.startScan()
                    } label: {
                        Label("Scanner", systemImage: "arrow.clockwise")
                    }
                    .disabled(scanner.isScanning)
                }
            }
            .overlay {
                if scanner.cameras.isEmpty && !scanner.isScanning && scanner.statusMessage.isEmpty {
                    ContentUnavailableView(
                        "Trouvez vos caméras",
                        systemImage: "video.badge.waveform",
                        description: Text("Lancez un scan pour détecter les caméras connectées à votre réseau WiFi actuel.")
                    )
                }
            }
            .task { scanner.startScan() }
        }
    }
}
