import SwiftUI

struct ReadReceiptsView: View {
    let message: MessageEntity
    let participants: [String: UserProfile]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Read by")
                .font(.headline)
                .padding(.bottom, 4)

            if readEntries.isEmpty {
                Text("No read receipts yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(readEntries, id: \.userID) { entry in
                    HStack(spacing: 12) {
                        AsyncProfileImageView(
                            userID: entry.userID,
                            displayName: entry.displayName,
                            photoURL: entry.photoURL,
                            photoVersion: entry.photoVersion,
                            size: .regular,
                            showsBorder: true
                        )
                        .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displayName)
                                .font(.body)
                            Text(entry.timestamp, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var readEntries: [ReadEntry] {
        guard !message.readBy.isEmpty else { return [] }

        let senderID = message.senderID

        return message.readBy
            .filter { $0 != senderID }
            .compactMap { userID in
                guard let profile = participants[userID] else { return nil }
                let readTimestamp = message.readTimestamps[userID] ?? message.timestamp
                return ReadEntry(
                    userID: userID,
                    displayName: profile.displayName,
                    photoURL: profile.profilePictureURL,
                    photoVersion: profile.photoVersion,
                    timestamp: readTimestamp
                )
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    struct ReadEntry {
        let userID: String
        let displayName: String
        let photoURL: String?
        let photoVersion: Int
        let timestamp: Date
    }
}
