import SwiftUI
import Photos
import CoreImage

/// Full control screen for one camera: live video, PTZ, and image/filter controls.
struct CameraDetailView: View {
    let camera: Camera

    @State private var client: ONVIFClient
    @State private var credentials: CameraCredentials?
    @State private var showCredentialsSheet = false
    @State private var connectionError: String?
    @State private var isConnecting = false

    @State private var streamURL: URL?
    @State private var presets: [PTZPreset] = []
    @State private var hardwareImaging = ImagingSettings()
    @State private var hardwareAvailable = false
    @State private var liveFilter = LiveFilterSettings.neutral

    @State private var selectedTab: Tab = .live
    @State private var snapshotToast: String?

    enum Tab: String, CaseIterable, Identifiable {
        case live = "Direct", ptz = "PTZ", image = "Image & filtres"
        var id: String { rawValue }
    }

    init(camera: Camera) {
        self.camera = camera
        let existingCredentials = KeychainStore.load(for: camera.id)
        _credentials = State(initialValue: existingCredentials)
        _client = State(initialValue: ONVIFClient(camera: camera, credentials: existingCredentials))
    }

    var body: some View {
        VStack(spacing: 0) {
            RTSPPlayerView(url: streamURL, liveFilter: liveFilter)
                .aspectRatio(16/9, contentMode: .fit)
                .background(Color.black)

            Picker("Onglet", selection: $selectedTab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch selectedTab {
                case .live:
                    liveTab
                case .ptz:
                    ptzTab
                case .image:
                    ImagingControlView(
                        hardware: $hardwareImaging,
                        hardwareAvailable: hardwareAvailable,
                        onApplyHardware: applyHardwareImaging,
                        liveFilter: $liveFilter
                    )
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(camera.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCredentialsSheet) {
            CredentialsSheet(cameraName: camera.displayName) { newCredentials in
                credentials = newCredentials
                KeychainStore.save(newCredentials, for: camera.id)
                client.updateCredentials(newCredentials)
                Task { await connect() }
            }
        }
        .task {
            if camera.kind == .onvif {
                if credentials == nil {
                    showCredentialsSheet = true
                } else {
                    await connect()
                }
            } else if let rtsp = camera.rtspURL {
                streamURL = rtsp
            }
        }
        .overlay(alignment: .top) {
            if let error = connectionError {
                Text(error)
                    .font(.footnote)
                    .padding(8)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
            if let toast = snapshotToast {
                Text(toast)
                    .font(.footnote)
                    .padding(8)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
            }
        }
    }

    private var liveTab: some View {
        VStack(spacing: 12) {
            HStack {
                Label(camera.ipAddress, systemImage: "network")
                Spacer()
                if isConnecting { ProgressView() }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button {
                    Task { await saveSnapshot() }
                } label: {
                    Label("Instantané", systemImage: "camera.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(camera.kind != .onvif)

                Button {
                    showCredentialsSheet = true
                } label: {
                    Label("Identifiants", systemImage: "key.fill")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding()
    }

    private var ptzTab: some View {
        Group {
            if client.supportsPTZ {
                PTZControlView(
                    onMove: { vector in Task { try? await client.ptzContinuousMove(vector) } },
                    onStop: { Task { try? await client.ptzStop() } },
                    presets: presets,
                    onGotoPreset: { preset in Task { try? await client.gotoPreset(token: preset.token) } },
                    onSavePreset: {
                        Task {
                            try? await client.setPreset(name: "Position \(presets.count + 1)")
                            presets = (try? await client.fetchPresets()) ?? presets
                        }
                    }
                )
                .padding()
            } else {
                ContentUnavailableView(
                    "Pas de moteur PTZ",
                    systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                    description: Text("Cette caméra ne signale pas de service PTZ ONVIF (caméra fixe, ou fonction non exposée).")
                )
            }
        }
    }

    private func connect() async {
        guard camera.kind == .onvif else { return }
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }
        do {
            try await client.loadCapabilities()
            streamURL = try await client.fetchStreamURL()
            presets = (try? await client.fetchPresets()) ?? []
            if client.supportsImaging, let settings = try? await client.fetchImagingSettings() {
                hardwareImaging = settings
                hardwareAvailable = true
            }
        } catch ONVIFClient.ONVIFError.unauthorized {
            connectionError = "Identifiants incorrects."
            showCredentialsSheet = true
        } catch {
            connectionError = "Connexion impossible : \(error.localizedDescription)"
        }
    }

    private func applyHardwareImaging() {
        Task {
            do {
                try await client.applyImagingSettings(hardwareImaging)
                snapshotToast = "Réglages appliqués à la caméra."
            } catch {
                connectionError = "Échec de l'application des réglages."
            }
            try? await Task.sleep(for: .seconds(2))
            snapshotToast = nil
            connectionError = nil
        }
    }

    private func saveSnapshot() async {
        do {
            let snapshotURL = try await client.fetchSnapshotURL()
            var request = URLRequest(url: snapshotURL)
            if let credentials {
                let auth = "\(credentials.username):\(credentials.password)"
                if let data = auth.data(using: .utf8) {
                    request.setValue("Basic \(data.base64EncodedString())", forHTTPHeaderField: "Authorization")
                }
            }
            let (data, _) = try await URLSession.shared.data(for: request)
            guard var image = UIImage(data: data) else { throw ONVIFClient.ONVIFError.malformedResponse }
            image = applyLiveFilter(to: image) ?? image

            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                snapshotToast = "Autorisez l'accès aux photos pour enregistrer l'instantané."
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            snapshotToast = "Instantané enregistré dans Photos."
        } catch {
            snapshotToast = "Échec de l'instantané : \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(2))
        snapshotToast = nil
    }

    private func applyLiveFilter(to image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        var output = ciImage
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(liveFilter.brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(liveFilter.contrast, forKey: kCIInputContrastKey)
            controls.setValue(liveFilter.saturation, forKey: kCIInputSaturationKey)
            output = controls.outputImage ?? output
        }
        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
