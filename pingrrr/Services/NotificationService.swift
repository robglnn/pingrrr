import Foundation
import UserNotifications
import Combine
import UIKit
import FirebaseMessaging
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    struct ChatNotification: Identifiable, Equatable {
        let id: String
        let conversationID: String
        let messageID: String
        let senderID: String
        let senderName: String
        let body: String
        let timestamp: Date
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastNotification: ChatNotification?

    private var authorizationTask: Task<Void, Never>?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
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

        do {
            let token = try await Messaging.messaging().token()
            try await Firestore.firestore()
                .collection("users")
                .document(userID)
                .setData(["fcmToken": token], merge: true)
        } catch {
            print("[NotificationService] Failed to store FCM token: \(error)")
        }
    }

    func clearLastNotification() {
        lastNotification = nil
    }

    private func handleIncomingNotification(userInfo: [AnyHashable: Any]) {
        guard let payload = parseNotificationPayload(userInfo: userInfo) else { return }
        lastNotification = payload
    }

    private func parseNotificationPayload(userInfo: [AnyHashable: Any]) -> ChatNotification? {
        guard
            let conversationID = userInfo["conversationId"] as? String,
            let messageID = userInfo["messageId"] as? String,
            let senderID = userInfo["senderId"] as? String
        else {
            return nil
        }

        let senderName = (userInfo["senderName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "New message"
        let body = (userInfo["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (userInfo["aps"] as? [String: Any])?
            .flatMap { $0["alert"] as? [String: Any] }?
            .compactMap { $0.value as? String }
            .joined(separator: " ")
            ?? ""

        let timestamp: Date
        if let seconds = userInfo["timestamp"] as? TimeInterval {
            timestamp = Date(timeIntervalSince1970: seconds)
        } else if let secondsString = userInfo["timestamp"] as? String,
                  let seconds = TimeInterval(secondsString) {
            timestamp = Date(timeIntervalSince1970: seconds)
        } else {
            timestamp = Date()
        }

        return ChatNotification(
            id: UUID().uuidString,
            conversationID: conversationID,
            messageID: messageID,
            senderID: senderID,
            senderName: senderName,
            body: body,
            timestamp: timestamp
        )
    }
}

extension NotificationService: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task {
            await refreshFCMToken()
        }
    }

    func messaging(_ messaging: Messaging, didReceive remoteMessage: MessagingRemoteMessage) {
        handleIncomingNotification(userInfo: remoteMessage.appData)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handleIncomingNotification(userInfo: notification.request.content.userInfo)
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        handleIncomingNotification(userInfo: response.notification.request.content.userInfo)
        completionHandler()
    }
}
