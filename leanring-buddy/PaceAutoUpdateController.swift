//
//  PaceAutoUpdateController.swift
//  leanring-buddy
//
//  Wires Sparkle into Pace so the app silently checks for updates
//  against the GitHub-hosted appcast and downloads / installs them on
//  user approval. No Apple Developer Program / notarization needed —
//  Sparkle verifies update authenticity with its own EdDSA signature
//  (private key kept in the Mac's keychain on the release machine;
//  public key embedded in Info.plist as SUPublicEDKey).
//
//  Lifecycle: created lazily by CompanionAppDelegate at launch. The
//  user can also trigger a manual check from the Settings window via
//  `checkForUpdatesManually()`.
//

import Foundation
import Sparkle

@MainActor
final class PaceAutoUpdateController: NSObject {
    static let shared = PaceAutoUpdateController()

    private let updaterController: SPUStandardUpdaterController?

    func checkForUpdatesManually() -> Bool {
        guard let updaterController, updaterController.updater.canCheckForUpdates else { return false }
        updaterController.checkForUpdates(nil)
        return true
    }

    override convenience init() {
        self.init(
            isLocalDevelopmentBuild: Bundle.main.object(forInfoDictionaryKey: "PaceLocalDevelopmentBuild") as? Bool == true)
    }

    init(isLocalDevelopmentBuild: Bool) {
        // startingUpdater: true → automatic background check kicks off
        // as soon as the controller is constructed, with the cadence
        // Sparkle's defaults / Info.plist drive (SUEnableAutomaticChecks,
        // SUScheduledCheckInterval) for normal releases.
        // A local build must never be replaced by the public update feed.
        self.updaterController = isLocalDevelopmentBuild ? nil : SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        guard let updaterController else {
            print("🔄 PaceAutoUpdateController: updates disabled for local development build")
            return
        }
        print("🔄 PaceAutoUpdateController: started (feed=\(updaterController.updater.feedURL?.absoluteString ?? "unset"))")
    }
}
