import SwiftUI

/// Image controls, split into the two things they actually are.
///
/// The distinction matters and is made explicit in the UI: the look is applied
/// on this phone and is free to undo, while the camera settings are written into
/// the device and change what every other client sees, including recordings.
struct ImageControlsSheet: View {
    @Bindable var session: CameraSession
    @Environment(\.dismiss) private var dismiss
    @State private var scope: Scope = .look

    private enum Scope: String, CaseIterable, Identifiable {
        case look = "Rendu"
        case camera = "Caméra"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Spacing.xl) {
                    if session.canAdjustImaging {
                        Picker("Portée", selection: $scope) {
                            ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    if scope == .look || !session.canAdjustImaging {
                        lookSection
                    } else {
                        cameraSection
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Palette.canvas)
            .navigationTitle("Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Client-side look

    private var lookSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(
                title: "Rendu à l'écran",
                subtitle: "Appliqué dans l'app uniquement — la caméra n'est pas modifiée."
            )

            presetStrip

            VStack(spacing: Theme.Spacing.md) {
                SliderRow(
                    title: "Luminosité",
                    systemImage: "sun.max",
                    value: $session.liveFilter.brightness,
                    range: -0.4...0.4,
                    neutral: 0
                )
                SliderRow(
                    title: "Contraste",
                    systemImage: "circle.lefthalf.filled",
                    value: $session.liveFilter.contrast,
                    range: 0.5...1.8,
                    neutral: 1
                )
                SliderRow(
                    title: "Saturation",
                    systemImage: "paintpalette",
                    value: $session.liveFilter.saturation,
                    range: 0...2,
                    neutral: 1
                )
            }
            .padding(Theme.Spacing.lg)
            .cardSurface()

            Button {
                withAnimation(Theme.Motion.snappy) { session.liveFilter = .neutral }
                Haptics.tap()
            } label: {
                Label("Réinitialiser le rendu", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(GhostButtonStyle(expands: true))
            .disabled(session.liveFilter.isNeutral)
        }
    }

    private var presetStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(LiveFilterSettings.FilterPreset.allCases) { preset in
                    let isSelected = session.liveFilter.preset == preset
                    Button {
                        withAnimation(Theme.Motion.snappy) { session.liveFilter.preset = preset }
                        Haptics.change()
                    } label: {
                        VStack(spacing: Theme.Spacing.sm) {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                                    .fill(isSelected ? AnyShapeStyle(Theme.Palette.accentGradient) : AnyShapeStyle(Theme.Palette.surfaceRaised))
                                Image(systemName: preset.systemImage)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(isSelected ? Color.white : Theme.Palette.textSecondary)
                            }
                            .frame(width: 64, height: 52)
                            Text(preset.rawValue)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.rawValue)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - Hardware imaging

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(
                title: "Réglages de la caméra",
                subtitle: "Écrits dans l'appareil — ils persistent hors de l'app."
            )

            VStack(spacing: Theme.Spacing.md) {
                if session.imagingOptions.brightness != nil {
                    SliderRow(
                        title: "Luminosité",
                        systemImage: "sun.max",
                        value: $session.imaging.brightness,
                        range: 0...1,
                        neutral: nil,
                        onCommit: session.scheduleImagingWrite
                    )
                }
                if session.imagingOptions.contrast != nil {
                    SliderRow(
                        title: "Contraste",
                        systemImage: "circle.lefthalf.filled",
                        value: $session.imaging.contrast,
                        range: 0...1,
                        neutral: nil,
                        onCommit: session.scheduleImagingWrite
                    )
                }
                if session.imagingOptions.colorSaturation != nil {
                    SliderRow(
                        title: "Saturation",
                        systemImage: "paintpalette",
                        value: $session.imaging.colorSaturation,
                        range: 0...1,
                        neutral: nil,
                        onCommit: session.scheduleImagingWrite
                    )
                }
                if session.imagingOptions.sharpness != nil {
                    SliderRow(
                        title: "Netteté",
                        systemImage: "triangle",
                        value: $session.imaging.sharpness,
                        range: 0...1,
                        neutral: nil,
                        onCommit: session.scheduleImagingWrite
                    )
                }
            }
            .padding(Theme.Spacing.lg)
            .cardSurface()

            VStack(spacing: 0) {
                if session.imagingOptions.supportsBacklightCompensation {
                    Toggle(isOn: $session.imaging.backlightCompensation) {
                        Label("Compensation de contre-jour", systemImage: "sun.haze")
                    }
                    .onChange(of: session.imaging.backlightCompensation) { _, _ in session.scheduleImagingWrite() }
                    .padding(Theme.Spacing.lg)
                    Divider().overlay(Theme.Palette.stroke)
                }
                if session.imagingOptions.supportsWideDynamicRange {
                    Toggle(isOn: $session.imaging.wideDynamicRange) {
                        Label("Plage dynamique étendue (WDR)", systemImage: "camera.aperture")
                    }
                    .onChange(of: session.imaging.wideDynamicRange) { _, _ in session.scheduleImagingWrite() }
                    .padding(Theme.Spacing.lg)
                }
            }
            .tint(Theme.Palette.accent)
            .cardSurface()

            if !session.imagingOptions.irCutModes.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text("Vision nocturne")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)

                    // Explicit rows rather than a Picker: the mode names are long
                    // enough that a segmented control truncates them, and ONVIF's
                    // inverted naming needs the full label to be understandable.
                    ForEach(session.imagingOptions.irCutModes) { mode in
                        let isSelected = session.imaging.irCutFilter == mode
                        Button {
                            session.imaging.irCutFilter = mode
                            session.scheduleImagingWrite()
                            Haptics.change()
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: mode.systemImage)
                                    .frame(width: 22)
                                    .foregroundStyle(isSelected ? Theme.Palette.accent : Theme.Palette.textSecondary)
                                Text(mode.label)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(Theme.Palette.accent)
                                }
                            }
                            .padding(.vertical, Theme.Spacing.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface()
            }

            HStack(spacing: Theme.Spacing.md) {
                if session.isApplyingImaging {
                    ProgressView().controlSize(.small)
                    Text("Envoi à la caméra…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Spacer()
                Button("Valeurs par défaut") { session.resetImaging() }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
    }
}

/// Labelled slider with a live value read-out and a double-tap-to-reset target.
struct SliderRow: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Value the control snaps back to on reset; `nil` hides the reset affordance.
    var neutral: Double?
    var onCommit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(formatted)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit?() }
            }
            .tint(Theme.Palette.accent)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard let neutral else { return }
            withAnimation(Theme.Motion.snappy) { value = neutral }
            Haptics.tap()
            onCommit?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(formatted)
    }

    private var formatted: String {
        // 0...1 controls read as percentages; signed ranges keep their sign.
        if range.lowerBound >= 0, range.upperBound <= 1 {
            return "\(Int((value * 100).rounded())) %"
        }
        return String(format: "%+.2f", value)
    }
}
