import SwiftUI

struct CredentialsSheet: View {
    let cameraName: String
    @State private var username: String = "admin"
    @State private var password: String = ""
    let onSave: (CameraCredentials) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Entrez les identifiants de « \(cameraName) » (ceux que vous utilisez déjà dans l'app du fabricant ou sur l'étiquette de la caméra).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Identifiants") {
                    TextField("Nom d'utilisateur", text: $username)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Mot de passe", text: $password)
                }
            }
            .navigationTitle("Connexion caméra")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connecter") {
                        onSave(CameraCredentials(username: username, password: password))
                        dismiss()
                    }
                    .disabled(username.isEmpty)
                }
            }
        }
    }
}
