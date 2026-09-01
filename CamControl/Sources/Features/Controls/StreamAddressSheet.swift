import SwiftUI

/// Takes the exact RTSP address of one camera.
///
/// The way out when guessing has failed. Every automatic path has an end — a
/// camera on a firmware nobody has catalogued, a stream moved to an address of
/// its owner's choosing — and past that point the person holding the phone knows
/// something the app cannot work out. Telling them so and then offering nowhere
/// to type it is the worst of both.
struct StreamAddressSheet: View {
    let cameraName: String
    let host: String
    var existing: URL?
    let onSave: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(cameraName)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("L'adresse exacte du flux se trouve dans l'interface web de la caméra, souvent sous « RTSP », « Flux » ou « Réseau », et dans son manuel.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }

                Section {
                    TextField("rtsp://\(host):554/…", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                } header: {
                    Text("Adresse du flux")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Theme.Palette.warning)
                    } else {
                        Text("Le nom d'utilisateur et le mot de passe peuvent être inclus, sous la forme rtsp://admin:motdepasse@\(host):554/… — ou laissés de côté : ceux déjà enregistrés pour cette caméra seront ajoutés.")
                    }
                }
            }
            .navigationTitle("Adresse du flux")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Utiliser", action: save)
                        .fontWeight(.semibold)
                        .disabled(parsed == nil)
                }
            }
            .onAppear {
                address = existing?.absoluteString ?? "rtsp://\(host):554/"
                isFocused = true
            }
        }
    }

    /// Validated only once something has been typed, so the field does not open
    /// already complaining.
    private var problem: String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "rtsp://\(host):554/", parsed == nil else { return nil }
        return "L'adresse doit commencer par rtsp:// et contenir un nom d'hôte."
    }

    private var parsed: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "rtsp",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private func save() {
        guard let parsed else { return }
        onSave(parsed)
        dismiss()
    }
}
