import Foundation
import UserNotifications
import Combine
import UIKit
import FirebaseMessaging
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class NotificationService: NSObject, ObservableObject {
    private var authorizationStatus: UNAuthorizationStatus = .notDetermined

    let objectWillChange = PassthroughSubject<Void, Never>()

    override init() {
        super.init()
        Messaging.messaging().delegate = self
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        do {
            let settings = try await center.notificationSettings()
            authorizationStatus = settings.authorizationStatus

            guard settings.authorizationStatus == .notDetermined else { return }

            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            authorizationStatus = granted ? .authorized : .denied
        } catch {
            print("[NotificationService] Authorization Error: \(error)")
        }
    }

    func registerForRemoteNotifications() async {
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func refreshFCMToken() async {
        guard let userID = Auth.auth().currentUser?.uid else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional else { return }

        guard let token = try? await Messaging.messaging().token() else { return }

        let db = Firestore.firestore()
        do {
            try await db.collection("users").document(userID).setData(["fcmToken": token], merge: true)
        } catch {
            print("[NotificationService] Failed to store FCM token: \(error)")
        }
    }
}

extension NotificationService: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task {
            await refreshFCMToken()
        }
    }
}

