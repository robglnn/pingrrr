import SwiftUI
import FirebaseCore
import FirebaseAppCheck

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FirebaseApp.configure()
        setupAppCheck()
        return true
    }

    private func setupAppCheck() {
#if DEBUG
        let providerFactory = AppCheckDebugProviderFactory()
#else
        let providerFactory = AppCheckDebugProviderFactory()
#endif
        AppCheck.setAppCheckProviderFactory(providerFactory)
    }
}

