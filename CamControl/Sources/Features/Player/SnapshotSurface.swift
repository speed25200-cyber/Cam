import SwiftUI
import UIKit

/// A picture built from still images fetched in a loop.
///
/// The last resort, for cameras that serve neither RTSP nor a multipart stream —
/// and there are many. It is not video and is never dressed up as video: the
/// player says so on screen. But it is exactly what those cameras' own web pages
/// do, and a room seen two or three times a second is the difference between
/// watching the camera and not having it at all.
struct SnapshotSurface: View {
    let url: URL?
    var interval: TimeInterval = 0.4
    var onStatusChange: (PlaybackStatus) -> Void = { _ in }

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        // `task(id:)` owns the loop's lifetime: it is cancelled when the view
        // goes away and restarted when the address changes, which is exactly the
        // rule, and leaves no timer to forget to invalidate.
        .task(id: url) {
            guard let url else {
                onStatusChange(.idle)
                return
            }
            onStatusChange(.opening)
            await poll(url)
        }
    }

    /// Fetches until cancelled. A run of failures is reported as a stall rather
    /// than a death: a camera that drops one frame while it re-exposes has not
    /// gone away, and tearing the picture down for that would be worse than the
    /// pause.
    private func poll(_ url: URL) async {
        var consecutiveFailures = 0

        while !Task.isCancelled {
            let started = Date()

            if let data = await SnapshotFetcher.shared.data(from: url),
               let decoded = UIImage(data: data) {
                image = decoded
                consecutiveFailures = 0
                onStatusChange(.playing)
            } else {
                consecutiveFailures += 1
                if consecutiveFailures == 3 {
                    onStatusChange(image == nil ? .failed : .stalled)
                }
            }

            guard !Task.isCancelled else { return }
            // Measured from the start of the request, so a slow camera is polled
            // as fast as it can answer rather than as fast as the clock allows.
            let remaining = interval - Date().timeIntervalSince(started)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }
}

/// Fetches one still image, answering whatever authentication the camera asks
/// for.
///
/// The credentials travel in the URL because that is how the rest of the app
/// carries them, but they are taken back out before the request: a camera that
/// wants digest will not accept them any other way, and `URLSession` only
/// negotiates it when the credential arrives through the challenge.
final class SnapshotFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SnapshotFetcher()

    /// Built without a delegate: the challenge handler is supplied per request
    /// instead, which keeps this a plain `let` rather than a lazy property being
    /// initialised from several threads at once.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        // A still endpoint answering from a cache is a frozen picture, which is
        // the one thing this must never show.
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    private let lock = NSLock()
    private var credential: URLCredential?

    func data(from url: URL) async -> Data? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let user = components?.user, !user.isEmpty {
            lock.lock()
            credential = URLCredential(
                user: user,
                password: components?.password ?? "",
                persistence: .forSession
            )
            lock.unlock()
        }
        components?.user = nil
        components?.password = nil

        guard let stripped = components?.url else { return nil }
        var request = URLRequest(url: stripped)
        request.setValue("CamControl", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request, delegate: self),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // Offered once. Answering the same rejection again would loop, and the
        // camera has already said what it thinks of these credentials.
        guard challenge.previousFailureCount == 0 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        lock.lock()
        let credential = self.credential
        lock.unlock()
        completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
    }
}
