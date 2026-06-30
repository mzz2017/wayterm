import Foundation

@MainActor
protocol AppBackgroundTaskLease: AnyObject {
    func end()
}

@MainActor
protocol AppBackgroundTaskLeasing: AnyObject {
    func beginTask(
        named name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> any AppBackgroundTaskLease
}

@MainActor
final class NoopAppBackgroundTaskLeaser: AppBackgroundTaskLeasing {
    func beginTask(
        named name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> any AppBackgroundTaskLease {
        NoopAppBackgroundTaskLease()
    }
}

@MainActor
private final class NoopAppBackgroundTaskLease: AppBackgroundTaskLease {
    func end() {}
}

#if os(iOS)
import UIKit

@MainActor
final class UIKitAppBackgroundTaskLeaser: AppBackgroundTaskLeasing {
    func beginTask(
        named name: String,
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> any AppBackgroundTaskLease {
        let lease = UIKitAppBackgroundTaskLease()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in
                expirationHandler()
                lease.end()
            }
        }
        lease.identifier = identifier
        return lease
    }
}

@MainActor
private final class UIKitAppBackgroundTaskLease: AppBackgroundTaskLease {
    var identifier = UIBackgroundTaskIdentifier.invalid

    func end() {
        guard identifier != .invalid else { return }
        let identifier = identifier
        self.identifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
