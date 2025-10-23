import SwiftUI
import SwiftData
import Combine

struct ConversationsView: View {
    @ObservedObject private var viewModel: ConversationsViewModel

    @State private var navigationPath: [ConversationRoute] = []
    @State private var activeNotification: NotificationService.ChatNotification?
    @State private var notificationDismissTask: Task<Void, Never>?
    @State private var activeSheet: ActiveSheet?

    private let appServices: AppServices
    private let modelContext: ModelContext

    init(appServices: AppServices, modelContext: ModelContext) {
        self.appServices = appServices
        self.modelContext = modelContext
        _viewModel = ObservedObject(initialValue: ConversationsViewModel(modelContext: modelContext, appServices: appServices))
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
                            NavigationLink(value: ConversationRoute(from: conversation)) {
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
            .navigationDestination(for: ConversationRoute.self) { route in
                ChatView(
                    conversation: placeholderConversation(from: route, modelContext: modelContext),
                    currentUserID: appServices.authService.currentUserID ?? "",
                    modelContext: modelContext,
                    appServices: appServices
                )
                .environment(\.modelContext, modelContext)
                .task {
                    await viewModel.ensureConversationAvailable(conversationID: route.id)
                }
            }
        }
        .overlay(alignment: .top) {
            if let notification = activeNotification {
                NotificationBannerView(notification: notification) {
                    let route = ConversationRoute(
                        id: notification.conversationID,
                        title: notification.conversationTitle,
                        participantIDs: []
                    )
                    openConversation(with: route)
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
                NewConversationSheet(appServices: appServices) { response, displayTitle, currentUserID in
                    activeSheet = nil
                    guard let response else { return }

                    let placeholderRoute = ConversationRoute(
                        id: response.conversationId,
                        title: displayTitle,
                        participantIDs: response.participantIds
                    )

                    // Optimistically append so the list shows the new conversation
                    viewModel.appendPlaceholderConversation(
                        id: response.conversationId,
                        title: displayTitle,
                        participantIDs: response.participantIds,
                        currentUserID: currentUserID
                    )

                    openConversation(with: placeholderRoute)

                    Task {
                        await viewModel.refresh()
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

    private func openConversation(with conversation: ConversationRoute) {
        activeNotification = nil
        if !navigationPath.contains(conversation) {
            navigationPath.append(conversation)
        }
    }
}

private struct ConversationRoute: Hashable, Codable {
    let id: String
    let title: String?
    let participantIDs: [String]

    init(id: String, title: String?, participantIDs: [String]) {
        self.id = id
        self.title = title
        self.participantIDs = participantIDs
    }

    init(from conversation: ConversationEntity) {
        self.init(id: conversation.id, title: conversation.title, participantIDs: conversation.participantIDs)
    }
}

private func placeholderConversation(from route: ConversationRoute, modelContext: ModelContext) -> ConversationEntity {
    let descriptor = FetchDescriptor<ConversationEntity>(
        predicate: #Predicate { $0.id == route.id }
    )

    if let existing = try? modelContext.fetch(descriptor).first {
        return existing
    }

    return ConversationEntity(
        id: route.id,
        title: route.title,
        participantIDs: route.participantIDs,
        type: .oneOnOne,
        lastMessageID: nil,
        lastMessagePreview: nil,
        lastMessageTimestamp: Date(),
        unreadCount: 0
    )
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

