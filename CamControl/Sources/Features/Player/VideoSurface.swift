import MobileVLCKit
import SwiftUI

/// What the decoder is currently doing. Drives the player's overlay so the user
/// sees the difference between "connecting", "the camera stopped sending" and
/// "this stream will never open".
enum PlaybackStatus: Equatable {
    case idle
    case opening
    case buffering
    case playing
    case stalled
    case ended
    case failed

    var isLive: Bool { self == .playing }
}

/// Live RTSP surface.
///
/// VLCKit rather than AVFoundation because AVPlayer cannot open RTSP at all —
/// it is the same engine every third-party camera app ends up using.
struct VideoSurface: UIViewRepresentable {
    let url: URL?
    var isMuted: Bool = true
    var onStatusChange: (PlaybackStatus) -> Void = { _ in }
    /// Called once the first frame's size is known, to size the view correctly
    /// for cameras that are not 16:9.
    var onAspectRatioChange: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> VideoHostView {
        let view = VideoHostView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: VideoHostView, context: Context) {
        context.coordinator.callbacks = (onStatusChange, onAspectRatioChange)
        context.coordinator.setMuted(isMuted)
        context.coordinator.play(url: url)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: VideoHostView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    /// Owns the player and translates VLC's state into `PlaybackStatus`.
    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        private var player: VLCMediaPlayer?
        private var currentURL: URL?
        private var watchdog: Timer?
        private var lastFrameTime: VLCTime?
        private var lastFrameChange = Date()
        private var reportedStatus: PlaybackStatus = .idle
        private var reportedAspect: CGFloat = 0

        var callbacks: (status: (PlaybackStatus) -> Void, aspect: (CGFloat) -> Void) = ({ _ in }, { _ in })

        func attach(to view: VideoHostView) {
            let player = VLCMediaPlayer()
            player.delegate = self
            player.drawable = view.renderView
            self.player = player
            startWatchdog()
        }

        /// Muting is done through the volume rather than VLCAudio's mute flag:
        /// the flag's name has moved between VLCKit releases, while `volume` has
        /// been the same integer since 2.x.
        func setMuted(_ muted: Bool) {
            player?.audio?.volume = muted ? 0 : 100
        }

        func play(url: URL?) {
            guard url != currentURL else { return }
            currentURL = url

            guard let url else {
                player?.stop()
                report(.idle)
                return
            }

            let media = VLCMedia(url: url)
            media.addOptions([
                // Cameras are one WiFi hop away: a large jitter buffer only adds
                // latency, and a stale live view is worse than a brief stutter.
                "network-caching": 300,
                // RTP over UDP loses packets on congested WiFi and tears the
                // picture; interleaving over the existing TCP connection is what
                // makes the stream stable on a home network.
                "rtsp-tcp": true,
                "rtsp-frame-buffer-size": 500_000,
                // Never let a stuck camera hang the decoder indefinitely.
                "rtsp-timeout": 10
            ])
            player?.media = media
            lastFrameTime = nil
            lastFrameChange = Date()
            report(.opening)
            player?.play()
        }

        func teardown() {
            watchdog?.invalidate()
            watchdog = nil
            player?.delegate = nil
            player?.stop()
            player = nil
        }

        // MARK: - VLC delegate

        func mediaPlayerStateChanged(_ aNotification: Notification) {
            syncState()
        }

        func mediaPlayerTimeChanged(_ aNotification: Notification) {
            noteProgress()
        }

        // MARK: - State

        /// VLC reports `.playing` as soon as it has a connection, and stays there
        /// when a camera silently stops sending — so playback is confirmed by the
        /// media clock advancing, not by the state alone.
        private func startWatchdog() {
            // Scheduled on the main run loop, which is also where VLC posts its
            // state notifications, so no extra hop is needed to touch the player.
            watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.syncState()
            }
        }

        private func noteProgress() {
            guard let time = player?.time else { return }
            if time.intValue != lastFrameTime?.intValue {
                lastFrameTime = time
                lastFrameChange = Date()
            }
        }

        private func syncState() {
            guard let player else { return }
            noteProgress()
            reportAspectRatioIfNeeded(player)

            // A `default` rather than `@unknown default`: VLCKit's state list has
            // gained and lost cases between 3.x releases, and naming one that a
            // given pod version does not define would stop the app compiling.
            switch player.state {
            case .error:
                report(.failed)
            case .ended, .stopped:
                report(currentURL == nil ? .idle : .ended)
            case .playing:
                // Five seconds without the clock moving means the camera stopped
                // sending, even though VLC still believes it is playing.
                report(Date().timeIntervalSince(lastFrameChange) > 5 ? .stalled : .playing)
            default:
                report(player.isPlaying ? .playing : .buffering)
            }
        }

        private func reportAspectRatioIfNeeded(_ player: VLCMediaPlayer) {
            let size = player.videoSize
            guard size.width > 0, size.height > 0 else { return }
            let ratio = size.width / size.height
            guard abs(ratio - reportedAspect) > 0.01 else { return }
            reportedAspect = ratio
            callbacks.aspect(ratio)
        }

        private func report(_ status: PlaybackStatus) {
            guard status != reportedStatus else { return }
            reportedStatus = status
            callbacks.status(status)
        }
    }
}

/// Hosts the view VLC renders into.
///
/// The render view is a plain subview rather than the host itself so SwiftUI can
/// transform, mask and animate the host without the decoder's layer fighting it.
final class VideoHostView: UIView {
    let renderView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        renderView.backgroundColor = .black
        renderView.isUserInteractionEnabled = false
        addSubview(renderView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VideoHostView is created in code only")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderView.frame = bounds
    }
}
