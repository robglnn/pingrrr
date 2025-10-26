import SwiftUI

struct AsyncProfileImageView: View {
    let userID: String
    let displayName: String
    let photoURL: String?
    let photoVersion: Int
    let size: ProfileImageSize
    var showsBorder: Bool = false

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var currentTask: Task<Void, Never>?

    private var dimension: CGFloat { size.pixelDimension }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }

            if isLoading && image == nil {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        }
        .frame(width: dimension, height: dimension)
        .clipShape(Circle())
        .overlay(borderOverlay)
        .contentShape(Circle())
        .onAppear { loadIfNeeded() }
        .onChange(of: photoVersion) { _ in loadIfNeeded(force: true) }
        .onChange(of: photoURL) { _ in loadIfNeeded(force: true) }
        .onDisappear {
            currentTask?.cancel()
            currentTask = nil
        }
    }

    private var borderOverlay: some View {
        Group {
            if showsBorder {
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
            } else {
                EmptyView()
            }
        }
    }

    private var placeholder: some View {
        Circle()
            .fill(Color.blue.opacity(0.18))
            .overlay(
                Text(initials)
                    .font(.system(size: dimension * 0.4, weight: .bold))
                    .foregroundColor(.blue)
            )
    }

    private var initials: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let components = trimmed.split(separator: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1) + components[1].prefix(1)).uppercased()
        } else {
            return String(trimmed.prefix(1)).uppercased()
        }
    }

    private func loadIfNeeded(force: Bool = false) {
        guard let urlString = photoURL, let url = URL(string: urlString) else {
            image = nil
            isLoading = false
            currentTask?.cancel()
            currentTask = nil
            return
        }

        if !force, image != nil { return }

        currentTask?.cancel()
        isLoading = true

        currentTask = Task { @MainActor in
            do {
                let descriptor = ProfileImageCache.Descriptor(userID: userID, url: url, photoVersion: photoVersion)
                let fetched = try await ProfileImageCache.shared.image(for: descriptor, size: size)
                image = fetched
            } catch {
                image = nil
            }
            isLoading = false
        }
    }
}
