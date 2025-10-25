import SwiftUI
import SwiftData
import Combine

struct ConversationsView: View {
    @ObservedObject private var viewModel: ConversationsViewModel

    @State private var navigationPath: [ConversationRoute] = []
    @State private var activeNotification: NotificationService.ChatNotification?
    @State private var notificationDismissTask: Task<Void, Never>?
    @State private var activeSheet: ActiveSheet?
    @State private var navigationSubscription: AnyCancellable?
    @State private var pendingDeletion: ConversationEntity?
    @State private var isShowingDeleteConfirmation = false

    private let appServices: AppServices
    private let modelContext: ModelContext

    init(appServices: AppServices, modelContext: ModelContext) {
        self.appServices = appServices
        self.modelContext = modelContext
        _viewModel = ObservedObject(initialValue: ConversationsViewModel(modelContext: modelContext, appServices: appServices))
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $navigationPath) {
                ZStack {
                    backgroundGradient
                        .ignoresSafeArea()

                    List {
                        Section {
                            NavigationLink {
                                AIChatView(appServices: appServices, modelContext: modelContext)
                            } label: {
                                AIAssistantRow()
                            }
                            .listRowBackground(Color.clear)
                        }

                        Section {
                            if viewModel.items.isEmpty {
                                emptyStateRow
                            } else {
                                ForEach(viewModel.items) { conversation in
                                    NavigationLink(value: ConversationRoute(from: conversation)) {
                                        ConversationRow(
                                            conversation: conversation,
                                            presence: presenceData(for: conversation)
                                        )
                                    }
                                    .listRowBackground(Color.clear)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            pendingDeletion = conversation
                                            isShowingDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.insetGrouped)
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

                        viewModel.appendPlaceholderConversation(
                            id: response.conversationId,
                            title: displayTitle,
                            participantIDs: response.participantIds,
                            currentUserID: currentUserID
                        )

                        openConversation(with: placeholderRoute)

                        Task {
                            await viewModel.ensureConversationAvailable(conversationID: response.conversationId)
                        }
                    }
                }
            }
        }
        .alert("Delete chat?", isPresented: $isShowingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let conversation = pendingDeletion {
                    viewModel.delete(conversation: conversation)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
                isShowingDeleteConfirmation = false
            }
        } message: {
            Text("This removes the chat from your device only. Other participants keep their copy.")
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(colors: [Color.black, Color.black.opacity(0.95)], startPoint: .top, endPoint: .bottom)
    }

    private var emptyStateRow: some View {
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
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
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

private struct AIAssistantRow: View {
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 56, height: 56)
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Pingrrr Assistant")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Ask questions, translate chats, get summaries")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private struct AIChatView: View {
    @StateObject private var viewModel: AIChatViewModel

    init(appServices: AppServices, modelContext: ModelContext) {
        _viewModel = StateObject(wrappedValue: AIChatViewModel(appServices: appServices, modelContext: modelContext))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.1))
            messageList
            inputArea
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .task { await viewModel.refreshConversations() }
        .alert("AI Error", isPresented: $viewModel.showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Context")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Conversation", selection: $viewModel.selectedConversationID) {
                Text("None").tag(String?.none)
                ForEach(viewModel.conversationOptions) { option in
                    Text(option.title).tag(String?.some(option.id))
                }
            }
            .pickerStyle(.menu)
            .tint(.white)

            Picker("Scope", selection: $viewModel.contextScope) {
                ForEach(AIChatViewModel.ContextScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .tint(.blue)

            quickActions
        }
        .padding()
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickActionButton(title: "Translate Last", systemImage: "globe") {
                await viewModel.runQuickAction(.translateLast)
            }
            .disabled(!viewModel.canRunQuickActions)

            QuickActionButton(title: "Summarize", systemImage: "list.bullet.rectangle") {
                await viewModel.runQuickAction(.summarize)
            }
            .disabled(!viewModel.canRunQuickActions)

            QuickActionButton(title: "Adjust Tone", systemImage: "textformat.size.larger") {
                await viewModel.runQuickAction(.adjustTone)
            }
            .disabled(!viewModel.canRunQuickActions)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        AIChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 16)
            }
            .background(Color.black)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastID = viewModel.messages.last?.id {
                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            Divider().overlay(Color.white.opacity(0.1))
            HStack(spacing: 12) {
                TextField("Ask the assistant…", text: $viewModel.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .lineLimit(1...4)

                Button {
                    Task { await viewModel.sendMessage() }
                } label: {
                    Image(systemName: viewModel.isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(viewModel.canSend ? .blue : .secondary)
                }
                .disabled(!viewModel.canSend)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial)
    }
}

private struct QuickActionButton: View {
    let title: String
    let systemImage: String
    let action: () async -> Void

    @State private var isRunning = false

    var body: some View {
        Button {
            guard !isRunning else { return }
            isRunning = true
            Task {
                await action()
                await MainActor.run { isRunning = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .imageScale(.medium)
                Text(title)
                    .font(.footnote)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .overlay {
            if isRunning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
                    .tint(.white)
            }
        }
    }
}

private struct AIChatBubble: View {
    let message: AIChatViewModel.Message

    var body: some View {
        HStack {
            if message.role == .assistant {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: message.role == .assistant ? .leading : .trailing, spacing: 6) {
            HStack {
                Text(message.role == .assistant ? "Assistant" : "You")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text(message.content)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .assistant ? Color.white.opacity(0.08) : Color.blue.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

@MainActor
final class AIChatViewModel: ObservableObject {
    enum ContextScope: String, CaseIterable, Identifiable {
        case none
        case recent
        case full

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "No context"
            case .recent: return "Last 10"
            case .full: return "Full"
            }
        }

        var lastN: Int {
            switch self {
            case .none: return 0
            case .recent: return 10
            case .full: return 200
            }
        }

        var includeFullHistory: Bool {
            self == .full
        }
    }

    struct ConversationOption: Identifiable {
        let id: String
        let title: String
    }

    struct Message: Identifiable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        let role: Role
        let content: String
    }

    @Published private(set) var conversationOptions: [ConversationOption] = []
    @Published var selectedConversationID: String?
    @Published var contextScope: ContextScope = .recent
    @Published var messages: [Message] = []
    @Published var inputText: String = ""
    @Published var isSending = false
    @Published var showingError = false
    @Published var errorMessage: String?

    var canRunQuickActions: Bool {
        selectedConversationID != nil && !isSending
    }

    var canSend: Bool {
        !isSending && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let appServices: AppServices
    private let modelContext: ModelContext

    init(appServices: AppServices, modelContext: ModelContext) {
        self.appServices = appServices
        self.modelContext = modelContext
    }

    func refreshConversations() async {
        let descriptor = FetchDescriptor<ConversationEntity>(
            sortBy: [SortDescriptor(\.lastMessageTimestamp, order: .reverse)]
        )
        if let conversations = try? modelContext.fetch(descriptor) {
            conversationOptions = conversations.map { conversation in
                ConversationOption(id: conversation.id, title: conversation.title?.isEmpty == false ? conversation.title! : "Chat")
            }
            if selectedConversationID == nil {
                selectedConversationID = conversationOptions.first?.id
            }
        }
    }

    func sendMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        inputText = ""
        messages.append(Message(role: .user, content: trimmed))
        isSending = true

        do {
            let reply = try await AIService.shared.assistantReply(
                prompt: trimmed,
                conversationID: contextScope == .none ? nil : selectedConversationID,
                lastN: contextScope.lastN == 0 ? 10 : contextScope.lastN,
                includeFullHistory: contextScope.includeFullHistory
            )
            messages.append(Message(role: .assistant, content: reply))
        } catch {
            handle(error: error)
        }

        isSending = false
    }

    enum QuickAction {
        case translateLast
        case summarize
        case adjustTone
    }

    func runQuickAction(_ action: QuickAction) async {
        guard let conversationID = selectedConversationID else { return }

        isSending = true
        do {
            switch action {
            case .translateLast:
                if let message = lastMessage(in: conversationID) {
                    let translated = try await AIService.shared.translate(
                        text: message.content,
                        targetLang: AIPreferencesService.shared.preferences.primaryLanguage,
                        formality: AIPreferencesService.shared.preferences.defaultFormality
                    )
                    messages.append(Message(role: .assistant, content: "Translation of last message:\n\n" + translated))
                } else {
                    messages.append(Message(role: .assistant, content: "No messages available to translate."))
                }
            case .summarize:
                let summary = try await AIService.shared.summarizeConversation(
                    conversationID: conversationID,
                    lastN: contextScope.lastN == 0 ? 50 : contextScope.lastN,
                    includeFullHistory: contextScope.includeFullHistory
                )
                messages.append(Message(role: .assistant, content: summary))
            case .adjustTone:
                if let message = lastMessage(in: conversationID) {
                    let adjusted = try await AIService.shared.adjustTone(
                        text: message.content,
                        language: AIPreferencesService.shared.preferences.primaryLanguage,
                        formality: .formal
                    )
                    messages.append(Message(role: .assistant, content: "Tone suggestion for last message:\n\n" + adjusted))
                } else {
                    messages.append(Message(role: .assistant, content: "No messages available for tone adjustment."))
                }
            }
        } catch {
            handle(error: error)
        }
        isSending = false
    }

    private func lastMessage(in conversationID: String) -> MessageEntity? {
        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate { $0.conversationID == conversationID },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)],
            fetchLimit: 1
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func handle(error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        showingError = true
    }
}

