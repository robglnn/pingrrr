import SwiftUI
import SwiftData

struct ConversationsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var viewModel: ConversationsViewModel

    @State private var isPresentingSettings = false

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
        NavigationStack {
            ZStack {
                backgroundGradient
                    .ignoresSafeArea()

                if viewModel.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.items) { conversation in
                            NavigationLink {
                                if let modelContext = modelContext,
                                   let userID = appServices.authService.currentUserID {
                                    ChatView(
                                        conversation: conversation,
                                        currentUserID: userID,
                                        modelContext: modelContext,
                                        appServices: appServices
                                    )
                                } else {
                                    Text("Unable to load conversation")
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                ConversationRow(conversation: conversation)
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
                isPresentingSettings = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .imageScale(.large)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // TODO: Present new conversation creator
            } label: {
                Image(systemName: "square.and.pencil")
                    .imageScale(.large)
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationEntity

    @State private var participantDisplayNames: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)

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

