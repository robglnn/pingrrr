import SwiftUI
import PhotosUI

struct MediaPickerSheet: View {
    enum Result {
        case image(Data)
        case cancel
    }

    var onResult: (Result) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            PhotosPicker(
                selection: $photoItems,
                maxSelectionCount: 1,
                matching: .images
            ) {
                VStack(spacing: 12) {
                    Image(systemName: "photo.stack")
                        .font(.system(size: 44, weight: .medium))
                    Text("Tap to pick a photo")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onResult(.cancel)
                        dismiss()
                    }
                }
            }
            .onChange(of: photoItems) { _, newItems in
                guard let item = newItems.first else { return }
                Task { await handlePhotoSelection(item) }
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run {
                onResult(.cancel)
                dismiss()
            }
            return
        }
        await MainActor.run {
            onResult(.image(data))
            photoItems = []
            dismiss()
        }
    }
}

