import SwiftUI

#if os(macOS)
@MainActor
struct ProUpgradeWindowPresentationService {
    typealias ContentFactory = (_ close: @escaping () -> Void) -> AnyView

    let show: (
        _ storeManager: StoreManager,
        _ source: PaywallSource,
        _ onClose: @escaping () -> Void,
        _ content: @escaping ContentFactory
    ) -> Void
    let close: () -> Void
}

extension ProUpgradeWindowPresentationService {
    static let live = ProUpgradeWindowPresentationService(
        show: { storeManager, source, onClose, content in
            ProUpgradeWindowPresenter.shared.show(
                storeManager: storeManager,
                source: source,
                onClose: onClose
            ) { closeWindow in
                content(closeWindow)
            }
        },
        close: {
            ProUpgradeWindowPresenter.shared.close()
        }
    )
}
#endif
