import UIKit

/// Thin wrapper over UIKit feedback generators.
///
/// Generators are kept alive and pre-prepared: creating one at the moment of the
/// event costs enough latency that the tap and the tap-back feel disconnected,
/// which matters for the PTZ pad where feedback is the only confirmation the
/// camera received a command.
@MainActor
enum Haptics {
    private static let impactLight = UIImpactFeedbackGenerator(style: .light)
    private static let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Call when a gesture begins so the first pulse is not delayed.
    static func prepare() {
        impactLight.prepare()
        impactMedium.prepare()
        selection.prepare()
    }

    static func tap() { impactLight.impactOccurred() }
    static func press() { impactMedium.impactOccurred() }
    static func change() { selection.selectionChanged() }
    static func success() { notification.notificationOccurred(.success) }
    static func warning() { notification.notificationOccurred(.warning) }
    static func failure() { notification.notificationOccurred(.error) }
}
