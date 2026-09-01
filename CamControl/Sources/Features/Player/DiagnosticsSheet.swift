import SwiftUI
import UIKit

/// What the app tried on a camera it could not open, in order.
///
/// Exists because every way a camera can fail to connect looks identical from
/// the player: a black screen and one sentence. A closed port, a wrong stream
/// address, a missing password and a camera that has no RTSP at all are four
/// different problems with four different answers, and the person holding the
/// phone is the only one who can see which it is. This tells them — and gives
/// them something to copy when it needs passing on.
struct DiagnosticsSheet: View {
    let camera: Camera
    let lines: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // Indexed rather than `enumerated()`: Swift has no key path
                    // to a tuple element, so `id: \.offset` does not compile.
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(Theme.Typography.mono)
                            .foregroundStyle(tint(for: lines[index]))
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Les adresses de flux sont testées une par une. « Port fermé » signifie que la caméra ne diffuse pas en RTSP à cette adresse ; « identifiants refusés » qu'elle diffuse, mais attend un compte différent.")
                }
            }
            .navigationTitle("Détails de la connexion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copié" : "Copier") {
                        UIPasteboard.general.string = report
                        copied = true
                        Haptics.tap()
                    }
                    .disabled(copied)
                }
            }
        }
    }

    /// The successful and the refused lines are the two worth finding at a
    /// glance; everything else is context.
    private func tint(for line: String) -> Color {
        if line.contains("trouvé") { return Theme.Palette.success }
        if line.contains("refusé") || line.contains("fermé") { return Theme.Palette.warning }
        return Theme.Palette.textSecondary
    }

    private var report: String {
        ("CamControl · \(camera.displayName)\n" + lines.joined(separator: "\n"))
    }
}
