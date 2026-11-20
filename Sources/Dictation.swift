import Foundation
import Observation
import Speech
import AVFoundation

/// Box to pass a non-`Sendable` object (audio request) to the real-time capture thread.
private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

/// Voice dictation on the Mac: microphone (AVAudioEngine) → recognition (Speech) → text sent live to the TV.
/// Recognition is on-device only: if the language has no offline model, dictation does not start.
@MainActor
@Observable
final class Dictation {
    var isListening = false

    /// Called on every partial result (updates the local field).
    @ObservationIgnored var onText: ((String) -> Void)?
    /// Called to send the text to the TV (at most one send every 300 ms, plus the final send).
    @ObservationIgnored var onSend: ((String) -> Void)?
    /// Error or permission-denied message, shown in the remote's footer.
    @ObservationIgnored var onProblem: ((String) -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var latest = ""
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var lastSend = Date.distantPast

    private static let sendInterval = 0.3
    private static let silenceDelay = 2.0
    private static let startGrace = 5.0     // delay before the first words

    func toggle() {
        if isListening { stop() } else { Task { await start() } }
    }

    // MARK: start

    private func start() async {
        guard !isListening, !starting else { return }
        starting = true
        defer { starting = false }
        guard await authorize() else { return }
        let language = Locale.preferredLanguages.first ?? "en-US"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            onProblem?(String(localized: "Speech recognition is currently unavailable."))
            return
        }
        // Never fall back silently to server-side recognition: audio would leave the Mac.
        guard recognizer.supportsOnDeviceRecognition else {
            let name = Locale.current.localizedString(forIdentifier: recognizer.locale.identifier) ?? recognizer.locale.identifier
            onProblem?(String(localized: "Offline dictation is not available for \(name). Enable it in System Settings → Keyboard → Dictation, then download the language."))
            return
        }
        guard AVCaptureDevice.default(for: .audio) != nil else {
            onProblem?(String(localized: "No microphone detected on this Mac."))
            return
        }

        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            onProblem?(String(localized: "No usable microphone on this Mac."))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        session += 1
        let id = session
        latest = ""
        lastSend = .distantPast
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(id: id, owner: self))
        Self.installTap(on: engine, format: format, request: request)
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            task?.cancel(); task = nil
            onProblem?(String(localized: "Microphone inaccessible: \(error.localizedDescription)"))
            return
        }
        self.engine = engine
        self.request = request
        isListening = true
        armSilence(after: Self.startGrace)
    }

    /// The audio tap runs on a real-time thread: it must be created outside the main actor.
    private nonisolated static func installTap(on engine: AVAudioEngine, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        let box = UncheckedBox(value: request)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.value.append(buffer)
        }
    }

    /// Speech's handler arrives on an arbitrary queue: we only keep `Sendable` values before hopping back.
    private nonisolated static func resultHandler(id: Int, owner: Dictation) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        let box = UncheckedBox(value: owner)
        return { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in box.value.handle(id: id, text: text, final: final, failed: failed) }
        }
    }

    // MARK: permissions

    private func authorize() async -> Bool {
        let speech = await Self.requestSpeechAuthorization()
        guard speech == .authorized else {
            onProblem?(String(localized: "Speech recognition denied. Allow it in System Settings → Privacy & Security → Speech Recognition."))
            return false
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            onProblem?(String(localized: "Microphone denied. Allow it in System Settings → Privacy & Security → Microphone."))
            return false
        }
        return true
    }

    /// TCC calls back on an arbitrary queue: the closure must not inherit @MainActor isolation,
    /// otherwise Swift 6 kills the app (dispatch_assert_queue) as soon as the permission prompt is answered.
    private nonisolated static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
    }

    // MARK: results

    private func handle(id: Int, text: String?, final: Bool, failed: Bool) {
        guard id == session, isListening else { return }
        if let text, !text.isEmpty {
            latest = text
            onText?(text)
            scheduleSend(text)
            armSilence(after: Self.silenceDelay)
        }
        if final || failed { stop() }
    }

    private func scheduleSend(_ text: String) {
        let wait = Self.sendInterval - Date().timeIntervalSince(lastSend)
        if wait <= 0 { sendNow(text); return }
        guard sendTask == nil else { return }   // a deferred send is already scheduled: it will pick up the latest text
        sendTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled else { return }
            self.sendTask = nil
            self.sendNow(self.latest)
        }
    }

    private func sendNow(_ text: String) {
        lastSend = Date()
        onSend?(text)
    }

    private func armSilence(after seconds: Double) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.stop() }
        }
    }

    // MARK: stop

    /// Stops listening. `sendFinal` sends the last recognized text to the TV (without pressing Enter).
    func stop(sendFinal: Bool = true) {
        guard isListening else { return }
        isListening = false
        session += 1
        silenceTask?.cancel(); silenceTask = nil
        sendTask?.cancel(); sendTask = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        if sendFinal, !latest.isEmpty { sendNow(latest) }
        latest = ""
    }
}
