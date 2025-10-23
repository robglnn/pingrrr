import SwiftUI
import SwiftData
import FirebaseFunctions

struct NewConversationSheet: View {
    @ObservedObject private var appServices: AppServices
    let onDismiss: (ConversationCreationResponse?, String?, String) -> Void

    @State private var conversationTitle: String = ""
    @State private var participantFields: [String] = [""]
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let maxParticipants = 5

    init(appServices: AppServices, onDismiss: @escaping (ConversationCreationResponse?, String?, String) -> Void) {
        _appServices = ObservedObject(initialValue: appServices)
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Conversation name", text: $conversationTitle)
                        .textInputAutocapitalization(.words)
                }

                Section("Participants") {
                    ForEach(Array(participantFields.enumerated()), id: \.offset) { index, _ in
                        HStack(alignment: .center, spacing: 12) {
                            TextField("Participant email or ID", text: Binding(
                                get: { participantFields[index] },
                                set: { participantFields[index] = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            if participantFields.count > 1 {
                                Button(role: .destructive) {
                                    removeParticipantField(at: index)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }

                    if participantFields.count < maxParticipants {
                        Button {
                            addParticipantField()
                        } label: {
                            Label("Add Participant", systemImage: "plus.circle")
                        }
                    }

                    Text("Add up to \(maxParticipants) participants by email or user ID. Your account is always included.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss(nil, nil, "") }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(action: createConversation) {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private func createConversation() {
        guard !isCreating else { return }
        guard let currentUserID = appServices.authService.currentUserID else {
            errorMessage = "Unable to determine current user."
            return
        }

        let entries = cleanedParticipants()

        guard !entries.isEmpty else {
            errorMessage = ConversationCreationError.missingParticipants.errorDescription
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            do {
                let response = try await appServices.conversationService.createConversation(
                    participantEmails: entries,
                    title: conversationTitle
                )

                let trimmedTitle = conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = trimmedTitle.isEmpty ? nil : trimmedTitle

                // Optimistically create the conversation locally for immediate UI display
                await MainActor.run {
                    createLocalConversation(
                        response: response,
                        title: displayTitle,
                        currentUserID: currentUserID
                    )
                    resetForm()
                    onDismiss(response, displayTitle, currentUserID)
                }
            } catch {
                await MainActor.run {
                    errorMessage = message(for: error)
                }
            }

            await MainActor.run {
                isCreating = false
            }
        }
    }

    @MainActor
    private func resetForm() {
        conversationTitle = ""
        participantFields = [""]
    }

    @MainActor
    private func createLocalConversation(
        response: ConversationCreationResponse,
        title: String?,
        currentUserID: String
    ) {
        guard let modelContext = appServices.sharedModelContext else {
            print("Conversation created: \(response.conversationId) (no modelContext available)")
            return
        }

        let id = response.conversationId
        let allConversations = (try? modelContext.fetch(FetchDescriptor<ConversationEntity>())) ?? []
        let participants = uniqueParticipants(currentUserID: currentUserID, others: response.participantIds)

        let entity: ConversationEntity
        if let existing = allConversations.first(where: { $0.id == id }) {
            entity = existing
        } else {
            entity = ConversationEntity(
                id: id,
                title: title,
                participantIDs: participants,
                type: ConversationType(rawValue: response.type) ?? .oneOnOne,
                lastMessageID: nil,
                lastMessagePreview: "",
                lastMessageTimestamp: Date(),
                unreadCount: 0
            )
            modelContext.insert(entity)
        }

        // Ensure metadata reflects latest creation info
        entity.title = title
        entity.participantIDs = participants
        entity.lastMessageID = nil
        entity.lastMessagePreview = ""
        entity.lastMessageTimestamp = Date()
        entity.unreadCount = 0

        do {
            try modelContext.save()
            print("[NewConversationSheet] Inserted local conversation \(entity.id)")
        } catch {
            print("[NewConversationSheet] Failed to save local conversation: \(error)")
        }
    }

    private func uniqueParticipants(currentUserID: String, others: [String]) -> [String] {
        var result: [String] = []
        let combined = [currentUserID] + others
        for id in combined where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private func addParticipantField() {
        guard participantFields.count < maxParticipants else { return }
        participantFields.append("")
    }

    private func removeParticipantField(at index: Int) {
        guard participantFields.indices.contains(index) else { return }
        participantFields.remove(at: index)
        if participantFields.isEmpty {
            participantFields = [""]
        }
    }

    private func cleanedParticipants() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []

        for value in participantFields {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !seen.contains(trimmed.lowercased()) {
                seen.insert(trimmed.lowercased())
                result.append(trimmed)
            }
        }

        if result.count > maxParticipants {
            result = Array(result.prefix(maxParticipants))
        }

        return result
    }

    private func message(for error: Error) -> String {
        if let creationError = error as? ConversationCreationError {
            return creationError.localizedDescription
        }

        if let nsError = error as NSError?, nsError.domain == FunctionsErrorDomain,
           let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .notFound:
                return "One or more participants haven’t signed up yet."
            case .failedPrecondition:
                return ConversationCreationError.missingParticipants.localizedDescription
            case .invalidArgument:
                return "Please double-check the email addresses and try again."
            case .permissionDenied:
                return "You don’t have permission to create this conversation."
            default:
                break
            }
        }

        return "Unable to create conversation. Please try again."
    }

    private enum ConversationCreationError: LocalizedError {
        case missingParticipants

        var errorDescription: String? {
            switch self {
            case .missingParticipants:
                return "Add at least one other participant by email or user ID."
            }
        }
    }
}


