//
//  PaceStarterPromptCatalog.swift
//  leanring-buddy
//
//  Pure state + content module for the first-run "Try these" card shown
//  at the top of the notch panel. Holds:
//
//    - PaceStarterPrompt    : one row in the card (slug, displayText).
//    - PaceStarterPromptCatalog.all : the deterministic 6-prompt list.
//    - PaceStarterPromptStore : UserDefaults-backed tried-set + first-
//                               seen + dismissed-at state with an
//                               `isVisible(now:)` decision function.
//
//  No UI here — `CompanionPanelView` reads the store and renders the
//  card. No LLM call to generate prompts — the 6 are hardcoded per PRD.
//  No telemetry — the only persisted state is local UserDefaults under
//  the `pace.firstRun.` prefix, used only to decide whether to keep
//  showing the card.
//
//  Visibility policy (mirrors docs/prds/first-run-experience.md):
//    - Card is visible while inside a 24h window starting at the first
//      time the panel opens with the card present (`firstSeenAt`).
//    - Card auto-dismisses once the user has tried 4 of the 6 prompts.
//    - Card hides immediately when the user taps "Hide for now"
//      (`dismissedAt`), and can be brought back by the Settings →
//      "Show starter prompts again" affordance via `resetVisibility()`.
//

import Foundation

// MARK: - PaceStarterPrompt

/// A single starter prompt the user can tap to submit as a real turn.
/// `slug` is the stable key persisted in UserDefaults. `displayText`
/// is the literal transcript sent to `submitChatTranscriptFromDeepLink`.
struct PaceStarterPrompt: Equatable, Identifiable {
    let slug: String
    let displayText: String
    let suggestedCategoryHint: String

    var id: String { slug }
}

// MARK: - PaceStarterPromptCatalog

/// The deterministic 6-prompt list shown to first-run users. Order
/// matches the PRD's "why this one" rationale — calendar first because
/// it's the highest-signal first ask, timer second for the fastest
/// "wow" moment, etc. Re-evaluated per release; acceptable to ship
/// hardcoded in v1.
enum PaceStarterPromptCatalog {
    static let all: [PaceStarterPrompt] = [
        PaceStarterPrompt(
            slug: "calendar-today",
            displayText: "what's on my calendar today?",
            suggestedCategoryHint: "Calendar retrieval"
        ),
        PaceStarterPrompt(
            slug: "set-five-minute-timer",
            displayText: "set a five minute timer",
            suggestedCategoryHint: "Local tool — start_timer"
        ),
        PaceStarterPrompt(
            slug: "open-safari-anthropic",
            displayText: "open Safari to anthropic.com",
            suggestedCategoryHint: "Local tool — open_url"
        ),
        PaceStarterPrompt(
            slug: "what-is-on-screen",
            displayText: "what's on my screen right now?",
            suggestedCategoryHint: "Screen awareness — VLM + OCR"
        ),
        PaceStarterPrompt(
            slug: "remember-prefer-safari",
            displayText: "remember that I prefer Safari as my browser",
            suggestedCategoryHint: "Local memory"
        ),
        PaceStarterPrompt(
            slug: "what-did-i-do-today",
            displayText: "what did I do today?",
            suggestedCategoryHint: "Retrieval — app usage + screen-watch journals"
        )
    ]

    /// The slug→prompt lookup used by the store when it has to reconcile
    /// a persisted tried-set against the current catalog (e.g. after a
    /// catalog update removes an old slug). Persisted entries that no
    /// longer map to a real prompt are silently dropped.
    static func prompt(forSlug slug: String) -> PaceStarterPrompt? {
        return all.first { prompt in prompt.slug == slug }
    }
}

// MARK: - PaceStarterPromptStore

/// UserDefaults-backed view of the first-run starter-prompt state.
/// All methods are pure with respect to their arguments — `now:` is
/// injected so visibility windowing is testable without freezing the
/// system clock.
enum PaceStarterPromptStore {

    // MARK: UserDefaults keys

    private enum StarterPromptUserDefaultsKey: String {
        case triedAtTimestampsBySlug = "pace.firstRun.starterPromptsTriedAt"
        case firstSeenAtTimestamp = "pace.firstRun.starterPromptsFirstSeenAt"
        case dismissedAtTimestamp = "pace.firstRun.starterPromptsDismissedAt"
    }

    // MARK: Visibility policy constants

    /// How long after `firstSeenAt` the card should stay visible.
    static let visibilityWindowSeconds: TimeInterval = 24 * 60 * 60

    /// Once the user has tapped this many distinct prompts, auto-dismiss.
    /// Less than 6 so a partial completion still feels like "graduated"
    /// rather than forcing the user to tap every row.
    static let autoDismissAfterTriedCount: Int = 4

    // MARK: First-seen bookkeeping

    /// Returns the timestamp at which the user first saw the card. If
    /// the panel has never opened with the card present, returns nil.
    /// The caller (notch panel) writes this value the first time the
    /// card actually renders via `markFirstSeenIfNeeded(now:)`.
    static func firstSeenAt() -> Date? {
        let interval = UserDefaults.standard.double(
            forKey: StarterPromptUserDefaultsKey.firstSeenAtTimestamp.rawValue
        )
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    /// Idempotent: writes `now` only if the key is unset. Safe to call
    /// every time the panel renders the card.
    static func markFirstSeenIfNeeded(now: Date = Date()) {
        guard firstSeenAt() == nil else { return }
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: StarterPromptUserDefaultsKey.firstSeenAtTimestamp.rawValue
        )
    }

    // MARK: Tried-set bookkeeping

    /// Returns the per-slug tried-at timestamp dictionary as it lives in
    /// UserDefaults. Slugs no longer in the catalog are filtered out so
    /// the auto-dismiss counter only reflects prompts the user can
    /// still see.
    static func triedAtTimestampsBySlug() -> [String: Date] {
        let rawDictionary = UserDefaults.standard.dictionary(
            forKey: StarterPromptUserDefaultsKey.triedAtTimestampsBySlug.rawValue
        ) ?? [:]
        var result: [String: Date] = [:]
        for (slug, value) in rawDictionary {
            guard PaceStarterPromptCatalog.prompt(forSlug: slug) != nil else { continue }
            if let timestampInterval = value as? TimeInterval {
                result[slug] = Date(timeIntervalSince1970: timestampInterval)
            } else if let timestampNumber = value as? NSNumber {
                result[slug] = Date(timeIntervalSince1970: timestampNumber.doubleValue)
            }
        }
        return result
    }

    /// Marks `slug` as tried at `now`. Idempotent for repeated taps —
    /// the timestamp gets overwritten, but the count stays at 1.
    static func markTried(slug: String, now: Date = Date()) {
        guard PaceStarterPromptCatalog.prompt(forSlug: slug) != nil else { return }
        var existingTimestamps = UserDefaults.standard.dictionary(
            forKey: StarterPromptUserDefaultsKey.triedAtTimestampsBySlug.rawValue
        ) ?? [:]
        existingTimestamps[slug] = now.timeIntervalSince1970
        UserDefaults.standard.set(
            existingTimestamps,
            forKey: StarterPromptUserDefaultsKey.triedAtTimestampsBySlug.rawValue
        )
    }

    static func hasTried(slug: String) -> Bool {
        return triedAtTimestampsBySlug()[slug] != nil
    }

    static func triedCount() -> Int {
        return triedAtTimestampsBySlug().count
    }

    // MARK: Dismissal bookkeeping

    static func dismissedAt() -> Date? {
        let interval = UserDefaults.standard.double(
            forKey: StarterPromptUserDefaultsKey.dismissedAtTimestamp.rawValue
        )
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    static func markDismissed(now: Date = Date()) {
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: StarterPromptUserDefaultsKey.dismissedAtTimestamp.rawValue
        )
    }

    /// Settings → "Show starter prompts again". Wipes the dismissed
    /// timestamp AND the first-seen timestamp so the 24h window starts
    /// fresh next time the panel opens. The tried-set is preserved so
    /// the user can see what they already exercised.
    static func resetVisibility() {
        UserDefaults.standard.removeObject(
            forKey: StarterPromptUserDefaultsKey.dismissedAtTimestamp.rawValue
        )
        UserDefaults.standard.removeObject(
            forKey: StarterPromptUserDefaultsKey.firstSeenAtTimestamp.rawValue
        )
    }

    // MARK: Visibility decision

    /// The single source of truth for "should the card be drawn now?".
    /// Pure: depends only on the three persisted timestamps plus `now`.
    /// Returns false in any of these cases:
    ///   - User explicitly dismissed (`dismissedAt` is set).
    ///   - User has tried at least `autoDismissAfterTriedCount` prompts.
    ///   - `firstSeenAt` is set and `now` is past the 24h window.
    /// Returns true otherwise — including the "never seen yet" case so
    /// the very first panel render shows the card.
    static func isVisible(now: Date = Date()) -> Bool {
        if dismissedAt() != nil { return false }
        if triedCount() >= autoDismissAfterTriedCount { return false }
        if let firstSeen = firstSeenAt() {
            let elapsedSinceFirstSeen = now.timeIntervalSince(firstSeen)
            if elapsedSinceFirstSeen >= visibilityWindowSeconds { return false }
        }
        return true
    }
}
