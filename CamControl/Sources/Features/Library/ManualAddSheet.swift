import SwiftUI

/// Adds a camera by address.
///
/// The escape hatch for everything discovery cannot reach: cameras on a VLAN or
/// a guest network, on a subnet the sweep skips, or with multicast and the usual
/// ports firewalled off.
struct ManualAddSheet: View {
    let onAdd: (Camera) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "80"
    @State private var username = "admin"
    @State private var password = ""
    @State private var streamURL = ""
    @State private var probe: ProbeState = .idle
    @FocusState private var focus: Field?

    private enum Field { case host, port, stream, username, password }

    private enum ProbeState: Equatable {
        case idle
        case running
        case success(Camera)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.64", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .host)
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .port)
                } header: {
                    Text("Adresse de la caméra")
                } footer: {
                    Text("Le port ONVIF est 80 sur la plupart des caméras, parfois 8000 ou 8080.")
                }

                Section {
                    TextField("rtsp://192.168.1.64:554/stream1", text: $streamURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .stream)
                } header: {
                    Text("Adresse du flux (facultatif)")
                } footer: {
                    Text("À remplir seulement si la caméra n'expose pas ONVIF et que vous connaissez son adresse RTSP exacte. Sinon, laissez vide : l'app essaie les adresses habituelles toute seule.")
                }

                Section("Identifiants ONVIF") {
                    TextField("Nom d'utilisateur", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                    SecureField("Mot de passe", text: $password)
                        .focused($focus, equals: .password)
                }

                Section {
                    switch probe {
                    case .idle:
                        EmptyView()
                    case .running:
                        HStack(spacing: Theme.Spacing.md) {
                            ProgressView()
                            Text("Contact de la caméra…")
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    case .success(let camera):
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(camera.displayName).foregroundStyle(Theme.Palette.textPrimary)
                                Text("Caméra ONVIF reconnue")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                            }
                        } icon: {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(Theme.Palette.success)
                        }
                    case .failure(let message):
                        Label {
                            Text(message).font(Theme.Typography.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Palette.warning)
                        }
                    }
                }
            }
            .navigationTitle("Ajouter une caméra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: addOrProbe) {
                        Text(isVerified ? "Ajouter" : "Vérifier")
                            .fontWeight(.semibold)
                    }
                    .disabled(!isAddressValid || probe == .running)
                }
            }
        }
    }

    private var isVerified: Bool {
        if case .success = probe { return true }
        return false
    }

    private var isAddressValid: Bool {
        LocalNetworkInfo.ipv4Value(host.trimmingCharacters(in: .whitespaces)) != nil
            && UInt16(port) != nil
    }

    private func addOrProbe() {
        if case .success(let camera) = probe {
            let credentials = CameraCredentials(username: username, password: password)
            KeychainStore.save(credentials, for: camera.credentialsKey)
            onAdd(camera)
            dismiss()
            return
        }
        Task { await runProbe() }
    }

    /// Confirms the address really is a camera before it lands in the library, so
    /// a typo surfaces here rather than as a permanently broken card.
    private func runProbe() async {
        focus = nil
        probe = .running

        let address = host.trimmingCharacters(in: .whitespaces)
        guard let portNumber = Int(port), let url = URL(string: "http://\(address):\(portNumber)/onvif/device_service") else {
            probe = .failure("Adresse invalide.")
            return
        }

        let override = parsedStreamURL()
        if !streamURL.trimmingCharacters(in: .whitespaces).isEmpty, override == nil {
            probe = .failure("L'adresse de flux doit commencer par rtsp:// .")
            Haptics.failure()
            return
        }

        let credentials = CameraCredentials(username: username, password: password)
        let client = ONVIFClient(deviceServiceURL: url, credentials: credentials, timeout: 6)

        do {
            let info = try await client.deviceInformation()
            var camera = Camera(
                host: address,
                onvifServiceURL: url,
                kind: .onvif,
                manufacturer: info.manufacturer,
                model: info.model,
                firmwareVersion: info.firmwareVersion,
                serialNumber: info.serialNumber,
                openPorts: [portNumber],
                rtspURLOverride: override,
                lastSeen: Date()
            )
            camera.isSaved = true
            probe = .success(camera)
            Haptics.success()
        } catch ONVIFError.unauthorized {
            probe = .failure("La caméra répond mais refuse ces identifiants.")
            Haptics.warning()
        } catch {
            // Not ONVIF, but an RTSP port may still be usable — offer it rather
            // than turning the user away with nothing. An address the user typed
            // is trusted without a port check: it may well point elsewhere.
            if override != nil || await PortScanner.isOpen(host: address, port: 554, timeout: 1.5) {
                var camera = Camera(
                    host: address,
                    kind: .rtsp,
                    openPorts: [554],
                    rtspURLOverride: override,
                    lastSeen: Date()
                )
                camera.isSaved = true
                probe = .success(camera)
                Haptics.success()
            } else {
                probe = .failure("Aucune caméra ONVIF ou RTSP ne répond à cette adresse.")
                Haptics.failure()
            }
        }
    }

    private func parsedStreamURL() -> URL? {
        let trimmed = streamURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "rtsp",
              url.host != nil else { return nil }
        return url
    }
}
