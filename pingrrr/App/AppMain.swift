import SwiftUI
import UIKit

@main
struct PingrrrApplication {
    static func main() {
        if #available(iOS 14.0, *) {
            PingrrrApp.main()
        } else {
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(AppDelegate.self)
            )
        }
    }
}
