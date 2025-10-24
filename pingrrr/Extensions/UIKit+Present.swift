import UIKit

extension UIApplication {
    static func present(alert: UIAlertController) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }

        var presenter = rootVC
        while let presented = presenter.presentedViewController {
            presenter = presented
        }

        presenter.present(alert, animated: true)
    }
}
