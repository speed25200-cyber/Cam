import SwiftUI

/// PTZ positions stored on the camera itself, so they survive the app and are
/// shared with every other client pointed at the same device.
struct PresetsSheet: View {
    @Bindable var session: CameraSession
    @Environment(\.dismiss) private var dismiss

    @State private var isNaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Group {
                if session.presets.isEmpty {
                    EmptyStateView(
                        systemImage: "bookmark",
                        title: "Aucune position",
                        message: "Orientez la caméra comme vous le souhaitez, puis enregistrez la position pour y revenir d'un geste.",
                        actionTitle: "Enregistrer la position actuelle"
                    ) { promptForName() }
                } else {
                    List {
                        ForEach(session.presets) { preset in
                            Button {
                                session.goto(preset: preset)
                                dismiss()
                            } label: {
                                HStack(spacing: Theme.Spacing.md) {
                                    Image(systemName: "scope")
                                        .foregroundStyle(Theme.Palette.accent)
                                    Text(preset.name)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.forward.circle")
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    session.deletePreset(preset)
                                } label: {
                                    Label("Supprimer", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.Palette.canvas)
            .navigationTitle("Positions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        promptForName()
                    } label: {
                        Label("Enregistrer", systemImage: "plus")
                    }
                }
            }
            .alert("Nom de la position", isPresented: $isNaming) {
                TextField("Entrée, Jardin, Portail…", text: $newName)
                Button("Annuler", role: .cancel) {}
                Button("Enregistrer") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.savePreset(named: name.isEmpty ? defaultName : name)
                }
            } message: {
                Text("La caméra mémorisera son orientation actuelle sous ce nom.")
            }
        }
    }

    private var defaultName: String { "Position \(session.presets.count + 1)" }

    private func promptForName() {
        newName = ""
        isNaming = true
    }
}
