import Observation
import UIKit

/// Last known still frame for each camera, shown on its library card.
///
/// A card with a real frame from the camera is the difference between a list of
/// IP addresses and a list of places, so the most recent snapshot is kept on disk
/// and shown immediately at launch, before anything connects.
@Observable
@MainActor
final class ThumbnailStore {
    static let shared = ThumbnailStore()

    /// Bumped whenever an image changes, and the only observable property here.
    ///
    /// The cache dictionary is deliberately *not* observed: `image(for:)` fills
    /// it lazily and is called from view bodies, so a tracked mutation there
    /// would invalidate the view that just read it, on every frame.
    private(set) var generation = 0

    @ObservationIgnored private var memory: [UUID: UIImage] = [:]
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        let base = directory ?? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return caches.appendingPathComponent("Thumbnails", isDirectory: true)
        }()
        self.directory = base
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func image(for id: UUID) -> UIImage? {
        // Registers the caller's dependency on the counter, so a stored image
        // still refreshes the card even though the cache itself is untracked.
        _ = generation
        if let cached = memory[id] { return cached }
        guard let data = try? Data(contentsOf: url(for: id)),
              let image = UIImage(data: data) else { return nil }
        memory[id] = image
        return image
    }

    /// Stores a JPEG straight from the camera. Downscaled first: a 4K still held
    /// per camera would cost tens of megabytes of memory for a 200-point card.
    func store(_ data: Data, for id: UUID) {
        guard let image = UIImage(data: data) else { return }
        let thumbnail = image.downscaled(toMaxDimension: 900) ?? image
        memory[id] = thumbnail
        generation &+= 1

        let fileURL = url(for: id)
        Task.detached(priority: .utility) {
            guard let encoded = thumbnail.jpegData(compressionQuality: 0.8) else { return }
            try? encoded.write(to: fileURL, options: .atomic)
        }
    }

    func remove(for id: UUID) {
        memory[id] = nil
        generation &+= 1
        try? fileManager.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}

extension UIImage {
    /// Aspect-preserving downscale. Returns `nil` if the image is already small
    /// enough, so callers can keep the original without a needless redraw.
    func downscaled(toMaxDimension maximum: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > maximum, longest > 0 else { return nil }
        let scale = maximum / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
