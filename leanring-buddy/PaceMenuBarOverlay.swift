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

private enum PaceLivingNotchMetrics {
    static let hoverBottomCornerRadius: CGFloat = 12
    static let activeBottomCornerRadius: CGFloat = 14
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

        let signalState = companionManager.nativeEffectiveSignalState
        let displayMode = PaceLivingNotchDisplayMode.resolve(
            signalState: signalState,
            isHovering: isHovering,
            showsPersistentRuntimeIndicator:
                companionManager.companionControlCenter.preferences.isCompanionModeEnabled
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
        let statusImage = NSImage(
            systemSymbolName: "waveform.path",
            accessibilityDescription: "Pace"
        )
        statusImage?.isTemplate = true
        button.image = statusImage
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
        onTap(overlayPanel.frame)
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

    init(
        companionManager: CompanionManager,
        surfaceModel: PaceLivingNotchSurfaceModel
    ) {
        self.companionManager = companionManager
        self.surfaceModel = surfaceModel
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .smTheme(DS.palette)
        .background(Color.black)
        .clipShape(notchShape)
        .contentShape(
            notchShape
        )
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
            Text("pace")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(Color.white.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: surfaceModel.physicalHousingWidth)

            HStack(spacing: 5) {
                Circle()
                    .fill(
                        companionManager.isOffDeviceTurnInFlight ? DS.Colors.offDeviceSignal : Color.white.opacity(0.55)
                    )
                    .frame(width: 4, height: 4)
                if companionManager.isOffDeviceTurnInFlight {
                    Text("\(offDevicePlannerLabel) ↗")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DS.Colors.offDeviceSignal)
                        .help("This request uses the off-device planner you enabled.")
                } else {
                    Text(compactActivityLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .lineLimit(1)
                }
                PaceCompanionCaptureIndicators(controlCenter: companionControlCenter)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .pointerCursor()
    }

    private var offDevicePlannerLabel: String {
        if companionManager.activePlannerTier == .cliDirect {
            return companionManager.activePlannerTierCLIDirectUpstream.displayLabel
        }
        return "Off-device"
    }

    private var compactActivityLabel: String {
        if companionManager.voiceState == .idle {
            return companionManager.allPermissionsGranted ? "Ready" : "Chat"
        }
        switch companionManager.voiceState {
        case .listening: return "Listening"
        case .processing: return "Thinking"
        case .responding: return "Speaking"
        case .idle: return "Chat"
        }
    }

    private var bottomCornerRadius: CGFloat {
        switch surfaceModel.displayMode {
        case .hardwareIdle:
            return 11
        case .hover:
            return PaceLivingNotchMetrics.hoverBottomCornerRadius
        case .active:
            return PaceLivingNotchMetrics.activeBottomCornerRadius
        }
    }

    private var notchShape: PaceExtendedNotchShape {
        PaceExtendedNotchShape(
            topShoulderRadius: 6,
            bottomCornerRadius: bottomCornerRadius
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
                controlCenter.activeSources.contains(.screen) == false
            {
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
