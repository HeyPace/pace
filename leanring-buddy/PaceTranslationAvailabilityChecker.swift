//
//  PaceTranslationAvailabilityChecker.swift
//  leanring-buddy
//
//  Resolves the user's preferred target language code from
//  `Locale.preferredLanguages`. (The on-device translation availability
//  probe that used to live here was unused scaffolding for an unshipped
//  translation feature and was removed; re-add it from git history if a
//  translation tool is ever built.)
//

import Foundation

enum PaceTranslationAvailabilityChecker {

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
