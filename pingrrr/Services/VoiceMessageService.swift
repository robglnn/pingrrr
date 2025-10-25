import Foundation
import Combine
import AVFoundation
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class VoiceMessageService: NSObject, ObservableObject {
    struct RecordingResult {
        let url: URL
        let duration: TimeInterval
    }

    enum VoiceError: LocalizedError {
        case permissionDenied
        case recordingInProgress
        case recordingNotStarted
        case failedToStart
        case unableToCreateRecorder
        case unknown

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone access is required to record voice messages."
            case .recordingInProgress:
                return "Recording already in progress."
            case .recordingNotStarted:
                return "No recording in progress."
            case .failedToStart:
                return "Failed to start recording."
            case .unableToCreateRecorder:
                return "Unable to configure microphone."
            case .unknown:
                return "An unknown audio error occurred."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var hasShownAutoDeleteWarning = false

    let maxDuration: TimeInterval = 30

    private var audioRecorder: AVAudioRecorder?
    private var durationTimer: Timer?
    private let session = AVAudioSession.sharedInstance()
    private var didReachMaxDuration = false
    var onAutoStop: (() -> Void)?

    private let db = Firestore.firestore()
    private let autoDeleteWarningKey = "com.pingrrr.voice.autoDeleteWarning"

    private var isLoadingWarningState = false
    private var authListener: AuthStateDidChangeListenerHandle?

    override init() {
        super.init()
        subscribeToAuthChanges()
        Task { await loadWarningState(force: true) }
    }

    deinit {
        if let authListener {
            Auth.auth().removeStateDidChangeListener(authListener)
        }
    }

    func startRecording() async throws {
        guard !isRecording else { throw VoiceError.recordingInProgress }

        let permissionGranted = await requestPermission()
        guard permissionGranted else { throw VoiceError.permissionDenied }

        try configureSession()

        await ensureWarningDisplayed()

        let url = makeRecordingURL()
        let recorder = try AVAudioRecorder(url: url, settings: recordingSettings())
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.record() else { throw VoiceError.failedToStart }

        audioRecorder = recorder
        recordingDuration = 0
        isRecording = true
        didReachMaxDuration = false
        lastRecordingURL = url

        startTimer()
    }

    func stopRecording() async throws -> RecordingResult {
        guard let recorder = audioRecorder else {
            if let url = lastRecordingURL {
                let duration = recordingDuration
                resetSession()
                return RecordingResult(url: url, duration: duration)
            }
            throw VoiceError.recordingNotStarted
        }

        recorder.stop()
        durationTimer?.invalidate()
        durationTimer = nil

        let duration = recordingDuration
        resetSession()

        return RecordingResult(url: recorder.url, duration: duration)
    }

    func cancelRecording() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioRecorder?.stop()
        if let url = audioRecorder?.url ?? lastRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioRecorder = nil
        recordingDuration = 0
        isRecording = false
        lastRecordingURL = nil
        didReachMaxDuration = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted {
                return true
            }
            let granted = await AVAudioApplication.requestRecordPermission()
            if granted {
                await ensureWarningDisplayed()
            }
            return granted
        } else {
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted {
                await ensureWarningDisplayed()
            }
            return granted
        }
    }

    private func configureSession() throws {
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func resetSession() {
        audioRecorder = nil
        isRecording = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        durationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let recorder = self.audioRecorder else {
                    self.durationTimer?.invalidate()
                    self.durationTimer = nil
                    return
                }

                recorder.updateMeters()
                self.recordingDuration = recorder.currentTime

                if recorder.currentTime >= self.maxDuration {
                    self.didReachMaxDuration = true
                    recorder.stop()
                }
            }
        }
        durationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func makeRecordingURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "voice_\(UUID().uuidString).m4a"
        return tempDir.appendingPathComponent(filename)
    }

    private func recordingSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }
}

extension VoiceMessageService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            self.durationTimer?.invalidate()
            self.durationTimer = nil
            if flag {
                self.recordingDuration = recorder.currentTime
                self.lastRecordingURL = recorder.url
            } else if let url = recorder.url as URL? {
                try? FileManager.default.removeItem(at: url)
                self.lastRecordingURL = nil
            }
            self.audioRecorder = nil
            self.isRecording = false
            try? self.session.setActive(false, options: .notifyOthersOnDeactivation)
            if self.didReachMaxDuration {
                self.didReachMaxDuration = false
                self.onAutoStop?()
            }
        }
    }
}

private extension VoiceMessageService {
    func subscribeToAuthChanges() {
        authListener = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            Task { await self?.loadWarningState(force: true) }
        }
    }

    func loadWarningState(force: Bool = false) async {
        if isLoadingWarningState && !force { return }
        isLoadingWarningState = true
        defer { isLoadingWarningState = false }

        if let userID = Auth.auth().currentUser?.uid {
            if !force, let cached = UserDefaults.standard.object(forKey: autoDeleteWarningKey + "." + userID) as? Bool {
                hasShownAutoDeleteWarning = cached
                return
            }
            do {
                let snapshot = try await db.collection("users").document(userID).getDocument()
                let remoteFlag = snapshot.data()? ["voiceWarningDismissed"] as? Bool ?? false
                hasShownAutoDeleteWarning = remoteFlag
                UserDefaults.standard.set(remoteFlag, forKey: autoDeleteWarningKey + "." + userID)
            } catch {
                print("[VoiceMessageService] Failed to load warning state: \(error)")
                hasShownAutoDeleteWarning = UserDefaults.standard.bool(forKey: autoDeleteWarningKey)
            }
        } else {
            hasShownAutoDeleteWarning = UserDefaults.standard.bool(forKey: autoDeleteWarningKey)
        }
    }

    func ensureWarningDisplayed() async {
        if !hasShownAutoDeleteWarning {
            await loadWarningState()
        }
        guard !hasShownAutoDeleteWarning else { return }
        await markWarningShown()
    }

    func markWarningShown() async {
        guard !hasShownAutoDeleteWarning else { return }
        hasShownAutoDeleteWarning = true

        if let userID = Auth.auth().currentUser?.uid {
            UserDefaults.standard.set(true, forKey: autoDeleteWarningKey + "." + userID)
            do {
                try await db.collection("users").document(userID).setData([
                    "voiceWarningDismissed": true,
                    "updatedAt": FieldValue.serverTimestamp()
                ], merge: true)
            } catch {
                print("[VoiceMessageService] Failed to persist warning flag: \(error)")
            }
        } else {
            UserDefaults.standard.set(true, forKey: autoDeleteWarningKey)
        }

        NotificationCenter.default.post(name: .voiceMessageDidRequireWarning, object: nil)
    }
}
