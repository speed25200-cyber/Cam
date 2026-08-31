import SwiftUI

/// Two layers of "image control":
/// 1. Hardware ONVIF Imaging settings (brightness/contrast/saturation/sharpness/
///    WDR/backlight/IR-cut) — sent to the camera itself, persists on-device.
/// 2. Client-side live filter (CoreImage/CALayer) — always available, purely
///    cosmetic on top of the video preview, works even without ONVIF Imaging support.
struct ImagingControlView: View {
    @Binding var hardware: ImagingSettings
    let hardwareAvailable: Bool
    let onApplyHardware: () -> Void

    @Binding var liveFilter: LiveFilterSettings

    var body: some View {
        Form {
            Section {
                Text("Filtre visuel (immédiat)")
                    .font(.headline)
            } footer: {
                Text("Appliqué en direct sur l'image affichée dans l'app, sur n'importe quelle caméra.")
            }

            Section("Ajustements") {
                sliderRow("Luminosité", value: $liveFilter.brightness, range: -0.5...0.5)
                sliderRow("Contraste", value: $liveFilter.contrast, range: 0.3...2.0)
                sliderRow("Saturation", value: $liveFilter.saturation, range: 0...2)
                sliderRow("Netteté", value: $liveFilter.sharpenAmount, range: 0...1.5)
            }

            Section("Préréglages") {
                Picker("Style", selection: $liveFilter.preset) {
                    ForEach(LiveFilterSettings.FilterPreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Button("Réinitialiser le filtre") { liveFilter = .neutral }
            }

            if hardwareAvailable {
                Section {
                    Text("Réglages caméra (matériel, ONVIF)")
                        .font(.headline)
                } footer: {
                    Text("Modifie les réglages internes de la caméra — ils persistent même en dehors de l'app.")
                }

                Section {
                    sliderRow("Luminosité", value: $hardware.brightness, range: 0...1)
                    sliderRow("Contraste", value: $hardware.contrast, range: 0...1)
                    sliderRow("Saturation", value: $hardware.colorSaturation, range: 0...1)
                    sliderRow("Netteté", value: $hardware.sharpness, range: 0...1)
                    Toggle("Compensation contre-jour", isOn: $hardware.backlightCompensation)
                    Toggle("Large plage dynamique (WDR)", isOn: $hardware.wideDynamicRange)
                    Picker("Vision nocturne", selection: $hardware.irCutFilter) {
                        ForEach(ImagingSettings.IRCutMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                } footer: {
                    Button("Appliquer à la caméra") { onApplyHardware() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            } else {
                Section {
                    Text("Cette caméra ne propose pas de service d'imagerie ONVIF — seul le filtre visuel ci-dessus est disponible.")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: value, in: range)
        }
    }
}
