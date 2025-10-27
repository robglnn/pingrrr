import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel: ChatViewModel

    @FocusState private var inputFocused: Bool

    private let conversation: ConversationEntity
    private let currentUserID: String

    @State private var showMediaSheet = false
    @State private var showVoiceWarning = false
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingScrollWorkItem: DispatchWorkItem?
    @State private var showingTranslationSettings = false
    @State private var suppressGlobeToggle = false

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
        .onAppear {
            viewModel.userStartedViewingChat()
        }
        .onDisappear {
            viewModel.userLeftChat()
            viewModel.stop()
        }
        .alert("Voice messages delete after 7 days", isPresented: $showVoiceWarning) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("To save space, voice messages auto-delete 7 days after they are sent.")
        }
        .sheet(isPresented: $showMediaSheet) {
            MediaPickerSheet { result in
                switch result {
                case let .image(data):
                    Task {
                        await viewModel.enqueuePendingMedia(data: data, type: .image)
                        await MainActor.run {
                            showMediaSheet = false
                            inputFocused = true
                        }
                    }
                case .cancel:
                    viewModel.clearPendingMedia()
                    showMediaSheet = false
                }
            }
        }
        .sheet(isPresented: $showingTranslationSettings) {
            AutoTranslateSettingsView(
                languages: viewModel.supportedTranslationLanguages,
                native: viewModel.autoTranslateNativeLanguage,
                target: viewModel.autoTranslateTargetLanguage
            ) { native, target in
                Task { await viewModel.updateAutoTranslateLanguages(native: native, target: target) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceMessageDidRequireWarning)) { _ in
            showVoiceWarning = true
        }
        .onChange(of: viewModel.isVoiceRecording) { _, isRecording in
            if isRecording {
                inputFocused = false
            }
        }
    }

    private let bottomAnchorID = "chatBottomAnchor"
    private let bottomScrollPadding: CGFloat = 10

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let snapshot = viewModel.presenceSnapshot {
                        PresenceHeaderView(snapshot: snapshot)
                    }
                    ForEach(viewModel.displayItems) { item in
                        MessageRowView(
                            item: item,
                            viewModel: viewModel,
                            onRetry: {
                                Task { await viewModel.retrySendingMessage(item.message) }
                            }
                        )
                        .id(item.id)
                    }
                    Color.clear
                        .frame(height: bottomScrollPadding)
                        .id(bottomAnchorID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .background(Color.black)
            .onAppear {
                scrollProxy = proxy
                scrollToBottom(proxy: proxy, delayed: true, animated: false)
            }
            .onChange(of: viewModel.displayItemsVersion) { _, _ in
                scrollToBottom(proxy: proxy, delayed: true)
            }
            .onChange(of: viewModel.accessoryVersion) { _, _ in
                scrollToBottom(proxy: proxy, delayed: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scrollToBottom(proxy explicitProxy: ScrollViewProxy? = nil, delayed: Bool, animated: Bool = true) {
        let proxy = explicitProxy ?? scrollProxy
        guard let proxy else { return }

        let executeScroll = {
            if animated {
                withAnimation(.easeOut) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }

        if delayed {
            pendingScrollWorkItem?.cancel()
            let workItem = DispatchWorkItem(block: executeScroll)
            pendingScrollWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
        } else {
            pendingScrollWorkItem?.cancel()
            pendingScrollWorkItem = nil
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

            if let pending = viewModel.pendingMedia {
                PendingMediaBanner(
                    pending: pending,
                    viewModel: viewModel,
                    onRemove: {
                        withAnimation {
                            viewModel.clearPendingMedia()
                        }
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal, 16)
            }

            if viewModel.isVoiceRecording {
                VoiceRecordingBar(
                    duration: viewModel.voiceRecordingDuration,
                    onCancel: {
                        viewModel.cancelVoiceRecording()
                    },
                    onSend: {
                        Task {
                            if await viewModel.stopVoiceRecording() {
                                await viewModel.sendCurrentVoiceRecording()
                                await MainActor.run { scrollToBottom(delayed: true) }
                            }
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            } else {
                HStack(spacing: 12) {
                    Button {
                        showMediaSheet = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .imageScale(.large)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if suppressGlobeToggle {
                            suppressGlobeToggle = false
                            return
                        }
                        Task { await viewModel.toggleAutoTranslate() }
                    } label: {
                        Image(systemName: "globe")
                            .imageScale(.medium)
                            .foregroundStyle(viewModel.isAutoTranslateActive ? .blue : .secondary)
                    }
                    .disabled(viewModel.aiIsProcessingTranslation)
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
                        suppressGlobeToggle = true
                        showingTranslationSettings = true
                    })

                    TextField("Type a message...", text: $viewModel.draftMessage, axis: .vertical)
                        .focused($inputFocused)
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                        .lineLimit(1...4)
                        .onChange(of: viewModel.draftMessage) { oldValue, newValue in
                            let oldTrimmed = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            let newTrimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

                            if oldTrimmed.isEmpty && !newTrimmed.isEmpty {
                                // User started typing
                                viewModel.userStartedTyping()
                            } else if !oldTrimmed.isEmpty && newTrimmed.isEmpty {
                                // User stopped typing
                                viewModel.userStoppedTyping()
                            }
                        }

                    Button {
                        let trimmed = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                        if viewModel.pendingMedia != nil {
                            Task {
                                await viewModel.sendPendingMedia()
                                if !trimmed.isEmpty {
                                    await viewModel.sendMessage()
                                }
                                await MainActor.run {
                                    inputFocused = false
                                    scrollToBottom(delayed: true)
                                }
                            }
                        } else if trimmed.isEmpty {
                            Task {
                                await viewModel.startVoiceRecording()
                            }
                        } else {
                            Task {
                                await viewModel.sendMessage()
                                await MainActor.run {
                                    inputFocused = false
                                    scrollToBottom(delayed: true)
                                }
                            }
                        }
                    } label: {
                        let hasPending = viewModel.pendingMedia != nil
                        let isTyping = !viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        let shouldShowSend = hasPending || isTyping
                        Image(systemName: shouldShowSend ? "paperplane.fill" : "mic.fill")
                            .imageScale(.large)
                            .foregroundStyle(shouldShowSend ? .blue : .secondary)
                    }
                    .disabled(viewModel.isSending)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial)
    }

    private struct PresenceHeaderView: View {
        let snapshot: PresenceService.Snapshot

        var body: some View {
            HStack {
                Text(snapshot.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
    }

private struct AutoTranslateSettingsView: View {
    let languages: [TranslationLanguage]
    let onUpdate: (TranslationLanguage, TranslationLanguage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedNative: TranslationLanguage
    @State private var selectedTarget: TranslationLanguage

    init(
        languages: [TranslationLanguage],
        native: TranslationLanguage,
        target: TranslationLanguage,
        onUpdate: @escaping (TranslationLanguage, TranslationLanguage) -> Void
    ) {
        self.languages = languages
        self._selectedNative = State(initialValue: native)
        self._selectedTarget = State(initialValue: target)
        self.onUpdate = onUpdate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your Language") {
                    Picker("Native", selection: $selectedNative) {
                        ForEach(languages) { language in
                            Text(language.name).tag(language)
                        }
                    }
                }

                Section("Translate To") {
                    Picker("Target", selection: $selectedTarget) {
                        ForEach(languages) { language in
                            Text(language.name).tag(language)
                        }
                    }
                }
            }
            .navigationTitle("Auto Translate")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onUpdate(selectedNative, selectedTarget)
                        dismiss()
                    }
                }
            }
        }
    }
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

        messageBubble

                if let insight = item.insight {
                    insightBubble(for: insight)
                }

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
            .contextMenu {
                if item.message.mediaType == nil && item.message.mediaURL == nil {
                    Button("Translate") {
                        Task { await viewModel.toggleTranslation(for: item.id) }
                    }
                    Button("Explain Slang") {
                        Task { await viewModel.explainSlang(for: item.id) }
                    }
                    Button("Cultural Hint") {
                        Task { await viewModel.culturalHint(for: item.id) }
                    }
                    Button("Adjust Tone") {
                        Task { await viewModel.adjustTone(for: item.id) }
                    }
                    Button("Smart Reply") {
                        Task { await viewModel.generateSmartReply(for: item.id) }
                    }
                    if item.insight != nil {
                        Button("Remove Insight") {
                            viewModel.removeInsight(for: item.id)
                        }
                    }
                    if let translated = item.message.translatedContent {
                        Button("Copy Translation") {
                            UIPasteboard.general.string = translated
                        }
                    }
                }
            }

            if !item.isCurrentUser {
                Spacer(minLength: 40)
            }
        }
    }

    private var messageBubble: some View {
        VStack(alignment: item.isCurrentUser ? .trailing : .leading, spacing: 6) {
            primaryBubble
            if let manual = manualTranslationText {
                translationBlock(text: manual, label: "Translated")
            } else if let auto = autoTranslationPayload {
                translationBlock(text: auto.text, label: translationLabel(for: auto))
            }
            if let reply = viewModel.smartReply(for: item.message.id) {
                smartReplyBlock(reply)
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

    private var primaryBubble: some View {
        Group {
            if let mediaType = item.message.mediaType, let mediaURL = item.message.mediaURL {
                MediaBubbleView(
                    mediaType: mediaType,
                    mediaURL: mediaURL,
                    isCurrentUser: item.isCurrentUser,
                    message: item.message,
                    viewModel: viewModel
                )
            } else {
                Text(bubbleText)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .padding(6)
            }
        }
    }

    private var bubbleText: String {
        if item.isCurrentUser, let original = item.message.originalContent, !original.isEmpty {
            return original
        }
        return item.message.content
    }

    private var autoTranslationPayload: MessageAutoTranslation? {
        viewModel.translationForDisplay(of: item.message, isCurrentUser: item.isCurrentUser)
    }

    private var manualTranslationText: String? {
        guard item.showTranslation else { return nil }
        return item.message.translatedContent
    }

    private func translationLabel(for payload: MessageAutoTranslation) -> String {
        if let language = TranslationLanguage.language(for: payload.targetLanguageCode) {
            return "Translated (\(language.name))"
        }
        return "Translated (\(payload.targetLanguageCode.uppercased()))"
    }

    @ViewBuilder
    private func translationBlock(text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func smartReplyBlock(_ suggestion: ChatViewModel.SmartReplySuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            translationBlock(
                text: suggestion.homeText,
                label: "Smart Reply (\(suggestion.homeLanguage.name))"
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Send in \(suggestion.targetLanguage.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    Text(suggestion.translatedText)
                        .font(.body)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        guard !isSendingSmartReply else { return }
                        isSendingSmartReply = true
                        Task {
                            await viewModel.sendSmartReply(for: item.message.id)
                            await MainActor.run { isSendingSmartReply = false }
                        }
                    } label: {
                        Image(systemName: isSendingSmartReply ? "hourglass" : "paperplane.fill")
                            .font(.body)
                            .padding(8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isSendingSmartReply || viewModel.isSending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func insightBubble(for insight: ChatViewModel.AIInsight) -> some View {
        let (icon, tint) = insightAppearance(for: insight.type)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(tint)
                Text(insightTitle(for: insight.type))
                    .font(.caption2)
                    .foregroundStyle(tint)
                Spacer()
                Button {
                    UIPasteboard.general.string = insight.content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(insight.content)
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func insightAppearance(for type: ChatViewModel.AIInsight.InsightType) -> (icon: String, tint: Color) {
        switch type {
        case .slang:
            return ("bubble.left.and.exclamationmark.bubble.right", .orange)
        case .culture:
            return ("globe", .purple)
        case .formality:
            return ("textformat.size.larger", .cyan)
        }
    }

    private func insightTitle(for type: ChatViewModel.AIInsight.InsightType) -> String {
        switch type {
        case .slang:
            return "Slang Clarified"
        case .culture:
            return "Cultural Tip"
        case .formality:
            return "Tone Adjustment"
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let receipts = readReceiptEntries

        if !receipts.isEmpty {
            OverlappingStatusAvatars(entries: receipts)
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

    @State private var showReceipts = false
    @State private var isSendingSmartReply = false

    private var readReceiptEntries: [ReadReceiptEntry] {
        guard item.isCurrentUser else { return [] }
        let currentUserID = viewModel.loggedInUserID
        let senderID = item.message.senderID

        let entries = item.message.readBy
            .filter { $0 != currentUserID && $0 != senderID }
            .compactMap { userID -> ReadReceiptEntry? in
                guard let profile = viewModel.readReceiptProfiles[userID] ?? viewModel.cachedProfile(for: userID) else { return nil }
                let timestamp = item.message.readTimestamps[userID]
                return ReadReceiptEntry(
                    userID: userID,
                    displayName: profile.displayName,
                    timestamp: timestamp
                )
            }
        return entries.sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    @ViewBuilder
    private var avatarView: some View {
        let profile = item.senderProfile ?? viewModel.cachedProfile(for: item.message.senderID)
        AsyncProfileImageView(
            userID: profile?.id ?? item.message.senderID,
            displayName: profile?.displayName ?? "User",
            photoURL: profile?.profilePictureURL,
            photoVersion: profile?.photoVersion ?? 0,
            size: .regular,
            showsBorder: false
        )
        .frame(width: 36, height: 36)
    }

    private var senderName: String {
        if let profile = item.senderProfile ?? viewModel.cachedProfile(for: item.message.senderID) {
            return profile.displayName
        }
        return item.isCurrentUser ? "You" : item.message.senderID
    }
}

private struct PendingMediaBanner: View {
    let pending: ChatViewModel.PendingMedia
    let viewModel: ChatViewModel
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if pending.type == .image, let thumbnail = viewModel.thumbnailImage(for: pending) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: pending.type == .voice ? "waveform" : "photo")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                if pending.type == .voice {
                    Text(pending.type.previewText)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                }

                if let duration = pending.duration, pending.type == .voice {
                    Text(Formatter.format(duration: duration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if pending.state == .uploading {
                    Text("Uploading…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready to send")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.8))
                    .font(.title3)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MediaBubbleView: View {
    let mediaType: MessageMediaType
    let mediaURL: String
    let isCurrentUser: Bool
    let message: MessageEntity
    let viewModel: ChatViewModel

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        Group {
            switch mediaType {
            case .image:
                mediaImage
            case .voice:
                VoiceMessageBubble(url: mediaURL, message: message, viewModel: viewModel)
            }
        }
    }

    private var mediaImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isCurrentUser ? Color.blue.opacity(0.9) : Color.white.opacity(0.08))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.8))
                    if let loadError {
                        Text(loadError)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                    } else {
                        Text("Tap to load photo")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 220, height: 160)
        .clipped()
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { Task { await loadImage() } }
        .task { await loadImageIfNeeded() }
    }

    private func loadImageIfNeeded() async {
        guard image == nil, !isLoading else { return }
        await loadImage()
    }

    private func loadImage() async {
        guard image == nil else { return }
        await MainActor.run {
            loadError = nil
            isLoading = true
        }

        do {
            let data = try await viewModel.loadMediaData(from: mediaURL, type: mediaType)
            if let fetchedImage = UIImage(data: data) {
                await MainActor.run { self.image = fetchedImage }
            } else {
                await MainActor.run { self.loadError = "Unsupported image data" }
            }
        } catch {
            await MainActor.run { self.loadError = error.localizedDescription }
        }

        await MainActor.run { self.isLoading = false }
    }
}

private struct VoiceRecordingBar: View {
    let duration: TimeInterval
    let onCancel: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onCancel) {
                Image(systemName: "trash.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Circle().fill(Color.white.opacity(0.12)))
            }

            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 24))
                    .foregroundStyle(.white)
                Text(Formatter.format(duration: duration))
                    .font(.headline)
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(Color.blue))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.blue.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct VoiceMessageBubble: View {
    let url: String
    let message: MessageEntity
    let viewModel: ChatViewModel

    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var progress: Double = 0
    @State private var player: AVAudioPlayer?
    @State private var timer: Timer?
    @State private var audioData: Data?

    var body: some View {
        HStack(spacing: 16) {
            Button {
                Task { await togglePlayback() }
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(Color.blue))
            }
            .disabled(isLoading)

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)

                HStack(spacing: 4) {
                    Text(Formatter.format(duration: message.voiceDuration ?? player?.duration ?? 0))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.6)
                            .tint(.white)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.08)))
        .onDisappear {
            stopPlayback()
        }
    }

    private func togglePlayback() async {
        if isPlaying {
            stopPlayback()
            return
        }

        if player == nil {
            await loadAudioIfNeeded()
        }

        guard let player else { return }

        player.currentTime = 0
        player.play()
        progress = 0
        isPlaying = true

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if player.isPlaying {
                progress = player.currentTime / player.duration
            } else {
                timer.invalidate()
                stopPlayback()
            }
        }
    }

    private func stopPlayback() {
        player?.stop()
        player?.currentTime = 0
        timer?.invalidate()
        timer = nil
        progress = 0
        isPlaying = false
    }

    private func loadAudioIfNeeded() async {
        if audioData != nil { return }

        await MainActor.run { isLoading = true }

        do {
            let data = try await viewModel.loadMediaData(from: url, type: .voice)
            audioData = data
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            await MainActor.run {
                self.player = player
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
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

    static func format(duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "0\"" }
        let seconds = Int(round(duration))
        return "\(seconds)\""
    }
}

private struct ReadReceiptEntry: Identifiable {
    let id = UUID()
    let userID: String
    let displayName: String
    let timestamp: Date?
}

private struct OverlappingStatusAvatars: View {
    let entries: [ReadReceiptEntry]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(entries.prefix(3), id: \.id) { entry in
                avatar(for: entry)
                    .frame(width: 16, height: 16)
            }
        }
    }

    private func avatar(for entry: ReadReceiptEntry) -> some View {
        let initial = entry.displayName.first.map { String($0).uppercased() } ?? "?"

        return Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(initial)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.blue)
            )
            .overlay(
                Circle()
                    .stroke(Color.blue.opacity(0.4), lineWidth: 0.5)
            )
    }
}

