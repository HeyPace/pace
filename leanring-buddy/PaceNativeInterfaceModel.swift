//
//  PaceNativeInterfaceModel.swift
//  leanring-buddy
//
//  Pure state and routing models shared by Pace's native surfaces.
//

import CoreGraphics
import Foundation

nonisolated enum PaceQuickPanelMetrics {
    static let width: CGFloat = 520
    static let height: CGFloat = 320
}

nonisolated enum PaceSignalState: String, CaseIterable, Equatable {
    case ready
    case listening
    case understanding
    case awaitingApproval
    case acting
    case speaking
    case completed
    case blocked
    case failed
}

nonisolated enum PaceLivingNotchDisplayMode: Equatable {
    case hardwareIdle
    case hover
    case active
    case panelOpen

    static func resolve(
        signalState: PaceSignalState,
        isHovering: Bool,
        showsPersistentRuntimeIndicator: Bool,
        isPanelOpen: Bool = false
    ) -> PaceLivingNotchDisplayMode {
        if isPanelOpen {
            return .panelOpen
        }

        if signalState != .ready || showsPersistentRuntimeIndicator {
            return .active
        }

        return isHovering ? .hover : .hardwareIdle
    }

    var additionalHeight: CGFloat {
        switch self {
        case .hardwareIdle, .hover, .active:
            return 0
        case .panelOpen:
            return PaceQuickPanelMetrics.height
        }
    }

    var preferredWidth: CGFloat? {
        switch self {
        case .hardwareIdle:
            return nil
        case .hover:
            return 300
        case .active:
            return 340
        case .panelOpen:
            return PaceQuickPanelMetrics.width
        }
    }
}

nonisolated struct PaceLivingNotchGeometry: Equatable {
    let physicalHousingFrame: CGRect
    let presentationFrame: CGRect

    static func resolve(
        screenFrame: CGRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        displayMode: PaceLivingNotchDisplayMode
    ) -> PaceLivingNotchGeometry? {
        guard safeAreaTopInset > 0,
              let auxiliaryTopLeftArea,
              let auxiliaryTopRightArea else {
            return nil
        }

        let physicalHousingWidth = auxiliaryTopRightArea.minX - auxiliaryTopLeftArea.maxX
        let physicalHousingMinimumY = screenFrame.maxY - safeAreaTopInset
        let geometryTolerance: CGFloat = 1

        guard physicalHousingWidth > 0,
              abs(auxiliaryTopLeftArea.maxY - screenFrame.maxY) <= geometryTolerance,
              abs(auxiliaryTopRightArea.maxY - screenFrame.maxY) <= geometryTolerance,
              abs(auxiliaryTopLeftArea.minY - physicalHousingMinimumY) <= geometryTolerance,
              abs(auxiliaryTopRightArea.minY - physicalHousingMinimumY) <= geometryTolerance else {
            return nil
        }

        let physicalHousingFrame = CGRect(
            x: auxiliaryTopLeftArea.maxX,
            y: physicalHousingMinimumY,
            width: physicalHousingWidth,
            height: safeAreaTopInset
        )
        let presentationHeight = safeAreaTopInset + displayMode.additionalHeight
        let maximumPresentationWidth = max(physicalHousingWidth, screenFrame.width - 16)
        let presentationWidth = min(
            max(physicalHousingWidth, displayMode.preferredWidth ?? physicalHousingWidth),
            maximumPresentationWidth
        )
        let centeredPresentationMinimumX = physicalHousingFrame.midX - (presentationWidth / 2)
        let presentationMinimumX = min(
            max(centeredPresentationMinimumX, screenFrame.minX + 8),
            screenFrame.maxX - presentationWidth - 8
        )
        let presentationFrame = CGRect(
            x: presentationMinimumX,
            y: screenFrame.maxY - presentationHeight,
            width: presentationWidth,
            height: presentationHeight
        )

        return PaceLivingNotchGeometry(
            physicalHousingFrame: physicalHousingFrame,
            presentationFrame: presentationFrame
        )
    }
}

nonisolated enum PaceSignalColorRole: Equatable {
    case local
    case offDevice
    case approval
    case success
    case blocked
    case failure
}

nonisolated enum PaceSignalMotionPolicy: Equatable {
    case still
    case crossfade
    case audioReactive
}

nonisolated struct PaceSignalPresentation: Equatable {
    let label: String
    let compactLabel: String
    let accessibilityValue: String
    let colorRole: PaceSignalColorRole
    let motionPolicy: PaceSignalMotionPolicy

    static func resolve(
        state: PaceSignalState,
        isOffDeviceTurn: Bool,
        reduceMotion: Bool
    ) -> PaceSignalPresentation {
        let label = label(for: state)
        let boundaryDescription = isOffDeviceTurn
            ? "Off-device planner active"
            : "Processing on this Mac"

        return PaceSignalPresentation(
            label: label,
            compactLabel: compactLabel(for: state),
            accessibilityValue: "\(label). \(boundaryDescription).",
            colorRole: colorRole(for: state, isOffDeviceTurn: isOffDeviceTurn),
            motionPolicy: motionPolicy(for: state, reduceMotion: reduceMotion)
        )
    }

    private static func label(for state: PaceSignalState) -> String {
        switch state {
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .understanding: return "Understanding"
        case .awaitingApproval: return "Waiting for approval"
        case .acting: return "Acting"
        case .speaking: return "Speaking"
        case .completed: return "Complete"
        case .blocked: return "Needs attention"
        case .failed: return "Couldn’t complete"
        }
    }

    private static func compactLabel(for state: PaceSignalState) -> String {
        switch state {
        case .ready: return "Ready"
        case .listening: return "Listening"
        case .understanding: return "Thinking"
        case .awaitingApproval: return "Approval"
        case .acting: return "Acting"
        case .speaking: return "Speaking"
        case .completed: return "Complete"
        case .blocked: return "Attention"
        case .failed: return "Failed"
        }
    }

    static func accessibilityAnnouncement(
        for state: PaceSignalState,
        isOffDeviceTurn: Bool
    ) -> String? {
        let processingLocation = isOffDeviceTurn
            ? "using the off-device model you enabled"
            : "on this Mac"

        switch state {
        case .ready:
            return nil
        case .listening:
            return "Pace is listening."
        case .understanding:
            return "Pace is understanding your request \(processingLocation)."
        case .awaitingApproval:
            return "Pace is waiting for your approval."
        case .acting:
            return "Pace is carrying out the approved action \(processingLocation)."
        case .speaking:
            return "Pace is responding."
        case .completed:
            return "Pace completed the request."
        case .blocked:
            return "Pace needs your attention before it can continue."
        case .failed:
            return "Pace could not complete the request. Open the panel for recovery options."
        }
    }

    private static func colorRole(
        for state: PaceSignalState,
        isOffDeviceTurn: Bool
    ) -> PaceSignalColorRole {
        if isOffDeviceTurn {
            return .offDevice
        }

        switch state {
        case .ready, .listening, .understanding, .acting, .speaking:
            return .local
        case .awaitingApproval:
            return .approval
        case .completed:
            return .success
        case .blocked:
            return .blocked
        case .failed:
            return .failure
        }
    }

    private static func motionPolicy(
        for state: PaceSignalState,
        reduceMotion: Bool
    ) -> PaceSignalMotionPolicy {
        guard !reduceMotion else {
            return state == .ready ? .still : .crossfade
        }

        switch state {
        case .ready, .completed, .blocked, .failed:
            return .still
        case .listening:
            return .audioReactive
        case .understanding, .awaitingApproval, .acting, .speaking:
            return .crossfade
        }
    }
}

nonisolated enum PaceSignalInterruptionOutcome: Equatable {
    case hidden
    case settle(PaceSignalState)

    static func resolve(
        latestState: PaceSignalState,
        surfaceIsVisible: Bool
    ) -> PaceSignalInterruptionOutcome {
        surfaceIsVisible ? .settle(latestState) : .hidden
    }
}

nonisolated enum PaceRuntimeVoicePhase: Equatable {
    case idle
    case listening
    case processing
    case responding
}

nonisolated enum PaceRuntimeHUDPhase: Equatable {
    case idle
    case listening
    case understanding
    case acting
    case needsClarification
    case done
    case failed
    case unsupported
}

nonisolated struct PacePanelPresentationModel: Equatable {
    let signalState: PaceSignalState
    let showsEmptyState: Bool

    static func resolve(
        voicePhase: PaceRuntimeVoicePhase,
        hudPhase: PaceRuntimeHUDPhase,
        latestActionStatus: PaceActionRunStatus?,
        hasConversationContent: Bool,
        hasLiveTranscript: Bool,
        hasStreamedResponse: Bool
    ) -> PacePanelPresentationModel {
        let signalState: PaceSignalState
        switch hudPhase {
        case .listening:
            signalState = .listening
        case .understanding:
            signalState = .understanding
        case .acting:
            signalState = latestActionStatus == .planned ? .awaitingApproval : .acting
        case .needsClarification, .unsupported:
            signalState = .blocked
        case .done:
            signalState = .completed
        case .failed:
            signalState = .failed
        case .idle:
            switch voicePhase {
            case .idle: signalState = .ready
            case .listening: signalState = .listening
            case .processing: signalState = .understanding
            case .responding: signalState = .speaking
            }
        }

        return PacePanelPresentationModel(
            signalState: signalState,
            showsEmptyState: !hasConversationContent
                && !hasLiveTranscript
                && !hasStreamedResponse
        )
    }
}

nonisolated enum PaceFirstCommandOutcome: Equatable {
    case waiting
    case responseReceived
    case awaitingApproval
    case actionCompleted
    case blocked
    case failed

    var allowsHandoff: Bool {
        self == .responseReceived || self == .actionCompleted
    }

    static func classify(
        hasNewAssistantResponse: Bool,
        latestActionStatus: PaceActionRunStatus?,
        isAwaitingApproval: Bool,
        hasFailureNarration: Bool,
        requestIsInFlight: Bool
    ) -> PaceFirstCommandOutcome {
        if hasFailureNarration || latestActionStatus == .failed {
            return .failed
        }

        if latestActionStatus == .denied || latestActionStatus == .skipped {
            return .blocked
        }

        if isAwaitingApproval || latestActionStatus == .planned {
            return .awaitingApproval
        }

        if latestActionStatus == .completed {
            return .actionCompleted
        }

        if hasNewAssistantResponse {
            return .responseReceived
        }

        if requestIsInFlight {
            return .waiting
        }

        return .waiting
    }
}

nonisolated enum PaceOnboardingStage: Int, CaseIterable, Codable, Equatable {
    case ignition
    case permissions
    case firstCommand
    case handoff
    case complete
}

nonisolated enum PaceOnboardingEvent: Equatable {
    case continueForward
    case goBack
    case skipJourney
    case firstValue(PaceFirstCommandOutcome)
    case handoffFinished
    case replayRequested
}

nonisolated struct PaceOnboardingStateModel: Equatable {
    static let currentVersion = 2
    static let legacyCompletionVersion = 1

    private(set) var stage: PaceOnboardingStage
    private(set) var isReplay: Bool

    init(
        storedCompletionVersion: Int?,
        legacyCompletionFlag: Bool,
        storedCheckpoint: Int?,
        isReplay: Bool = false
    ) {
        self.isReplay = isReplay

        if isReplay {
            stage = .ignition
            return
        }

        let effectiveCompletionVersion = max(
            storedCompletionVersion ?? 0,
            legacyCompletionFlag ? Self.legacyCompletionVersion : 0
        )
        if effectiveCompletionVersion >= Self.legacyCompletionVersion {
            stage = .complete
            return
        }

        if let storedCheckpoint,
           let checkpointStage = PaceOnboardingStage(rawValue: storedCheckpoint),
           checkpointStage != .complete,
           checkpointStage != .handoff {
            stage = checkpointStage
        } else {
            stage = .ignition
        }
    }

    mutating func send(_ event: PaceOnboardingEvent) {
        switch event {
        case .continueForward:
            switch stage {
            case .ignition: stage = .permissions
            case .permissions: stage = .firstCommand
            case .firstCommand, .handoff, .complete: break
            }
        case .goBack:
            switch stage {
            case .permissions: stage = .ignition
            case .firstCommand: stage = .permissions
            case .ignition, .handoff, .complete: break
            }
        case .skipJourney:
            stage = .complete
        case .firstValue(let outcome):
            if stage == .firstCommand, outcome.allowsHandoff {
                stage = .handoff
            }
        case .handoffFinished:
            if stage == .handoff {
                stage = .complete
            }
        case .replayRequested:
            isReplay = true
            stage = .ignition
        }
    }

    var shouldPresentAutomatically: Bool {
        !isReplay && stage != .complete
    }

    var checkpointValue: Int? {
        switch stage {
        case .ignition, .permissions, .firstCommand:
            return stage.rawValue
        case .handoff, .complete:
            return nil
        }
    }

    func shouldSchedulePermissionAutoAdvance(
        allCorePermissionsGranted: Bool
    ) -> Bool {
        stage == .permissions && allCorePermissionsGranted
    }
}

nonisolated struct PaceOnboardingDelayedTransitionToken: Equatable {
    fileprivate let generation: Int
    let stage: PaceOnboardingStage
}

nonisolated struct PaceOnboardingDelayedTransitionGate: Equatable {
    private var generation = 0

    mutating func schedule(
        for stage: PaceOnboardingStage
    ) -> PaceOnboardingDelayedTransitionToken {
        generation += 1
        return PaceOnboardingDelayedTransitionToken(
            generation: generation,
            stage: stage
        )
    }

    mutating func cancel() {
        generation += 1
    }

    func shouldApply(
        _ token: PaceOnboardingDelayedTransitionToken,
        currentStage: PaceOnboardingStage
    ) -> Bool {
        token.generation == generation && token.stage == currentStage
    }
}

@MainActor
final class PaceOnboardingProgressStore {
    static let shared = PaceOnboardingProgressStore()

    static let legacyCompletionKey = "hasCompletedOnboarding"
    static let completionVersionKey = "paceOnboardingCompletionVersion"
    static let checkpointKey = "paceOnboardingCheckpoint"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadState(isReplay: Bool = false) -> PaceOnboardingStateModel {
        let storedCompletionVersion: Int?
        if userDefaults.object(forKey: Self.completionVersionKey) == nil {
            storedCompletionVersion = nil
        } else {
            storedCompletionVersion = userDefaults.integer(forKey: Self.completionVersionKey)
        }

        let storedCheckpoint: Int?
        if userDefaults.object(forKey: Self.checkpointKey) == nil {
            storedCheckpoint = nil
        } else {
            storedCheckpoint = userDefaults.integer(forKey: Self.checkpointKey)
        }

        return PaceOnboardingStateModel(
            storedCompletionVersion: storedCompletionVersion,
            legacyCompletionFlag: userDefaults.bool(forKey: Self.legacyCompletionKey),
            storedCheckpoint: storedCheckpoint,
            isReplay: isReplay
        )
    }

    func saveCheckpoint(from stateModel: PaceOnboardingStateModel) {
        if let checkpointValue = stateModel.checkpointValue {
            userDefaults.set(checkpointValue, forKey: Self.checkpointKey)
        } else {
            userDefaults.removeObject(forKey: Self.checkpointKey)
        }
    }

    func markCompleted() {
        userDefaults.set(
            PaceOnboardingStateModel.currentVersion,
            forKey: Self.completionVersionKey
        )
        userDefaults.set(true, forKey: Self.legacyCompletionKey)
        userDefaults.removeObject(forKey: Self.checkpointKey)
    }
}

nonisolated enum PaceCommandCenterGroup: String, CaseIterable, Identifiable {
    case work = "Use Pace"
    case observe = "Activity & Privacy"
    case configure = "Customize"
    case diagnostics = "Help"

    var id: String { rawValue }
}

nonisolated enum PaceCommandCenterDestination: String, CaseIterable, Identifiable {
    case conversations
    case skills
    case flows
    case tasks
    case usage
    case activity
    case memory
    case privacy
    case permissions
    case general
    case planner
    case models
    case research
    case proactive
    case companion
    case mcp
    case voice
    case cloudBridge
    case about
    case debug
    case doctor

    var id: String { rawValue }

    var group: PaceCommandCenterGroup {
        switch self {
        case .conversations, .skills, .flows, .tasks:
            return .work
        case .usage, .activity, .privacy, .permissions:
            return .observe
        case .general, .planner, .models, .research, .proactive, .companion, .memory,
             .mcp, .voice, .cloudBridge:
            return .configure
        case .about, .debug, .doctor:
            return .diagnostics
        }
    }

    var title: String {
        switch self {
        case .conversations: return "Conversations"
        case .skills: return "Automations"
        case .flows: return "Multi-step automations"
        case .tasks: return "Scheduled tasks"
        case .usage: return "Local usage"
        case .activity: return "Activity history"
        case .memory: return "Memory"
        case .privacy: return "Privacy"
        case .permissions: return "Permissions"
        case .general: return "General"
        case .planner: return "How Pace thinks"
        case .models: return "Models on this Mac"
        case .research: return "Research mode"
        case .proactive: return "Background suggestions"
        case .companion: return "Companion mode"
        case .mcp: return "Connected apps & tools"
        case .voice: return "Voice"
        case .cloudBridge: return "Off-device model"
        case .about: return "About"
        case .debug: return "Developer details"
        case .doctor: return "Help & diagnostics"
        }
    }

    var subtitle: String {
        switch self {
        case .conversations: return "Review what you and Pace have discussed."
        case .skills: return "Browse and teach reusable actions in plain language."
        case .flows: return "Build repeatable sequences from several actions."
        case .tasks: return "Review work Pace runs on a schedule."
        case .usage: return "See local model and feature usage on this Mac."
        case .activity: return "Inspect actions, outcomes, and approvals in order."
        case .memory: return "Choose what Pace may remember between conversations."
        case .privacy: return "See where processing happened and what data was used."
        case .permissions: return "Control the macOS access behind each capability."
        case .general: return "Set startup, interface, and everyday behavior."
        case .planner: return "Choose how Pace turns requests into safe steps."
        case .models: return "Manage the on-device models Pace uses."
        case .research: return "Control deeper, multi-source research behavior."
        case .proactive: return "Decide when Pace may offer help without being asked."
        case .companion: return "Configure optional background awareness."
        case .mcp: return "Connect additional tools while keeping boundaries visible."
        case .voice: return "Choose listening, transcription, and spoken-response behavior."
        case .cloudBridge: return "Configure an explicitly off-device reasoning option."
        case .about: return "Version information and Pace’s local-first promise."
        case .debug: return "Inspect low-level runtime information for troubleshooting."
        case .doctor: return "Check readiness and recover from setup problems."
        }
    }

    var isAdvanced: Bool {
        switch self {
        case .usage, .planner, .research, .proactive, .companion, .mcp,
             .cloudBridge, .debug:
            return true
        case .conversations, .skills, .flows, .tasks, .activity, .memory,
             .privacy, .permissions, .general, .models, .voice, .about, .doctor:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .conversations: return "bubble.left.and.bubble.right"
        case .skills: return "square.grid.2x2"
        case .flows: return "play.square.stack"
        case .tasks: return "clock.arrow.circlepath"
        case .usage: return "chart.bar"
        case .activity: return "list.bullet.rectangle"
        case .memory: return "brain"
        case .privacy: return "hand.raised"
        case .permissions: return "lock.shield"
        case .general: return "switch.2"
        case .planner: return "brain.head.profile"
        case .models: return "shippingbox"
        case .research: return "magnifyingglass.circle"
        case .proactive: return "bell.badge"
        case .companion: return "sensor.tag.radiowaves.forward"
        case .mcp: return "point.3.connected.trianglepath.dotted"
        case .voice: return "waveform"
        case .cloudBridge: return "antenna.radiowaves.left.and.right"
        case .about: return "info.circle"
        case .debug: return "ladybug"
        case .doctor: return "stethoscope"
        }
    }

    static func destinations(in group: PaceCommandCenterGroup) -> [PaceCommandCenterDestination] {
        allCases.filter { $0.group == group }
    }

    static func primaryDestinations(
        in group: PaceCommandCenterGroup
    ) -> [PaceCommandCenterDestination] {
        destinations(in: group).filter { !$0.isAdvanced }
    }

    static var advancedDestinations: [PaceCommandCenterDestination] {
        allCases.filter(\.isAdvanced)
    }

    static func resolve(
        requestedDestination: PaceCommandCenterDestination?,
        storedDestinationRawValue: String?
    ) -> PaceCommandCenterDestination {
        if let requestedDestination {
            return requestedDestination
        }

        if let storedDestinationRawValue,
           let storedDestination = PaceCommandCenterDestination(rawValue: storedDestinationRawValue) {
            return storedDestination
        }

        return .conversations
    }
}
