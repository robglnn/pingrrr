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
    @State private var selectedImageData: Data?
    @State private var isPresentingPreview = false

    var body: some View {
        NavigationStack {
            List {
                Section("Photos") {
                    PhotosPicker(
                        selection: $photoItems,
                        maxSelectionCount: 1,
                        matching: .images
                    ) {
                        HStack {
                            Image(systemName: "photo")
                            Text("Choose Photo")
                        }
                    }
                    .onChange(of: photoItems) { _, newItems in
                        guard let item = newItems.first else { return }
                        Task { await handlePhotoSelection(item) }
                    }
                }
            }
            .navigationTitle("Share")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onResult(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        if let data = selectedImageData {
                            onResult(.image(data))
                        } else {
                            onResult(.cancel)
                        }
                    }
                    .disabled(selectedImageData == nil)
                }
            }
            .sheet(isPresented: $isPresentingPreview) {
                NavigationStack {
                    VStack {
                        if let data = selectedImageData, let image = UIImage(data: data) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        } else {
                            Text("No Preview Available")
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .navigationTitle("Preview")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Back") { isPresentingPreview = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Send") {
                                if let data = selectedImageData {
                                    onResult(.image(data))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            onResult(.cancel)
            return
        }
        await MainActor.run {
            selectedImageData = data
            isPresentingPreview = true
        }
    }
}

