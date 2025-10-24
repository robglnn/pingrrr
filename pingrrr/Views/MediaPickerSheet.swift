import SwiftUI
import PhotosUI

struct MediaPickerSheet: View {
    enum Result {
        case image(Data)
        case voice(Data)
        case cancel
    }

    var onResult: (Result) -> Void
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isRecordingVoice = false
    @State private var voiceData: Data?

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

                Section("Voice Message") {
                    Button {
                        // Placeholder voice recording action
                        if let sampleData = "placeholder voice".data(using: .utf8) {
                            onResult(.voice(sampleData))
                        } else {
                            onResult(.cancel)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "mic")
                            Text("Record Voice (placeholder)")
                        }
                    }
                }
            }
            .navigationTitle("Share")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onResult(.cancel) }
                }
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            onResult(.cancel)
            return
        }
        onResult(.image(data))
    }
}

