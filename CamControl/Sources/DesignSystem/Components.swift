import SwiftUI

// MARK: - Surfaces

/// Rounded card surface used for every elevated block in the app.
struct CardSurface: ViewModifier {
    var radius: CGFloat = Theme.Radius.lg
    var fill: Color = Theme.Palette.surface

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.stroke, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }
}

extension View {
    func cardSurface(radius: CGFloat = Theme.Radius.lg, fill: Color = Theme.Palette.surface) -> some View {
        modifier(CardSurface(radius: radius, fill: fill))
    }

    /// Frosted control that sits on top of video, where the background is unknown.
    func glassControl(radius: CGFloat = Theme.Radius.pill) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
    }
}

// MARK: - Status

/// Small capsule describing a device's state — the primary at-a-glance signal
/// on every camera card.
struct StatusBadge: View {
    let text: String
    let systemImage: String?
    let tint: Color
    var filled: Bool = false

    init(_ text: String, systemImage: String? = nil, tint: Color, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.filled = filled
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(Theme.Typography.micro)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(filled ? Color.white : tint)
        .background(filled ? tint : tint.opacity(0.16), in: Capsule())
        .overlay {
            if !filled {
                Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

/// Pulsing red dot + LIVE wordmark shown while a stream is actually playing.
struct LiveIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.Palette.live)
                .frame(width: 6, height: 6)
                .scaleEffect(pulsing ? 1.0 : 0.55)
                .opacity(pulsing ? 1.0 : 0.5)
            Text("LIVE")
                .font(Theme.Typography.micro)
                .kerning(0.8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        .onAppear {
            guard !reduceMotion else { pulsing = true; return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
        .accessibilityLabel("Diffusion en direct")
    }
}

// MARK: - Buttons

/// Filled accent button — one per screen at most, for the primary action.
struct AccentButtonStyle: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Theme.Palette.accentGradient, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.instant, value: configuration.isPressed)
    }
}

/// Neutral bordered button for secondary actions.
struct GhostButtonStyle: ButtonStyle {
    var expands = false
    var tint: Color = Theme.Palette.textPrimary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.callout)
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(Theme.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .strokeBorder(Theme.Palette.stroke, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.Motion.instant, value: configuration.isPressed)
    }
}

/// Circular icon button used in the player HUD, where labels would crowd the frame.
struct CircularIconButton: View {
    let systemImage: String
    var size: CGFloat = 44
    var tint: Color = .white
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isActive ? Color.black : tint)
                .frame(width: size, height: size)
                .background {
                    if isActive {
                        Circle().fill(.white)
                    } else {
                        Circle().fill(.black.opacity(0.35))
                        Circle().fill(.ultraThinMaterial)
                    }
                }
                .overlay { Circle().strokeBorder(.white.opacity(isActive ? 0 : 0.16), lineWidth: 1) }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var action: (label: String, handler: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            if let action {
                Button(action.label, action: action.handler)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
    }
}

// MARK: - Empty states

/// Full-bleed empty/error state with an optional call to action.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.12))
                    .frame(width: 92, height: 92)
                Image(systemName: systemImage)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.Palette.accent)
            }

            VStack(spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(message)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(AccentButtonStyle())
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity)
    }
}
