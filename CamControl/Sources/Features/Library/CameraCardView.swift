import SwiftUI

/// One camera in the library.
///
/// Leads with the last frame the camera sent rather than an icon: a wall of
/// identical video glyphs makes the user read addresses to tell their own
/// cameras apart, while a still of the driveway is recognised instantly.
struct CameraCardView: View {
    let camera: Camera
    var thumbnail: UIImage?
    var isReachable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            details
        }
        .cardSurface()
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(camera.displayName)
        .accessibilityValue(isReachable ? "Disponible" : "Injoignable")
        .accessibilityAddTraits(.isButton)
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .center
            )
            .allowsHitTesting(false)

            HStack {
                StatusBadge(
                    camera.kind.label,
                    systemImage: camera.kind == .onvif ? "checkmark.seal.fill" : nil,
                    tint: kindTint,
                    filled: camera.kind == .onvif
                )
                Spacer()
                if !isReachable {
                    StatusBadge("Hors ligne", systemImage: "wifi.slash", tint: Theme.Palette.textTertiary)
                }
            }
            .padding(Theme.Spacing.md)
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: Theme.Radius.lg,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: Theme.Radius.lg,
                style: .continuous
            )
        )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.Palette.surfaceRaised, Theme.Palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "video.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("Aucun aperçu")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var details: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(camera.subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: Theme.Spacing.sm) {
                if camera.capabilities.hasPTZ {
                    featureIcon("dpad.fill", label: "PTZ")
                }
                if camera.capabilities.hasImaging {
                    featureIcon("slider.horizontal.3", label: "Réglages d'image")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func featureIcon(_ systemImage: String, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.Palette.accent)
            .frame(width: 24, height: 24)
            .background(Theme.Palette.accent.opacity(0.14), in: Circle())
            .accessibilityLabel(label)
    }

    private var kindTint: Color {
        switch camera.kind {
        case .onvif: return Theme.Palette.accent
        case .rtsp: return Theme.Palette.warning
        case .unknown: return Theme.Palette.textTertiary
        }
    }
}
