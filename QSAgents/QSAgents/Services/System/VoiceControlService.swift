import Foundation
import Speech
import AVFoundation
import Combine
import AppKit

/// Destinazione del riconoscimento vocale.
enum VoiceTarget: Equatable, Identifiable, Hashable {
    case orchestrator
    case terminal(UUID)

    var id: String {
        switch self {
        case .orchestrator: return "orchestrator"
        case .terminal(let id): return id.uuidString
        }
    }

    var label: String {
        switch self {
        case .orchestrator: return "Orchestratore (chat)"
        case .terminal: return "Terminale"
        }
    }
}

/// Speech-to-text macOS (Speech framework) + opzionale TTS risposte.
@MainActor
final class VoiceControlService: NSObject, ObservableObject {
    @Published var isListening: Bool = false
    /// Speech recognition TCC.
    @Published var isAuthorized: Bool = false
    /// Mic TCC (separate from Speech).
    @Published var microphoneAuthorized: Bool = false
    @Published var speechStatusLabel: String = "—"
    @Published var microphoneStatusLabel: String = "—"
    /// Combined ready flag for UI (both granted).
    @Published var bothPermissionsReady: Bool = false
    @Published var partialTranscript: String = ""
    @Published var finalTranscript: String = ""
    @Published var statusMessage: String = "Microfono pronto"
    @Published var errorMessage: String?
    @Published var target: VoiceTarget = .orchestrator
    @Published var autoSend: Bool = true
    @Published var speakReplies: Bool = false
    @Published var preferredLocale: String = "it-IT"
    /// Last diagnostic line for Permissions screen.
    @Published var diagnosticsLine: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private let synthesizer = AVSpeechSynthesizer()
    private var becomeActiveObserver: NSObjectProtocol?
    private var permissionRequestInFlight = false

    override init() {
        super.init()
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredLocale))
        // Read status only — do NOT prompt at launch.
        refreshAllPermissions()
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAllPermissions()
            }
        }
    }

    deinit {
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    // MARK: - Permissions (status)

    private func applyAuthStatus(_ status: SFSpeechRecognizerAuthorizationStatus) {
        switch status {
        case .authorized:
            isAuthorized = true
            speechStatusLabel = "Consentito"
        case .denied:
            isAuthorized = false
            speechStatusLabel = "Negato — apri Impostazioni Sistema e attiva QS Agents"
        case .restricted:
            isAuthorized = false
            speechStatusLabel = "Limitato dal sistema (MDM / Screen Time)"
        case .notDetermined:
            isAuthorized = false
            speechStatusLabel = "Non richiesto — premi «Richiedi» o usa 🎤"
        @unknown default:
            isAuthorized = false
            speechStatusLabel = "Sconosciuto (\(status.rawValue))"
        }
        updateCombinedStatus()
    }

    /// Prefer AVAudioApplication (macOS 14+) but also probe AVCaptureDevice —
    /// some builds only update one of the two TCC paths.
    private func applyMicrophoneStatus() {
        var granted = false
        var label = "Sconosciuto"
        var parts: [String] = []

        if #available(macOS 14.0, *) {
            let p = AVAudioApplication.shared.recordPermission
            parts.append("AVAudioApp=\(micPermName(p))")
            switch p {
            case .granted:
                granted = true
                label = "Consentito"
            case .denied:
                label = "Negato — riabilita in Impostazioni → Privacy → Microfono"
            case .undetermined:
                label = "Non richiesto — premi «Richiedi» o usa 🎤"
            @unknown default:
                label = "Sconosciuto"
            }
        }

        // Cross-check with CaptureDevice (still used by many macOS audio stacks)
        let cap = AVCaptureDevice.authorizationStatus(for: .audio)
        parts.append("AVCapture=\(captureName(cap))")
        switch cap {
        case .authorized:
            granted = true
            if label != "Consentito" { label = "Consentito (via Capture)" }
        case .denied:
            if !granted {
                label = "Negato — riabilita in Impostazioni → Privacy → Microfono"
            }
        case .restricted:
            if !granted {
                label = "Limitato dal sistema"
            }
        case .notDetermined:
            if !granted && label == "Sconosciuto" {
                label = "Non richiesto — premi «Richiedi» o usa 🎤"
            }
        @unknown default:
            break
        }

        microphoneAuthorized = granted
        microphoneStatusLabel = label
        diagnosticsLine = parts.joined(separator: " · ")
            + " · speech=\(speechRawName(SFSpeechRecognizer.authorizationStatus()))"
            + " · bundle=com.qsagents.mac"
        updateCombinedStatus()
    }

    private func updateCombinedStatus() {
        bothPermissionsReady = isAuthorized && microphoneAuthorized
        if bothPermissionsReady {
            statusMessage = "Microfono + speech pronti"
        } else if !microphoneAuthorized && !isAuthorized {
            statusMessage = "Servono Microfono e Riconoscimento vocale"
        } else if !microphoneAuthorized {
            statusMessage = "Manca permesso Microfono"
        } else {
            statusMessage = "Manca permesso Riconoscimento vocale"
        }
    }

    private func micPermName(_ p: AVAudioApplication.recordPermission) -> String {
        switch p {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown"
        }
    }

    private func captureName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func speechRawName(_ s: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    func refreshAuthorization() {
        refreshAllPermissions()
    }

    func refreshAllPermissions() {
        applyAuthStatus(SFSpeechRecognizer.authorizationStatus())
        applyMicrophoneStatus()
    }

    // MARK: - Permission requests (async, wait for dialog)

    /// Request both permissions; waits for system dialogs. Returns true if both granted.
    @discardableResult
    func ensurePermissions() async -> Bool {
        if permissionRequestInFlight {
            // Avoid double dialogs
            try? await Task.sleep(nanoseconds: 300_000_000)
            refreshAllPermissions()
            return bothPermissionsReady
        }
        permissionRequestInFlight = true
        defer { permissionRequestInFlight = false }

        // 1) Speech
        let speechOK = await requestSpeechAuthorization()
        // 2) Microphone
        let micOK = await requestMicrophoneAuthorization()

        refreshAllPermissions()

        if speechOK && micOK {
            errorMessage = nil
            statusMessage = "Permessi OK — puoi parlare"
            return true
        }

        var missing: [String] = []
        if !micOK { missing.append("Microfono") }
        if !speechOK { missing.append("Riconoscimento vocale") }
        errorMessage = "Permesso negato o non concesso: \(missing.joined(separator: " + ")). Abilita in Impostazioni Sistema → Privacy."
        statusMessage = "Autorizzazioni mancanti"
        return false
    }

    /// Fire-and-forget from UI buttons (permissions screen).
    func requestPermissionsIfNeeded() {
        Task { @MainActor in
            _ = await ensurePermissions()
        }
    }

    func requestMicrophoneIfNeeded() {
        Task { @MainActor in
            _ = await requestMicrophoneAuthorization()
            applyMicrophoneStatus()
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted {
            applyAuthStatus(current)
            return false
        }
        // notDetermined → system dialog
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        applyAuthStatus(status)
        return status == .authorized
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        // Already granted via either API?
        applyMicrophoneStatus()
        if microphoneAuthorized { return true }

        if #available(macOS 14.0, *) {
            let perm = AVAudioApplication.shared.recordPermission
            if perm == .granted { return true }
            if perm == .denied {
                applyMicrophoneStatus()
                return false
            }
            // undetermined
            let granted: Bool = await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
            // Also try Capture path if still not granted (some stacks need both)
            if !granted {
                let cap = AVCaptureDevice.authorizationStatus(for: .audio)
                if cap == .notDetermined {
                    let capGranted: Bool = await withCheckedContinuation { cont in
                        AVCaptureDevice.requestAccess(for: .audio) { ok in
                            cont.resume(returning: ok)
                        }
                    }
                    applyMicrophoneStatus()
                    return capGranted || microphoneAuthorized
                }
            }
            applyMicrophoneStatus()
            return granted || microphoneAuthorized
        } else {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized { return true }
            if status == .denied || status == .restricted {
                applyMicrophoneStatus()
                return false
            }
            let granted: Bool = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    cont.resume(returning: ok)
                }
            }
            applyMicrophoneStatus()
            return granted
        }
    }

    // MARK: - System Settings deep links

    func openSystemMicrophoneSettings() {
        openPrivacyURLs([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ])
    }

    func openSystemSpeechSettings() {
        openPrivacyURLs([
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_SpeechRecognition",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ])
    }

    func openSystemPrivacySettings() {
        openPrivacyURLs([
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ])
    }

    private func openPrivacyURLs(_ candidates: [String]) {
        for s in candidates {
            if let url = URL(string: s), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Listen

    func toggleListening() {
        if isListening {
            stopListening(commit: true)
        } else {
            startListening()
        }
    }

    /// Public entry: ensures permissions first, then starts engine.
    func startListening() {
        errorMessage = nil
        statusMessage = "Verifica permessi…"
        Task { @MainActor in
            let ok = await ensurePermissions()
            guard ok else {
                // If denied, open the right Settings pane after a beat
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !self.microphoneAuthorized {
                    self.openSystemMicrophoneSettings()
                } else if !self.isAuthorized {
                    self.openSystemSpeechSettings()
                }
                return
            }
            self.beginListeningEngine()
        }
    }

    private func beginListeningEngine() {
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: preferredLocale))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()

        guard let speechRecognizer else {
            errorMessage = "SFSpeechRecognizer non disponibile su questo Mac"
            statusMessage = "Speech non disponibile"
            return
        }
        if !speechRecognizer.isAvailable {
            // Still try — on-device may flip; warn but continue if authorized
            statusMessage = "Speech offline limitato — provo comunque…"
        }

        // Tear down any previous session cleanly
        if isListening || audioEngine.isRunning {
            _ = stopListening(commit: false)
        } else {
            cleanupEngine()
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13.0, *) {
            // Prefer on-device when available; if false, allow network speech
            request.requiresOnDeviceRecognition = false
            if speechRecognizer.supportsOnDeviceRecognition {
                // Keep flexible: don't force on-device only (often fails for it-IT)
                request.requiresOnDeviceRecognition = false
            }
        }
        request.taskHint = .dictation
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)

        // CRITICAL: use inputFormat, not outputFormat (output often 0 Hz before start)
        var format = inputNode.inputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            // Fallback: try output format after prepare
            audioEngine.prepare()
            format = inputNode.inputFormat(forBus: 0)
        }
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = inputNode.outputFormat(forBus: 0)
        }
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = """
            Nessun microfono attivo (sampleRate=0).
            Controlla: Impostazioni → Suono → Input, e che QS Agents sia ON in Privacy → Microfono.
            \(diagnosticsLine)
            """
            statusMessage = "Microfono assente / non autorizzato"
            cleanupEngine()
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    self.partialTranscript = text
                    if result.isFinal {
                        self.finalTranscript = text
                    }
                }
                if let error {
                    let ns = error as NSError
                    // 216 = cancelled; 203 = no speech; 1110 = retry
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 216 || ns.code == 1110) {
                        return
                    }
                    if self.isListening {
                        // Soft errors: keep listening if we already have partial text
                        if self.partialTranscript.isEmpty {
                            self.errorMessage = "Speech: \(error.localizedDescription)"
                            self.statusMessage = "Errore speech"
                            self.stopListening(commit: false)
                        }
                    }
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            partialTranscript = ""
            finalTranscript = ""
            statusMessage = target == .orchestrator
                ? "Ti ascolto → Orchestratore… (\(Int(format.sampleRate)) Hz)"
                : "Ti ascolto → Terminale… (\(Int(format.sampleRate)) Hz)"
            AppLogger.info("Voice listening started · \(format.sampleRate) Hz · \(format.channelCount) ch")
        } catch {
            errorMessage = "Impossibile avviare microfono: \(error.localizedDescription). \(diagnosticsLine)"
            statusMessage = "Mic error"
            cleanupEngine()
            AppLogger.error("Voice engine start failed: \(error.localizedDescription)")
        }
    }

    /// Stops mic. If commit, returns the best transcript via callback-style properties.
    @discardableResult
    func stopListening(commit: Bool) -> String {
        let text = (finalTranscript.isEmpty ? partialTranscript : finalTranscript)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        recognitionRequest?.endAudio()
        cleanupEngine()

        isListening = false
        if commit, !text.isEmpty {
            finalTranscript = text
            statusMessage = "Trascrizione pronta"
        } else if !commit {
            statusMessage = bothPermissionsReady ? "In ascolto interrotto" : statusMessage
        } else {
            statusMessage = "Nessuna parlata rilevata"
        }
        return commit ? text : ""
    }

    private func cleanupEngine() {
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    /// Quick hardware + permission probe for Settings UI.
    func runMicProbe() {
        Task { @MainActor in
            refreshAllPermissions()
            let ok = await ensurePermissions()
            guard ok else {
                self.statusMessage = "Probe fallito — permessi"
                return
            }
            let node = self.audioEngine.inputNode
            self.audioEngine.prepare()
            let fmt = node.inputFormat(forBus: 0)
            if fmt.sampleRate > 0 {
                self.statusMessage = "Probe OK · \(Int(fmt.sampleRate)) Hz · \(fmt.channelCount) ch"
                self.errorMessage = nil
                self.diagnosticsLine += " · probeOK"
            } else {
                self.errorMessage = "Probe: microfono non espone format (sampleRate=0). Verifica input di sistema e permesso Microfono per com.qsagents.mac"
                self.statusMessage = "Probe fallito — hardware/TCC"
            }
        }
    }

    // MARK: - TTS

    func speak(_ text: String) {
        guard speakReplies else { return }
        let clean = text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
        let utterance = AVSpeechUtterance(string: String(clean.prefix(500)))
        utterance.voice = AVSpeechSynthesisVoice(language: preferredLocale)
            ?? AVSpeechSynthesisVoice(language: "it-IT")
            ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
