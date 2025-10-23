import SwiftUI
import SwiftData
import FirebaseFunctions

struct NewConversationSheet: View {
    @ObservedObject private var appServices: AppServices
    let onDismiss: (ConversationCreationResponse?, String?, String) -> Void

    @State private var conversationTitle: String = ""
    @State private var participantInput: String = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

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
                    TextField("Participant emails or IDs (comma separated)", text: $participantInput, axis: .vertical)
                        .lineLimit(1...4)

                    Text("Include at least one other participant. Enter either their email or user ID. Your account is automatically added.")
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

        let entries = participantInput
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

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
        participantInput = ""
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


