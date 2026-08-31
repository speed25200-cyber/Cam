import SwiftUI
import UIKit

/// The app's single source of truth for color, type, spacing and motion.
///
/// Every token is defined once here and resolves per color scheme, so the whole
/// app follows the system appearance without any view branching on `colorScheme`.
enum Theme {

    // MARK: - Color

    enum Palette {
        /// Page background, behind everything.
        static let canvas = Color.adaptive(light: 0xF4F5F7, dark: 0x08090B)
        /// Cards and sheets sitting on the canvas.
        static let surface = Color.adaptive(light: 0xFFFFFF, dark: 0x14161B)
        /// Controls sitting on a surface (chips, sliders, inset rows).
        static let surfaceRaised = Color.adaptive(light: 0xF0F2F5, dark: 0x1E212A)
        /// Hairline borders. Deliberately low contrast — structure, not decoration.
        static let stroke = Color.adaptive(light: 0x000000, dark: 0xFFFFFF).opacity(0.10)

        static let textPrimary = Color.adaptive(light: 0x0B0D12, dark: 0xF3F5F8)
        static let textSecondary = Color.adaptive(light: 0x5C6470, dark: 0x99A1AE)
        static let textTertiary = Color.adaptive(light: 0x8B939F, dark: 0x646C7A)

        /// Brand accent — used for interactive affordances and ONVIF-capable devices.
        static let accent = Color.adaptive(light: 0x0891B2, dark: 0x22D3EE)
        static let accentSecondary = Color.adaptive(light: 0x4F46E5, dark: 0x818CF8)

        static let live = Color.adaptive(light: 0xDC2626, dark: 0xFF453A)
        static let success = Color.adaptive(light: 0x059669, dark: 0x34D399)
        static let warning = Color.adaptive(light: 0xD97706, dark: 0xFBBF24)
        static let danger = Color.adaptive(light: 0xDC2626, dark: 0xFF6B6B)

        /// Always-dark surface for anything overlaying video.
        static let videoScrim = Color(red: 0.03, green: 0.04, blue: 0.05)

        static let accentGradient = LinearGradient(
            colors: [accent, accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Type

    enum Typography {
        static let title = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let body = Font.system(size: 15, weight: .regular)
        static let callout = Font.system(size: 14, weight: .medium)
        static let caption = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 11, weight: .semibold)
        /// Tabular figures — for IP addresses, bitrates, timers that must not jitter.
        static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    }

    // MARK: - Metrics

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let pill: CGFloat = 999
    }

    // MARK: - Motion

    /// Named animations so timing stays consistent — and so Reduce Motion can
    /// flatten all of them in one place via `Motion.resolve(_:reduced:)`.
    enum Motion {
        static let snappy = Animation.snappy(duration: 0.28, extraBounce: 0.02)
        static let bouncy = Animation.bouncy(duration: 0.42, extraBounce: 0.12)
        static let gentle = Animation.smooth(duration: 0.35)
        static let instant = Animation.easeOut(duration: 0.15)

        static func resolve(_ animation: Animation, reduced: Bool) -> Animation? {
            reduced ? .easeInOut(duration: 0.12) : animation
        }
    }
}

// MARK: - Color helpers

extension Color {
    /// Builds a color that resolves differently in light and dark mode from two
    /// hex literals, so tokens can be declared as plain constants.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
