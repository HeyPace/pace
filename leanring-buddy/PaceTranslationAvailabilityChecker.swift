//
//  PaceTranslationAvailabilityChecker.swift
//  leanring-buddy
//
//  Tiny wrapper around Apple's `Translation.LanguageAvailability`
//  (macOS 15+). Returns whether on-device translation is possible
//  for a given (sourceLanguage, targetLanguage) pair on THIS Mac.
//
//  Why scope it this small: the full `TranslationSession.translate`
//  API requires a SwiftUI `translationTask` view modifier with a
//  configured session — meaning translation can only happen inside
//  a SwiftUI view tree, not from a headless voice agent's
//  background task. Pace's voice-first flow doesn't have a natural
//  view host for that, so the actual translate call is a multi-day
//  UI design problem.
//
//  `LanguageAvailability`, on the other hand, IS a clean async API
//  — no presenter, no view, no closure. It tells us whether the
//  Mac has the on-device model for a given language pair, which
//  is the prerequisite for any future translation tool. Shipping
//  this scaffolds the dependency: when the UI integration lands,
//  the availability check is already wired and tested.
//
//  Privacy: Apple's framework runs the check against the on-device
//  model catalogue. Nothing leaves the Mac; no language pair is
//  logged.
//

import Foundation

#if canImport(Translation)
import Translation
#endif

enum PaceTranslationAvailabilityStatus: Equatable {
    /// Model is downloaded and ready — translation can run offline.
    case installed
    /// System knows how to translate this pair but hasn't downloaded
    /// the model yet. The full TranslationSession call would prompt
    /// the user to download.
    case supportedButNotDownloaded
    /// Apple doesn't support this language pair on this OS at all.
    case unsupportedLanguagePair
    /// Translation framework not available (macOS < 15 or some
    /// resource-constrained build configuration).
    case translationFrameworkUnavailable
}

enum PaceTranslationAvailabilityChecker {

    /// Probe Apple's on-device translation availability for a single
    /// language pair. Returns `.translationFrameworkUnavailable` on
    /// macOS < 15 so callers can fall through to whatever fallback
    /// they have.
    static func checkAvailability(
        fromLanguageCode: String,
        toLanguageCode: String
    ) async -> PaceTranslationAvailabilityStatus {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let availabilityService = LanguageAvailability()
            let sourceLanguage = Locale.Language(identifier: fromLanguageCode)
            let targetLanguage = Locale.Language(identifier: toLanguageCode)
            let frameworkStatus = await availabilityService.status(
                from: sourceLanguage,
                to: targetLanguage
            )
            switch frameworkStatus {
            case .installed:
                return .installed
            case .supported:
                return .supportedButNotDownloaded
            case .unsupported:
                return .unsupportedLanguagePair
            @unknown default:
                return .unsupportedLanguagePair
            }
        }
        return .translationFrameworkUnavailable
        #else
        return .translationFrameworkUnavailable
        #endif
    }

    /// Convenience helper for the common case: can we translate
    /// from a detected source language to the user's preferred
    /// language right now without prompting them to download
    /// anything? Returns true only when the model is already
    /// installed.
    static func canTranslateRightNowOffline(
        fromLanguageCode: String,
        toLanguageCode: String
    ) async -> Bool {
        let availabilityStatus = await checkAvailability(
            fromLanguageCode: fromLanguageCode,
            toLanguageCode: toLanguageCode
        )
        return availabilityStatus == .installed
    }

    /// Determine the user's preferred target language from
    /// `Locale.preferredLanguages`, normalised to the BCP-47 root
    /// language code (e.g. "en-US" → "en"). Falls back to "en" when
    /// the preference list is empty.
    nonisolated static func resolveUserTargetLanguageCode(
        preferredLanguagesFromLocale: [String]
    ) -> String {
        guard let firstPreferredLanguage = preferredLanguagesFromLocale.first else {
            return "en"
        }
        // BCP-47: "en-US", "de-DE-Latn" — language code is the
        // first hyphenated segment. ICU's `Locale.Language`
        // happily takes the full tag but we normalise to the
        // root code so the availability check is symmetric with
        // the source-language detection layer (which typically
        // emits just "en", "de", "fr", etc.).
        return firstPreferredLanguage
            .split(separator: "-")
            .first
            .map(String.init) ?? "en"
    }
}
