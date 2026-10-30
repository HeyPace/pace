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
import SaaSMakerUI
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

@MainActor
enum PaceLivingNotchScreenGeometryResolver {
    static func targetScreen() -> NSScreen? {
        if let mainScreen = NSScreen.main,
            geometry(for: mainScreen, displayMode: .hardwareIdle) != nil
        {
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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PaceMenuBarOverlayHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

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
        onMouseDown?()
    }

}

@MainActor
private final class PaceLivingNotchSurfaceModel: ObservableObject {
    @Published var displayMode: PaceLivingNotchDisplayMode = .hardwareIdle
    @Published var physicalHousingWidth: CGFloat = 0
    @Published var physicalHousingHeight: CGFloat = 0
}

private struct PaceLivingNotchAccessibilityModifier: ViewModifier {
    let accessibilityValue: String
    let openPanel: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pace")
            .accessibilityValue(accessibilityValue)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openPanel() }
    }
}

@MainActor
final class PaceMenuBarOverlayManager {
    private weak var companionManager: CompanionManager?
    private var overlayPanel: PaceMenuBarOverlayPanel?
    private var fallbackMenuBarStatusItem: NSStatusItem?
    private var companionManagerObservation: AnyCancellable?
    private var companionControlCenterObservation: AnyCancellable?
    private var isHovering = false
    private var isVisible = false
    private var lastAppliedDisplayMode: PaceLivingNotchDisplayMode?
    private var lastAppliedGeometry: PaceLivingNotchGeometry?
    private let surfaceModel = PaceLivingNotchSurfaceModel()
    private let onTap: (NSRect) -> Void

    init(
        companionManager: CompanionManager,
        onTap: @escaping (NSRect) -> Void
    ) {
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
        if let fallbackMenuBarStatusItem {
            NSStatusBar.system.removeStatusItem(fallbackMenuBarStatusItem)
        }

    }

    func show() {
        isVisible = true
        refreshPresentation(animated: false)
        overlayPanel?.orderFrontRegardless()
    }

    func hide() {
        isVisible = false
        overlayPanel?.orderOut(nil)
        removeFallbackMenuBarStatusItem()
    }

    private func createOverlayPanel(
        companionManager: CompanionManager,
        initialFrame: CGRect
    ) {
        let overlayView = PaceMenuBarOverlayView(
            companionManager: companionManager,
            surfaceModel: surfaceModel
        )

        let hostingView = PaceMenuBarOverlayHostingView(rootView: overlayView)
        hostingView.frame = CGRect(origin: .zero, size: initialFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.onMouseDown = { [weak self] in
            self?.handleTap()
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
        panel.contentView = hostingView
        panel.setFrame(initialFrame, display: true)

        overlayPanel = panel
    }

    private func refreshPresentation(animated: Bool) {
        guard isVisible, let companionManager else { return }

        let signalState = companionManager.nativePanelPresentation.signalState
        let displayMode = PaceLivingNotchDisplayMode.resolve(
            signalState: signalState,
            isHovering: isHovering,
            showsPersistentRuntimeIndicator:
                companionManager.companionControlCenter.preferences.isCompanionModeEnabled
                || !companionManager.companionControlCenter.activeSources.isEmpty
                || companionManager.isOffDeviceTurnInFlight
        )

        let geometry = PaceLivingNotchScreenGeometryResolver.geometry(
            displayMode: displayMode
        )
        let ambientHomePresentation = PaceAmbientHomePresentation.resolve(
            hasReliablePhysicalNotchGeometry: geometry != nil
        )
        updateFallbackMenuBarStatusItem(for: ambientHomePresentation)

        let presentationIsAlreadyApplied =
            lastAppliedDisplayMode == displayMode
            && lastAppliedGeometry == geometry
            && (geometry == nil || overlayPanel?.isVisible == true)
        guard !presentationIsAlreadyApplied else { return }
        lastAppliedDisplayMode = displayMode
        lastAppliedGeometry = geometry

        guard let geometry else {
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

        let shouldAnimate =
            animated
            && overlayPanel.isVisible
            && displayMode == .hover
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.14
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

    private func updateFallbackMenuBarStatusItem(
        for ambientHomePresentation: PaceAmbientHomePresentation
    ) {
        switch ambientHomePresentation {
        case .livingNotch:
            removeFallbackMenuBarStatusItem()
        case .menuBarItem:
            createFallbackMenuBarStatusItemIfNeeded()
        }
    }

    private func createFallbackMenuBarStatusItemIfNeeded() {
        guard fallbackMenuBarStatusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else {
            NSStatusBar.system.removeStatusItem(statusItem)
            return
        }
        button.image = PaceBrandMark.menuBarImage()
        button.toolTip = "Open Pace conversations"
        button.target = self
        button.action = #selector(fallbackMenuBarStatusItemTapped)
        fallbackMenuBarStatusItem = statusItem
    }

    private func removeFallbackMenuBarStatusItem() {
        guard let fallbackMenuBarStatusItem else { return }
        NSStatusBar.system.removeStatusItem(fallbackMenuBarStatusItem)
        self.fallbackMenuBarStatusItem = nil
    }

    @objc private func fallbackMenuBarStatusItemTapped() {
        guard let button = fallbackMenuBarStatusItem?.button,
            let buttonWindow = button.window
        else {
            return
        }
        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        onTap(buttonWindow.convertToScreen(buttonFrameInWindow))
    }

    private func handleTap() {
        guard let overlayPanel else { return }
        let conversationAnchor =
            PaceLivingNotchScreenGeometryResolver.geometry(displayMode: .active)?.presentationFrame
            ?? overlayPanel.frame
        onTap(conversationAnchor)
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
    @ObservedObject private var imageOverlayController: PaceImageOverlayController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        companionManager: CompanionManager,
        surfaceModel: PaceLivingNotchSurfaceModel
    ) {
        self.companionManager = companionManager
        self.surfaceModel = surfaceModel
        self._companionControlCenter = ObservedObject(
            wrappedValue: companionManager.companionControlCenter
        )
        self._imageOverlayController = ObservedObject(wrappedValue: companionManager.imageOverlayController)
    }

    var body: some View {
        PaceSeamNotchSurface(
            displayMode: surfaceModel.displayMode,
            physicalHousingWidth: surfaceModel.physicalHousingWidth,
            physicalHousingHeight: surfaceModel.physicalHousingHeight,
            signalState: signalState,
            activityLabel: compactActivityLabel,
            isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
            plannerLabel: offDevicePlannerLabel,
            audioPowerLevel: companionManager.currentAudioPowerLevel,
            colorRoleOverride: companionManager.nativeEffectiveSignalColorRoleOverride,
            isCameraActive: companionControlCenter.activeSources.contains(.camera),
            isScreenActive: companionControlCenter.activeSources.contains(.screen),
            persistentStatus: companionControlCenter.preferences.isCompanionModeEnabled
                ? companionControlCenter.runtimeStatusText : nil
        )
        .smTheme(DS.palette)
        .contentShape(Rectangle())
        .pointerCursor()
        .help(
            companionControlCenter.preferences.isCompanionModeEnabled
                ? companionControlCenter.runtimeStatusText
                : statusText
        )
        .modifier(
            PaceLivingNotchAccessibilityModifier(
                accessibilityValue:
                    "\(signalPresentation.accessibilityValue)"
                    + "\(captureAccessibilityDescription) Press "
                    + "\(PaceNotchChatShortcut.currentShortcutAccessibilityLabel) to open Pace.",
                openPanel: {
                    NotificationCenter.default.post(name: .paceShowPanel, object: nil)
                }
            )
        )
        .onChange(of: signalState) { _, newSignalState in
            announceAccessibilityState(newSignalState)
        }
        .onChange(of: companionManager.isOffDeviceTurnInFlight) { _, isOffDeviceTurn in
            guard isOffDeviceTurn else { return }
            announceAccessibilityState(signalState)
        }
    }

    private var offDevicePlannerLabel: String {
        if companionManager.activePlannerTier == .cliDirect {
            return companionManager.activePlannerTierCLIDirectUpstream.displayLabel
        }
        return "Cloud"
    }

    private var compactActivityLabel: String {
        if case .generating(let request) = imageOverlayController.state {
            return "Drawing \(request.title)…"
        }
        switch signalState {
        case .ready: return "Ready"
        case .listening: return "Listening…"
        case .understanding: return "Thinking…"
        case .awaitingApproval: return "Waiting for approval"
        case .acting: return companionManager.currentTurnHUDState.detail ?? "Working…"
        case .speaking: return "Speaking…"
        case .completed: return "Done"
        case .blocked: return "Open Pace to continue"
        case .failed: return "Something needs attention"
        }
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
            return companionManager.activePlannerTierIsOffDevice || companionManager.isLMStudioReachable
                ? "Pace" : "Local offline"
        case .listening:
            return "Listening"
        case .processing:
            return "Thinking"
        case .responding:
            return "Speaking"
        }
    }

    private var signalState: PaceSignalState {
        companionManager.nativePanelPresentation.signalState
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
            activeCaptureDescriptions.isEmpty
        {
            activeCaptureDescriptions.append(
                "Companion mode \(companionControlCenter.runtimeStatusText.lowercased())"
            )
        }

        guard activeCaptureDescriptions.isEmpty == false else { return "" }
        return " \(activeCaptureDescriptions.joined(separator: ". "))."
    }

    private func announceAccessibilityState(_ signalState: PaceSignalState) {
        guard
            let announcement = PaceSignalPresentation.accessibilityAnnouncement(
                for: signalState,
                isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight
            )
        else { return }

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
