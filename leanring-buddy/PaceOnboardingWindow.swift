//
//  PaceOnboardingWindow.swift
//  leanring-buddy
//
//  Hosts PaceOnboardingView in a borderless centered panel on the
//  first-ever launch — replaces the old "auto-open the notch panel"
//  pattern, which was cramped and shoved a bunch of UI at the user
//  before they'd seen anything about what Pace was.
//

import AppKit
import SwiftUI

@MainActor
final class PaceOnboardingWindowManager {
    static let shared = PaceOnboardingWindowManager()

    private var window: NSWindow?

    private init() {}

    static var hasCompletedOnboarding: Bool {
        PaceOnboardingProgressStore.shared.loadState().stage == .complete
    }

    func showOnboardingIfNeeded(companionManager: CompanionManager) {
        guard !Self.hasCompletedOnboarding else { return }
        show(companionManager: companionManager)
    }

    func show(companionManager: CompanionManager, isReplay: Bool = false) {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = PaceOnboardingView(
            companionManager: companionManager,
            isReplay: isReplay,
            onComplete: { [weak self] in
                self?.close()
            }
        )
        let hostingController = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Welcome to Pace"
        newWindow.titleVisibility = .hidden
        newWindow.titlebarAppearsTransparent = true
        newWindow.isMovableByWindowBackground = true
        newWindow.backgroundColor = NSColor(DS.Colors.surface)
        newWindow.minSize = NSSize(width: 900, height: 620)
        newWindow.contentViewController = hostingController
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = newWindow
    }

    private func close() {
        window?.close()
        window = nil
    }
}
