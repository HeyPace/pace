//
//  PaceMenuBarOverlay.swift
//  leanring-buddy
//
//  Extends the physical MacBook camera housing into Pace's ambient surface.
//  The idle frame comes from NSScreen's safe-area geometry. Pace never draws
//  a synthetic notch on displays that do not report a camera housing.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Pace's overlay hierarchy is centralized so ambient screen signals can
/// never cover the notch product. The glow remains above ordinary app
/// windows, the notch owns the menu-bar surface, and teaching annotations
/// stay topmost while they are intentionally visible.
enum PaceWindowLayering {
    static let screenActivityGlow = NSWindow.Level(
        rawValue: NSWindow.Level.mainMenu.rawValue - 1
    )
    static let livingNotch = NSWindow.Level(
        rawValue: NSWindow.Level.mainMenu.rawValue + 1
    )
    static let teachingOverlay = NSWindow.Level.screenSaver
}

private enum PaceLivingNotchMetrics {
    static let hoverBottomCornerRadius: CGFloat = 12
    static let activeBottomCornerRadius: CGFloat = 14
}

@MainActor
enum PaceLivingNotchScreenGeometryResolver {
    static func targetScreen() -> NSScreen? {
        if let mainScreen = NSScreen.main,
           geometry(for: mainScreen, displayMode: .hardwareIdle) != nil {
            return mainScreen
        }

        return NSScreen.screens.first {
            geometry(for: $0, displayMode: .hardwareIdle) != nil
        }
    }

    static func geometry(
        for screen: NSScreen,
        displayMode: PaceLivingNotchDisplayMode
    ) -> PaceLivingNotchGeometry? {
        PaceLivingNotchGeometry.resolve(
            screenFrame: screen.frame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
            displayMode: displayMode
        )
    }

    static func geometry(
        displayMode: PaceLivingNotchDisplayMode
    ) -> PaceLivingNotchGeometry? {
        guard let targetScreen = targetScreen() else { return nil }
        return geometry(for: targetScreen, displayMode: displayMode)
    }
}

private final class PaceMenuBarOverlayPanel: NSPanel {
    var permitsKeyWindow = false

    override var canBecomeKey: Bool { permitsKeyWindow }
    override var canBecomeMain: Bool { false }
}

private final class PaceMenuBarOverlayHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var shouldInterceptMouseDown: (() -> Bool)?

    private var mouseTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let mouseTrackingArea {
            removeTrackingArea(mouseTrackingArea)
        }

        let replacementTrackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(replacementTrackingArea)
        mouseTrackingArea = replacementTrackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        if shouldInterceptMouseDown?() == true {
            onMouseDown?()
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
private final class PaceLivingNotchSurfaceModel: ObservableObject {
    @Published var displayMode: PaceLivingNotchDisplayMode = .hardwareIdle
    @Published var physicalHousingWidth: CGFloat = 0
    @Published var physicalHousingHeight: CGFloat = 0
}

@MainActor
final class PaceMenuBarOverlayManager {
    private weak var companionManager: CompanionManager?
    private var overlayPanel: PaceMenuBarOverlayPanel?
    private var companionManagerObservation: AnyCancellable?
    private var companionControlCenterObservation: AnyCancellable?
    private var overlayPanelResignKeyObserver: NSObjectProtocol?
    private var clickOutsideMonitor: Any?
    private var localClickOutsideMonitor: Any?
    private var panelPresentedAt: Date?
    private var isHovering = false
    private var isQuickPanelPresented = false
    private var isVisible = false
    private let surfaceModel = PaceLivingNotchSurfaceModel()
    private let onTap: (NSRect) -> Void

    var isQuickPanelOpen: Bool {
        isQuickPanelPresented
    }

    init(companionManager: CompanionManager, onTap: @escaping (NSRect) -> Void) {
        self.companionManager = companionManager
        self.onTap = onTap

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        companionManagerObservation = companionManager.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPresentation(animated: true)
            }
        }
        companionControlCenterObservation = companionManager.companionControlCenter.objectWillChange.sink {
            [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshPresentation(animated: true)
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
        if let localClickOutsideMonitor {
            NSEvent.removeMonitor(localClickOutsideMonitor)
        }
        if let overlayPanelResignKeyObserver {
            NotificationCenter.default.removeObserver(overlayPanelResignKeyObserver)
        }
    }

    func show() {
        isVisible = true
        refreshPresentation(animated: false)
        overlayPanel?.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        removeClickOutsideMonitors()
        overlayPanel?.orderOut(nil)
    }

    func setQuickPanelPresented(_ isQuickPanelPresented: Bool) {
        guard self.isQuickPanelPresented != isQuickPanelPresented else { return }
        self.isQuickPanelPresented = isQuickPanelPresented
        if isQuickPanelPresented {
            panelPresentedAt = Date()
            installClickOutsideMonitors()
        } else {
            removeClickOutsideMonitors()
        }
        refreshPresentation(animated: true)

        guard let overlayPanel else { return }
        overlayPanel.permitsKeyWindow = isQuickPanelPresented
        if isQuickPanelPresented {
            overlayPanel.makeKeyAndOrderFront(nil)
            overlayPanel.orderFrontRegardless()
        } else {
            overlayPanel.resignKey()
            overlayPanel.orderFrontRegardless()
        }
    }

    private func createOverlayPanel(
        companionManager: CompanionManager,
        initialFrame: CGRect
    ) {
        let overlayView = PaceMenuBarOverlayView(
            companionManager: companionManager,
            surfaceModel: surfaceModel,
            onClose: { [weak self] in
                self?.setQuickPanelPresented(false)
            }
        )

        let hostingView = PaceMenuBarOverlayHostingView(rootView: overlayView)
        hostingView.frame = CGRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.onMouseDown = { [weak self] in
            self?.handleTap()
        }
        hostingView.shouldInterceptMouseDown = { [weak self] in
            self?.isQuickPanelPresented == false
        }
        hostingView.onHoverChanged = { [weak self] isHovering in
            self?.handleHoverChanged(isHovering)
        }

        let panel = PaceMenuBarOverlayPanel(
            contentRect: CGRect(origin: .zero, size: initialFrame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = PaceWindowLayering.livingNotch
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.permitsKeyWindow = isQuickPanelPresented
        panel.contentView = hostingView
        panel.setFrame(initialFrame, display: true)

        overlayPanelResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.isQuickPanelPresented,
                      Date().timeIntervalSince(self.panelPresentedAt ?? .distantPast) >= 0.45 else {
                    return
                }
                self.setQuickPanelPresented(false)
            }
        }

        overlayPanel = panel
    }

    private func refreshPresentation(animated: Bool) {
        guard isVisible, let companionManager else { return }

        let signalState = companionManager.nativeEffectiveSignalState
        let displayMode = PaceLivingNotchDisplayMode.resolve(
            signalState: signalState,
            isHovering: isHovering,
            showsPersistentRuntimeIndicator:
                companionManager.companionControlCenter.preferences.isCompanionModeEnabled,
            isPanelOpen: isQuickPanelPresented
        )

        guard let geometry = PaceLivingNotchScreenGeometryResolver.geometry(
            displayMode: displayMode
        ) else {
            overlayPanel?.orderOut(nil)
            return
        }

        if overlayPanel == nil {
            createOverlayPanel(
                companionManager: companionManager,
                initialFrame: geometry.presentationFrame
            )
        }

        surfaceModel.displayMode = displayMode
        surfaceModel.physicalHousingWidth = geometry.physicalHousingFrame.width
        surfaceModel.physicalHousingHeight = geometry.physicalHousingFrame.height
        guard let overlayPanel else { return }

        let shouldAnimate = animated
            && overlayPanel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.34
                animationContext.timingFunction = CAMediaTimingFunction(
                    name: .easeOut
                )
                overlayPanel.animator().setFrame(geometry.presentationFrame, display: true)
            }
        } else {
            overlayPanel.setFrame(geometry.presentationFrame, display: true)
        }

        overlayPanel.orderFrontRegardless()
    }

    private func handleTap() {
        guard let overlayPanel else { return }
        onTap(overlayPanel.frame)
    }

    private func installClickOutsideMonitors() {
        removeClickOutsideMonitors()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissPanelIfClickIsOutside()
        }
        localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissPanelIfClickIsOutside()
            return event
        }
    }

    private func dismissPanelIfClickIsOutside() {
        guard isQuickPanelPresented, let overlayPanel else { return }
        if let panelPresentedAt,
           Date().timeIntervalSince(panelPresentedAt) < 0.45 {
            return
        }
        guard overlayPanel.frame.contains(NSEvent.mouseLocation) == false else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isQuickPanelPresented else { return }
            self.setQuickPanelPresented(false)
        }
    }

    private func removeClickOutsideMonitors() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
        if let localClickOutsideMonitor {
            NSEvent.removeMonitor(localClickOutsideMonitor)
            self.localClickOutsideMonitor = nil
        }
    }

    private func handleHoverChanged(_ isHovering: Bool) {
        guard self.isHovering != isHovering else { return }
        self.isHovering = isHovering
        refreshPresentation(animated: true)
    }

    @objc private func screenParametersDidChange() {
        refreshPresentation(animated: false)
    }

    @objc private func workspaceDidWake() {
        refreshPresentation(animated: false)
    }
}

private struct PaceMenuBarOverlayView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var surfaceModel: PaceLivingNotchSurfaceModel
    @ObservedObject private var companionControlCenter: PaceCompanionControlCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onClose: () -> Void

    init(
        companionManager: CompanionManager,
        surfaceModel: PaceLivingNotchSurfaceModel,
        onClose: @escaping () -> Void
    ) {
        self.companionManager = companionManager
        self.surfaceModel = surfaceModel
        self.onClose = onClose
        self._companionControlCenter = ObservedObject(
            wrappedValue: companionManager.companionControlCenter
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if surfaceModel.displayMode != .hardwareIdle {
                livingNotchHeader
                    .frame(height: surfaceModel.physicalHousingHeight)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .move(edge: .top).combined(with: .opacity)
                    )
            } else {
                Color.clear
                    .frame(height: surfaceModel.physicalHousingHeight)
            }

            if surfaceModel.displayMode == .panelOpen {
                PacePanelChatView(
                    companionManager: companionManager,
                    isEmbeddedInLivingNotch: true
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .scale(scale: 0.86, anchor: .top).combined(with: .opacity)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(notchShape)
        .contentShape(
            notchShape
        )
        .shadow(
            color: surfaceModel.displayMode == .panelOpen
                ? Color.black.opacity(0.55)
                : Color.clear,
            radius: 14,
            x: 0,
            y: 8
        )
        .help(companionControlCenter.preferences.isCompanionModeEnabled
            ? companionControlCenter.runtimeStatusText
            : statusText)
        .accessibilityElement(
            children: surfaceModel.displayMode == .panelOpen ? .contain : .ignore
        )
        .accessibilityLabel("Pace")
        .accessibilityValue(
            "\(signalPresentation.accessibilityValue)\(captureAccessibilityDescription) Press \(PaceNotchChatShortcut.currentShortcutAccessibilityLabel) to open Pace."
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            NotificationCenter.default.post(name: .paceShowPanel, object: nil)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82),
            value: surfaceModel.displayMode
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: DS.Motion.stateChange),
            value: signalState
        )
        .onChange(of: signalState) { _, newSignalState in
            announceAccessibilityState(newSignalState)
        }
        .onChange(of: companionManager.isOffDeviceTurnInFlight) { _, isOffDeviceTurn in
            guard isOffDeviceTurn else { return }
            announceAccessibilityState(signalState)
        }
    }

    private var livingNotchHeader: some View {
        HStack(spacing: 0) {
            Text(livingNotchPrimaryLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    alignment: .leading
                )

            Color.clear
                .frame(width: surfaceModel.physicalHousingWidth)

            HStack(spacing: 5) {
                if surfaceModel.displayMode != .panelOpen {
                    PaceNotchBrandMark(
                        signalState: signalState,
                        isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                        audioPowerLevel: companionManager.currentAudioPowerLevel
                    )

                    PaceCompanionCaptureIndicators(controlCenter: companionControlCenter)
                }

                if surfaceModel.displayMode == .panelOpen {
                    notchControlButton(
                        systemName: "gearshape",
                        help: "Open Pace settings"
                    ) {
                        PaceSettingsWindowManager.shared.show(companionManager: companionManager)
                        onClose()
                    }
                    .keyboardShortcut(",", modifiers: [.command])

                    notchControlButton(
                        systemName: "xmark",
                        help: "Close Pace"
                    ) {
                        onClose()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
            }
            .frame(
                maxWidth: .infinity,
                alignment: .trailing
            )
        }
        .padding(.horizontal, surfaceModel.displayMode == .panelOpen ? 18 : 10)
        .pointerCursor()
    }

    private var livingNotchPrimaryLabel: String {
        guard surfaceModel.displayMode != .panelOpen else {
            return "Pace"
        }

        let currentTurnHUDState = companionManager.currentTurnHUDState
        switch currentTurnHUDState.status {
        case .idle:
            return "Pace"
        case .listening:
            return currentTurnHUDState.title
        case .understanding, .acting:
            return preferredLiveStatusText(
                detail: currentTurnHUDState.detail,
                fallback: currentTurnHUDState.title
            )
        case .needsClarification:
            return currentTurnHUDState.title
        case .done:
            return preferredLiveStatusText(
                detail: currentTurnHUDState.detail,
                fallback: companionManager.recentActionResults.first?.title ?? currentTurnHUDState.title
            )
        case .failed, .unsupported:
            return preferredLiveStatusText(
                detail: currentTurnHUDState.detail,
                fallback: currentTurnHUDState.title
            )
        }
    }

    private func preferredLiveStatusText(detail: String?, fallback: String) -> String {
        guard let detail,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return detail
    }

    private func notchControlButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.72))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(help)
        .accessibilityLabel(help)
    }

    private var bottomCornerRadius: CGFloat {
        switch surfaceModel.displayMode {
        case .hardwareIdle:
            return 11
        case .hover:
            return PaceLivingNotchMetrics.hoverBottomCornerRadius
        case .active, .panelOpen:
            return PaceLivingNotchMetrics.activeBottomCornerRadius
        }
    }

    private var notchShape: PaceExtendedNotchShape {
        PaceExtendedNotchShape(
            topShoulderRadius: surfaceModel.displayMode == .panelOpen ? 8 : 6,
            bottomCornerRadius: surfaceModel.displayMode == .panelOpen
                ? 20
                : bottomCornerRadius
        )
    }

    private var statusText: String {
        guard companionManager.allPermissionsGranted else {
            return "Setup"
        }

        switch companionManager.voiceState {
        case .idle:
            if companionControlCenter.preferences.isCompanionModeEnabled {
                return "Pace — \(companionControlCenter.runtimeStatusText)"
            }
            return companionManager.isLMStudioReachable ? "Pace" : "Local offline"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    private var signalState: PaceSignalState {
        companionManager.nativeEffectiveSignalState
    }

    private var signalPresentation: PaceSignalPresentation {
        PaceSignalPresentation.resolve(
            state: signalState,
            isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
            reduceMotion: reduceMotion
        )
    }

    private var captureAccessibilityDescription: String {
        var activeCaptureDescriptions: [String] = []
        if companionControlCenter.activeSources.contains(.camera) {
            activeCaptureDescriptions.append("Camera active")
        }
        if companionControlCenter.activeSources.contains(.screen) {
            activeCaptureDescriptions.append("Screen active")
        }
        if companionControlCenter.preferences.isCompanionModeEnabled,
           activeCaptureDescriptions.isEmpty {
            activeCaptureDescriptions.append(
                "Companion mode \(companionControlCenter.runtimeStatusText.lowercased())"
            )
        }

        guard activeCaptureDescriptions.isEmpty == false else { return "" }
        return " \(activeCaptureDescriptions.joined(separator: ". "))."
    }

    private func announceAccessibilityState(_ signalState: PaceSignalState) {
        guard let announcement = PaceSignalPresentation.accessibilityAnnouncement(
            for: signalState,
            isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight
        ) else { return }

        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}

private struct PaceNotchBrandMark: View {
    let signalState: PaceSignalState
    let isOffDeviceTurn: Bool
    let audioPowerLevel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CodexArrowShape()
                .fill(
                    LinearGradient(
                        colors: [
                            markColor.opacity(0.72),
                            markColor,
                            markColor.opacity(0.82),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            CodexArrowShape()
                .stroke(
                    Color.white.opacity(isActiveRequest ? 0.5 : 0.28),
                    style: StrokeStyle(lineWidth: 0.55, lineCap: .round, lineJoin: .round)
                )
                .blendMode(.plusLighter)
        }
        .frame(width: 11, height: 13)
        .rotationEffect(.degrees(45))
        .scaleEffect(markScale)
        .opacity(isActiveRequest ? 1 : 0.78)
        .shadow(
            color: markColor.opacity(isActiveRequest ? 0.72 : 0.3),
            radius: isActiveRequest ? 6 : 3
        )
        .frame(width: 24, height: 18)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.08),
            value: audioPowerLevel
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: DS.Motion.stateChange),
            value: signalState
        )
        .accessibilityHidden(true)
    }

    private var markColor: Color {
        isOffDeviceTurn ? DS.Colors.offDeviceSignal : DS.Colors.localSignal
    }

    private var markScale: CGFloat {
        guard !reduceMotion else { return 1 }
        guard signalState == .listening else {
            return isActiveRequest ? 1.06 : 1
        }

        let normalizedAudioPowerLevel = min(max(audioPowerLevel * 3.2, 0), 1)
        return 1.06 + (normalizedAudioPowerLevel * 0.28)
    }

    private var isActiveRequest: Bool {
        switch signalState {
        case .listening, .understanding, .awaitingApproval, .acting, .speaking:
            return true
        case .ready, .completed, .blocked, .failed:
            return false
        }
    }
}

private struct PaceCompanionCaptureIndicators: View {
    @ObservedObject var controlCenter: PaceCompanionControlCenter

    var body: some View {
        HStack(spacing: 1.5) {
            if controlCenter.activeSources.contains(.camera) {
                indicator(color: .green, label: "Camera active")
            }
            if controlCenter.activeSources.contains(.screen) {
                indicator(color: .cyan, label: "Screen active")
            }
            if controlCenter.preferences.isCompanionModeEnabled,
               controlCenter.activeSources.contains(.camera) == false,
               controlCenter.activeSources.contains(.screen) == false {
                indicator(color: runtimeColor, label: controlCenter.runtimeStatusText)
            }
        }
        .help(controlCenter.runtimeStatusText)
    }

    private func indicator(color: Color, label: String) -> some View {
        Circle()
            .fill(color)
            .frame(width: 5, height: 5)
            .overlay(Circle().stroke(Color.black.opacity(0.8), lineWidth: 0.5))
            .accessibilityLabel(label)
    }

    private var runtimeColor: Color {
        switch controlCenter.runtimeState {
        case .observing: return .green
        case .interpreting: return .cyan
        case .paused: return .yellow
        case .degraded: return .orange
        case .privacyBlocked: return .red
        case .off, .starting: return .gray
        }
    }
}

private struct PaceExtendedNotchShape: Shape {
    let topShoulderRadius: CGFloat
    let bottomCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let resolvedTopShoulderRadius = min(topShoulderRadius, rect.width / 4, rect.height / 2)
        let resolvedBottomCornerRadius = min(
            bottomCornerRadius,
            rect.width / 4,
            rect.height / 2
        )

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.minY + resolvedTopShoulderRadius
            ),
            control1: CGPoint(
                x: rect.minX + (resolvedTopShoulderRadius * 0.7),
                y: rect.minY
            ),
            control2: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.minY + (resolvedTopShoulderRadius * 0.35)
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius
            )
        )
        path.addQuadCurve(
            to: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius + resolvedBottomCornerRadius,
                y: rect.maxY
            ),
            control: CGPoint(
                x: rect.minX + resolvedTopShoulderRadius,
                y: rect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius - resolvedBottomCornerRadius,
                y: rect.maxY
            )
        )
        path.addQuadCurve(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY - resolvedBottomCornerRadius
            ),
            control: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.maxY
            )
        )
        path.addLine(
            to: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.minY + resolvedTopShoulderRadius
            )
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(
                x: rect.maxX - resolvedTopShoulderRadius,
                y: rect.minY + (resolvedTopShoulderRadius * 0.35)
            ),
            control2: CGPoint(
                x: rect.maxX - (resolvedTopShoulderRadius * 0.7),
                y: rect.minY
            )
        )
        path.closeSubpath()
        return path
    }
}
