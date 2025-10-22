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
        .onDisappear { viewModel.stop() }
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
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(
                            message: message,
                            isOwnMessage: message.senderID == currentUserID,
                            onRetry: { Task { await viewModel.retrySendingMessage(message) } }
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(Color.black)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
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

private struct MessageBubbleView: View {
    let message: MessageEntity
    let isOwnMessage: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isOwnMessage { Spacer(minLength: 60) }

            VStack(alignment: isOwnMessage ? .trailing : .leading, spacing: 6) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(spacing: 6) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if isOwnMessage {
                        statusIcon
                    }
                }
            }
            .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: isOwnMessage ? .trailing : .leading)

            if !isOwnMessage { Spacer(minLength: 60) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if isOwnMessage {
            return AnyShapeStyle(Color.blue.opacity(0.9))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.08))
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch message.status {
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
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        case .failed:
            Button(action: onRetry) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }
}

private enum Formatter {
    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
