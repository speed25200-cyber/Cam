import SwiftUI

struct CameraRowView: View {
    let camera: Camera

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(iconColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName).font(.body.weight(.medium))
                Text(camera.ipAddress).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Text(kindLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(iconColor.opacity(0.15), in: Capsule())
                .foregroundStyle(iconColor)
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch camera.kind {
        case .onvif: return "video.fill"
        case .rtspGuess: return "video"
        case .httpOnly: return "questionmark.video"
        }
    }

    private var iconColor: Color {
        switch camera.kind {
        case .onvif: return .green
        case .rtspGuess: return .orange
        case .httpOnly: return .gray
        }
    }

    private var kindLabel: String {
        switch camera.kind {
        case .onvif: return "ONVIF"
        case .rtspGuess: return "RTSP"
        case .httpOnly: return "Inconnu"
        }
    }
}
