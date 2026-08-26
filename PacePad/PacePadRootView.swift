import Combine
import SwiftUI
import UIKit

struct PacePadRootView: View {
    @ObservedObject var viewModel: PacePadViewModel
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var pairingCodeFieldIsFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.paceBackground.ignoresSafeArea()

                if viewModel.companionState == .sleeping {
                    PacePadSleepingView()
                } else {
                    companionContent(in: geometry.size)
                        .accessibilityHidden(shouldShowPairingPanel)
                }

                if viewModel.companionState == .sleeping {
                    VStack {
                        Spacer()
                        Button(action: viewModel.toggleNightMode) {
                            Label("Wake Pace", systemImage: "sun.max.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.paceSecondaryText.opacity(0.7))
                                .frame(minWidth: 120, minHeight: 48)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 18)
                    }
                } else {
                    VStack(spacing: 0) {
                        topStatusBar
                        Spacer()
                        if viewModel.showsControls {
                            bottomControls
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .allowsHitTesting(!viewModel.isAmbientIdleDimmed)
                    .accessibilityHidden(
                        viewModel.isAmbientIdleDimmed || shouldShowPairingPanel
                    )
                }

                if shouldShowPairingPanel {
                    pairingPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.24),
                value: shouldShowPairingPanel
            )
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.24),
                value: viewModel.showsControls
            )
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            viewModel.updateCameraOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            viewModel.updateCameraOrientation()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }

    private func companionContent(in size: CGSize) -> some View {
        ZStack {
            Button(action: viewModel.handleFaceTapped) {
                PacePadFace(
                    state: viewModel.companionState,
                    isAmbientIdleDimmed: viewModel.isAmbientIdleDimmed,
                    reducesMotion: accessibilityReduceMotion
                )
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canUseFaceInteraction)
            .accessibilityLabel(primaryInteractionAccessibilityLabel)
            .accessibilityHint(primaryInteractionAccessibilityHint)

            VStack {
                Spacer()

                VStack(spacing: 10) {
                    primaryStateLabel
                        .allowsHitTesting(false)

                    if let currentMessageText = viewModel.currentMessageText {
                        ScrollView(.vertical) {
                            Text(currentMessageText)
                                .font(.title3)
                                .foregroundStyle(Color.paceSecondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxWidth: min(size.width * 0.78, 720), maxHeight: 170)
                        .transition(.opacity)
                    }

                    if let recoverableIssue = viewModel.recoverableIssue {
                        VStack(spacing: 8) {
                            Text(recoverableIssue.message)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.paceError)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)

                            if let actionTitle = recoverableIssue.actionTitle {
                                Button(actionTitle, action: viewModel.performRecoveryAction)
                                    .buttonStyle(PacePadRecoveryButtonStyle())
                            }
                        }
                        .frame(maxWidth: min(size.width * 0.78, 720))
                    }

                    if viewModel.companionState == .disconnected {
                        disconnectedRecoveryControls
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, companionBottomPadding(for: size.width))
                .opacity(viewModel.isAmbientIdleDimmed ? 0 : 1)
                .allowsHitTesting(!viewModel.isAmbientIdleDimmed)
                .accessibilityHidden(viewModel.isAmbientIdleDimmed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var topStatusBar: some View {
        ViewThatFits(in: .horizontal) {
            statusBarLayout(showsConnectionText: true, showsPrivacyText: true)
            statusBarLayout(showsConnectionText: false, showsPrivacyText: false)
        }
        .opacity(viewModel.isAmbientIdleDimmed ? 0 : 1)
    }

    private func statusBarLayout(
        showsConnectionText: Bool,
        showsPrivacyText: Bool
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(connectionIndicatorColor)
                    .frame(width: 8, height: 8)
                Text(showsConnectionText ? viewModel.connectionStatusText : "Pace")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.paceSecondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                privacyIndicator(
                    systemImage: viewModel.audioRecorder.isRecording ? "mic.fill" : "mic.slash.fill",
                    statusText: viewModel.audioRecorder.isRecording ? "Mic live" : "Mic idle",
                    isActive: viewModel.audioRecorder.isRecording,
                    showsText: showsPrivacyText
                )
                privacyIndicator(
                    systemImage: viewModel.cameraService.isRunning ? "camera.fill" : "camera.slash.fill",
                    statusText: viewModel.cameraService.isRunning ? "Camera live" : "Camera off",
                    isActive: viewModel.cameraService.isRunning
                        && !viewModel.isAllCapturePaused,
                    showsText: showsPrivacyText
                )
                Button(action: viewModel.toggleControls) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(
                            viewModel.showsControls ? Color.paceBlue : Color.pacePrimaryText
                        )
                        .frame(width: 44, height: 44)
                        .background(Color.paceRaisedSurface, in: Circle())
                        .overlay(Circle().stroke(Color.paceBorder, lineWidth: 1))
                }
                .accessibilityLabel(viewModel.showsControls ? "Hide controls" : "Show controls")
                Button(action: viewModel.toggleAllCapturePaused) {
                    Image(systemName: viewModel.isAllCapturePaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(viewModel.isAllCapturePaused ? Color.paceBlue : Color.pacePrimaryText)
                        .frame(width: 44, height: 44)
                        .background(Color.paceRaisedSurface, in: Circle())
                        .overlay(Circle().stroke(Color.paceBorder, lineWidth: 1))
                }
                .accessibilityLabel(
                    viewModel.isAllCapturePaused ? "Resume camera and microphone" : "Pause camera and microphone")
            }
        }
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    microphoneControl
                    cameraControl
                    speakerControl
                    nightModeControl
                }

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 10
                ) {
                    microphoneControl
                    cameraControl
                    speakerControl
                    nightModeControl
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "sun.min.fill")
                    .foregroundStyle(Color.paceSecondaryText)
                Slider(value: $viewModel.brightness, in: 0.03...1)
                    .tint(Color.paceBlue)
                    .onChange(of: viewModel.brightness) {
                        viewModel.updateBrightness()
                    }
                    .accessibilityLabel("Screen brightness")
                Image(systemName: "sun.max.fill")
                    .foregroundStyle(Color.paceSecondaryText)
            }
            .frame(maxWidth: 320)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.paceSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.paceBorder, lineWidth: 1)
        )
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private var pairingPanel: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {}

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            pairingTitle
                            Spacer()
                            dismissPairingButton
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            pairingTitle
                            dismissPairingButton
                        }
                    }
                    Text(
                        "Enter the six-digit code shown in Pace on \(viewModel.discoveredMacName ?? "your Mac"). The connection stays on your local network."
                    )
                    .font(.body)
                    .foregroundStyle(Color.paceSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        pairingCodeField
                        pairButton
                            .frame(width: 104)
                    }

                    VStack(spacing: 12) {
                        pairingCodeField
                        pairButton
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .background(Color.paceSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.paceBorder, lineWidth: 1)
            )
            .padding(24)
            .accessibilityAddTraits(.isModal)
            .accessibilityElement(children: .contain)
            .onAppear {
                pairingCodeFieldIsFocused = true
            }
            .onDisappear {
                pairingCodeFieldIsFocused = false
            }
        }
    }

    private var shouldShowPairingPanel: Bool {
        if case .pairingAvailable = viewModel.client.status {
            return !viewModel.isPairingPanelDismissed
        }
        return false
    }

    @ViewBuilder
    private var disconnectedRecoveryControls: some View {
        if case .pairingAvailable = viewModel.client.status {
            Button("Pair with this Mac", action: viewModel.showPairingPanel)
                .buttonStyle(PacePadRecoveryButtonStyle())
        } else {
            HStack(spacing: 10) {
                Button("Look again", action: viewModel.retryConnection)
                    .buttonStyle(PacePadRecoveryButtonStyle())
                if viewModel.client.hasStoredPairing {
                    Button("Pair again", action: viewModel.pairAgain)
                        .buttonStyle(PacePadRecoveryButtonStyle())
                }
            }
        }
    }

    private var connectionIndicatorColor: Color {
        if case .connected = viewModel.client.status { return .paceSecondaryText }
        return .paceSecondaryText
    }

    private var primaryInteractionAccessibilityLabel: String {
        if viewModel.isAmbientIdleDimmed { return "Wake Pace" }
        return switch viewModel.companionState {
        case .idle: "Talk to Pace"
        case .listening: "Stop and send recording"
        case .disconnected: "Pace is disconnected"
        case .transcribing: "Pace is transcribing your recording"
        case .processing(let usesOffDevicePlanner):
            usesOffDevicePlanner ? "Pace is thinking off-device" : "Pace is thinking on this Mac"
        case .speaking: "Stop Pace speaking"
        case .proactive: "Stop Pace before speaking"
        case .paused: "Pace camera and microphone are paused"
        case .sleeping: "Pace is in night mode"
        }
    }

    private var primaryInteractionAccessibilityHint: String {
        if viewModel.isAmbientIdleDimmed {
            return "Double-tap to restore Pace without starting a recording."
        }
        return switch viewModel.companionState {
        case .idle: "Double-tap to start talking."
        case .listening: "Double-tap to stop recording and send."
        case .transcribing, .processing:
            "Double-tap to dismiss this turn here. Pace may continue it on your Mac."
        case .speaking, .proactive: "Double-tap to stop this response."
        default: "This face shows Pace’s current state."
        }
    }

    private var primaryStateText: String {
        switch viewModel.companionState {
        case .disconnected: "Open Pace on your Mac"
        case .idle: "Tap Pace to talk"
        case .listening: "I'm listening"
        case .transcribing: "Sending to your Mac · tap to dismiss"
        case .processing(let usesOffDevicePlanner):
            usesOffDevicePlanner ? "Thinking off-device · tap to dismiss" : "Thinking on this Mac · tap to dismiss"
        case .speaking(let usesOffDevicePlanner):
            usesOffDevicePlanner ? "Speaking off-device · tap to stop" : "Speaking · tap to stop"
        case .proactive: "A quick thought · tap to stop"
        case .paused: "Camera and microphone paused"
        case .sleeping: ""
        }
    }

    private var primaryStateLabel: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(primaryStateAccentColor)
                .frame(width: 7, height: 7)
                .shadow(color: primaryStateAccentColor.opacity(0.5), radius: 5)

            Text(primaryStateText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .font(.system(.headline, design: .rounded).weight(.semibold))
        .foregroundStyle(Color.pacePrimaryText)
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .background(primaryStateAccentColor.opacity(0.045), in: Capsule())
        .overlay(
            Capsule()
                .stroke(primaryStateAccentColor.opacity(0.2), lineWidth: 0.75)
        )
    }

    private var primaryStateAccentColor: Color {
        switch viewModel.companionState {
        case .processing(let usesOffDevicePlanner),
            .speaking(let usesOffDevicePlanner):
            usesOffDevicePlanner ? .paceAmber : .paceBlue
        case .disconnected:
            .paceSecondaryText
        case .paused:
            .paceSecondaryText
        case .idle:
            .paceFriendlyBlue
        case .listening, .transcribing, .proactive:
            .paceBlue
        case .sleeping:
            .paceSecondaryText
        }
    }

    @ViewBuilder
    private func privacyIndicator(
        systemImage: String,
        statusText: String,
        isActive: Bool,
        showsText: Bool
    ) -> some View {
        if showsText {
            Label(statusText, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.paceBlue : Color.paceSecondaryText)
                .accessibilityLabel(statusText)
        } else {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? Color.paceBlue : Color.paceSecondaryText)
                .frame(minWidth: 28, minHeight: 44)
                .accessibilityLabel(statusText)
        }
    }

    private var microphoneControl: some View {
        controlButton(
            systemImage: viewModel.isMicrophoneEnabled ? "mic.fill" : "mic.slash.fill",
            label: microphoneControlLabel,
            isSelected: viewModel.isMicrophoneEnabled
                && viewModel.audioRecorder.microphonePermissionIsGranted,
            action: viewModel.toggleMicrophone
        )
    }

    private var cameraControl: some View {
        controlButton(
            systemImage: viewModel.isCameraEnabled ? "camera.fill" : "camera.slash.fill",
            label: cameraControlLabel,
            isSelected: viewModel.isCameraEnabled
                && viewModel.cameraService.cameraPermissionIsGranted,
            action: viewModel.toggleCamera
        )
    }

    private var speakerControl: some View {
        controlButton(
            systemImage: viewModel.isSpeakerMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            label: viewModel.isSpeakerMuted ? "Unmute" : "Mute Pace",
            isSelected: !viewModel.isSpeakerMuted,
            action: viewModel.toggleSpeakerMute
        )
    }

    private var nightModeControl: some View {
        controlButton(
            systemImage: "moon.fill",
            label: "Night mode",
            isSelected: viewModel.isNightModeEnabled,
            action: viewModel.toggleNightMode
        )
    }

    private var pairingTitle: some View {
        Text("Give Pace a place in the room")
            .font(.system(.title2, design: .rounded).weight(.bold))
            .foregroundStyle(Color.pacePrimaryText)
    }

    private var dismissPairingButton: some View {
        Button("Not now", action: viewModel.dismissPairingPanel)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.paceSecondaryText)
    }

    private var pairingCodeField: some View {
        TextField("000000", text: $viewModel.pairingCode)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .font(.system(.title, design: .monospaced).weight(.semibold))
            .foregroundStyle(Color.pacePrimaryText)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color.paceRaisedSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.paceBorder, lineWidth: 1)
            )
            .onChange(of: viewModel.pairingCode) {
                viewModel.normalizePairingCodeInput()
            }
            .accessibilityLabel("Six-digit pairing code")
            .accessibilityFocused($pairingCodeFieldIsFocused)
    }

    private var pairButton: some View {
        Button("Pair", action: viewModel.pair)
            .font(.headline)
            .foregroundStyle(Color.paceBackground)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Color.paceBlue, in: RoundedRectangle(cornerRadius: 12))
            .disabled(viewModel.pairingCode.filter(\.isNumber).count != 6)
            .opacity(viewModel.pairingCode.filter(\.isNumber).count == 6 ? 1 : 0.45)
    }

    private func companionBottomPadding(for availableWidth: CGFloat) -> CGFloat {
        guard viewModel.showsControls else { return 54 }
        if availableWidth < 520 || dynamicTypeSize.isAccessibilitySize {
            return 260
        }
        return 150
    }

    private var microphoneControlLabel: String {
        guard viewModel.audioRecorder.microphonePermissionIsGranted else { return "Allow mic" }
        return viewModel.isMicrophoneEnabled ? "Mute mic" : "Enable mic"
    }

    private var cameraControlLabel: String {
        guard viewModel.cameraService.cameraPermissionIsGranted else { return "Allow camera" }
        return viewModel.isCameraEnabled ? "Turn camera off" : "Turn camera on"
    }

    private func controlButton(
        systemImage: String,
        label: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isSelected ? Color.paceBlue : Color.paceSecondaryText)
            .frame(
                minWidth: 96,
                maxWidth: .infinity,
                minHeight: dynamicTypeSize.isAccessibilitySize ? 76 : 52
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PacePadRecoveryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.paceBlue)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(Color.paceRaisedSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.paceBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PacePadFace: View {
    let state: PacePadViewModel.CompanionState
    let isAmbientIdleDimmed: Bool
    let reducesMotion: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let minimumDimension = min(geometry.size.width, geometry.size.height)
            let featureScale = min(max(minimumDimension / 400, 1.25), 2.28)

            ZStack {
                Color.paceCompanionCanvas.opacity(isAmbientIdleDimmed ? 0.24 : 1)

                screenMaterial(minimumDimension: minimumDimension)

                TimelineView(
                    .animation(minimumInterval: animationFrameInterval, paused: timelineIsPaused)
                ) { timeline in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    let visibleMotionSeconds = reducesMotion ? 0 : seconds
                    let animationValues = PacePadFaceAnimationValues(
                        state: state,
                        seconds: visibleMotionSeconds
                    )
                    let maintenanceOffset = ambientMaintenanceOffset(seconds: seconds)

                    ZStack {
                        Ellipse()
                            .fill(faceColor.opacity(animationValues.haloOpacity))
                            .frame(width: minimumDimension * 0.76, height: minimumDimension * 0.6)
                            .blur(radius: 48)
                            .offset(y: 12)
                            .scaleEffect(animationValues.haloScale)

                        VStack(spacing: animationValues.eyeMouthSpacing) {
                            HStack(spacing: animationValues.eyeSpacing) {
                                eye(
                                    isLeftEye: true,
                                    heightScale: animationValues.eyeHeightScale,
                                    gazeOffset: animationValues.eyeHorizontalOffset
                                )
                                eye(
                                    isLeftEye: false,
                                    heightScale: animationValues.eyeHeightScale,
                                    gazeOffset: animationValues.eyeHorizontalOffset
                                )
                            }

                            mouth(animationValues: animationValues)
                        }
                        .offset(y: reducesMotion ? 0 : animationValues.breathingOffset)
                        .scaleEffect(featureScale)
                        .offset(
                            x: maintenanceOffset.width,
                            y: maintenanceOffset.height
                        )
                        .opacity(isAmbientIdleDimmed ? 0.2 : 1)
                    }
                    .animation(reducesMotion ? nil : .easeOut(duration: 0.22), value: state)
                }

                PacePadScreenScanlineField(
                    displayScale: displayScale,
                    darkLineOpacity: isAmbientIdleDimmed ? 0.12 : 0.34,
                    lightLineOpacity: isAmbientIdleDimmed ? 0.001 : 0.01
                )
                .padding(18)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: min(max(minimumDimension * 0.045, 28), 46) - 5,
                        style: .continuous
                    )
                )

                Rectangle()
                    .fill(Color.white.opacity(isAmbientIdleDimmed ? 0.01 : 0.04))
                    .frame(height: 1)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityHidden(true)
    }

    private func screenMaterial(minimumDimension: CGFloat) -> some View {
        let screenCornerRadius = min(max(minimumDimension * 0.045, 28), 46)

        return ZStack {
            RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                .stroke(
                    Color.paceBorder.opacity(isAmbientIdleDimmed ? 0.16 : 0.62),
                    lineWidth: 1.5
                )
                .padding(11)

            PacePadScreenUpperHighlightShape(cornerRadius: screenCornerRadius - 5)
                .stroke(
                    faceColor.opacity(isAmbientIdleDimmed ? 0.006 : 0.11),
                    style: StrokeStyle(lineWidth: 1.3, lineCap: .round)
                )
                .padding(18)

            Rectangle()
                .fill(Color.black.opacity(isAmbientIdleDimmed ? 0.08 : 0.34))
                .frame(height: 1.5)
                .padding(.horizontal, screenCornerRadius + 18)
                .padding(.bottom, 18)
                .frame(maxHeight: .infinity, alignment: .bottom)

            screenEdgeSignal
                .padding(13)
        }
    }

    private var edgeSignalOpacity: Double {
        switch state {
        case .listening, .processing, .speaking, .proactive: 0.34
        case .transcribing: 0.2
        case .idle: 0.06
        case .disconnected, .paused, .sleeping: 0
        }
    }

    private var timelineIsPaused: Bool {
        return state == .disconnected || state == .paused || state == .sleeping
    }

    private var animationFrameInterval: TimeInterval {
        if reducesMotion || isAmbientIdleDimmed { return 60 }
        return switch state {
        case .listening, .speaking, .proactive: 1 / 15
        case .idle: 1 / 8
        case .transcribing, .processing: 1 / 6
        case .disconnected, .paused, .sleeping: 1
        }
    }

    private var screenEdgeSignal: some View {
        ZStack {
            VStack(spacing: 0) {
                horizontalEdgeSignal
                Spacer()
                horizontalEdgeSignal
            }
            HStack(spacing: 0) {
                verticalEdgeSignal
                Spacer()
                verticalEdgeSignal
            }
        }
        .opacity(edgeSignalOpacity)
    }

    private var horizontalEdgeSignal: some View {
        LinearGradient(
            colors: [.clear, faceColor, .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 2)
    }

    private var verticalEdgeSignal: some View {
        LinearGradient(
            colors: [.clear, faceColor, .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: 2)
    }

    private func ambientMaintenanceOffset(seconds: TimeInterval) -> CGSize {
        let maintenancePhase = Int(seconds / 480).quotientAndRemainder(dividingBy: 4).remainder
        return switch maintenancePhase {
        case 0: CGSize(width: -5, height: -4)
        case 1: CGSize(width: 5, height: -3)
        case 2: CGSize(width: 4, height: 4)
        default: CGSize(width: -4, height: 3)
        }
    }

    @ViewBuilder
    private func eye(
        isLeftEye: Bool,
        heightScale: CGFloat,
        gazeOffset: CGFloat
    ) -> some View {
        switch state {
        case .listening:
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(faceColor.opacity(0.12))

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(faceColor.opacity(0.26), lineWidth: 10)

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(faceColor, lineWidth: 4.5)

                Circle()
                    .fill(faceColor.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .offset(x: gazeOffset)

                Circle()
                    .fill(Color.white.opacity(0.86))
                    .frame(width: 7, height: 7)
                    .offset(x: gazeOffset - 4, y: -4)
            }
            .frame(width: 78, height: 72)
            .scaleEffect(y: min(heightScale, 1.08))
            .rotationEffect(.degrees(isLeftEye ? -2 : 2))
            .shadow(color: faceColor.opacity(0.22), radius: 9, y: 4)
        case .paused, .sleeping:
            Capsule()
                .fill(faceColor.opacity(0.7))
                .frame(width: 82, height: 8)
                .rotationEffect(.degrees(isLeftEye ? 3 : -3))
                .frame(height: 72)
        default:
            ZStack {
                PacePadHappyEyeShape()
                    .stroke(
                        eyeColor.opacity(0.27),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )

                PacePadHappyEyeShape()
                    .stroke(
                        eyeColor,
                        style: StrokeStyle(lineWidth: 6.5, lineCap: .round)
                    )
            }
            .frame(width: 86, height: 48)
            .scaleEffect(y: max(0.12, min(heightScale, 1)))
            .rotationEffect(.degrees(isLeftEye ? -2 : 2))
            .shadow(color: eyeColor.opacity(0.22), radius: 9, y: 4)
            .frame(height: 72)
        }
    }

    @ViewBuilder
    private func mouth(animationValues: PacePadFaceAnimationValues) -> some View {
        switch state {
        case .speaking, .proactive:
            HStack(alignment: .center, spacing: 7) {
                ForEach(0..<5, id: \.self) { barIndex in
                    Capsule()
                        .fill(faceColor)
                        .frame(
                            width: 8,
                            height: animationValues.speakingBarHeight(for: barIndex)
                        )
                }
            }
            .frame(height: 42)
        case .processing, .transcribing:
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(faceColor).frame(width: 9, height: 9)
                }
            }
            .frame(height: 42)
        case .paused:
            Capsule()
                .fill(faceColor)
                .frame(width: 72, height: 8)
                .rotationEffect(.degrees(-7))
                .frame(height: 42)
        case .disconnected:
            PacePadSmileShape(curveDepth: -5)
                .stroke(mouthColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 72, height: 32)
        case .idle, .listening:
            ZStack {
                PacePadHappyMouthShape()
                    .fill(happyMouthFillColor)

                PacePadHappyMouthShape()
                    .stroke(mouthColor.opacity(0.28), lineWidth: 7)

                PacePadHappyMouthShape()
                    .stroke(mouthColor.opacity(0.94), lineWidth: 2.2)

                if state == .listening {
                    PacePadHappyMouthShape()
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                }
            }
            .frame(width: 108, height: 66)
            .shadow(color: mouthColor.opacity(0.24), radius: 9, y: 4)
        case .sleeping:
            PacePadSmileShape(curveDepth: 8)
                .stroke(mouthColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 58, height: 30)
        }
    }

    private var eyeColor: Color {
        switch state {
        case .idle:
            .paceFriendlyBlue
        default:
            faceColor
        }
    }

    private var mouthColor: Color {
        switch state {
        case .disconnected, .paused, .sleeping:
            .paceSecondaryText
        case .speaking(let usesOffDevicePlanner) where usesOffDevicePlanner,
            .processing(let usesOffDevicePlanner) where usesOffDevicePlanner:
            .paceAmber
        case .idle:
            .paceFriendlyBlue
        default:
            .paceBlue
        }
    }

    private var happyMouthFillColor: Color {
        switch state {
        case .idle:
            .paceFriendlyBlueDeep
        default:
            mouthColor.opacity(0.68)
        }
    }

    private var faceColor: Color {
        switch state {
        case .speaking(let usesOffDevicePlanner),
            .processing(let usesOffDevicePlanner):
            usesOffDevicePlanner ? .paceAmber : .paceBlue
        case .disconnected, .paused, .sleeping:
            .paceSecondaryText
        case .idle:
            .paceFriendlyBlue
        case .listening, .transcribing, .proactive:
            .paceBlue
        }
    }
}

private struct PacePadFaceAnimationValues {
    let state: PacePadViewModel.CompanionState
    let seconds: TimeInterval

    var eyeHeightScale: CGFloat {
        if state == .idle, seconds.truncatingRemainder(dividingBy: 5.4) < 0.13 { return 0.12 }
        if state == .listening { return 1.35 }
        if state == .paused { return 0.35 }
        return 1
    }

    var eyeSpacing: CGFloat { state == .listening ? 62 : 54 }
    var eyeMouthSpacing: CGFloat { 40 }
    var eyeHorizontalOffset: CGFloat {
        guard state == .idle else { return 0 }
        return sin(seconds * 0.47) * 4
    }
    var breathingOffset: CGFloat { sin(seconds * 1.1) * 4 }
    var haloOpacity: Double {
        switch state {
        case .listening, .proactive: 0.18 + (sin(seconds * 2.7) + 1) * 0.045
        case .speaking: 0.16
        case .idle: 0.055
        default: 0.03
        }
    }
    var haloScale: CGFloat {
        switch state {
        case .listening, .speaking, .proactive:
            0.94 + CGFloat((sin(seconds * 1.1) + 1) * 0.025)
        default:
            0.96
        }
    }

    func speakingBarHeight(for barIndex: Int) -> CGFloat {
        let phase = seconds * 7 + Double(barIndex) * 0.92
        return 10 + CGFloat((sin(phase) + 1) * 11)
    }
}

private struct PacePadSmileShape: Shape {
    let curveDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let signalStartX = rect.minX + rect.width * 0.14
        let signalEndX = rect.maxX - rect.width * 0.14
        let signalBaselineY = rect.midY - curveDepth * 0.35
        path.move(to: CGPoint(x: rect.minX, y: signalBaselineY))
        path.addLine(to: CGPoint(x: signalStartX, y: signalBaselineY))
        path.addQuadCurve(
            to: CGPoint(x: signalEndX, y: signalBaselineY),
            control: CGPoint(x: rect.midX, y: rect.midY + curveDepth)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: signalBaselineY))
        return path
    }
}

private struct PacePadHappyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.7)
        )
        return path
    }
}

private struct PacePadHappyMouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12),
            control: CGPoint(x: rect.midX, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12),
            control1: CGPoint(x: rect.minX + rect.width * 0.96, y: rect.maxY),
            control2: CGPoint(x: rect.minX + rect.width * 0.04, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct PacePadScreenScanlineField: View {
    let displayScale: CGFloat
    let darkLineOpacity: Double
    let lightLineOpacity: Double

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            let scanlineSpacing = max(4, 12 / displayScale)
            let physicalPixelWidth = 1 / displayScale
            var darkScanlinePath = Path()
            var lightScanlinePath = Path()
            var scanlineY = scanlineSpacing / 2

            while scanlineY < size.height {
                lightScanlinePath.move(to: CGPoint(x: 0, y: scanlineY))
                lightScanlinePath.addLine(to: CGPoint(x: size.width, y: scanlineY))

                let darkScanlineY = scanlineY + physicalPixelWidth
                darkScanlinePath.move(to: CGPoint(x: 0, y: darkScanlineY))
                darkScanlinePath.addLine(to: CGPoint(x: size.width, y: darkScanlineY))
                scanlineY += scanlineSpacing
            }

            context.stroke(
                lightScanlinePath,
                with: .color(Color.white.opacity(lightLineOpacity)),
                lineWidth: physicalPixelWidth
            )
            context.stroke(
                darkScanlinePath,
                with: .color(Color.paceBackground.opacity(darkLineOpacity)),
                lineWidth: physicalPixelWidth
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct PacePadScreenUpperHighlightShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let clampedCornerRadius = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + clampedCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + clampedCornerRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - clampedCornerRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + clampedCornerRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.18))
        return path
    }
}

private struct PacePadSleepingView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            VStack(spacing: 34) {
                HStack(spacing: 58) {
                    Capsule().frame(width: 46, height: 5)
                    Capsule().frame(width: 46, height: 5)
                }
                .foregroundStyle(Color.paceSecondaryText.opacity(0.28))

                Text(timeline.date, style: .time)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.paceSecondaryText.opacity(0.38))
            }
        }
        .accessibilityLabel("Pace is in night mode")
    }
}

extension Color {
    fileprivate static let paceBackground = Color(red: 8 / 255, green: 10 / 255, blue: 13 / 255)
    fileprivate static let paceCompanionCanvas = Color(red: 6 / 255, green: 18 / 255, blue: 30 / 255)
    fileprivate static let paceSurface = Color(red: 16 / 255, green: 19 / 255, blue: 24 / 255)
    fileprivate static let paceRaisedSurface = Color(red: 23 / 255, green: 27 / 255, blue: 34 / 255)
    fileprivate static let paceBorder = Color(red: 42 / 255, green: 48 / 255, blue: 57 / 255)
    fileprivate static let pacePrimaryText = Color(red: 241 / 255, green: 240 / 255, blue: 236 / 255)
    fileprivate static let paceSecondaryText = Color(red: 167 / 255, green: 175 / 255, blue: 186 / 255)
    fileprivate static let paceBlue = Color(red: 79 / 255, green: 139 / 255, blue: 255 / 255)
    fileprivate static let paceFriendlyBlue = Color(red: 42 / 255, green: 148 / 255, blue: 225 / 255)
    fileprivate static let paceFriendlyBlueDeep = Color(red: 21 / 255, green: 110 / 255, blue: 174 / 255)
    fileprivate static let paceAmber = Color(red: 255 / 255, green: 179 / 255, blue: 71 / 255)
    fileprivate static let paceError = Color(uiColor: .systemRed)
}
