//
//  PaceSettingsWindow.swift
//  leanring-buddy
//
//  Compatibility entry point for callers that still use “Settings.”
//  All management now routes into the single Pace Command Center window.
//

import Foundation

@MainActor
final class PaceSettingsWindowManager {
    static let shared = PaceSettingsWindowManager()

    private init() {}

    func show(
        companionManager: CompanionManager,
        destination: PaceCommandCenterDestination = .general
    ) {
        PaceMainWindowManager.shared.show(
            companionManager: companionManager,
            destination: destination
        )
    }
}
