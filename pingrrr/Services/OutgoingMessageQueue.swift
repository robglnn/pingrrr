import Foundation
import SwiftData
import FirebaseFirestore

@MainActor
final class OutgoingMessageQueue {
    private let db = Firestore.firestore()
    private let networkMonitor: NetworkMonitor
    private var modelContext: ModelContext?
    private var networkListenerID: UUID?
    private var timer: Timer?
    private var isFlushing = false

    private let baseBackoff: TimeInterval = 2
    private let maxBackoff: TimeInterval = 60

    init(networkMonitor: NetworkMonitor) {
        self.networkMonitor = networkMonitor
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        networkListenerID = networkMonitor.addListener { [weak self] isReachable in
            Task { @MainActor in
                guard let self else { return }
                if isReachable {
                    self.triggerFlush()
                }
            }
        }

        scheduleTimerIfNeeded()
    }

    func reset() {
        timer?.invalidate()
        timer = nil

        if let listenerID = networkListenerID {
            networkMonitor.removeListener(listenerID)
        }
        networkListenerID = nil

        modelContext = nil
        isFlushing = false
    }

    func enqueueRetry(for message: MessageEntity, markFailed: Bool = true) {
        guard let modelContext else { return }

        if markFailed {
            message.status = .failed
        } else {
            message.status = .sending
        }

        message.isLocalOnly = true

        let cappedRetry = min(message.retryCount + 1, 5)
        message.retryCount = cappedRetry
        message.nextRetryTimestamp = Date().addingTimeInterval(backoffDelay(for: cappedRetry))

        do {
            try modelContext.save()
        } catch {
            print("[OutgoingQueue] Failed to persist retry state: \(error)")
        }

        scheduleTimerIfNeeded()
    }

    func triggerFlush() {
        scheduleTimerIfNeeded(force: true)
    }

    private func scheduleTimerIfNeeded(force: Bool = false) {
        guard let nextDate = nextPendingRetryDate() else {
            timer?.invalidate()
            timer = nil
            return
        }

        if let timer, !force {
            let remaining = timer.fireDate.timeIntervalSinceNow
            if remaining <= 1 { return }
        }

        let interval = max(nextDate.timeIntervalSinceNow, 0.5)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.flushQueue()
            }
        }
    }

    private func nextPendingRetryDate() -> Date? {
        guard let modelContext else { return nil }

        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate<MessageEntity> { entity in
                entity.isLocalOnly &&
                    (entity.statusRawValue == MessageStatus.failed.rawValue ||
                     entity.statusRawValue == MessageStatus.sending.rawValue)
            },
            sortBy: [SortDescriptor(\.nextRetryTimestamp, order: .forward)]
        )

        guard let messages = try? modelContext.fetch(descriptor) else { return nil }

        let now = Date()
        for message in messages {
            if let next = message.nextRetryTimestamp, next > now {
                return next
            }
        }

        return now
    }

    private func backoffDelay(for retryCount: Int) -> TimeInterval {
        let exponential = baseBackoff * pow(2, Double(retryCount - 1))
        return min(exponential, maxBackoff)
    }

    private func shouldAttemptSend(_ message: MessageEntity) -> Bool {
        guard networkMonitor.isReachable else { return false }

        if let nextRetryTimestamp = message.nextRetryTimestamp {
            return nextRetryTimestamp <= Date()
        }

        return true
    }

    private func markAsSent(_ message: MessageEntity) {
        message.status = .sent
        message.isLocalOnly = false
        message.retryCount = 0
        message.nextRetryTimestamp = nil
    }

    private func recordFailure(_ message: MessageEntity) {
        let cappedRetry = min(message.retryCount + 1, 5)
        message.retryCount = cappedRetry
        message.status = .failed
        message.nextRetryTimestamp = Date().addingTimeInterval(backoffDelay(for: cappedRetry))
    }

    private func pendingMessages() -> [MessageEntity] {
        guard let modelContext else { return [] }

        let descriptor = FetchDescriptor<MessageEntity>(
            predicate: #Predicate<MessageEntity> { entity in
                entity.isLocalOnly &&
                    (entity.statusRawValue == MessageStatus.sending.rawValue ||
                     entity.statusRawValue == MessageStatus.failed.rawValue)
            },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        return (try? modelContext.fetch(descriptor)) ?? []
    }

    private func createPayload(for message: MessageEntity) -> [String: Any] {
        [
            "id": message.id,
            "conversationID": message.conversationID,
            "senderID": message.senderID,
            "content": message.content,
            "translatedContent": message.translatedContent as Any,
            "timestamp": message.timestamp,
            "status": MessageStatus.sent.rawValue,
            "readBy": message.readBy
        ]
    }

    private func flushQueue() async {
        guard networkMonitor.isReachable else {
            timer?.invalidate()
            timer = nil
            return
        }

        guard !isFlushing else { return }
        guard let modelContext else { return }

        isFlushing = true
        defer {
            isFlushing = false
            scheduleTimerIfNeeded()
        }

        let messages = pendingMessages()
        guard !messages.isEmpty else { return }

        for message in messages where shouldAttemptSend(message) {
            await send(message: message, modelContext: modelContext)
        }

        do {
            try modelContext.save()
        } catch {
            print("[OutgoingQueue] Failed to save after flush: \(error)")
        }
    }

    private func send(message: MessageEntity, modelContext: ModelContext) async {
        let docRef = db.collection("conversations")
            .document(message.conversationID)
            .collection("messages")
            .document(message.id)

        do {
            try await docRef.setData(createPayload(for: message))
            markAsSent(message)
        } catch {
            print("[OutgoingQueue] Send failed: \(error)")
            recordFailure(message)
        }
    }
}



