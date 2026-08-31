import SwiftUI

/// Asks for one camera's ONVIF credentials.
struct CredentialsSheet: View {
    let cameraName: String
    var existing: CameraCredentials?
    let onSave: (CameraCredentials) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var password = ""
    @State private var revealPassword = false
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(cameraName)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Utilisez le compte ONVIF de la caméra. Sur beaucoup de modèles il se crée séparément du compte de l'app du fabricant, dans les réglages « ONVIF » ou « Utilisateurs ».")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }

                Section("Identifiants") {
                    TextField("Nom d'utilisateur", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.next)
                        .focused($focus, equals: .username)
                        .onSubmit { focus = .password }

                    HStack {
                        Group {
                            if revealPassword {
                                TextField("Mot de passe", text: $password)
                            } else {
                                SecureField("Mot de passe", text: $password)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit(save)

                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealPassword ? "Masquer le mot de passe" : "Afficher le mot de passe")
                    }
                }

                Section {
                    Label(
                        "Enregistrés dans le Trousseau iOS, jamais envoyés hors de votre réseau.",
                        systemImage: "lock.shield"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .navigationTitle("Connexion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connecter", action: save)
                        .fontWeight(.semibold)
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                username = existing?.username ?? "admin"
                password = existing?.password ?? ""
                // Land on whichever field is actually missing.
                focus = username.isEmpty ? .username : .password
            }
        }
    }

    private func save() {
        let trimmed = username.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSave(CameraCredentials(username: trimmed, password: password))
        dismiss()
    }
}
