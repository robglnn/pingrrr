import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool

    private let conversation: ConversationEntity
    private let currentUserID: String

    init(conversation: ConversationEntity, currentUserID: String, modelContext: ModelContext, appServices: AppServices) {
        self.conversation = conversation
        self.currentUserID = currentUserID
        _viewModel = StateObject(wrappedValue: ChatViewModel(
            conversation: conversation,
            currentUserID: currentUserID,
            modelContext: modelContext,
            appServices: appServices
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            messagesList
            typingIndicator
            inputBar
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(conversation.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { viewModel.start() }
        .onDisappear {
            viewModel.userLeftChat()
            viewModel.userStoppedTyping()
        }
        .onChange(of: viewModel.draftMessage) { _, _ in
            if viewModel.draftMessage.isEmpty {
                viewModel.userStoppedTyping()
            } else {
                viewModel.userStartedTyping()
            }
        }
        .onChange(of: inputFocused) { _, focused in
            if focused {
                Task { await viewModel.markMessagesAsRead() }
            }
        }
        .onAppear {
            viewModel.userStartedViewingChat()
            Task { await viewModel.markMessagesAsRead() }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Text(conversation.title ?? "Chat")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Spacer()

                presenceIndicator
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Divider()
                .overlay(Color.white.opacity(0.1))
        }
        .background(Color.black.opacity(0.95))
    }

    private var presenceIndicator: some View {
        Group {
            if let snapshot = viewModel.presenceSnapshot {
                if snapshot.isOnline {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Online")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if let lastSeen = snapshot.lastSeen {
                    Text("Last seen \(Formatter.relativeDateFormatter.localizedString(for: lastSeen, relativeTo: Date()))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Offline")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Connecting...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.displayItems) { item in
                        MessageRowView(
                            item: item,
                            viewModel: viewModel,
                            onRetry: { Task { await viewModel.retrySendingMessage(item.message) } }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.black)
            .onAppear {
                scrollToBottom(proxy: proxy, animated: false, delayed: true)
            }
            .onChange(of: viewModel.displayItems.count) { _, _ in
                scrollToBottom(proxy: proxy, animated: true, delayed: false)
            }
            .onChange(of: viewModel.displayItems.last?.id) { _, _ in
                scrollToBottom(proxy: proxy, animated: true, delayed: false)
                Task { await viewModel.markMessagesAsRead() }
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool, delayed: Bool) {
        guard let lastID = viewModel.displayItems.last?.id else { return }

        let executeScroll = {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }

        if delayed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: executeScroll)
        } else {
            DispatchQueue.main.async(execute: executeScroll)
        }
    }

    private var typingIndicator: some View {
        Group {
            if viewModel.isTyping {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                        .tint(.secondary)
                    Text("Someone is typing...")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.9))
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            Divider()
                .overlay(Color.white.opacity(0.1))

            HStack(spacing: 12) {
                Button {
                    // TODO: Attachment support
                } label: {
                    Image(systemName: "plus.circle")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }

                TextField("Message", text: $viewModel.draftMessage, axis: .vertical)
                    .focused($inputFocused)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .lineLimit(1...4)

                Button {
                    Task {
                        await viewModel.sendMessage()
                    }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .imageScale(.large)
                        .foregroundStyle(viewModel.draftMessage.isEmpty ? .gray : .blue)
                }
                .disabled(viewModel.draftMessage.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }
}

private struct MessageRowView: View {
    let item: ChatViewModel.MessageDisplayItem
    let viewModel: ChatViewModel
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if item.isCurrentUser {
                Spacer(minLength: 40)
            } else {
                if item.showAvatar {
                    avatarView
                } else {
                    Spacer().frame(width: 40)
                }
            }

            VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 6) {
                if item.showSenderName {
                    Text(senderName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(item.message.content)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 6) {
                    Text(item.message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if item.isCurrentUser {
                        statusIcon
                    }
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: item.isCurrentUser ? .trailing : .leading)

            if !item.isCurrentUser {
                Spacer(minLength: 40)
            }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if item.isCurrentUser {
            return AnyShapeStyle(Color.blue.opacity(0.9))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.08))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .delivered:
            Image(systemName: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .read:
            if !readReceiptEntries.isEmpty {
                OverlappingStatusAvatars(entries: readReceiptEntries)
                    .onTapGesture {
                        showReceipts = true
                    }
                    .sheet(isPresented: $showReceipts) {
                        ReadReceiptsView(
                            message: item.message,
                            participants: viewModel.readReceiptProfiles
                        )
                        .presentationDetents([.height(320)])
                    }
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        case .failed:
            Button(action: onRetry) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    @State private var showReceipts = false

    private var readReceiptEntries: [ReadReceiptEntry] {
        guard item.isCurrentUser else { return [] }
        return item.message.readBy
            .filter { $0 != item.message.senderID }
            .compactMap { userID -> ReadReceiptEntry? in
                guard let profile = viewModel.readReceiptProfiles[userID] ?? viewModel.cachedProfile(for: userID) else { return nil }
                return ReadReceiptEntry(userID: userID, profile: profile)
            }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let urlString = item.senderProfile?.profilePictureURL,
           let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    ProgressView()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
        } else {
            placeholder
                .frame(width: 36, height: 36)
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(senderInitial)
                    .font(.caption.bold())
                    .foregroundColor(.blue)
            )
    }

    private var senderName: String {
        item.senderProfile?.displayName ?? item.message.senderID
    }

    private var senderInitial: String {
        senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "?"
            : String(senderName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }
}

private enum Formatter {
    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct ReadReceiptEntry: Identifiable {
    let id = UUID()
    let userID: String
    let profile: UserProfile

    var avatar: some View {
        Group {
            if let urlString = profile.profilePictureURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(profile.displayName.prefix(1).uppercased())
                    .font(.caption.bold())
                    .foregroundColor(.blue)
            )
    }
}

private struct OverlappingStatusAvatars: View {
    let entries: [ReadReceiptEntry]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(entries.prefix(3), id: \.id) { entry in
                entry.avatar
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            if entries.count > 3 {
                Text("+\(entries.count - 3)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}
