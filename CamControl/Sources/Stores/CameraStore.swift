import Foundation
import Observation

/// The user's saved cameras, persisted across launches.
///
/// The list itself is plain JSON in Application Support; credentials live in the
/// Keychain and are only ever fetched on demand, keyed by the camera's stable id.
@Observable
@MainActor
final class CameraStore {

    private(set) var cameras: [Camera] = []
    /// Set when a save fails, so the UI can say so instead of silently losing data.
    private(set) var persistenceError: String?

    private let fileURL: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        self.fileURL = base.appendingPathComponent("cameras.json")
        load()
    }

    private static func defaultDirectory() -> URL {
        let manager = FileManager.default
        let base = (try? manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? manager.temporaryDirectory
        let directory = base.appendingPathComponent("CamControl", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Queries

    var isEmpty: Bool { cameras.isEmpty }

    func camera(withID id: UUID) -> Camera? {
        cameras.first { $0.id == id }
    }

    /// Whether a discovered camera is already in the library, matched the same
    /// way re-discovery matches: serial number when known, host otherwise.
    func saved(matching discovered: Camera) -> Camera? {
        cameras.first { $0.matches(discovered) }
    }

    func isSaved(_ discovered: Camera) -> Bool {
        saved(matching: discovered) != nil
    }

    // MARK: - Mutations

    /// Adds a camera to the library, or refreshes the existing entry if the same
    /// device is already saved. Returns the entry that ended up in the library.
    @discardableResult
    func add(_ camera: Camera) -> Camera {
        if let existing = saved(matching: camera) {
            let merged = existing.merging(discovered: camera)
            update(merged)
            return merged
        }
        var stored = camera
        stored.isSaved = true
        stored.lastSeen = Date()
        cameras.append(stored)
        persist()
        return stored
    }

    func update(_ camera: Camera) {
        guard let index = cameras.firstIndex(where: { $0.id == camera.id }) else { return }
        cameras[index] = camera
        persist()
    }

    func rename(_ camera: Camera, to name: String) {
        guard var stored = self.camera(withID: camera.id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.customName = trimmed.isEmpty ? nil : trimmed
        update(stored)
    }

    /// Removes a camera and everything attached to it — credentials and cached
    /// thumbnail included, so "forget" really forgets.
    func remove(_ camera: Camera) {
        cameras.removeAll { $0.id == camera.id }
        KeychainStore.delete(for: camera.credentialsKey)
        ThumbnailStore.shared.remove(for: camera.id)
        persist()
    }

    func removeAll() {
        for camera in cameras {
            ThumbnailStore.shared.remove(for: camera.id)
        }
        cameras.removeAll()
        KeychainStore.deleteAll()
        persist()
    }

    /// Folds a completed scan into the library: saved cameras that moved to a new
    /// DHCP address are updated in place rather than duplicated.
    func reconcile(with discovered: [Camera]) {
        var changed = false
        for found in discovered {
            guard let index = cameras.firstIndex(where: { $0.matches(found) }) else { continue }
            // `Camera`'s equality is identity-based, so it cannot answer "did
            // anything change here" — the fields the merge can touch are what
            // decide whether this is worth a write.
            let merged = cameras[index].merging(discovered: found)
            if merged.differsInDeviceData(from: cameras[index]) {
                cameras[index] = merged
                changed = true
            }
        }
        if changed { persist() }
    }

    // MARK: - Credentials

    func credentials(for camera: Camera) -> CameraCredentials? {
        KeychainStore.load(for: camera.credentialsKey)
    }

    func setCredentials(_ credentials: CameraCredentials, for camera: Camera) {
        KeychainStore.save(credentials, for: camera.credentialsKey)
    }

    /// Credentials to try on a camera that has none of its own.
    var defaultCredentials: CameraCredentials? {
        KeychainStore.load(for: KeychainStore.sharedAccount)
    }

    /// Records a pair that just worked, so the next camera connects without
    /// asking. Only ever called after a successful connection — a rejected
    /// password is never promoted to the default.
    func rememberAsDefault(_ credentials: CameraCredentials) {
        KeychainStore.save(credentials, for: KeychainStore.sharedAccount)
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            cameras = try JSONDecoder().decode([Camera].self, from: data)
        } catch {
            // A corrupt file must not brick the app; start clean and keep the
            // old file aside so nothing is silently destroyed.
            let backup = fileURL.appendingPathExtension("corrupt")
            try? fileManager.removeItem(at: backup)
            try? fileManager.moveItem(at: fileURL, to: backup)
            cameras = []
            persistenceError = "La liste des caméras était illisible et a été réinitialisée."
        }
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cameras)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistenceError = nil
        } catch {
            persistenceError = "Impossible d'enregistrer la liste des caméras."
        }
    }
}
