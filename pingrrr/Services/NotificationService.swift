import Foundation
import UserNotifications
import Combine
import UIKit
import FirebaseMessaging
import FirebaseAuth
import FirebaseFirestore
import AVFoundation

extension Notification.Name {
    static let navigateToConversation = Notification.Name("navigateToConversation")
}

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
        let conversationTitle: String?
    }

    struct ToastNotification: Identifiable, Equatable {
        let id: String
        let conversationID: String
        let conversationTitle: String?
        let senderName: String
        let message: String
        let timestamp: Date

        var displayTitle: String {
            conversationTitle ?? "Chat"
        }

        var displayMessage: String {
            message.isEmpty ? senderName : "\(senderName): \(message)"
        }
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastNotification: ChatNotification?
    @Published private(set) var currentToast: ToastNotification?

    private var currentChatID: String?
    private var recentChatActivity: [String: Date] = [:]
    private var toastHideWorkItem: DispatchWorkItem?

    var currentConversationID: String? {
        currentChatID
    }

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

    func showForegroundNotification(
        message: String,
        conversationID: String,
        conversationTitle: String?,
        senderName: String
    ) {
        guard UIApplication.shared.applicationState == .active else { return }
        guard !isInDoNotDisturb() else {
            print("[NotificationService] Suppressing toast (Do Not Disturb)")
            return
        }

        if isInConversation(conversationID) {
            markChatAsRecentlyActive(conversationID)
            return
        }

        if isRecentlyActive(conversationID) {
            return
        }

        if currentToast != nil {
            return
        }

        let toast = ToastNotification(
            id: UUID().uuidString,
            conversationID: conversationID,
            conversationTitle: conversationTitle,
            senderName: senderName,
            message: message,
            timestamp: Date()
        )

        currentToast = toast
        scheduleToastHide()
        markChatAsRecentlyActive(conversationID)
    }

    func hideCurrentToast() {
        toastHideWorkItem?.cancel()
        toastHideWorkItem = nil
        currentToast = nil
    }

    func setCurrentChatID(_ chatID: String) {
        currentChatID = chatID
        markChatAsRecentlyActive(chatID)
        hideCurrentToast()
    }

    func clearCurrentChatID() {
        if let chatID = currentChatID {
            markChatAsRecentlyActive(chatID)
        }
        currentChatID = nil
    }

    func markChatAsRecentlyActive(_ chatID: String) {
        recentChatActivity[chatID] = Date()
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
        let body: String
        if let explicitBody = (userInfo["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            body = explicitBody
        } else if
            let apsAny = userInfo["aps"],
            let aps = apsAny as? [String: Any],
            let alertAny = aps["alert"],
            let alert = alertAny as? [String: Any]
        {
            let components: [String] = alert.compactMap { _, value in
                value as? String
            }
            body = components.joined(separator: " ")
        } else {
            body = ""
        }

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
            timestamp: timestamp,
            conversationTitle: userInfo["conversationTitle"] as? String
        )
    }

    private func isInDoNotDisturb() -> Bool {
        if #available(iOS 15.0, *) {
            return AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        }
        return false
    }

    func isInConversation(_ conversationID: String) -> Bool {
        currentChatID == conversationID
    }

    private func isRecentlyActive(_ chatID: String, within seconds: TimeInterval = 5) -> Bool {
        guard let last = recentChatActivity[chatID] else { return false }
        return Date().timeIntervalSince(last) < seconds
    }

    private func scheduleToastHide() {
        toastHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.currentToast = nil
            self?.toastHideWorkItem = nil
        }
        toastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }
}

extension NotificationService: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        Task {
            await refreshFCMToken()
        }
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
