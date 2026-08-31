import Foundation

/// Mirrors the ONVIF Imaging service's `ImagingSettings20` type — the fields that
/// map to a physical camera's own image pipeline (as opposed to a client-side filter).
/// All values are normalized to 0...1 for the UI; ONVIF's own ranges vary per camera
/// and are queried via GetOptions before being applied.
struct ImagingSettings: Equatable {
    var brightness: Double = 0.5
    var colorSaturation: Double = 0.5
    var contrast: Double = 0.5
    var sharpness: Double = 0.5
    var backlightCompensation: Bool = false
    var wideDynamicRange: Bool = false
    var irCutFilter: IRCutMode = .auto

    enum IRCutMode: String, CaseIterable, Identifiable {
        case on = "ON"
        case off = "OFF"
        case auto = "AUTO"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .on: return "Vision nocturne forcée"
            case .off: return "Vision nocturne désactivée"
            case .auto: return "Automatique"
            }
        }
    }
}

/// Client-side visual filter applied live on top of the video preview, via
/// CALayer/CoreImage compositing — works on every camera regardless of ONVIF support.
struct LiveFilterSettings: Equatable {
    var brightness: Double = 0     // -1...1 (CIColorControls inputBrightness is -1...1 but we clamp to sane range)
    var contrast: Double = 1       // 0...4 (CIColorControls inputContrast, 1 = neutral)
    var saturation: Double = 1     // 0...2 (CIColorControls inputSaturation, 1 = neutral)
    var sharpenAmount: Double = 0  // 0...2 (CISharpenLuminance inputSharpness)
    var preset: FilterPreset = .none

    enum FilterPreset: String, CaseIterable, Identifiable {
        case none = "Aucun"
        case noir = "Noir & blanc"
        case sepia = "Sépia"
        case vivid = "Vif"
        case cool = "Froid"
        case warm = "Chaud"
        var id: String { rawValue }
    }

    static let neutral = LiveFilterSettings()
}
