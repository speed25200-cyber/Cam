import SwiftUI

struct SettingsView: View {
    @Environment(CameraStore.self) private var store
    @State private var confirmReset = false
    @State private var interface = LocalNetworkInfo.currentInterface()

    var body: some View {
        NavigationStack {
            List {
                if let error = store.persistenceError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Palette.warning)
                            .font(Theme.Typography.caption)
                    }
                }

                Section("Réseau") {
                    if let interface {
                        LabeledContent("Interface", value: interface.name)
                        LabeledContent("Adresse") {
                            Text(interface.address).font(Theme.Typography.mono)
                        }
                        LabeledContent("Masque", value: "/\(interface.prefixLength)")
                    } else {
                        Label("Pas de réseau local détecté", systemImage: "wifi.slash")
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    Button {
                        interface = LocalNetworkInfo.currentInterface()
                    } label: {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                }

                Section("Bibliothèque") {
                    LabeledContent("Caméras enregistrées", value: "\(store.cameras.count)")
                    Button(role: .destructive) {
                        confirmReset = true
                    } label: {
                        Label("Tout oublier", systemImage: "trash")
                    }
                    .disabled(store.isEmpty)
                }

                Section {
                    Label {
                        Text("Les identifiants sont stockés dans le Trousseau iOS, chiffrés par le système et jamais inclus dans la liste des caméras.")
                    } icon: {
                        Image(systemName: "lock.shield.fill").foregroundStyle(Theme.Palette.success)
                    }
                    Label {
                        Text("Aucune donnée ne quitte votre réseau local : l'app parle directement aux caméras, sans service tiers ni cloud.")
                    } icon: {
                        Image(systemName: "network.slash").foregroundStyle(Theme.Palette.accent)
                    }
                } header: {
                    Text("Confidentialité")
                } footer: {
                    Text("N'utilisez CamControl que sur des caméras qui vous appartiennent, avec vos propres identifiants. Accéder à un appareil sans autorisation est illégal.")
                }
                .font(Theme.Typography.caption)

                Section("À propos") {
                    LabeledContent("Version", value: appVersion)
                    LabeledContent("Protocole", value: "ONVIF Profile S · RTSP")
                }
            }
            .navigationTitle("Réglages")
            .alert("Tout oublier ?", isPresented: $confirmReset) {
                Button("Annuler", role: .cancel) {}
                Button("Tout oublier", role: .destructive) { store.removeAll() }
            } message: {
                Text("Toutes les caméras enregistrées, leurs identifiants et leurs aperçus seront supprimés de cet appareil.")
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
