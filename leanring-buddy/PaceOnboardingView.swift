//
//  PaceOnboardingView.swift
//  leanring-buddy
//
//  A first-run journey that reaches one real production command.
//

import AppKit
import AVFoundation
import SwiftUI

@MainActor
struct PaceOnboardingView: View {
    @ObservedObject private var companionManager: CompanionManager
    @ObservedObject private var chatSession: PaceChatSession
    @ObservedObject private var permissionService = PacePermissionService.shared

    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var commandFieldIsFocused: Bool

    @State private var stateModel: PaceOnboardingStateModel
    @State private var commandText = "Open Notes and start a weekly plan"
    @State private var submittedCommandText: String?
    @State private var assistantMessageCountBeforeSubmission = 0
    @State private var actionIdentifiersBeforeSubmission: Set<UUID> = []
    @State private var failureNarrationBeforeSubmission: PaceFailureNarration?
    @State private var firstCommandOutcome: PaceFirstCommandOutcome = .waiting
    @State private var firstCommandUsedOffDevicePlanner = false
    @State private var voiceFirstCommandIsArmed = false
    @State private var delayedTransitionGate = PaceOnboardingDelayedTransitionGate()
    @State private var permissionAutoAdvanceTask: Task<Void, Never>?
    @State private var handoffTask: Task<Void, Never>?
    @State private var handoffIsContracted = false

    private let progressStore = PaceOnboardingProgressStore.shared

    init(
        companionManager: CompanionManager,
        isReplay: Bool = false,
        onComplete: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self._chatSession = ObservedObject(wrappedValue: companionManager.chatSession)
        self.onComplete = onComplete
        self._stateModel = State(
            initialValue: PaceOnboardingProgressStore.shared.loadState(isReplay: isReplay)
        )
    }

    var body: some View {
        ZStack {
            DS.Colors.surface
                .ignoresSafeArea()

            subtleBackgroundSignal

            VStack(spacing: 0) {
                topBar

                Group {
                    switch stateModel.stage {
                    case .ignition:
                        ignitionScene
                    case .permissions:
                        permissionsScene
                    case .firstCommand:
                        firstCommandScene
                    case .handoff:
                        handoffScene
                    case .complete:
                        Color.clear.onAppear(perform: completeJourney)
                    }
                }
                .id(stateModel.stage)
                .transition(.opacity)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: DS.Motion.sceneReveal),
                    value: stateModel.stage
                )
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .preferredColorScheme(.dark)
        .onAppear {
            chatSession.loadHistoryWithoutBlockingInterface()
            schedulePermissionAutoAdvanceIfNeeded()
        }
        .onDisappear(perform: cancelDelayedWork)
        .onChange(of: permissionService.grants) {
            schedulePermissionAutoAdvanceIfNeeded()
        }
        .onChange(of: companionManager.recentActionResults.count) {
            refreshFirstCommandOutcome()
        }
        .onChange(of: chatSession.messages.count) {
            refreshFirstCommandOutcome()
        }
        .onChange(of: companionManager.voiceState) {
            prepareForVoiceFirstCommandIfNeeded()
            refreshFirstCommandOutcome()
        }
        .onChange(of: companionManager.lastTranscript) {
            captureVoiceFirstCommandIfNeeded()
        }
        .onChange(of: companionManager.lastFailureNarration) {
            refreshFirstCommandOutcome()
        }
        .onChange(of: companionManager.isOffDeviceTurnInFlight) {
            if stateModel.stage == .firstCommand,
               companionManager.isOffDeviceTurnInFlight {
                firstCommandUsedOffDevicePlanner = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pace introduction. \(progressAccessibilityLabel)")
    }

    private var subtleBackgroundSignal: some View {
        PaceSignalView(
            state: signalState,
            isOffDeviceTurn: onboardingUsesOffDeviceBoundary,
            audioPowerLevel: companionManager.currentAudioPowerLevel,
            lineCount: 3
        )
        .frame(width: 760, height: 260)
        .opacity(0.055)
        .blur(radius: 16)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(signalPresentation.colorRole.color)
                .frame(width: 7, height: 7)
                .shadow(color: signalPresentation.colorRole.color.opacity(0.5), radius: 7, x: 0, y: 2)
                .accessibilityHidden(true)

            Text("PACE")
                .font(DS.Typography.captionStrong)
                .tracking(1.4)
                .foregroundStyle(DS.Colors.textPrimary)

            Text(onboardingUsesOffDeviceBoundary ? "Off-device" : "On this Mac")
                .font(DS.Typography.captionStrong)
                .foregroundStyle(signalPresentation.colorRole.color)

            Spacer()

            if stateModel.stage != .handoff && stateModel.stage != .complete {
                if canNavigateBack {
                    Button {
                        navigateBack()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .pointerCursor()
                    .keyboardShortcut("[", modifiers: [.command])
                    .accessibilityHint("Returns to the previous introduction step")
                }

                Text(progressLabel)
                    .font(DS.Typography.metadata)
                    .foregroundStyle(DS.Colors.textTertiary)

                Button("Skip introduction") {
                    skipJourney()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DS.Colors.textSecondary)
                .pointerCursor()
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityHint("Closes the introduction without changing permissions")
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 58)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DS.Colors.borderSubtle.opacity(0.75))
                .frame(height: 1)
        }
    }

    private var ignitionScene: some View {
        HStack(spacing: 70) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Meet the signal\nthat stays with you.")
                    .font(DS.Typography.display)
                    .tracking(-1.4)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Hold Control + Option and speak naturally. Pace understands your request and carries it out while your voice, screen, and context stay on this Mac by default.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineSpacing(5)
                    .frame(maxWidth: 430, alignment: .leading)
                    .padding(.top, 22)

                HStack(spacing: 18) {
                    primaryButton("Continue", systemImage: "arrow.right") {
                        advanceFromIgnition()
                    }
                    .keyboardShortcut(.return, modifiers: [])

                    Text("Three short steps")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.Colors.textTertiary)
                }
                .padding(.top, 34)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20) {
                PaceSignalNotchView(
                    state: .ready,
                    isOffDeviceTurn: false
                )
                .frame(width: 260, height: 70)

                Text("Ready on this Mac")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.localSignal)

                Text("The same signal follows every request—from the first word to the finished action.")
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(width: 250)
            }
            .frame(width: 280)
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var permissionsScene: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Allow what Pace needs.")
                .font(DS.Typography.sceneTitle)
                .tracking(-0.9)
                .foregroundStyle(DS.Colors.textPrimary)

            Text("Each permission unlocks one visible capability. Continue now or change any choice later in Pace settings.")
                .font(DS.Typography.body)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(.top, 12)

            VStack(spacing: 0) {
                permissionRow(
                    kind: .accessibility,
                    systemImage: "cursorarrow.motionlines",
                    title: "Control your Mac",
                    detail: "Runs requested clicks, keystrokes, and the global push-to-talk shortcut."
                )

                Divider().overlay(DS.Colors.borderSubtle)

                permissionRow(
                    kind: .screenRecording,
                    systemImage: "rectangle.inset.filled.and.person.filled",
                    title: "Understand the screen",
                    detail: "Reads a requested screenshot on-device, then discards the captured image."
                )

                Divider().overlay(DS.Colors.borderSubtle)

                permissionRow(
                    kind: .microphone,
                    systemImage: "waveform",
                    title: "Hear your request",
                    detail: "Captures push-to-talk audio for local transcription. Pace does not keep the recording."
                )
            }
            .background(DS.Colors.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
            .padding(.top, 28)

            HStack {
                Text(permissionSummary)
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(allCorePermissionsGranted ? DS.Colors.success : DS.Colors.textTertiary)

                Spacer()

                secondaryButton("Continue for now") {
                    advanceFromPermissions()
                }
                .keyboardShortcut(.return, modifiers: [])

                if let nextMissingCorePermission {
                    primaryButton(
                        nextPermissionButtonTitle(for: nextMissingCorePermission),
                        systemImage: "arrow.right"
                    ) {
                        requestPermission(nextMissingCorePermission)
                    }
                }
            }
            .padding(.top, 24)
        }
        .padding(.horizontal, 82)
        .padding(.vertical, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func permissionRow(
        kind: PacePermissionKind,
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        let isGranted = permissionService.isGranted(kind)

        return HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isGranted ? DS.Colors.success : DS.Colors.localSignal)
                .frame(width: 30)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(DS.Typography.bodyStrong)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
            }

            Spacer(minLength: 24)

            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.success)
            } else {
                Text("Not yet")
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isGranted ? "Granted" : "Not granted")
    }

    private var firstCommandProcessGuide: some View {
        HStack(alignment: .top, spacing: 24) {
            firstCommandGuideStep(
                systemImage: "text.bubble",
                title: "Ask",
                detail: "Speak or type naturally"
            )
            firstCommandGuideStep(
                systemImage: "checkmark.shield",
                title: "Review",
                detail: "Approve sensitive actions"
            )
            firstCommandGuideStep(
                systemImage: "checkmark.circle",
                title: "Finish",
                detail: "See the real result"
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Ask naturally, review sensitive actions, then see the real result")
    }

    private func firstCommandGuideStep(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(DS.Typography.captionStrong)
                .foregroundStyle(DS.Colors.localSignal)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textPrimary)
                Text(detail)
                    .font(DS.Typography.caption)
                    .foregroundStyle(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var firstCommandScene: some View {
        HStack(spacing: 54) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Give Pace one real job.")
                    .font(DS.Typography.sceneTitle)
                    .tracking(-0.9)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text("Edit the suggestion or write your own request. Pace will use the same real path it uses after setup and ask before any sensitive action.")
                    .font(DS.Typography.body)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineSpacing(4)
                    .padding(.top, 14)

                firstCommandProcessGuide
                    .padding(.top, 22)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Your first request")
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.Colors.textTertiary)

                    TextField("Ask Pace to do something", text: $commandText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(DS.Typography.headline)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(2...4)
                        .focused($commandFieldIsFocused)
                        .disabled(submittedCommandText != nil && companionManager.voiceState != .idle)
                        .accessibilityLabel("First command")

                    Rectangle()
                        .fill(commandFieldIsFocused ? DS.Colors.localSignal : DS.Colors.borderSubtle)
                        .frame(height: 1)

                    HStack {
                        Text(firstCommandOutcome.allowsHandoff ? "Return to continue" : "Return to run")
                            .font(DS.Typography.caption)
                            .foregroundStyle(DS.Colors.textTertiary)
                        Spacer()
                        if !firstCommandOutcome.allowsHandoff {
                            primaryButton(
                                submittedCommandText == nil ? "Try it" : "Run again",
                                systemImage: "arrow.up",
                                isEnabled: !trimmedCommandText.isEmpty
                                    && companionManager.voiceState == .idle
                            ) {
                                submitFirstCommand()
                            }
                            .keyboardShortcut(.return, modifiers: [])
                        }
                    }
                }
                .padding(22)
                .background(DS.Colors.surfaceInset)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.surface, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                }
                .padding(.top, 28)

                if firstCommandOutcome == .blocked || firstCommandOutcome == .failed {
                    HStack(spacing: 14) {
                        if let recoveryDestination = firstCommandRecoveryDestination {
                            Button(firstCommandRecoveryTitle) {
                                PaceSettingsWindowManager.shared.show(
                                    companionManager: companionManager,
                                    destination: recoveryDestination
                                )
                            }
                            .buttonStyle(.plain)
                            .font(DS.Typography.captionStrong)
                            .foregroundStyle(DS.Colors.localSignal)
                            .pointerCursor()
                        }

                        Button("Edit request") {
                            resetFirstCommandForRetry()
                        }
                        .buttonStyle(.plain)
                        .font(DS.Typography.captionStrong)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .pointerCursor()
                    }
                    .padding(.top, 16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            firstCommandStatusWell
                .frame(width: 300)
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 46)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            commandFieldIsFocused = true
        }
    }

    private var firstCommandStatusWell: some View {
        VStack(spacing: 22) {
            PaceSignalNotchView(
                state: signalState,
                isOffDeviceTurn: onboardingUsesOffDeviceBoundary,
                audioPowerLevel: companionManager.currentAudioPowerLevel
            )
            .frame(width: 230, height: 64)

            VStack(spacing: 8) {
                Text(signalPresentation.label)
                    .font(DS.Typography.headline)
                    .foregroundStyle(DS.Colors.textPrimary)

                Text(firstCommandStatusDetail)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 230)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(signalPresentation.accessibilityValue)
            .accessibilityValue(firstCommandStatusDetail)

            if let latestResponseText {
                Text(latestResponseText)
                    .font(DS.Typography.callout)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(DS.Colors.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            }

            if firstCommandOutcome.allowsHandoff {
                VStack(spacing: 10) {
                    primaryButton("Continue to Pace", systemImage: "arrow.right") {
                        continueFromFirstValue()
                    }
                    .keyboardShortcut(.return, modifiers: [])

                    Button("Run another request") {
                        resetFirstCommandForRetry()
                    }
                    .buttonStyle(.plain)
                    .font(DS.Typography.captionStrong)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .pointerCursor()
                }
            }
        }
        .padding(26)
        .background(DS.Colors.surfaceInset.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.window, style: .continuous)
                .stroke(signalPresentation.colorRole.color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var handoffScene: some View {
        GeometryReader { geometryProxy in
            VStack(spacing: 20) {
                Spacer()

                PaceSignalNotchView(
                    state: firstCommandOutcome == .actionCompleted ? .completed : .ready,
                    isOffDeviceTurn: firstCommandUsedOffDevicePlanner
                )
                .frame(width: handoffIsContracted ? 132 : 330, height: handoffIsContracted ? 38 : 88)
                .offset(y: handoffIsContracted ? -(geometryProxy.size.height / 2 - 54) : 0)
                .opacity(reduceMotion ? (handoffIsContracted ? 0 : 1) : 1)

                if !handoffIsContracted || reduceMotion {
                    Text(handoffTitle)
                        .font(DS.Typography.windowTitle)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .transition(.opacity)

                    Text("From here, the same signal lives in the menu bar.")
                        .font(DS.Typography.body)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .transition(.opacity)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: beginHandoff)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(handoffTitle) Pace is ready in the menu bar.")
    }

    private var progressLabel: String {
        switch stateModel.stage {
        case .ignition: return "1 / 3"
        case .permissions: return "2 / 3"
        case .firstCommand: return "3 / 3"
        case .handoff, .complete: return ""
        }
    }

    private var canNavigateBack: Bool {
        switch stateModel.stage {
        case .permissions:
            return true
        case .firstCommand:
            return companionManager.voiceState == .idle
        case .ignition, .handoff, .complete:
            return false
        }
    }

    private var progressAccessibilityLabel: String {
        switch stateModel.stage {
        case .ignition: return "Step 1 of 3, introduction"
        case .permissions: return "Step 2 of 3, permissions"
        case .firstCommand: return "Step 3 of 3, first command"
        case .handoff: return "Finishing introduction"
        case .complete: return "Introduction complete"
        }
    }

    private var signalState: PaceSignalState {
        switch stateModel.stage {
        case .ignition, .permissions, .complete:
            return .ready
        case .handoff:
            return firstCommandOutcome == .actionCompleted ? .completed : .ready
        case .firstCommand:
            switch firstCommandOutcome {
            case .awaitingApproval: return .awaitingApproval
            case .actionCompleted: return .completed
            case .blocked: return .blocked
            case .failed: return .failed
            case .responseReceived: return .completed
            case .waiting:
                switch companionManager.voiceState {
                case .idle: return submittedCommandText == nil ? .ready : .understanding
                case .listening: return .listening
                case .processing: return .understanding
                case .responding: return .speaking
                }
            }
        }
    }

    private var signalPresentation: PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: signalState,
            isOffDeviceTurn: onboardingUsesOffDeviceBoundary,
            reduceMotion: reduceMotion
        )
    }

    private var onboardingUsesOffDeviceBoundary: Bool {
        companionManager.isOffDeviceTurnInFlight
            || ((stateModel.stage == .firstCommand || stateModel.stage == .handoff)
                && firstCommandUsedOffDevicePlanner)
    }

    private var trimmedCommandText: String {
        commandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var corePermissionGrantCount: Int {
        [PacePermissionKind.accessibility, .screenRecording, .microphone]
            .filter { permissionService.isGranted($0) }
            .count
    }

    private var allCorePermissionsGranted: Bool {
        corePermissionGrantCount == 3
    }

    private var nextMissingCorePermission: PacePermissionKind? {
        [PacePermissionKind.accessibility, .screenRecording, .microphone]
            .first { !permissionService.isGranted($0) }
    }

    private func nextPermissionButtonTitle(
        for permissionKind: PacePermissionKind
    ) -> String {
        switch permissionKind {
        case .accessibility: return "Open Accessibility"
        case .screenRecording: return "Open Screen Recording"
        case .microphone: return "Allow Microphone"
        case .camera, .calendar, .reminders, .contacts: return "Open Settings"
        }
    }

    private func requestPermission(_ permissionKind: PacePermissionKind) {
        if permissionKind == .microphone {
            requestMicrophone()
        } else {
            openSystemSettings(for: permissionKind)
        }
    }

    private var permissionSummary: String {
        if allCorePermissionsGranted {
            return "All three permissions are ready. Continuing…"
        }
        return "\(corePermissionGrantCount) of 3 ready · Screen Recording may refresh after Pace reopens"
    }

    private var latestResponseText: String? {
        guard submittedCommandText != nil else { return nil }
        return chatSession.messages.last(where: { $0.role == .pace })?.body
    }

    private var firstCommandStatusDetail: String {
        switch firstCommandOutcome {
        case .waiting:
            return submittedCommandText == nil
                ? "Ready for an editable request."
                : "Pace is working on your request."
        case .responseReceived:
            return "Pace answered without changing anything on your Mac."
        case .awaitingApproval:
            return "Review the action before Pace continues."
        case .actionCompleted:
            return companionManager.recentActionResults.first?.detail ?? "The requested action completed."
        case .blocked:
            return companionManager.recentActionResults.first?.detail ?? "The request needs your attention before it can continue."
        case .failed:
            return currentFirstCommandFailureNarration?.spokenText
                ?? companionManager.recentActionResults.first?.detail
                ?? "Pace could not complete that request. You can edit it and try again."
        }
    }

    private var handoffTitle: String {
        if firstCommandUsedOffDevicePlanner {
            return firstCommandOutcome == .actionCompleted
                ? "Your first action used the off-device model you enabled."
                : "Pace answered using the off-device model you enabled."
        }
        return firstCommandOutcome == .actionCompleted
            ? "Your first action is complete."
            : "Pace answered on your Mac."
    }

    private var currentFirstCommandFailureNarration: PaceFailureNarration? {
        guard let latestFailureNarration = companionManager.lastFailureNarration,
              latestFailureNarration != failureNarrationBeforeSubmission else { return nil }
        return latestFailureNarration
    }

    private var firstCommandRecoveryDestination: PaceCommandCenterDestination? {
        switch currentFirstCommandFailureNarration?.suggestion {
        case .openSpecificPermission(_):
            return .permissions
        case .runTTSSidecarScript:
            return .voice
        case .configureMCPServer(_):
            return .mcp
        case .openLocalAIBridgeFolder:
            return .cloudBridge
        case .openSettings:
            return .general
        case nil:
            return firstCommandOutcome == .failed ? .doctor : nil
        }
    }

    private var firstCommandRecoveryTitle: String {
        switch firstCommandRecoveryDestination {
        case .permissions: return "Open Permissions"
        case .voice: return "Open Voice Settings"
        case .mcp: return "Open Connected Tools"
        case .cloudBridge: return "Open Off-Device Model Settings"
        case .doctor: return "Open Help & Diagnostics"
        default: return "Open Pace Settings"
        }
    }

    private func primaryButton(
        _ title: String,
        systemImage: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(PaceOnboardingPrimaryButtonStyle())
        .pointerCursor(isEnabled: isEnabled)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func secondaryButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(PaceOnboardingSecondaryButtonStyle())
            .pointerCursor()
    }

    private func advanceFromIgnition() {
        stateModel.send(.continueForward)
        saveCurrentCheckpoint()
    }

    private func advanceFromPermissions() {
        permissionAutoAdvanceTask?.cancel()
        permissionAutoAdvanceTask = nil
        stateModel.send(.continueForward)
        saveCurrentCheckpoint()
    }

    private func navigateBack() {
        guard canNavigateBack else { return }
        permissionAutoAdvanceTask?.cancel()
        permissionAutoAdvanceTask = nil
        if stateModel.stage == .firstCommand {
            resetFirstCommandForRetry()
        }
        stateModel.send(.goBack)
        saveCurrentCheckpoint()
    }

    private func skipJourney() {
        cancelDelayedWork()
        stateModel.send(.skipJourney)
        progressStore.markCompleted()
        onComplete()
    }

    private func saveCurrentCheckpoint() {
        progressStore.saveCheckpoint(from: stateModel)
    }

    private func schedulePermissionAutoAdvanceIfNeeded() {
        permissionAutoAdvanceTask?.cancel()
        permissionAutoAdvanceTask = nil

        guard stateModel.shouldSchedulePermissionAutoAdvance(
            allCorePermissionsGranted: allCorePermissionsGranted
        ) else { return }
        let transitionToken = delayedTransitionGate.schedule(for: .permissions)
        permissionAutoAdvanceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled,
                      delayedTransitionGate.shouldApply(
                        transitionToken,
                        currentStage: stateModel.stage
                      ) else { return }
                advanceFromPermissions()
            } catch {
                return
            }
        }
    }

    private func submitFirstCommand() {
        let exactCommandText = trimmedCommandText
        guard !exactCommandText.isEmpty, companionManager.voiceState == .idle else { return }

        handoffTask?.cancel()
        handoffTask = nil
        assistantMessageCountBeforeSubmission = chatSession.messages.filter { $0.role == .pace }.count
        actionIdentifiersBeforeSubmission = Set(companionManager.recentActionResults.map(\.id))
        failureNarrationBeforeSubmission = companionManager.lastFailureNarration
        firstCommandOutcome = .waiting
        submittedCommandText = exactCommandText
        firstCommandUsedOffDevicePlanner = false
        voiceFirstCommandIsArmed = false
        companionManager.submitChatTranscriptFromDeepLink(exactCommandText)
    }

    private func prepareForVoiceFirstCommandIfNeeded() {
        guard stateModel.stage == .firstCommand,
              submittedCommandText == nil,
              companionManager.voiceState == .listening else { return }

        assistantMessageCountBeforeSubmission = chatSession.messages.filter { $0.role == .pace }.count
        actionIdentifiersBeforeSubmission = Set(companionManager.recentActionResults.map(\.id))
        failureNarrationBeforeSubmission = companionManager.lastFailureNarration
        firstCommandOutcome = .waiting
        voiceFirstCommandIsArmed = true
    }

    private func captureVoiceFirstCommandIfNeeded() {
        guard stateModel.stage == .firstCommand,
              submittedCommandText == nil,
              voiceFirstCommandIsArmed,
              let finalizedVoiceTranscript = companionManager.lastTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !finalizedVoiceTranscript.isEmpty else { return }

        commandText = finalizedVoiceTranscript
        submittedCommandText = finalizedVoiceTranscript
        voiceFirstCommandIsArmed = false
        refreshFirstCommandOutcome()
    }

    private func refreshFirstCommandOutcome() {
        guard stateModel.stage == .firstCommand, submittedCommandText != nil else { return }

        let assistantMessageCount = chatSession.messages.filter { $0.role == .pace }.count
        let newActionRecord = companionManager.recentActionResults.first {
            !actionIdentifiersBeforeSubmission.contains($0.id)
        }
        let hasNewFailureNarration = companionManager.lastFailureNarration != nil
            && companionManager.lastFailureNarration != failureNarrationBeforeSubmission

        firstCommandOutcome = PaceFirstCommandOutcome.classify(
            hasNewAssistantResponse: assistantMessageCount > assistantMessageCountBeforeSubmission,
            latestActionStatus: newActionRecord?.status,
            isAwaitingApproval: newActionRecord?.status == .planned,
            hasFailureNarration: hasNewFailureNarration,
            requestIsInFlight: companionManager.voiceState != .idle
        )

    }

    private func continueFromFirstValue() {
        guard stateModel.stage == .firstCommand,
              firstCommandOutcome.allowsHandoff else { return }
        stateModel.send(.firstValue(firstCommandOutcome))
    }

    private func resetFirstCommandForRetry() {
        handoffTask?.cancel()
        handoffTask = nil
        delayedTransitionGate.cancel()
        submittedCommandText = nil
        firstCommandOutcome = .waiting
        firstCommandUsedOffDevicePlanner = false
        voiceFirstCommandIsArmed = false
        commandFieldIsFocused = true
    }

    private func beginHandoff() {
        handoffTask?.cancel()
        let transitionToken = delayedTransitionGate.schedule(for: .handoff)
        handoffTask = Task { @MainActor in
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.16)) {
                    handoffIsContracted = true
                }
                try? await Task.sleep(for: .milliseconds(220))
            } else {
                withAnimation(.easeInOut(duration: DS.Motion.handoff)) {
                    handoffIsContracted = true
                }
                try? await Task.sleep(for: .milliseconds(1_050))
            }

            guard !Task.isCancelled,
                  delayedTransitionGate.shouldApply(
                    transitionToken,
                    currentStage: stateModel.stage
                  ) else { return }
            stateModel.send(.handoffFinished)
        }
    }

    private func completeJourney() {
        progressStore.markCompleted()
        onComplete()
    }

    private func cancelDelayedWork() {
        delayedTransitionGate.cancel()
        permissionAutoAdvanceTask?.cancel()
        permissionAutoAdvanceTask = nil
        handoffTask?.cancel()
        handoffTask = nil
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in
                PacePermissionService.shared.refresh()
            }
        }
    }

    private func openSystemSettings(for permissionKind: PacePermissionKind) {
        let settingsURLString: String
        switch permissionKind {
        case .accessibility:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphone:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .camera:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .calendar:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .contacts:
            settingsURLString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
        }

        if let settingsURL = URL(string: settingsURLString) {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

private struct PaceOnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.calloutStrong)
            .foregroundStyle(DS.Colors.textOnAccent)
            .padding(.horizontal, 17)
            .frame(height: 38)
            .background(DS.Colors.localSignal.opacity(configuration.isPressed ? 0.74 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .shadow(color: DS.Colors.localSignal.opacity(0.22), radius: 10, x: 0, y: 5)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1))
            .animation(
                reduceMotion ? nil : .easeOut(duration: DS.Motion.micro),
                value: configuration.isPressed
            )
    }
}

private struct PaceOnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Typography.captionStrong)
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(DS.Colors.surfaceRaised.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            }
    }
}
