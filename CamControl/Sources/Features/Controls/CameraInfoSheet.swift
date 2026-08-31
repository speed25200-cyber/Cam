import SwiftUI

/// Identity and capability sheet for one camera, plus the destructive actions
/// that belong with it (rename, forget).
struct CameraInfoSheet: View {
    let camera: Camera
    let playback: PlaybackStatus
    let store: CameraStore

    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Nom", value: camera.displayName)
                    LabeledContent("Adresse") {
                        Text(camera.host).font(Theme.Typography.mono)
                    }
                    if let manufacturer = camera.manufacturer {
                        LabeledContent("Fabricant", value: manufacturer)
                    }
                    if let model = camera.model {
                        LabeledContent("Modèle", value: model)
                    }
                    if let firmware = camera.firmwareVersion {
                        LabeledContent("Micrologiciel", value: firmware)
                    }
                    if let serial = camera.serialNumber {
                        LabeledContent("Numéro de série") {
                            Text(serial).font(Theme.Typography.mono)
                        }
                    }
                }

                Section {
                    LabeledContent("Flux") {
                        StatusBadge(playbackLabel, systemImage: playbackIcon, tint: playbackTint)
                    }
                    LabeledContent("Protocole") {
                        StatusBadge(camera.kind.label, tint: Theme.Palette.accent)
                    }
                    if !camera.openPorts.isEmpty {
                        LabeledContent("Ports ouverts") {
                            Text(camera.openPorts.map(String.init).joined(separator: ", "))
                                .font(Theme.Typography.mono)
                        }
                    }
                } header: {
                    Text("État")
                } footer: {
                    Text(camera.kind.explanation)
                }

                Section("Fonctions") {
                    capabilityRow("Flux vidéo", available: camera.capabilities.hasMedia, icon: "video")
                    capabilityRow("Orientation PTZ", available: camera.capabilities.hasPTZ, icon: "dpad")
                    capabilityRow("Réglages d'image", available: camera.capabilities.hasImaging, icon: "slider.horizontal.3")
                }

                Section {
                    Button {
                        draftName = camera.customName ?? camera.displayName
                        isRenaming = true
                    } label: {
                        Label("Renommer", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        Label("Oublier cette caméra", systemImage: "trash")
                    }
                } footer: {
                    Text("Oublier supprime la caméra de la liste, ses identifiants du Trousseau et son aperçu enregistré.")
                }
            }
            .navigationTitle("Informations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .alert("Renommer", isPresented: $isRenaming) {
                TextField("Nom de la caméra", text: $draftName)
                Button("Annuler", role: .cancel) {}
                Button("Enregistrer") { store.rename(camera, to: draftName) }
            }
            .alert("Oublier cette caméra ?", isPresented: $confirmForget) {
                Button("Annuler", role: .cancel) {}
                Button("Oublier", role: .destructive) {
                    store.remove(camera)
                    dismiss()
                }
            } message: {
                Text("Ses identifiants seront également supprimés du Trousseau.")
            }
        }
    }

    private func capabilityRow(_ title: String, available: Bool, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Theme.Palette.success : Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) : \(available ? "pris en charge" : "non pris en charge")")
    }

    private var playbackLabel: String {
        switch playback {
        case .playing: return "En direct"
        case .opening, .buffering: return "Connexion"
        case .stalled: return "Interrompu"
        case .failed: return "Échec"
        case .ended: return "Terminé"
        case .idle: return "Inactif"
        }
    }

    private var playbackIcon: String {
        switch playback {
        case .playing: return "dot.radiowaves.left.and.right"
        case .opening, .buffering: return "arrow.triangle.2.circlepath"
        case .stalled, .failed: return "exclamationmark.triangle"
        case .ended, .idle: return "pause"
        }
    }

    private var playbackTint: Color {
        switch playback {
        case .playing: return Theme.Palette.success
        case .opening, .buffering: return Theme.Palette.warning
        case .stalled, .failed: return Theme.Palette.danger
        case .ended, .idle: return Theme.Palette.textTertiary
        }
    }
}
