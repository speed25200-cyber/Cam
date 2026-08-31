import Foundation

/// The camera's own image pipeline (ONVIF Imaging service) — changes here are
/// written to the device and persist outside the app.
///
/// Values are held normalized in 0...1 so the UI is uniform; the real device
/// ranges vary per model and live in `ImagingOptions`, which is read from
/// `GetOptions` before anything is written back.
struct ImagingSettings: Equatable {
    var brightness: Double = 0.5
    var colorSaturation: Double = 0.5
    var contrast: Double = 0.5
    var sharpness: Double = 0.5
    var backlightCompensation = false
    var wideDynamicRange = false
    var irCutFilter: IRCutMode = .auto

    enum IRCutMode: String, CaseIterable, Identifiable, Equatable {
        case on = "ON"
        case off = "OFF"
        case auto = "AUTO"

        var id: String { rawValue }

        /// ONVIF's `IrCutFilter` naming is inverted relative to how people think
        /// about it: the filter being ON blocks infrared, i.e. night vision OFF.
        var label: String {
            switch self {
            case .on: return "Jour (filtre IR actif)"
            case .off: return "Nuit (filtre IR retiré)"
            case .auto: return "Automatique"
            }
        }

        var systemImage: String {
            switch self {
            case .on: return "sun.max.fill"
            case .off: return "moon.stars.fill"
            case .auto: return "circle.lefthalf.filled"
            }
        }
    }
}

/// One device-reported numeric range, used to convert between the UI's 0...1 and
/// whatever scale the camera actually uses (0–100, 0–255, -128…127, …).
struct ImagingRange: Equatable {
    var minimum: Double
    var maximum: Double

    /// ONVIF's most common range; used until `GetOptions` tells us otherwise.
    static let standard = ImagingRange(minimum: 0, maximum: 100)

    var span: Double { max(maximum - minimum, .ulpOfOne) }

    func normalize(_ deviceValue: Double) -> Double {
        min(max((deviceValue - minimum) / span, 0), 1)
    }

    func denormalize(_ uiValue: Double) -> Double {
        minimum + min(max(uiValue, 0), 1) * span
    }
}

/// What one specific camera supports, read from the Imaging service's `GetOptions`.
/// Controls the camera does not advertise are hidden rather than shown broken.
struct ImagingOptions: Equatable {
    var brightness: ImagingRange?
    var contrast: ImagingRange?
    var colorSaturation: ImagingRange?
    var sharpness: ImagingRange?
    var supportsBacklightCompensation = false
    var supportsWideDynamicRange = false
    var irCutModes: [ImagingSettings.IRCutMode] = []

    /// Assumed capabilities for a camera whose `GetOptions` call failed but whose
    /// `GetImagingSettings` succeeded — better than hiding every control.
    static let permissive = ImagingOptions(
        brightness: .standard,
        contrast: .standard,
        colorSaturation: .standard,
        sharpness: .standard,
        supportsBacklightCompensation: true,
        supportsWideDynamicRange: true,
        irCutModes: ImagingSettings.IRCutMode.allCases
    )

    var hasAnyControl: Bool {
        brightness != nil || contrast != nil || colorSaturation != nil || sharpness != nil
            || supportsBacklightCompensation || supportsWideDynamicRange || !irCutModes.isEmpty
    }
}

/// Client-side look applied to the rendered video only. Always available, even on
/// cameras with no Imaging service, and never written to the device.
///
/// Deliberately limited to effects that are real on iOS: brightness, contrast,
/// saturation, desaturation and a color cast. `CALayer.filters` is declared on
/// iOS but has no effect there, so anything built on arbitrary Core Image filters
/// would silently do nothing to live video.
struct LiveFilterSettings: Equatable {
    /// Additive exposure, neutral at 0.
    var brightness: Double = 0
    /// Multiplicative contrast, neutral at 1.
    var contrast: Double = 1
    /// Color intensity, neutral at 1, 0 is fully grey.
    var saturation: Double = 1
    var preset: FilterPreset = .none

    /// Presets are parameter bundles rather than opaque effects, so a manual
    /// adjustment on top of a preset composes predictably instead of fighting it.
    enum FilterPreset: String, CaseIterable, Identifiable, Equatable {
        case none = "Aucun"
        case noir = "N&B"
        case sepia = "Sépia"
        case vivid = "Vif"
        case cool = "Froid"
        case warm = "Chaud"
        case night = "Nuit +"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .none: return "circle.slash"
            case .noir: return "circle.righthalf.filled"
            case .sepia: return "camera.filters"
            case .vivid: return "sparkles"
            case .cool: return "snowflake"
            case .warm: return "flame"
            case .night: return "moon.stars.fill"
            }
        }

        /// Extra brightness, contrast and saturation the preset contributes.
        var adjustment: (brightness: Double, contrast: Double, saturation: Double) {
            switch self {
            case .none: return (0, 1, 1)
            case .noir: return (0, 1.15, 0)
            case .sepia: return (0.02, 1.05, 0.18)
            case .vivid: return (0, 1.12, 1.4)
            case .cool: return (0, 1.05, 1.05)
            case .warm: return (0.02, 1.02, 1.1)
            // Lifts a dark infrared frame: brighter, punchier, less colour noise.
            case .night: return (0.16, 1.22, 0.55)
            }
        }

        /// Multiplicative colour cast as RGB factors, all 1 for a neutral preset.
        var tint: (red: Double, green: Double, blue: Double) {
            switch self {
            case .sepia: return (1.0, 0.92, 0.76)
            case .cool: return (0.88, 0.96, 1.0)
            case .warm: return (1.0, 0.94, 0.84)
            case .none, .noir, .vivid, .night: return (1, 1, 1)
            }
        }

        var hasTint: Bool {
            let tint = self.tint
            return abs(tint.red - 1) > 0.001 || abs(tint.green - 1) > 0.001 || abs(tint.blue - 1) > 0.001
        }
    }

    static let neutral = LiveFilterSettings()

    var isNeutral: Bool { self == .neutral }

    /// Manual adjustments combined with the active preset — the values actually
    /// rendered, shared by the live view and the snapshot encoder so a saved
    /// still matches what was on screen.
    var resolved: (brightness: Double, contrast: Double, saturation: Double) {
        let preset = preset.adjustment
        return (
            brightness: brightness + preset.brightness,
            contrast: contrast * preset.contrast,
            saturation: saturation * preset.saturation
        )
    }
}
