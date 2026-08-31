import SwiftUI

/// Analogue pan/tilt pad.
///
/// A joystick rather than a direction pad because framing a camera is a
/// continuous act: the distance from centre sets the motor speed, so the same
/// control does both a slow nudge and a fast sweep without a separate speed
/// setting.
struct PTZJoystick: View {
    let onChange: (PTZVector) -> Void
    let onRelease: () -> Void
    var isEnabled = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var knobOffset: CGSize = .zero
    @State private var isDragging = false
    /// Last octant the knob was in, so the haptic fires on direction change
    /// rather than continuously during the drag.
    @State private var lastOctant: Int?

    private let padSize: CGFloat = 200
    private var radius: CGFloat { padSize / 2 - knobRadius }
    private let knobRadius: CGFloat = 32

    var body: some View {
        ZStack {
            base
            directionHints
            knob
        }
        .frame(width: padSize, height: padSize)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Commande d'orientation")
        .accessibilityHint("Faites glisser pour orienter la caméra. Plus loin du centre, plus le mouvement est rapide.")
        .accessibilityAdjustableAction { direction in
            // VoiceOver users get discrete steps rather than a drag they cannot see.
            let step = 0.5
            switch direction {
            case .increment: nudge(PTZVector(pan: step, tilt: 0))
            case .decrement: nudge(PTZVector(pan: -step, tilt: 0))
            @unknown default: break
            }
        }
    }

    // MARK: - Layers

    private var base: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Theme.Palette.accent.opacity(isDragging ? 0.18 : 0.06), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: padSize / 2
                    )
                )
            Circle()
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            Circle()
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                .padding(padSize * 0.22)
        }
    }

    private var directionHints: some View {
        ForEach(0..<4, id: \.self) { index in
            let angle = Double(index) * 90.0
            Image(systemName: "chevron.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(highlight(forQuadrant: index) ? 0.95 : 0.28))
                .offset(y: -(padSize / 2 - 14))
                .rotationEffect(.degrees(angle))
        }
    }

    private var knob: some View {
        ZStack {
            Circle()
                .fill(Theme.Palette.accentGradient)
                .shadow(color: Theme.Palette.accent.opacity(isDragging ? 0.55 : 0.25), radius: isDragging ? 16 : 8)
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
            Image(systemName: "move.3d")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: knobRadius * 2, height: knobRadius * 2)
        .scaleEffect(isDragging ? 1.08 : 1)
        .offset(knobOffset)
    }

    private func highlight(forQuadrant index: Int) -> Bool {
        guard isDragging else { return false }
        // 0 = up, 1 = right, 2 = down, 3 = left, matching the rotation above.
        switch index {
        case 0: return knobOffset.height < -8
        case 1: return knobOffset.width > 8
        case 2: return knobOffset.height > 8
        case 3: return knobOffset.width < -8
        default: return false
        }
    }

    // MARK: - Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    Haptics.prepare()
                    Haptics.press()
                }
                let constrained = PTZVector.constrain(offset: value.translation, radius: radius)
                knobOffset = constrained
                emitOctantHaptic(for: constrained)
                onChange(PTZVector.fromJoystick(offset: constrained, radius: radius))
            }
            .onEnded { _ in
                isDragging = false
                lastOctant = nil
                withAnimation(Theme.Motion.resolve(Theme.Motion.bouncy, reduced: reduceMotion)) {
                    knobOffset = .zero
                }
                Haptics.tap()
                onRelease()
            }
    }

    private func emitOctantHaptic(for offset: CGSize) {
        let distance = sqrt(offset.width * offset.width + offset.height * offset.height)
        guard distance > radius * 0.25 else {
            lastOctant = nil
            return
        }
        let angle = atan2(offset.height, offset.width) + .pi
        let octant = Int((angle / (.pi / 4)).rounded()) % 8
        guard octant != lastOctant else { return }
        lastOctant = octant
        Haptics.change()
    }

    private func nudge(_ vector: PTZVector) {
        onChange(vector)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            onRelease()
        }
    }
}

/// Vertical zoom rocker sitting beside the pad.
struct ZoomRocker: View {
    let onChange: (Double) -> Void
    let onRelease: () -> Void
    var isEnabled = true

    @State private var activeDirection: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            button(systemImage: "plus", direction: 1, label: "Zoom avant")
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(height: 1)
            button(systemImage: "minus", direction: -1, label: "Zoom arrière")
        }
        .frame(width: 56)
        .glassControl(radius: Theme.Radius.lg)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
    }

    private func button(systemImage: String, direction: Int, label: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(activeDirection == direction ? Theme.Palette.accent : .white.opacity(0.85))
            .frame(width: 56, height: 56)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard activeDirection != direction else { return }
                        activeDirection = direction
                        Haptics.press()
                        onChange(Double(direction) * 0.6)
                    }
                    .onEnded { _ in
                        activeDirection = 0
                        onRelease()
                    }
            )
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }
}
