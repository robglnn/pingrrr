import SwiftUI

struct ToastNotificationView: View {
    let notification: NotificationService.ToastNotification
    let onTap: () -> Void
    let onDismiss: () -> Void

    @State private var offset: CGFloat = -120
    @State private var opacity: Double = 0

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(String(notification.senderName.prefix(1)))
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.blue)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(notification.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(notification.displayMessage)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(6)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 8)
            .padding(.horizontal, 16)
        }
        .offset(y: offset)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                offset = 0
                opacity = 1
            }
        }
        .onTapGesture(perform: onTap)
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -30 {
                        withAnimation(.spring()) {
                            onDismiss()
                        }
                    }
                }
        )
    }
}

struct ToastNotificationOverlay: View {
    @ObservedObject var notificationService: NotificationService

    var body: some View {
        VStack {
            if let toast = notificationService.currentToast {
                ToastNotificationView(
                    notification: toast,
                    onTap: {
                        NotificationCenter.default.post(
                            name: .navigateToConversation,
                            object: toast.conversationID
                        )
                        notificationService.hideCurrentToast()
                    },
                    onDismiss: {
                        withAnimation(.spring()) {
                            notificationService.hideCurrentToast()
                        }
                        NotificationCenter.default.post(name: .navigateToConversation, object: nil)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 12)
            }

            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(notificationService.currentToast != nil)
        .onDisappear {
            NotificationCenter.default.post(name: .navigateToConversation, object: nil)
        }
    }
}

