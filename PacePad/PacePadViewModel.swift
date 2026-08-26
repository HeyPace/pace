import Combine
import SwiftUI
import UIKit

@MainActor
final class PacePadViewModel: ObservableObject {
    enum CompanionState: Equatable {
        case disconnected
        case idle
        case listening
        case transcribing
        case processing(usesOffDevicePlanner: Bool)
        case speaking(usesOffDevicePlanner: Bool)
        case proactive
        case paused
        case sleeping
    }

    struct RecoverableIssue: Equatable {
        enum Action: Equatable {
            case openSettings
            case retryConnection
            case retryCamera
            case retryVoiceTurn
        }

        let message: String
        let action: Action?

        var actionTitle: String? {
            switch action {
            case .openSettings: "Open Settings"
            case .retryConnection: "Try again"
            case .retryCamera: "Try camera again"
            case .retryVoiceTurn: "Try talking again"
            case nil: nil
            }
        }
    }

    @Published private(set) var companionState: CompanionState = .disconnected {
        didSet {
            guard companionState != oldValue else { return }
            updateAmbientIdlePolicy()
        }
    }
    @Published private(set) var connectionStatusText = "Looking for Pace on your Mac"
    @Published private(set) var discoveredMacName: String?
    @Published private(set) var currentMessageText: String?
    @Published var pairingCode = ""
    @Published var isMicrophoneEnabled = true
    @Published var isCameraEnabled = true
    @Published var isSpeakerMuted = false
    @Published var isAllCapturePaused = false
    @Published var isNightModeEnabled = false
    @Published var brightness = 0.7
    @Published var showsControls = false
    @Published private(set) var isAmbientIdleDimmed = false
    @Published private(set) var isPairingPanelDismissed = false
    @Published private(set) var recoverableIssue: RecoverableIssue?

    let client = PacePadClient()
    let audioRecorder = PacePadAudioRecorder()
    let cameraService = PacePadCameraService()
    let speechPlayer = PacePadSpeechPlayer()

    private var activeTurnIdentifier: String?
    private var ambientIdleTask: Task<Void, Never>?
    private var brightnessBeforeNightMode: CGFloat?
    private var brightnessManagedScreen: UIScreen?
    private var dismissedTurnIdentifiers: Set<String> = []
    private var controlsAutoHideTask: Task<Void, Never>?
    private var proactiveAnimationTask: Task<Void, Never>?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasObservedClientStatus = false
    private var hasRequestedCapturePermissions = false
    private var subscriptions: Set<AnyCancellable> = []

    init() {
        client.onMessage = { [weak self] payload in
            self?.handle(payload)
        }
        client.onCameraFrameRequested = { [weak self] request in
            self?.handleCameraFrameRequest(request)
        }
        cameraService.onStablePresenceChanged = { [weak self] isPresent, confidence, observedAt in
            guard let self else { return }
            guard reportedPrivacyState.permitsCameraMedia else { return }
            if isPresent {
                registerUserActivity()
            }
            client.sendPresenceChange(
                isUserPresent: isPresent,
                confidence: confidence,
                observedAt: observedAt
            )
        }
        speechPlayer.onSpeechFinished = { [weak self] in
            guard let self, !isAllCapturePaused, !isNightModeEnabled else { return }
            companionState = .idle
        }
        Publishers.Merge(audioRecorder.objectWillChange, cameraService.objectWillChange)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &subscriptions)
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        UIApplication.shared.isIdleTimerDisabled = true
        if let activeScreen {
            if isNightModeEnabled {
                brightnessManagedScreen = activeScreen
                brightnessBeforeNightMode = brightnessBeforeNightMode ?? activeScreen.brightness
                activeScreen.brightness = 0.03
            } else {
                brightness = Double(activeScreen.brightness)
            }
        }
        observeClientStatus()
        client.start()
        sendPrivacyState()
    }

    func stop() {
        guard hasStarted else { return }
        hasStarted = false
        UIApplication.shared.isIdleTimerDisabled = false
        if isNightModeEnabled, let brightnessBeforeNightMode {
            brightnessManagedScreen?.brightness = brightnessBeforeNightMode
        }
        abandonActiveVoiceTurn()
        cameraService.pause()
        speechPlayer.stop()
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = nil
        ambientIdleTask?.cancel()
        ambientIdleTask = nil
        isAmbientIdleDimmed = false
        proactiveAnimationTask?.cancel()
        proactiveAnimationTask = nil
        client.stop()
    }

    func pair() {
        recoverableIssue = nil
        client.pair(using: pairingCode)
    }

    func dismissPairingPanel() {
        isPairingPanelDismissed = true
    }

    func showPairingPanel() {
        isPairingPanelDismissed = false
    }

    func retryConnection() {
        recoverableIssue = nil
        client.retryDiscovery()
    }

    func toggleControls() {
        registerUserActivity()
        showsControls.toggle()
        if showsControls {
            scheduleControlsAutoHide()
        } else {
            controlsAutoHideTask?.cancel()
            controlsAutoHideTask = nil
            updateAmbientIdlePolicy()
        }
    }

    func pairAgain() {
        recoverableIssue = nil
        pairingCode = ""
        isPairingPanelDismissed = false
        client.forgetStalePairing()
    }

    func normalizePairingCodeInput() {
        let normalizedDigits = pairingCode.filter(\.isNumber).prefix(6)
        pairingCode = String(normalizedDigits)
    }

    func handleFaceTapped() {
        guard !isAllCapturePaused, !isNightModeEnabled else { return }
        guard case .connected = client.status else { return }
        if isAmbientIdleDimmed {
            registerUserActivity()
            announceForAccessibility("Pace is awake")
            return
        }
        registerUserActivity()
        if audioRecorder.isRecording {
            finishVoiceTurn()
            return
        }
        switch companionState {
        case .speaking, .proactive:
            stopCurrentResponse()
            return
        case .transcribing, .processing:
            dismissPendingTurn()
            return
        case .idle:
            break
        case .disconnected, .listening, .paused, .sleeping:
            return
        }
        guard isMicrophoneEnabled, audioRecorder.microphonePermissionIsGranted else {
            presentRecoverableIssue(
                message: "Microphone access is off. Allow it in Settings to talk to Pace.",
                action: .openSettings
            )
            return
        }
        do {
            speechPlayer.stop()
            recoverableIssue = nil
            activeTurnIdentifier = UUID().uuidString
            try audioRecorder.startRecording()
            scheduleRecordingTimeout(forTurnIdentifier: activeTurnIdentifier)
            companionState = .listening
            currentMessageText = nil
            sendPrivacyState()
        } catch {
            audioRecorder.cancelRecording()
            activeTurnIdentifier = nil
            presentRecoverableIssue(
                message: "Pace couldn’t start the iPad microphone.",
                action: .retryVoiceTurn
            )
        }
    }

    func toggleAllCapturePaused() {
        registerUserActivity()
        isAllCapturePaused.toggle()
        if isAllCapturePaused {
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            abandonActiveVoiceTurn()
            cameraService.pause()
            speechPlayer.stop()
            companionState = .paused
        } else {
            companionState = connectionIsReady ? .idle : .disconnected
            Task { @MainActor [weak self] in
                guard let self, isCameraEnabled else { return }
                await cameraService.requestPermissionAndStart()
                sendPrivacyState()
            }
        }
        sendPrivacyState()
    }

    func toggleMicrophone() {
        registerUserActivity()
        scheduleControlsAutoHide()
        guard audioRecorder.microphonePermissionIsGranted else {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await audioRecorder.requestPermission()
                isMicrophoneEnabled = audioRecorder.microphonePermissionIsGranted
                if !audioRecorder.microphonePermissionIsGranted {
                    presentRecoverableIssue(
                        message: "Microphone access is off. Allow it in Settings to talk to Pace.",
                        action: .openSettings
                    )
                }
                sendPrivacyState()
            }
            return
        }
        isMicrophoneEnabled.toggle()
        if !isMicrophoneEnabled {
            abandonActiveVoiceTurn()
            if companionState == .listening {
                companionState = connectionIsReady ? .idle : .disconnected
            }
        }
        sendPrivacyState()
    }

    func toggleCamera() {
        registerUserActivity()
        scheduleControlsAutoHide()
        guard cameraService.cameraPermissionIsGranted else {
            isCameraEnabled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateCameraOrientation()
                await cameraService.requestPermissionAndStart()
                if cameraService.lastErrorText != nil {
                    presentCameraRecoveryIssue()
                    isCameraEnabled = false
                }
                sendPrivacyState()
            }
            return
        }
        isCameraEnabled.toggle()
        if isCameraEnabled, !isAllCapturePaused {
            Task { @MainActor [weak self] in
                await self?.cameraService.requestPermissionAndStart()
                self?.sendPrivacyState()
            }
        } else {
            cameraService.pause()
            sendPrivacyState()
        }
    }

    func toggleSpeakerMute() {
        registerUserActivity()
        scheduleControlsAutoHide()
        isSpeakerMuted.toggle()
        if isSpeakerMuted {
            speechPlayer.stop()
            if case .speaking = companionState {
                companionState = .idle
            }
        }
        sendPrivacyState()
    }

    func toggleNightMode() {
        registerUserActivity()
        isNightModeEnabled.toggle()
        if isNightModeEnabled {
            controlsAutoHideTask?.cancel()
            controlsAutoHideTask = nil
            showsControls = false
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            abandonActiveVoiceTurn()
            cameraService.pause()
            speechPlayer.stop()
            companionState = .sleeping
            if let activeScreen {
                brightnessManagedScreen = activeScreen
                brightnessBeforeNightMode = activeScreen.brightness
                activeScreen.brightness = 0.03
            }
        } else {
            let restoredBrightness = brightnessBeforeNightMode ?? CGFloat(brightness)
            (brightnessManagedScreen ?? activeScreen)?.brightness = restoredBrightness
            brightness = Double(restoredBrightness)
            brightnessBeforeNightMode = nil
            brightnessManagedScreen = nil
            companionState = connectionIsReady ? .idle : .disconnected
            if isCameraEnabled, !isAllCapturePaused {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await cameraService.requestPermissionAndStart()
                    sendPrivacyState()
                }
            }
        }
        sendPrivacyState()
    }

    func updateBrightness() {
        guard !isNightModeEnabled else { return }
        registerUserActivity()
        scheduleControlsAutoHide()
        activeScreen?.brightness = brightness
    }

    func updateCameraOrientation() {
        guard
            let interfaceOrientation = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .effectiveGeometry.interfaceOrientation
        else {
            return
        }
        cameraService.updateImageOrientation(interfaceOrientation)
    }

    func unpair() {
        client.unpair()
        pairingCode = ""
        isPairingPanelDismissed = false
    }

    var canUseFaceInteraction: Bool {
        guard connectionIsReady, !isAllCapturePaused, !isNightModeEnabled else { return false }
        return switch companionState {
        case .idle, .listening, .transcribing, .processing, .speaking, .proactive:
            true
        case .disconnected, .paused, .sleeping:
            false
        }
    }

    func performRecoveryAction() {
        guard let recoveryAction = recoverableIssue?.action else { return }
        registerUserActivity()
        switch recoveryAction {
        case .openSettings:
            guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(settingsURL)
        case .retryConnection:
            retryConnection()
        case .retryCamera:
            recoverableIssue = nil
            isCameraEnabled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                updateCameraOrientation()
                await cameraService.requestPermissionAndStart()
                if cameraService.lastErrorText != nil {
                    presentCameraRecoveryIssue()
                    isCameraEnabled = false
                }
                sendPrivacyState()
            }
        case .retryVoiceTurn:
            recoverableIssue = nil
            companionState = connectionIsReady ? .idle : .disconnected
        }
    }

    private func observeClientStatus() {
        guard !hasObservedClientStatus else { return }
        hasObservedClientStatus = true
        client.$status
            .sink { [weak self] status in
                self?.accept(status)
            }
            .store(in: &subscriptions)
    }

    private var connectionIsReady: Bool {
        if case .connected = client.status { return true }
        return false
    }

    private var activeScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .screen
    }

    private func accept(_ status: PacePadClient.Status) {
        switch status {
        case .discovering:
            abandonActiveVoiceTurn()
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            connectionStatusText = "Looking for Pace on your Mac"
            discoveredMacName = nil
            if !isAllCapturePaused, !isNightModeEnabled {
                companionState = .disconnected
            }
        case .pairingAvailable(let macName):
            abandonActiveVoiceTurn()
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            connectionStatusText = "Pair with \(macName)"
            discoveredMacName = macName
            isPairingPanelDismissed = false
            if !isAllCapturePaused, !isNightModeEnabled {
                companionState = .disconnected
            }
        case .connecting(let macName):
            abandonActiveVoiceTurn()
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            connectionStatusText = "Connecting to \(macName)"
            discoveredMacName = macName
        case .connected(let macName):
            connectionStatusText = "Connected to \(macName)"
            discoveredMacName = macName
            recoverableIssue = nil
            dismissedTurnIdentifiers.removeAll()
            isPairingPanelDismissed = false
            if !isAllCapturePaused, !isNightModeEnabled,
                companionState == .disconnected
            {
                companionState = .idle
            }
            sendPrivacyState()
            Task { @MainActor [weak self] in
                await self?.activateCaptureAfterConnection()
            }
        case .unavailable(let reason):
            abandonActiveVoiceTurn()
            proactiveAnimationTask?.cancel()
            proactiveAnimationTask = nil
            connectionStatusText = "Pace is temporarily unavailable"
            let errorMessage =
                if reason.isEmpty {
                    "Pace couldn’t reconnect to your Mac."
                } else {
                    "Pace couldn’t reconnect to your Mac. Check that both devices are on the same Wi-Fi."
                }
            presentRecoverableIssue(message: errorMessage, action: .retryConnection)
            if !isAllCapturePaused, !isNightModeEnabled {
                companionState = .disconnected
            }
        }
    }

    private func finishVoiceTurn() {
        guard let turnIdentifier = activeTurnIdentifier else { return }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        do {
            let utterance = try audioRecorder.stopRecording()
            companionState = .transcribing
            let didSend = client.sendUtterance(
                audioData: utterance.audioData,
                durationSeconds: utterance.durationSeconds,
                turnIdentifier: turnIdentifier
            )
            if !didSend {
                activeTurnIdentifier = nil
                companionState = .disconnected
                presentRecoverableIssue(
                    message: "Your recording couldn’t reach Pace on your Mac.",
                    action: .retryConnection
                )
            }
        } catch {
            activeTurnIdentifier = nil
            companionState = .idle
            presentRecoverableIssue(
                message: "Pace couldn’t finish that recording.",
                action: .retryVoiceTurn
            )
        }
    }

    private func handle(_ payload: PaceCompanionMessagePayload) {
        switch payload {
        case .interactionState(let stateChange):
            guard !isAllCapturePaused, !isNightModeEnabled else { return }
            if let turnIdentifier = stateChange.turnIdentifier,
                dismissedTurnIdentifiers.contains(turnIdentifier)
            {
                return
            }
            companionState =
                switch stateChange.state {
                case .idle: .idle
                case .listening: .listening
                case .transcribing: .transcribing
                case .processing:
                    .processing(usesOffDevicePlanner: stateChange.usesOffDevicePlanner)
                case .speaking: companionState
                }
            announceCurrentStateForAccessibility()
        case .assistantResponse(let response):
            if dismissedTurnIdentifiers.remove(response.turnIdentifier) != nil {
                return
            }
            activeTurnIdentifier = nil
            currentMessageText = response.spokenText
            guard !isAllCapturePaused, !isNightModeEnabled else { return }
            companionState = .speaking(usesOffDevicePlanner: response.usesOffDevicePlanner)
            if isSpeakerMuted {
                companionState = .idle
            } else {
                speechPlayer.speak(response.spokenText)
            }
            announceForAccessibility(response.spokenText)
        case .proactiveMessage(let proactiveMessage):
            guard !isAllCapturePaused, !isNightModeEnabled else { return }
            guard proactiveMessage.expiresAt.map({ $0 > Date() }) ?? true else { return }
            proactiveAnimationTask?.cancel()
            currentMessageText = proactiveMessage.spokenText
            companionState = .proactive
            proactiveAnimationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(650))
                guard let self, !Task.isCancelled,
                    !isAllCapturePaused, !isNightModeEnabled
                else {
                    return
                }
                companionState = .speaking(usesOffDevicePlanner: false)
                if isSpeakerMuted {
                    companionState = .idle
                } else {
                    speechPlayer.speak(proactiveMessage.spokenText)
                }
                announceForAccessibility(proactiveMessage.spokenText)
            }
        case .error(let errorMessage):
            presentRecoverableIssue(
                message: errorMessage.message,
                action: errorMessage.isRecoverable ? .retryVoiceTurn : nil
            )
            abandonActiveVoiceTurn()
            speechPlayer.stop()
            if isNightModeEnabled {
                companionState = .sleeping
            } else if isAllCapturePaused {
                companionState = .paused
            } else {
                companionState = connectionIsReady ? .idle : .disconnected
            }
            announceForAccessibility(errorMessage.message)
        case .pairRequest, .pairResponse, .unpairRequest, .sessionHello, .heartbeat,
            .userUtterance, .presenceChanged, .cameraFrameRequest,
            .cameraFrameResponse, .privacyStateChanged:
            break
        }
    }

    private func handleCameraFrameRequest(_ request: PaceCompanionCameraFrameRequest) {
        guard request.expiresAt > Date(),
            reportedPrivacyState.permitsCameraMedia
        else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                let capturedFrame = await cameraService.captureNextJPEGFrame(),
                request.expiresAt > Date(),
                reportedPrivacyState.permitsCameraMedia
            else {
                return
            }
            client.sendCameraFrame(
                requestIdentifier: request.requestIdentifier,
                imageData: capturedFrame.imageData,
                capturedAt: capturedFrame.capturedAt
            )
        }
    }

    private func sendPrivacyState() {
        client.sendPrivacyState(reportedPrivacyState)
    }

    private var reportedPrivacyState: PaceCompanionPrivacyState {
        PaceCompanionPrivacyState(
            isMicrophoneEnabled: isMicrophoneEnabled
                && audioRecorder.microphonePermissionIsGranted,
            isCameraEnabled: isCameraEnabled
                && cameraService.cameraPermissionIsGranted
                && cameraService.isRunning,
            isSpeakerMuted: isSpeakerMuted,
            isAllCapturePaused: isAllCapturePaused || isNightModeEnabled
        )
    }

    private func activateCaptureAfterConnection() async {
        guard !isAllCapturePaused, !isNightModeEnabled else { return }
        if !hasRequestedCapturePermissions {
            hasRequestedCapturePermissions = true
            await audioRecorder.requestPermission()
            if !audioRecorder.microphonePermissionIsGranted {
                isMicrophoneEnabled = false
                presentRecoverableIssue(
                    message: "Microphone access is off. Allow it in Settings to talk to Pace.",
                    action: .openSettings
                )
            }
        }
        if isCameraEnabled {
            updateCameraOrientation()
            await cameraService.requestPermissionAndStart()
            if cameraService.lastErrorText != nil {
                presentCameraRecoveryIssue()
                isCameraEnabled = false
            }
        }
        sendPrivacyState()
    }

    private func announceCurrentStateForAccessibility() {
        let announcement: String? =
            switch companionState {
            case .transcribing: "Sending your recording to Pace on your Mac"
            case .processing(let usesOffDevicePlanner):
                usesOffDevicePlanner ? "Thinking off-device" : "Thinking on this Mac"
            default: nil
            }
        if let announcement {
            announceForAccessibility(announcement)
        }
    }

    private func announceForAccessibility(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func scheduleControlsAutoHide() {
        guard showsControls else { return }
        if assistiveNavigationIsActive {
            controlsAutoHideTask?.cancel()
            controlsAutoHideTask = nil
            return
        }
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard !assistiveNavigationIsActive else {
                controlsAutoHideTask = nil
                return
            }
            showsControls = false
            controlsAutoHideTask = nil
            updateAmbientIdlePolicy()
        }
    }

    private var assistiveNavigationIsActive: Bool {
        UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
    }

    private func stopCurrentResponse() {
        proactiveAnimationTask?.cancel()
        proactiveAnimationTask = nil
        speechPlayer.stop()
        companionState = connectionIsReady ? .idle : .disconnected
        announceForAccessibility("Pace stopped speaking")
    }

    private func abandonActiveVoiceTurn() {
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        audioRecorder.cancelRecording()
        activeTurnIdentifier = nil
    }

    private func scheduleRecordingTimeout(forTurnIdentifier turnIdentifier: String?) {
        recordingTimeoutTask?.cancel()
        guard let turnIdentifier else { return }
        recordingTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(PaceCompanionProtocol.maximumUtteranceDurationSeconds)
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled,
                activeTurnIdentifier == turnIdentifier,
                audioRecorder.isRecording
            else {
                return
            }
            finishVoiceTurn()
        }
    }

    private func dismissPendingTurn() {
        if let activeTurnIdentifier {
            dismissedTurnIdentifiers.insert(activeTurnIdentifier)
        }
        activeTurnIdentifier = nil
        companionState = connectionIsReady ? .idle : .disconnected
        currentMessageText = nil
        announceForAccessibility("Turn dismissed here. Pace may still finish it on your Mac.")
    }

    private func presentCameraRecoveryIssue() {
        if cameraService.cameraPermissionIsGranted {
            presentRecoverableIssue(
                message: "Pace couldn’t start the iPad camera.",
                action: .retryCamera
            )
        } else {
            presentRecoverableIssue(
                message: "Camera access is off. Allow it in Settings for presence awareness.",
                action: .openSettings
            )
        }
    }

    private func presentRecoverableIssue(
        message: String,
        action: RecoverableIssue.Action?
    ) {
        recoverableIssue = RecoverableIssue(message: message, action: action)
        announceForAccessibility(message)
    }

    private func registerUserActivity() {
        isAmbientIdleDimmed = false
        updateAmbientIdlePolicy()
    }

    private func updateAmbientIdlePolicy() {
        ambientIdleTask?.cancel()
        ambientIdleTask = nil
        guard companionState == .idle, !showsControls, !isNightModeEnabled else {
            isAmbientIdleDimmed = false
            return
        }
        ambientIdleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, companionState == .idle, !showsControls else {
                return
            }
            isAmbientIdleDimmed = true
            ambientIdleTask = nil
        }
    }
}
