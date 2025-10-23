import SwiftUI
import SwiftData
import Combine

struct ConversationsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var viewModel: ConversationsViewModel

    @State private var navigationPath: [String] = []
    @State private var activeNotification: NotificationService.ChatNotification?
    @State private var notificationDismissTask: Task<Void, Never>?
    @State private var activeSheet: ActiveSheet?

    private let appServices: AppServices

    init(appServices: AppServices, modelContext: ModelContext? = nil) {
        self.appServices = appServices
        if let modelContext {
            _viewModel = ObservedObject(initialValue: ConversationsViewModel(modelContext: modelContext, appServices: appServices))
        } else {
            let container = try! ModelContainer(for: UserEntity.self, ConversationEntity.self, MessageEntity.self)
            let context = container.mainContext
            _viewModel = ObservedObject(initialValue: ConversationsViewModel(modelContext: context, appServices: appServices))
        }
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.items) { conversation in
                            NavigationLink(value: conversation.id) {
                                ConversationRow(
                                    conversation: conversation,
                                    presence: presenceData(for: conversation)
                                )
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Chats")
            .toolbar { toolbar }
            .refreshable { await viewModel.refresh() }
            .task { viewModel.start() }
            .onDisappear { viewModel.stop() }
            .navigationDestination(for: String.self) { conversationID in
                if let conversation = viewModel.items.first(where: { $0.id == conversationID }),
                   let userID = appServices.authService.currentUserID {
                    ChatView(
                        conversation: conversation,
                        currentUserID: userID,
                        modelContext: modelContext,
                        appServices: appServices
                    )
                    .environment(\.modelContext, modelContext)
                } else {
                    Text("Unable to load conversation")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .top) {
            if let notification = activeNotification {
                NotificationBannerView(notification: notification) {
                    openConversation(withID: notification.conversationID)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(appServices.notificationService.$lastNotification.compactMap { $0 }) { notification in
            presentNotification(notification)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .settings:
                SettingsSheet(appServices: appServices) {
                    activeSheet = nil
                }
            case .newConversation:
                NewConversationSheet(appServices: appServices) { newConversationID in
                    activeSheet = nil
                    if let id = newConversationID {
                        openConversation(withID: id)
                    }
                }
            }
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(colors: [Color.black, Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Start a conversation")
                .font(.headline)
                .foregroundStyle(.white)

            Text("Chats you’re part of will appear here. Create or join a conversation to get going.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "line.3.horizontal")
                    .imageScale(.large)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                activeSheet = .newConversation
            } label: {
                Image(systemName: "square.and.pencil")
                    .imageScale(.large)
            }
        }
    }
}

private enum ActiveSheet: Identifiable {
    case settings
    case newConversation

    var id: Int {
        switch self {
        case .settings: return 0
        case .newConversation: return 1
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationEntity
    let presence: ConversationsViewModel.PresenceViewData

    @State private var participantDisplayNames: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if presence.isOnline {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                    } else if let lastSeen = presence.lastSeen {
                        Text("Last seen \(Formatter.relativeDateFormatter.localizedString(for: lastSeen, relativeTo: Date()))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let timestamp = conversation.lastMessageTimestamp {
                        Text(Formatter.relativeDateFormatter.localizedString(for: timestamp, relativeTo: Date()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(conversation.lastMessagePreview ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if conversation.unreadCount > 0 {
                badge(count: conversation.unreadCount)
            }
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        conversation.title ?? "Chat"
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.7))
                .frame(width: 44, height: 44)
            Text(initials)
                .font(.callout.bold())
                .foregroundStyle(.white)
        }
    }

    private var initials: String {
        let words = title.split(separator: " ")
        return words.prefix(2).map { String($0.prefix(1)) }.joined().uppercased()
    }

    private func badge(count: Int) -> some View {
        Text("\(count)")
            .font(.caption.bold())
            .padding(6)
            .background(Color.blue, in: Capsule())
            .foregroundStyle(.white)
    }
}

private enum Formatter {
    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private extension ConversationsView {
    func presenceData(for conversation: ConversationEntity) -> ConversationsViewModel.PresenceViewData {
        guard let currentUserID = appServices.authService.currentUserID else {
            return ConversationsViewModel.PresenceViewData(isOnline: false, lastSeen: nil)
        }
        return viewModel.presenceState(for: conversation, currentUserID: currentUserID)
    }

    private func presentNotification(_ notification: NotificationService.ChatNotification) {
        notificationDismissTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            activeNotification = notification
        }

        notificationDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                if activeNotification?.id == notification.id {
                    activeNotification = nil
                }
            }
        }
    }

    private func openConversation(withID id: String) {
        activeNotification = nil
        if !navigationPath.contains(id) {
            navigationPath.append(id)
        }
    }
}

private struct NotificationBannerView: View {
    let notification: NotificationService.ChatNotification
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(notification.senderName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(notification.body.isEmpty ? "New message" : notification.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(notification.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .shadow(color: Color.black.opacity(0.3), radius: 12, x: 0, y: 8)
    }
}

