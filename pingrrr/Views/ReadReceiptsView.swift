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
                        OverlappingAvatarView(profiles: entry.profiles)

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

        return message.readBy.compactMap { userID in
            guard let profile = participants[userID] else { return nil }
            return ReadEntry(
                userID: userID,
                displayName: profile.displayName,
                timestamp: message.timestamp,
                profiles: [profile]
            )
        }
    }

    struct ReadEntry {
        let userID: String
        let displayName: String
        let timestamp: Date
        let profiles: [UserProfile]
    }
}

struct OverlappingAvatarView: View {
    let profiles: [UserProfile]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(profiles.enumerated()), id: \.offset) { index, profile in
                avatar(for: profile)
                    .offset(x: CGFloat(index) * 20)
            }
        }
        .frame(width: CGFloat(profiles.count) * 20 + 28)
    }

    private func avatar(for profile: UserProfile) -> some View {
        Group {
            if let urlString = profile.profilePictureURL,
               let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        placeholder(for: profile)
                    case .failure:
                        placeholder(for: profile)
                    @unknown default:
                        placeholder(for: profile)
                    }
                }
            } else {
                placeholder(for: profile)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.white.opacity(0.6), lineWidth: 1)
        )
    }

    private func placeholder(for profile: UserProfile) -> some View {
        Circle()
            .fill(Color.blue.opacity(0.2))
            .overlay(
                Text(profile.displayName.prefix(1).uppercased())
                    .font(.caption.bold())
                    .foregroundColor(.blue)
            )
    }
}
