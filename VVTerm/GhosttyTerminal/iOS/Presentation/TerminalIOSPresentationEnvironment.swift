#if os(iOS)
import UIKit

@MainActor
struct TerminalIOSPresentationEnvironment {
    var isApplicationActive: () -> Bool
    var presentController: (_ controller: UIViewController, _ sourceView: UIView, _ sourceRect: CGRect) -> Void
    var openURL: (URL) -> Void

    static var live: Self {
        Self(
            isApplicationActive: {
                UIApplication.shared.applicationState == .active
            },
            presentController: { controller, sourceView, sourceRect in
                guard let presenter = sourceView.nearestTerminalPresentingViewController() else { return }
                if let popover = controller.popoverPresentationController {
                    popover.sourceView = sourceView
                    popover.sourceRect = sourceRect
                }
                presenter.present(controller, animated: true)
            },
            openURL: { url in
                UIApplication.shared.open(url)
            }
        )
    }
}

private extension UIView {
    func nearestTerminalPresentingViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController {
                return viewController.topMostPresentedViewController
            }
            responder = current.next
        }
        return window?.rootViewController?.topMostPresentedViewController
    }
}

private extension UIViewController {
    var topMostPresentedViewController: UIViewController {
        var controller = self
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }
}
#endif
