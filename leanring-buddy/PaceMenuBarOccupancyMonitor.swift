import AppKit
import ApplicationServices

nonisolated struct PaceMenuBarOccupancy: Equatable, Sendable {
    var itemFrames: [CGRect] = []
    var isReliable = false

    func overlaps(_ presentationFrame: CGRect, housingFrame: CGRect) -> Bool {
        guard isReliable else { return true }
        let menuRow = CGRect(
            x: presentationFrame.minX, y: housingFrame.minY,
            width: presentationFrame.width, height: housingFrame.height)
        return itemFrames.contains { !$0.isEmpty && $0.insetBy(dx: -3, dy: 0).intersects(menuRow) }
    }

    static func appKitFrame(from quartzFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: quartzFrame.minX, y: primaryScreenTop - quartzFrame.maxY,
               width: quartzFrame.width, height: quartzFrame.height)
    }
}

extension Notification.Name {
    static let paceMenuBarOccupancyChanged = Notification.Name("paceMenuBarOccupancyChanged")
}

/// Reads only top-level item bounds. No screenshots, menu text, input hooks or AX actions.
@MainActor
final class PaceMenuBarOccupancyMonitor {
    static let shared = PaceMenuBarOccupancyMonitor()
    private(set) var occupancy = PaceMenuBarOccupancy()
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?

    func start() {
        guard refreshTimer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    func refresh() {
        guard refreshTask == nil,
              PaceLivingNotchScreenGeometryResolver.targetScreen() != nil,
              let application = NSWorkspace.shared.frontmostApplication,
              let primaryScreen = NSScreen.screens.first else { return }
        let processIdentifier = application.processIdentifier
        let primaryScreenTop = primaryScreen.frame.maxY
        refreshTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .utility) {
                Self.readOccupancy(
                    processIdentifier: processIdentifier, primaryScreenTop: primaryScreenTop)
            }.value
            guard let self else { return }
            self.refreshTask = nil
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                self.refresh()
                return
            }
            self.publish(snapshot)
        }
    }

    private func publish(_ snapshot: PaceMenuBarOccupancy) {
        guard occupancy != snapshot else { return }
        occupancy = snapshot
        NotificationCenter.default.post(name: .paceMenuBarOccupancyChanged, object: nil)
    }

    nonisolated private static func readOccupancy(
        processIdentifier: pid_t, primaryScreenTop: CGFloat
    ) -> PaceMenuBarOccupancy {
        guard AXIsProcessTrusted() else { return PaceMenuBarOccupancy() }
        let deadline = Date().addingTimeInterval(0.12)
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.015)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
            let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID()
        else { return PaceMenuBarOccupancy() }
        let menuBar = menuBarValue as! AXUIElement
        AXUIElementSetMessagingTimeout(menuBar, 0.015)
        var itemCount = 0
        guard AXUIElementGetAttributeValueCount(
            menuBar, kAXChildrenAttribute as CFString, &itemCount) == .success,
            itemCount > 0, itemCount <= 64 else { return PaceMenuBarOccupancy() }
        var children: CFArray?
        guard AXUIElementCopyAttributeValues(
            menuBar, kAXChildrenAttribute as CFString, 0, itemCount, &children) == .success,
            let items = children as? [AXUIElement], !items.isEmpty
        else { return PaceMenuBarOccupancy() }
        var frames: [CGRect] = []
        for item in items {
            guard Date() < deadline else { return PaceMenuBarOccupancy() }
            AXUIElementSetMessagingTimeout(item, 0.015)
            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                item, kAXPositionAttribute as CFString, &positionValue) == .success,
                AXUIElementCopyAttributeValue(
                    item, kAXSizeAttribute as CFString, &sizeValue) == .success,
                let positionValue, let sizeValue,
                CFGetTypeID(positionValue) == AXValueGetTypeID(),
                CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else { return PaceMenuBarOccupancy() }
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            else { return PaceMenuBarOccupancy() }
            frames.append(PaceMenuBarOccupancy.appKitFrame(
                from: CGRect(origin: position, size: size), primaryScreenTop: primaryScreenTop))
        }

        // Status extras have separate WindowServer windows; the menu-bar background does not.
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  layer >= Int(CGWindowLevelForKey(.mainMenuWindow)),
                  layer <= Int(CGWindowLevelForKey(.statusWindow)),
                  let owner = window[kCGWindowOwnerPID as String] as? Int,
                  owner != ProcessInfo.processInfo.processIdentifier,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0, frame.width < 500, frame.height > 0, frame.height <= 48
            else { continue }
            frames.append(PaceMenuBarOccupancy.appKitFrame(
                from: frame, primaryScreenTop: primaryScreenTop))
        }
        return PaceMenuBarOccupancy(itemFrames: frames, isReliable: true)
    }
}
