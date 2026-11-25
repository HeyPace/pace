//
//  PaceMessageShareService.swift
//  leanring-buddy
//
//  Thin wrapper over `NSSharingServicePicker` that lets users share a
//  Pace assistant reply through any of the system's installed share
//  destinations — Messages, Mail, Notes, AirDrop, Reminders, third-
//  party apps that register sharing services, etc.
//
//  The whole point is that we don't have to build per-destination
//  integrations. macOS already knows where the user wants to send
//  text and which extensions to surface; we just hand it the text
//  and an anchor view.
//

import AppKit
import SwiftUI

@MainActor
enum PaceMessageShareService {

    /// Present the system share sheet anchored to `anchorView`. The
    /// anchor edge defaults to `.minY` so the picker drops below the
    /// triggering control, matching the convention every other macOS
    /// share button uses.
    ///
    /// Empty / whitespace-only text is a no-op — the share sheet
    /// would otherwise pop up with nothing meaningful for the user
    /// to send.
    static func presentSharePicker(
        forText messageText: String,
        anchoredTo anchorView: NSView,
        preferredEdge: NSRectEdge = .minY
    ) {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        let sharingItems: [Any] = [trimmedText]
        let sharingPicker = NSSharingServicePicker(items: sharingItems)
        sharingPicker.show(
            relativeTo: anchorView.bounds,
            of: anchorView,
            preferredEdge: preferredEdge
        )
    }
}

// MARK: - Share + Copy context menu items

/// Right-click menu actions for a chat message. The Share entry
/// hands the message to NSSharingServicePicker; the Copy entry
/// stays in pasteboard land for users who'd rather paste it
/// themselves. The view embeds a hidden NSView via
/// NSViewRepresentable so NSSharingServicePicker has a real
/// AppKit anchor to position itself against.
struct ShareAndCopyContextMenuItems: View {
    let messageBody: String

    var body: some View {
        Button("copy") {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(messageBody, forType: .string)
        }
        Button("share…") {
            presentSystemSharePickerAnchoredToKeyWindow()
        }
    }

    /// Anchor the share picker to whichever NSView is currently
    /// receiving events in the key window. Using the key window's
    /// content view as the anchor is what every other right-click-
    /// initiated share picker on macOS does, and it produces the
    /// expected "share sheet floats near where I right-clicked"
    /// behaviour without us having to thread a per-row NSView
    /// reference through SwiftUI.
    private func presentSystemSharePickerAnchoredToKeyWindow() {
        guard let anchorView = NSApp.keyWindow?.contentView else { return }
        PaceMessageShareService.presentSharePicker(
            forText: messageBody,
            anchoredTo: anchorView
        )
    }
}
