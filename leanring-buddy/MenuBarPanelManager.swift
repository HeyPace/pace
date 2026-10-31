//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the custom borderless NSPanel that drops down from the Pace
//  notch/menu-bar overlay. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let paceDismissPanel = Notification.Name("paceDismissPanel")
    static let paceNotchConversationVisibilityChanged = Notification.Name("paceNotchConversationVisibilityChanged")
    /// Posted by `CompanionManager` when the notch chat shortcut fires,
    /// so the panel manager can bring the panel forward without the
    /// manager needing a direct reference to it. Mirrors the existing
    /// `paceDismissPanel` pattern.
    static let paceShowPanel = Notification.Name("paceShowPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class PaceConversationPanelSurfaceModel: ObservableObject {
    @Published var placement: PaceConversationPanelPlacement = .anchored(.zero)
    @Published var presentation: PaceConversationPanelPresentation = .hidden
}

private struct PaceConversationPanelSurface: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var surfaceModel: PaceConversationPanelSurfaceModel
    @ObservedObject var companionControlCenter: PaceCompanionControlCenter
    let usesChatPanelAsPrimarySurface: Bool

    var body: some View {
        GeometryReader { geometry in
            switch surfaceModel.placement {
            case .physicalNotch(let notchGeometry):
                VStack(spacing: 0) {
                    PaceSeamNotchHeader(
                        physicalHousingWidth: notchGeometry.physicalHousingFrame.width,
                        physicalHousingHeight: notchGeometry.physicalHousingFrame.height,
                        signalState: companionManager.nativeEffectiveSignalState,
                        isOffDeviceTurn: companionManager.isOffDeviceTurnInFlight,
                        isExpanded: true,
                        isCameraActive: companionControlCenter.activeSources.contains(.camera),
                        isScreenActive: companionControlCenter.activeSources.contains(.screen),
                        persistentStatus: companionControlCenter.runtimeStatusText,
                        companionStatusColor: companionStatusColor,
                        onBrandTap: {
                            NotificationCenter.default.post(name: .paceShowPanel, object: nil)
                        },
                        onChatTap: {
                            NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
                        }
                    )
                    .accessibilityValue(headerAccessibilityValue)
                    PacePanelChatView(
                        companionManager: companionManager, isEmbeddedInNotch: true,
                        composerFocusRequestID: surfaceModel.presentation.composerFocusRequestID)
                        .frame(width: PaceQuickPanelMetrics.width, height: PaceQuickPanelMetrics.seamlessContentHeight)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 24, bottomTrailingRadius: 24, style: .continuous))
            case .anchored:
                if usesChatPanelAsPrimarySurface {
                    PaceChatPanelView(
                        companionManager: companionManager,
                        composerFocusRequestID: surfaceModel.presentation.composerFocusRequestID)
                } else {
                    PacePanelChatView(
                        companionManager: companionManager,
                        composerFocusRequestID: surfaceModel.presentation.composerFocusRequestID)
                }
            }
        }
        .onExitCommand {
            NotificationCenter.default.post(name: .paceDismissPanel, object: nil)
        }
    }

    private var companionStatusColor: Color? {
        guard companionControlCenter.preferences.isCompanionModeEnabled,
            companionControlCenter.activeSources.isEmpty
        else { return nil }
        switch companionControlCenter.runtimeState {
        case .observing: return .green
        case .interpreting: return .cyan
        case .paused: return .yellow
        case .degraded: return .orange
        case .privacyBlocked: return .red
        case .off, .starting: return .gray
        }
    }

    private var headerAccessibilityValue: String {
        var descriptions: [String] = []
        if companionControlCenter.activeSources.contains(.camera) { descriptions.append("Camera active") }
        if companionControlCenter.activeSources.contains(.screen) { descriptions.append("Screen active") }
        if companionControlCenter.preferences.isCompanionModeEnabled {
            descriptions.append("Companion mode \(companionControlCenter.runtimeStatusText)")
        }
        if companionManager.isOffDeviceTurnInFlight { descriptions.append("Off-device request active") }
        return descriptions.joined(separator: ". ")
    }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var panel: NSPanel?
    private let surfaceModel = PaceConversationPanelSurfaceModel()
    private var isPanelPresented: Bool { surfaceModel.presentation.isPresented }
    private var screenParametersObserver: NSObjectProtocol?
    private var workspaceWakeObserver: NSObjectProtocol?
    private var menuBarOccupancyObserver: NSObjectProtocol?
    private var panelAnchorFrameOverride: NSRect?
    private var clickOutsideMonitor: Any?
    private var localClickOutsideMonitor: Any?
    /// When the panel was last shown. Outside-click dismissal is ignored for
    /// a brief grace window after this so the very click/gesture that opened
    /// the panel (e.g. tapping the mascot, which is outside the panel frame)
    /// can't immediately close it.
    private var panelShownAt: Date?
    private var visibilityAnimationGeneration = 0
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?

    private let companionManager: CompanionManager
    private let usesChatPanelAsPrimarySurface: Bool
    private let panelWidth: CGFloat
    private let panelHeight: CGFloat
    init(companionManager: CompanionManager) {
        let shouldUseChatPanelAsPrimarySurface = PaceUserPreferencesStore.bool(
            for: .useChatPanelAsPrimarySurface
        )
        self.companionManager = companionManager
        self.usesChatPanelAsPrimarySurface = shouldUseChatPanelAsPrimarySurface
        if shouldUseChatPanelAsPrimarySurface {
            self.panelWidth = 320
            self.panelHeight = 460
        } else {
            self.panelWidth = PaceQuickPanelMetrics.width
            self.panelHeight = PaceQuickPanelMetrics.height
        }
        super.init()
        menuBarOccupancyObserver = NotificationCenter.default.addObserver(
            forName: .paceMenuBarOccupancyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionVisiblePanel() }
        }

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .paceDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }

        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .paceShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let manager = self else { return }
            let presentationIntent = notification.object as? PaceConversationPanelPresentationIntent ?? .interactive
            Task { @MainActor in
                manager.showPanel(intent: presentationIntent)
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionVisiblePanel() }
        }
        workspaceWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionVisiblePanel() }
        }

    }

    deinit {
        if let menuBarOccupancyObserver { NotificationCenter.default.removeObserver(menuBarOccupancyObserver) }
        if let screenParametersObserver { NotificationCenter.default.removeObserver(screenParametersObserver) }
        if let workspaceWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceWakeObserver) }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func togglePanel() {
        if case .interactive = surfaceModel.presentation {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func togglePanel(anchoredTo anchorFrame: NSRect) {
        panelAnchorFrameOverride = anchorFrame
        togglePanel()
    }

    /// Non-toggling show anchored to a frame — used when a conversation
    /// starts so the panel reliably appears at the mascot (never closes an
    /// already-open panel mid-turn).
    func showPanel(anchoredTo anchorFrame: NSRect) {
        panelAnchorFrameOverride = anchorFrame
        showPanel()
    }

    func showPanelForSmokeTest() {
        showPanel()
    }

    /// Entry point for the pace://panel deeplink (Raycast/Shortcuts).
    func showPanelFromDeepLink() {
        showPanel()
    }

    func hidePanelForSmokeTest() {
        hidePanel()
    }

    // MARK: - Panel Lifecycle

    private func showPanel(intent: PaceConversationPanelPresentationIntent = .interactive) {
        PaceMenuBarOccupancyMonitor.shared.start()
        PaceMenuBarOccupancyMonitor.shared.refresh()
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }
        let wasVisible = isPanelPresented
        surfaceModel.presentation = surfaceModel.presentation.presenting(intent)
        positionPanelBelowAnchor()
        let expandedPanelFrame = panel.frame
        visibilityAnimationGeneration += 1

        if wasVisible == false,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false
        {
            let collapsedPanelFrame = surfaceModel.placement.collapsedFrame
            panel.alphaValue = 1
            panel.setFrame(collapsedPanelFrame, display: false)
            if intent.requestsKeyboardFocus {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = 0.24
                animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
                panel.animator().setFrame(expandedPanelFrame, display: true)
            }
        } else {
            panel.alphaValue = 1
            if intent.requestsKeyboardFocus {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.orderFrontRegardless()
        }
        updateNotchConversationVisibility()
        panelShownAt = Date()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        let wasVisible = isPanelPresented
        surfaceModel.presentation = .hidden
        guard let panel, wasVisible else {
            removeClickOutsideMonitor()
            updateNotchConversationVisibility()
            return
        }
        visibilityAnimationGeneration += 1
        let animationGeneration = visibilityAnimationGeneration
        removeClickOutsideMonitor()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            updateNotchConversationVisibility()
            return
        }
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.18
            animationContext.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
            panel.animator().setFrame(surfaceModel.placement.collapsedFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel,
                    self.visibilityAnimationGeneration == animationGeneration,
                    !self.isPanelPresented
                else { return }
                panel.orderOut(nil)
                self.updateNotchConversationVisibility()
            }
        }
    }

    private func createPanel() {
        let hostingView = NSHostingView(
            rootView: PaceConversationPanelSurface(
                companionManager: companionManager,
                surfaceModel: surfaceModel,
                companionControlCenter: companionManager.companionControlCenter,
                usesChatPanelAsPrimarySurface: usesChatPanelAsPrimarySurface))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowAnchor() {
        guard let panel,
            let anchorFrame = panelAnchorFrameOverride ?? defaultMenuBarAnchorFrame(),
            let anchorScreen = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) }) ?? NSScreen.main
        else { return }
        let notchGeometry = PaceLivingNotchScreenGeometryResolver.geometry(displayMode: .hover)
        surfaceModel.placement = PaceConversationPanelPlacement.resolve(
            notchGeometry: notchGeometry,
            anchorFrame: anchorFrame,
            screenFrame: notchGeometry.flatMap { notchGeometry in
                NSScreen.screens.first { $0.frame.contains(notchGeometry.physicalHousingFrame) }?.frame
            } ?? anchorScreen.frame,
            contentSize: CGSize(width: panelWidth, height: panelHeight))
        if let notchGeometry,
            !PaceMenuBarOccupancyMonitor.shared.occupancy.overlaps(
                surfaceModel.placement.frame, housingFrame: notchGeometry.physicalHousingFrame)
        {
            panel.level = PaceWindowLayering.livingNotch
        } else {
            // Preserve the camera anchor, but let native menus own their row when crowded.
            panel.level = .floating
        }
        panel.setFrame(surfaceModel.placement.frame, display: true)
    }

    private func repositionVisiblePanel() {
        guard isPanelPresented else { return }
        visibilityAnimationGeneration += 1
        positionPanelBelowAnchor()
        updateNotchConversationVisibility()
    }

    private func updateNotchConversationVisibility() {
        let isNotchConversationVisible: Bool
        if case .physicalNotch = surfaceModel.placement {
            isNotchConversationVisible = panel?.isVisible == true
        } else {
            isNotchConversationVisible = false
        }
        NotificationCenter.default.post(
            name: .paceNotchConversationVisibilityChanged, object: nil,
            userInfo: ["isVisible": isNotchConversationVisible])
    }

    private func defaultMenuBarAnchorFrame() -> NSRect? {
        if let livingNotchGeometry = PaceLivingNotchScreenGeometryResolver.geometry(
            displayMode: .active
        ) {
            return livingNotchGeometry.presentationFrame
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 1)
        return NSRect(
            x: screen.frame.midX,
            y: screen.frame.maxY - menuBarHeight,
            width: 0,
            height: menuBarHeight
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        // Global monitor: clicks that land in OTHER apps.
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.dismissPanelIfClickIsOutside()
        }

        // Local monitor: clicks that land in OUR OWN other windows — most
        // importantly the Settings window. A global monitor never sees these
        // (they're same-process events), so without this the panel stays open
        // when you click the Settings window. Returns the event unchanged so
        // the clicked control still works.
        localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.dismissPanelIfClickIsOutside()
            return event
        }
    }

    /// Hides the panel when a click lands outside its frame. Shared by the
    /// global (other-app) and local (own-window, e.g. Settings) monitors.
    private func dismissPanelIfClickIsOutside() {
        guard let panel else { return }
        // Grace window: ignore the click/gesture that just opened the panel
        // (tapping the mascot is outside the panel frame, so without this it
        // would immediately re-close — the open/close flicker).
        if let panelShownAt, Date().timeIntervalSince(panelShownAt) < 0.45 {
            return
        }
        let clickLocation = NSEvent.mouseLocation
        if panel.frame.contains(clickLocation) {
            return
        }
        // Small delay so a Grant button inside the panel that spawns a system
        // permission dialog doesn't race the dismissal. Clicks inside the
        // panel already returned above; anything here is genuinely outside,
        // so dismiss like NSPopover.
        let dismissalGeneration = visibilityAnimationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, panel.isVisible, self.isPanelPresented,
                self.visibilityAnimationGeneration == dismissalGeneration
            else { return }
            self.hidePanel()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
        if let monitor = localClickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            localClickOutsideMonitor = nil
        }
    }
}
