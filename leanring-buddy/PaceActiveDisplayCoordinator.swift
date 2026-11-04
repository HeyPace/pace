import AppKit
import ApplicationServices
import Combine

nonisolated struct PaceDisplayID: Equatable, Hashable, Sendable {
    let rawValue: CGDirectDisplayID
}

nonisolated struct PaceDisplayGeometry: Equatable, Sendable {
    let displayID: PaceDisplayID
    let frame: CGRect

    static func appKitFrame(from quartzFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: quartzFrame.minX, y: primaryScreenTop - quartzFrame.maxY,
               width: quartzFrame.width, height: quartzFrame.height)
    }

    static func selectedDisplay(
        screens: [PaceDisplayGeometry], focusedWindowFrame: CGRect?, pointerLocation: CGPoint,
        previousDisplayID: PaceDisplayID?
    ) -> PaceDisplayID? {
        if let focusedWindowFrame, !focusedWindowFrame.isEmpty {
            var selectedDisplay: PaceDisplayGeometry?
            var largestIntersectionArea: CGFloat = 0
            for screen in screens {
                let intersectionArea = Self.intersectionArea(screen.frame, focusedWindowFrame)
                guard intersectionArea > 0 else { continue }
                if intersectionArea > largestIntersectionArea
                    || (intersectionArea == largestIntersectionArea && screen.displayID == previousDisplayID)
                {
                    selectedDisplay = screen
                    largestIntersectionArea = intersectionArea
                }
            }
            if let selectedDisplay { return selectedDisplay.displayID }
        }
        return screens.first { $0.frame.contains(pointerLocation) }?.displayID
            ?? screens.first { $0.displayID == previousDisplayID }?.displayID
            ?? screens.first?.displayID
    }

    private static func intersectionArea(_ screenFrame: CGRect, _ windowFrame: CGRect) -> CGFloat {
        let intersection = screenFrame.intersection(windowFrame)
        return intersection.isNull ? 0 : max(intersection.width, 0) * max(intersection.height, 0)
    }
}

nonisolated enum PaceDisplayRouteReason: Equatable, Sendable {
    case applicationActivated
    case focusedWindowChanged
    case pointerDown
    case explicitAnchor
    case activeSpaceChanged
    case screensChanged
    case wake
}

nonisolated struct PaceActiveDisplayRoute: Equatable, Sendable {
    let displayID: PaceDisplayID?
    let reason: PaceDisplayRouteReason
    let revision: UInt64
}

nonisolated struct PaceFocusedWindowObserverBinding: Sendable {
    let start: @Sendable () -> Void
    let stop: @Sendable () -> Void
}

/// Owns one display choice for both native surfaces. It never activates Pace or opens a panel.
@MainActor
final class PaceActiveDisplayCoordinator {
    static let shared = PaceActiveDisplayCoordinator(
        observesSystemEvents: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    @Published private(set) var route: PaceActiveDisplayRoute
    let routeChanges = PassthroughSubject<PaceActiveDisplayRoute, Never>()
    private let screens: @MainActor () -> [PaceDisplayGeometry]
    private let pointerLocation: @MainActor () -> CGPoint
    private let systemUptime: @MainActor () -> TimeInterval
    private let frontmostProcessIdentifier: @MainActor () -> pid_t?
    private let ownProcessIdentifier: pid_t
    private let focusedWindowReader: @Sendable (pid_t, CGFloat) async -> CGRect?
    private var notificationObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private var mouseDownMonitor: Any?
    private var focusedWindowObservation: PaceFocusedWindowObserverBinding?
    private let focusedWindowObservationFactory: (@Sendable (pid_t, @escaping @MainActor @Sendable () -> Void) async -> PaceFocusedWindowObserverBinding?)?
    private var focusedWindowObservationGeneration: UInt64 = 0
    private var focusRefreshTask: Task<Void, Never>?
    private var focusRequestGeneration: UInt64 = 0
    private var pendingFocusReason: PaceDisplayRouteReason?
    private var lastPointerDownAt: TimeInterval = -.infinity
    private let observesSystemEvents: Bool

    init(
        observesSystemEvents: Bool = false,
        screens: @escaping @MainActor () -> [PaceDisplayGeometry] = {
            NSScreen.screens.compactMap { screen in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
                else { return nil }
                return PaceDisplayGeometry(displayID: PaceDisplayID(rawValue: displayID), frame: screen.frame)
            }
        },
        pointerLocation: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation },
        systemUptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        frontmostProcessIdentifier: @escaping @MainActor () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        focusedWindowReader: @escaping @Sendable (pid_t, CGFloat) async -> CGRect? = { processIdentifier, primaryScreenTop in
            await Task.detached(priority: .utility) {
                PaceFocusedWindowObservation.readFrame(
                    processIdentifier: processIdentifier, primaryScreenTop: primaryScreenTop)
            }.value
        },
        focusedWindowObservationFactory: (@Sendable (pid_t, @escaping @MainActor @Sendable () -> Void) async -> PaceFocusedWindowObserverBinding?)? = nil
    ) {
        self.screens = screens
        self.pointerLocation = pointerLocation
        self.systemUptime = systemUptime
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.ownProcessIdentifier = ownProcessIdentifier
        self.focusedWindowReader = focusedWindowReader
        self.observesSystemEvents = observesSystemEvents
        self.focusedWindowObservationFactory = focusedWindowObservationFactory
        self.route = PaceActiveDisplayRoute(
            displayID: PaceDisplayGeometry.selectedDisplay(
                screens: screens(), focusedWindowFrame: nil, pointerLocation: pointerLocation(), previousDisplayID: nil),
            reason: .screensChanged, revision: 0)
        if observesSystemEvents { startObserving() }
    }

    deinit {
        focusRefreshTask?.cancel()
        for (center, observer) in notificationObservers { center.removeObserver(observer) }
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        focusedWindowObservation?.stop()
    }

    var targetScreen: NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == route.displayID?.rawValue
        }
    }

    func selectDisplay(containing anchorFrame: CGRect) {
        guard let display = screens().first(where: { $0.frame.contains(CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)) })
        else { return }
        focusRequestGeneration &+= 1
        pendingFocusReason = nil
        lastPointerDownAt = systemUptime()
        publish(displayID: display.displayID, reason: .explicitAnchor)
    }

    func pointerDidClick(at location: CGPoint) {
        guard let display = screens().first(where: { $0.frame.contains(location) }) else { return }
        focusRequestGeneration &+= 1
        pendingFocusReason = nil
        lastPointerDownAt = systemUptime()
        publish(displayID: display.displayID, reason: .pointerDown)
    }

    func handleSystemEvent(_ reason: PaceDisplayRouteReason) {
        focusRequestGeneration &+= 1
        if reason == .activeSpaceChanged || reason == .screensChanged || reason == .wake {
            let selectedDisplayID = screens().contains { $0.displayID == route.displayID }
                ? route.displayID
                : PaceDisplayGeometry.selectedDisplay(
                    screens: screens(), focusedWindowFrame: nil, pointerLocation: pointerLocation(), previousDisplayID: nil)
            publish(displayID: selectedDisplayID, reason: reason)
        }
        guard frontmostProcessIdentifier() != ownProcessIdentifier else {
            pendingFocusReason = nil
            focusedWindowObservationGeneration &+= 1
            focusedWindowObservation?.stop()
            focusedWindowObservation = nil
            return
        }
        // Activation and AX can arrive after the click that caused them. Keep that explicit choice.
        pendingFocusReason = reason
        beginPendingFocusRefresh()
    }

    private func beginPendingFocusRefresh() {
        guard focusRefreshTask == nil, let reason = pendingFocusReason,
            let processIdentifier = frontmostProcessIdentifier(), processIdentifier != ownProcessIdentifier,
            let primaryScreenTop = screens().first?.frame.maxY else { return }
        pendingFocusReason = nil
        let generation = focusRequestGeneration
        let allowsFocusSelection = systemUptime() - lastPointerDownAt >= 0.25
            || reason == .activeSpaceChanged || reason == .screensChanged || reason == .wake
        let focusedWindowReader = focusedWindowReader
        focusRefreshTask = Task { [weak self] in
            let focusedWindowFrame = await focusedWindowReader(processIdentifier, primaryScreenTop)
            guard let self else { return }
            if generation == focusRequestGeneration,
                frontmostProcessIdentifier() == processIdentifier
            {
                let displayID = PaceDisplayGeometry.selectedDisplay(
                    screens: screens(), focusedWindowFrame: focusedWindowFrame,
                    pointerLocation: pointerLocation(), previousDisplayID: route.displayID)
                if allowsFocusSelection { publish(displayID: displayID, reason: reason) }
            }
            // A click can retire display selection without retiring the frontmost app's AX lifetime.
            if frontmostProcessIdentifier() == processIdentifier,
                observesSystemEvents || focusedWindowObservationFactory != nil
            {
                await replaceFocusedWindowObservation(processIdentifier: processIdentifier)
            }
            focusRefreshTask = nil
            beginPendingFocusRefresh()
        }
    }

    private func publish(displayID: PaceDisplayID?, reason: PaceDisplayRouteReason) {
        guard displayID != route.displayID || reason == .activeSpaceChanged || reason == .screensChanged || reason == .wake
        else { return }
        route = PaceActiveDisplayRoute(displayID: displayID, reason: reason, revision: route.revision &+ 1)
        routeChanges.send(route)
    }

    private func startObserving() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for (center, name, reason) in [
            (workspaceCenter, NSWorkspace.didActivateApplicationNotification, PaceDisplayRouteReason.applicationActivated),
            (workspaceCenter, NSWorkspace.activeSpaceDidChangeNotification, .activeSpaceChanged),
            (workspaceCenter, NSWorkspace.didWakeNotification, .wake),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .screensChanged),
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSystemEvent(reason) }
            }
            notificationObservers.append((center, observer))
        }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let clickLocation: CGPoint
                if let quartzLocation = event.cgEvent?.location, let primaryScreenTop = self.screens().first?.frame.maxY {
                    clickLocation = CGPoint(x: quartzLocation.x, y: primaryScreenTop - quartzLocation.y)
                } else {
                    clickLocation = NSEvent.mouseLocation
                }
                // Outside-click monitors must evaluate the frame that received this click before it moves.
                DispatchQueue.main.async { [weak self] in self?.pointerDidClick(at: clickLocation) }
            }
        }
        handleSystemEvent(.applicationActivated)
    }

    private func replaceFocusedWindowObservation(processIdentifier: pid_t) async {
        let generation = focusedWindowObservationGeneration
        let onChange: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.frontmostProcessIdentifier() == processIdentifier else { return }
            self.handleSystemEvent(.focusedWindowChanged)
        }
        let observation: PaceFocusedWindowObserverBinding?
        if let focusedWindowObservationFactory {
            observation = await focusedWindowObservationFactory(processIdentifier, onChange)
        } else {
            observation = await Task.detached(priority: .utility) {
                guard let observation = PaceFocusedWindowObservation(
                    processIdentifier: processIdentifier, onChange: onChange) else { return nil as PaceFocusedWindowObserverBinding? }
                return PaceFocusedWindowObserverBinding(start: { observation.start() }, stop: { observation.stop() })
            }.value
        }
        guard generation == focusedWindowObservationGeneration,
            frontmostProcessIdentifier() == processIdentifier else { return }
        focusedWindowObservation?.stop()
        focusedWindowObservation = observation
        observation?.start()
    }
}

nonisolated private final class PaceFocusedWindowObservation: @unchecked Sendable {
    private let observer: AXObserver
    private let context: PaceFocusedWindowObservationContext

    nonisolated init?(processIdentifier: pid_t, onChange: @escaping @MainActor @Sendable () -> Void) {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard AXUIElementSetMessagingTimeout(application, 0.02) == .success else { return nil }
        var createdObserver: AXObserver?
        guard AXObserverCreate(processIdentifier, Self.focusedWindowChanged, &createdObserver) == .success,
            let createdObserver else { return nil }
        observer = createdObserver
        self.context = PaceFocusedWindowObservationContext(onChange: onChange)
        let context = Unmanaged.passUnretained(self.context).toOpaque()
        AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, context)
        if let window = Self.focusedWindow(application: application) {
            AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, context)
            AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, context)
        }
    }

    nonisolated private static let focusedWindowChanged: AXObserverCallback = { _, _, _, context in
        guard let context else { return }
        MainActor.assumeIsolated {
            Unmanaged<PaceFocusedWindowObservationContext>.fromOpaque(context).takeUnretainedValue().onChange()
        }
    }

    func start() {
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    nonisolated static func readFrame(processIdentifier: pid_t, primaryScreenTop: CGFloat) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        guard AXUIElementSetMessagingTimeout(application, 0.02) == .success else { return nil }
        guard let window = focusedWindow(application: application) else { return nil }
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
            position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
            size.width > 0, size.height > 0 else { return nil }
        return PaceDisplayGeometry.appKitFrame(
            from: CGRect(origin: position, size: size), primaryScreenTop: primaryScreenTop)
    }

    nonisolated private static func focusedWindow(application: AXUIElement) -> AXUIElement? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let windowValue, CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        guard AXUIElementSetMessagingTimeout(window, 0.02) == .success else { return nil }
        return window
    }
}

nonisolated private final class PaceFocusedWindowObservationContext: @unchecked Sendable {
    let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }
}
