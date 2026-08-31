import CoreImage
import SwiftUI

/// Applies a `LiveFilterSettings` look in the two places it has to exist: on the
/// live video view, and baked into a saved still.
///
/// Both paths read the same `resolved` values, so the JPEG written to Photos
/// matches the frame the user was looking at when they tapped the shutter.
enum LiveFilterRenderer {

    /// Renders the look into a still image with Core Image.
    static func apply(_ settings: LiveFilterSettings, to image: UIImage) -> UIImage? {
        guard !settings.isNeutral else { return image }
        guard let input = CIImage(image: image) else { return nil }

        let values = settings.resolved
        var output = input

        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(values.brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(values.contrast, forKey: kCIInputContrastKey)
            controls.setValue(values.saturation, forKey: kCIInputSaturationKey)
            output = controls.outputImage ?? output
        }

        if settings.preset.hasTint {
            let tint = settings.preset.tint
            if let matrix = CIFilter(name: "CIColorMatrix") {
                matrix.setValue(output, forKey: kCIInputImageKey)
                matrix.setValue(CIVector(x: tint.red, y: 0, z: 0, w: 0), forKey: "inputRVector")
                matrix.setValue(CIVector(x: 0, y: tint.green, z: 0, w: 0), forKey: "inputGVector")
                matrix.setValue(CIVector(x: 0, y: 0, z: tint.blue, w: 0), forKey: "inputBVector")
                output = matrix.outputImage ?? output
            }
        }

        guard let cgImage = sharedContext.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// One context for the app: each `CIContext` allocates its own GPU resources,
    /// and creating one per snapshot is measurably slower than reusing this.
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])
}

/// Applies the look to a live SwiftUI view.
///
/// Uses SwiftUI's own compositing effects, which are GPU-backed and work on any
/// hosted view — including the UIKit view the RTSP decoder renders into.
struct LiveLookModifier: ViewModifier {
    let settings: LiveFilterSettings

    func body(content: Content) -> some View {
        let values = settings.resolved
        let tint = settings.preset.tint

        return content
            .saturation(values.saturation)
            .contrast(values.contrast)
            .brightness(values.brightness)
            .modifier(TintModifier(tint: tint, isActive: settings.preset.hasTint))
    }
}

/// Multiplicative colour cast, skipped entirely when neutral so the view tree
/// stays free of a no-op compositing layer.
private struct TintModifier: ViewModifier {
    let tint: (red: Double, green: Double, blue: Double)
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.colorMultiply(Color(red: tint.red, green: tint.green, blue: tint.blue))
        } else {
            content
        }
    }
}

extension View {
    func liveLook(_ settings: LiveFilterSettings) -> some View {
        modifier(LiveLookModifier(settings: settings))
    }
}
