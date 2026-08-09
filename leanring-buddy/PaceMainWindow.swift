//
//  PaceMainWindow.swift
//  leanring-buddy
//
//  Proper resizable main window for everything that doesn't fit (and
//  shouldn't fit) in the menu-bar notch panel: past conversations,
//  usage analytics, extended settings, onboarding. The notch panel
//  stays minimal — voice state, latest reply, "Open Pace…" — and the
//  product gets a real Mac UI for the longer-form surfaces.
//
//  Lifecycle owned by CompanionAppDelegate; the window is created lazily
//  the first time the user opens it. Multiple "Open Pace…" taps reuse
//  the same window.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class PaceCommandCenterRouter: ObservableObject {
    static let storedDestinationKey = "paceCommandCenterDestination"

    @Published var selectedDestination: PaceCommandCenterDestination {
        didSet {
            userDefaults.set(selectedDestination.rawValue, forKey: Self.storedDestinationKey)
        }
    }

    private let userDefaults: UserDefaults

    init(
        requestedDestination: PaceCommandCenterDestination?,
        userDefaults: UserDefaults = .standard
    ) {
        self.userDefaults = userDefaults
        self.selectedDestination = PaceCommandCenterDestination.resolve(
            requestedDestination: requestedDestination,
            storedDestinationRawValue: userDefaults.string(forKey: Self.storedDestinationKey)
        )
    }

    func select(_ destination: PaceCommandCenterDestination) {
        selectedDestination = destination
    }
}

@MainActor
final class PaceMainWindowManager {
    static let shared = PaceMainWindowManager()

    private let defaultContentSize = NSSize(width: 1040, height: 700)
    private let minimumContentSize = NSSize(width: 820, height: 540)
    private var window: NSWindow?
    private var router: PaceCommandCenterRouter?

    private init() {}

    func show(
        companionManager: CompanionManager,
        destination: PaceCommandCenterDestination? = nil
    ) {
        if let existingWindow = window {
            if let destination {
                router?.select(destination)
            }
            ensureUsableContentSize(for: existingWindow)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let commandCenterRouter = PaceCommandCenterRouter(
            requestedDestination: destination
        )
        router = commandCenterRouter
        let rootView = PaceMainView(
            companionManager: companionManager,
            router: commandCenterRouter
        )
        let hostingController = NSHostingController(rootView: rootView)

        let newWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Pace Command Center"
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.contentMinSize = minimumContentSize
        newWindow.contentViewController = hostingController
        // NSHostingController can temporarily replace the requested content
        // size with its fitting size when attached. Reassert the operating
        // canvas after attachment so first open cannot collapse below usable.
        newWindow.setContentSize(defaultContentSize)
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }

    private func ensureUsableContentSize(for window: NSWindow) {
        window.contentMinSize = minimumContentSize
        let currentContentSize = window.contentLayoutRect.size
        guard currentContentSize.width < minimumContentSize.width
                || currentContentSize.height < minimumContentSize.height else { return }
        window.setContentSize(defaultContentSize)
        window.center()
    }
}
