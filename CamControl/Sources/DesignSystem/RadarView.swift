import SwiftUI

/// Animated sweep shown while the subnet is being probed.
///
/// The blips are positioned deterministically from each device's IP address, so a
/// device keeps its spot for the whole scan instead of jumping between frames.
/// Purely decorative: it visualises progress, not physical location.
struct RadarView: View {
    /// 0...1 sweep completion, driven by the scanner's real progress.
    var progress: Double
    /// Discovered hosts, in discovery order.
    var blips: [String]
    var isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweepAngle: Double = 0

    private let ringCount = 3

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2

            ZStack {
                rings(radius: radius)
                crosshairs(radius: radius)
                if isActive { sweep(radius: radius) }
                blipLayer(radius: radius)
                core
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: startSweep)
        .onChange(of: isActive) { _, active in
            if active { startSweep() }
        }
        .accessibilityElement()
        .accessibilityLabel("Scan du réseau en cours")
        .accessibilityValue("\(Int(progress * 100)) pour cent")
    }

    // MARK: - Layers

    private func rings(radius: CGFloat) -> some View {
        ForEach(1...ringCount, id: \.self) { index in
            let fraction = CGFloat(index) / CGFloat(ringCount)
            Circle()
                .strokeBorder(Theme.Palette.accent.opacity(0.10 + 0.05 * fraction), lineWidth: 1)
                .frame(width: radius * 2 * fraction, height: radius * 2 * fraction)
        }
    }

    private func crosshairs(radius: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Theme.Palette.accent.opacity(0.08))
                .frame(width: radius * 2, height: 1)
            Rectangle()
                .fill(Theme.Palette.accent.opacity(0.08))
                .frame(width: 1, height: radius * 2)
        }
    }

    private func sweep(radius: CGFloat) -> some View {
        Circle()
            .fill(
                AngularGradient(
                    stops: [
                        .init(color: Theme.Palette.accent.opacity(0.00), location: 0.00),
                        .init(color: Theme.Palette.accent.opacity(0.05), location: 0.55),
                        .init(color: Theme.Palette.accent.opacity(0.28), location: 0.92),
                        .init(color: Theme.Palette.accent.opacity(0.55), location: 1.00)
                    ],
                    center: .center
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .rotationEffect(.degrees(sweepAngle))
            .blendMode(.plusLighter)
    }

    private func blipLayer(radius: CGFloat) -> some View {
        ForEach(Array(blips.enumerated()), id: \.element) { index, host in
            let position = blipPosition(host: host, index: index, radius: radius)
            Blip(delay: Double(index) * 0.05)
                .position(x: radius + position.x, y: radius + position.y)
        }
    }

    private var core: some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.accent.opacity(0.18))
                .frame(width: 54, height: 54)
                .blur(radius: 8)
            Image(systemName: "wifi")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
        }
    }

    // MARK: - Geometry

    /// Deterministic polar placement: the angle comes from a stable hash of the
    /// host so a device never moves once found, the ring from its discovery order.
    private func blipPosition(host: String, index: Int, radius: CGFloat) -> CGPoint {
        var hash: UInt64 = 5381
        for byte in host.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        let angle = Double(hash % 360) * .pi / 180
        let ringFraction = 0.35 + 0.55 * Double((index % ringCount) + 1) / Double(ringCount)
        let distance = radius * CGFloat(ringFraction) * 0.85
        return CGPoint(x: cos(angle) * distance, y: sin(angle) * distance)
    }

    private func startSweep() {
        guard !reduceMotion else { return }
        sweepAngle = 0
        withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
            sweepAngle = 360
        }
    }
}

/// A single discovered-device dot, with a one-shot ping ring on appearance.
private struct Blip: View {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var ping = false

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.Palette.accent.opacity(ping ? 0 : 0.6), lineWidth: 1.5)
                .frame(width: ping ? 34 : 8, height: ping ? 34 : 8)
            Circle()
                .fill(Theme.Palette.accent)
                .frame(width: 7, height: 7)
                .shadow(color: Theme.Palette.accent.opacity(0.8), radius: 5)
        }
        .scaleEffect(appeared ? 1 : 0.1)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            guard !reduceMotion else {
                appeared = true
                return
            }
            withAnimation(Theme.Motion.bouncy.delay(delay)) { appeared = true }
            withAnimation(.easeOut(duration: 1.1).delay(delay).repeatForever(autoreverses: false)) { ping = true }
        }
    }
}
