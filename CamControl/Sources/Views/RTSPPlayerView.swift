import SwiftUI
import MobileVLCKit
import CoreImage

/// Live RTSP video surface. Wraps VLCKit's `VLCMediaPlayer`, which is what
/// gives us actual H.264/H.265 RTSP decoding — AVFoundation has no RTSP support.
///
/// Live "filters" (brightness/contrast/saturation/sharpen/presets) are applied
/// directly to the rendered layer via `CALayer.filters` using Core Image filter
/// names, so they work on top of ANY camera's stream, regardless of whether the
/// camera itself exposes ONVIF Imaging controls.
struct RTSPPlayerView: UIViewRepresentable {
    let url: URL?
    var liveFilter: LiveFilterSettings
    var onPlayerReady: ((VLCMediaPlayer) -> Void)?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        let player = VLCMediaPlayer()
        player.drawable = view.videoView
        context.coordinator.player = player
        onPlayerReady?(player)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.currentURL != url {
            coordinator.currentURL = url
            if let url {
                let media = VLCMedia(url: url)
                // Reasonable defaults for LAN cameras: low-latency, no huge caching buffer.
                media.addOptions(["network-caching": 300])
                coordinator.player?.media = media
                coordinator.player?.play()
            } else {
                coordinator.player?.stop()
            }
        }
        uiView.applyFilter(liveFilter)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: PlayerContainerView, coordinator: Coordinator) {
        coordinator.player?.stop()
    }

    final class Coordinator {
        var player: VLCMediaPlayer?
        var currentURL: URL?
    }
}

/// Hosts the actual video-rendering UIView and owns the live CoreImage filter stack.
final class PlayerContainerView: UIView {
    let videoView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoView.backgroundColor = .black
        addSubview(videoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoView.frame = bounds
    }

    func applyFilter(_ settings: LiveFilterSettings) {
        videoView.layer.filters = Self.buildFilters(for: settings)
    }

    private static func buildFilters(for settings: LiveFilterSettings) -> [CIFilter]? {
        var filters: [CIFilter] = []

        if let preset = presetFilter(settings.preset) {
            filters.append(preset)
        }

        let controls = CIFilter(name: "CIColorControls")
        controls?.setValue(settings.brightness, forKey: kCIInputBrightnessKey)
        controls?.setValue(settings.contrast, forKey: kCIInputContrastKey)
        controls?.setValue(settings.saturation, forKey: kCIInputSaturationKey)
        if let controls, isNonNeutral(settings) {
            filters.append(controls)
        }

        if settings.sharpenAmount > 0.001 {
            let sharpen = CIFilter(name: "CISharpenLuminance")
            sharpen?.setValue(settings.sharpenAmount, forKey: kCIInputSharpnessKey)
            if let sharpen { filters.append(sharpen) }
        }

        return filters.isEmpty ? nil : filters
    }

    private static func isNonNeutral(_ s: LiveFilterSettings) -> Bool {
        abs(s.brightness) > 0.001 || abs(s.contrast - 1) > 0.001 || abs(s.saturation - 1) > 0.001
    }

    private static func presetFilter(_ preset: LiveFilterSettings.FilterPreset) -> CIFilter? {
        switch preset {
        case .none: return nil
        case .noir: return CIFilter(name: "CIPhotoEffectNoir")
        case .sepia:
            let f = CIFilter(name: "CISepiaTone"); f?.setValue(0.85, forKey: kCIInputIntensityKey); return f
        case .vivid: return CIFilter(name: "CIPhotoEffectChrome")
        case .cool: return CIFilter(name: "CIPhotoEffectProcess")
        case .warm: return CIFilter(name: "CIPhotoEffectTransfer")
        }
    }
}
