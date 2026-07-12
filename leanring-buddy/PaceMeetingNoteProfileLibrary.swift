//
//  PaceMeetingNoteProfileLibrary.swift
//  leanring-buddy
//
//  Loads meeting note profiles from two sources, mirroring the
//  `PaceRecipeLibrary` (bundled) + `PaceSkillLoader` (user override)
//  pattern:
//    1. Bundled `Resources/meeting-note-profiles/<slug>.json` — the
//       curated set shipped with the app. Validated at startup via
//       `PaceToolRegistry.validateForAppStartup` so malformed drift
//       fails loud at launch (same contract as recipes).
//    2. User `~/Library/Application Support/Pace/meeting-note-profiles/
//       <slug>.json` — user-authored profiles. A user profile whose
//       slug matches a bundled one OVERRIDES it. A malformed user file
//       is skipped (soft fail) so a bad file can never crash the app.
//
//  Pure module — no UI, no async, no global state.
//
//  See openspec/changes/adaptive-meeting-notes for the full spec.
//

import Foundation

// MARK: - Validation issue type

/// One specific problem the validator surfaced. Mirrors
/// `PaceRecipeValidationIssue` so the startup-validation site treats
/// both validator outputs uniformly.
nonisolated struct PaceMeetingNoteProfileValidationIssue: Equatable, CustomStringConvertible {
    let message: String

    var description: String {
        message
    }
}

// MARK: - Library

nonisolated enum PaceMeetingNoteProfileLibrary {
    /// Subdirectory inside the bundle where profile JSON files live.
    static let bundleResourceDirectory: String = "meeting-note-profiles"

    /// The profile slugs shipped in the bundle. Authoritative list so a
    /// missing-from-bundle profile is detected at validation instead of
    /// silently absent.
    static let bundledProfileSlugs: [String] = [
        "general",
        "standup",
        "one-on-one",
    ]

    // MARK: - Loading

    /// All available profiles: bundled profiles, with any user profile
    /// of the same slug overriding, plus user-only profiles. The
    /// `general` profile is always present (falls back to the built-in
    /// static value even if the bundled file is somehow missing) so
    /// selection can always resolve to it.
    static func loadProfiles(
        bundle: Bundle = .main,
        userDirectory: URL? = nil
    ) -> [PaceMeetingNoteProfile] {
        var bySlug: [String: PaceMeetingNoteProfile] = [:]

        // Bundled first.
        for profile in loadBundledProfiles(bundle: bundle) {
            bySlug[profile.slug] = profile
        }
        // General must always exist.
        if bySlug["general"] == nil {
            bySlug["general"] = .general
        }
        // User overrides / additions win.
        for profile in loadUserProfiles(directory: userDirectory ?? userProfilesDirectory()) {
            bySlug[profile.slug] = profile
        }

        // Stable order: general first, then the rest alphabetically by name.
        return bySlug.values.sorted { lhs, rhs in
            if lhs.slug == "general" { return true }
            if rhs.slug == "general" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Resolve a single profile by slug, falling back to `.general` when
    /// the slug is unknown. Used by the selection path.
    static func profile(forSlug slug: String, bundle: Bundle = .main) -> PaceMeetingNoteProfile {
        loadProfiles(bundle: bundle).first { $0.slug == slug } ?? .general
    }

    /// Pure precedence resolver for which profile synthesizes a meeting.
    /// Precedence:
    ///   1. an explicit per-meeting slug, else
    ///   2. a non-`general` pinned default preference, else
    ///   3. a locally-inferred slug (only supplied when inference is
    ///      enabled and no non-general default is pinned), else
    ///   4. the default preference (i.e. `general`) → `.general`.
    /// Any slug that isn't in `available` is ignored at that tier.
    /// Kept pure (no I/O, no planner) so the precedence is unit-testable.
    static func resolveProfile(
        explicitSlug: String?,
        defaultSlug: String,
        inferredSlug: String?,
        available: [PaceMeetingNoteProfile]
    ) -> PaceMeetingNoteProfile {
        func find(_ slug: String?) -> PaceMeetingNoteProfile? {
            guard let slug else { return nil }
            return available.first { $0.slug == slug }
        }
        if let explicit = find(explicitSlug) { return explicit }
        if defaultSlug != "general", let pinned = find(defaultSlug) { return pinned }
        if let inferred = find(inferredSlug) { return inferred }
        return find(defaultSlug) ?? .general
    }

    /// Whether local inference should run given the current selection
    /// inputs: only when enabled, no explicit per-meeting choice, and no
    /// non-general default is pinned. Pure predicate for testability.
    static func shouldInfer(
        explicitSlug: String?,
        defaultSlug: String,
        inferenceEnabled: Bool
    ) -> Bool {
        guard inferenceEnabled else { return false }
        guard explicitSlug == nil else { return false }
        return defaultSlug == "general"
    }

    /// Load bundled profiles that decode cleanly. Skips (does not throw
    /// on) a profile whose JSON fails to decode — startup validation
    /// surfaces the precise failure separately, matching recipes.
    static func loadBundledProfiles(bundle: Bundle = .main) -> [PaceMeetingNoteProfile] {
        var loaded: [PaceMeetingNoteProfile] = []
        for slug in bundledProfileSlugs {
            guard let url = profileResourceURL(slug: slug, bundle: bundle, allowSourceTreeFallback: false),
                  let data = try? Data(contentsOf: url),
                  let profile = try? decoder.decode(PaceMeetingNoteProfile.self, from: data) else {
                continue
            }
            loaded.append(profile)
        }
        return loaded
    }

    /// Load user-authored profiles from `directory` (defaults to
    /// Application Support). A malformed file is skipped (soft fail); a
    /// bad user file MUST NOT crash.
    static func loadUserProfiles(directory: URL = PaceMeetingNoteProfileLibrary.userProfilesDirectory()) -> [PaceMeetingNoteProfile] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        var loaded: [PaceMeetingNoteProfile] = []
        for url in entries where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let profile = try? decoder.decode(PaceMeetingNoteProfile.self, from: data),
                  Self.validateProfileShape(profile, expectedSlug: profile.slug).isEmpty else {
                continue
            }
            loaded.append(profile)
        }
        return loaded
    }

    static func userProfilesDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Pace", isDirectory: true)
            .appendingPathComponent(bundleResourceDirectory, isDirectory: true)
            ?? URL(fileURLWithPath: "/dev/null")
    }

    // MARK: - Validation

    /// Validate every bundled profile JSON. Called from
    /// `PaceToolRegistry.validateForAppStartup` so malformed profile
    /// drift fails the app at launch instead of at first user
    /// interaction. `allowSourceTreeFallback` mirrors the recipe
    /// convention: false at runtime (bundle-only), true for tests.
    static func validateBundledProfiles(
        bundle: Bundle = .main,
        allowSourceTreeFallback: Bool = true
    ) -> [PaceMeetingNoteProfileValidationIssue] {
        validateBundledProfiles(resolveProfileURL: { slug in
            profileResourceURL(
                slug: slug,
                bundle: bundle,
                allowSourceTreeFallback: allowSourceTreeFallback
            )
        })
    }

    /// Test-facing entry point taking an explicit URL provider so unit
    /// tests can validate a fixture directory without a full `Bundle`.
    static func validateBundledProfiles(
        resolveProfileURL: (String) -> URL?
    ) -> [PaceMeetingNoteProfileValidationIssue] {
        var issues: [PaceMeetingNoteProfileValidationIssue] = []
        var seenSlugs: Set<String> = []

        for expectedSlug in bundledProfileSlugs {
            guard let url = resolveProfileURL(expectedSlug) else {
                issues.append(PaceMeetingNoteProfileValidationIssue(
                    message: "missing bundled profile at Resources/\(bundleResourceDirectory)/\(expectedSlug).json"
                ))
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                issues.append(PaceMeetingNoteProfileValidationIssue(
                    message: "could not read bundled profile \(expectedSlug): \(error.localizedDescription)"
                ))
                continue
            }
            let profile: PaceMeetingNoteProfile
            do {
                profile = try decoder.decode(PaceMeetingNoteProfile.self, from: data)
            } catch {
                issues.append(PaceMeetingNoteProfileValidationIssue(
                    message: "bundled profile \(expectedSlug).json failed to decode: \(error.localizedDescription)"
                ))
                continue
            }
            issues.append(contentsOf: validateProfileShape(profile, expectedSlug: expectedSlug))

            if seenSlugs.contains(profile.slug) {
                issues.append(PaceMeetingNoteProfileValidationIssue(message: "duplicate profile slug \(profile.slug)"))
            } else {
                seenSlugs.insert(profile.slug)
            }
        }

        return issues
    }

    // MARK: - Private helpers

    /// Structural checks reused by bundled validation (loud) and user
    /// loading (soft skip). Returned as issues so the caller decides
    /// whether an issue is fatal.
    static func validateProfileShape(
        _ profile: PaceMeetingNoteProfile,
        expectedSlug: String
    ) -> [PaceMeetingNoteProfileValidationIssue] {
        var issues: [PaceMeetingNoteProfileValidationIssue] = []

        if profile.slug != expectedSlug {
            issues.append(PaceMeetingNoteProfileValidationIssue(
                message: "profile at \(expectedSlug).json declares slug \(profile.slug); filename and slug must match"
            ))
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PaceMeetingNoteProfileValidationIssue(message: "profile \(expectedSlug) has empty name"))
        }
        if profile.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(PaceMeetingNoteProfileValidationIssue(message: "profile \(expectedSlug) has empty description"))
        }
        if profile.sections.isEmpty {
            issues.append(PaceMeetingNoteProfileValidationIssue(message: "profile \(expectedSlug) must declare at least one section"))
        }
        for section in profile.sections {
            if section.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(PaceMeetingNoteProfileValidationIssue(message: "profile \(expectedSlug) has a section with an empty key"))
            }
            if section.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(PaceMeetingNoteProfileValidationIssue(message: "profile \(expectedSlug) section \(section.key) has an empty instruction"))
            }
        }

        return issues
    }

    /// Bundle resource lookup, mirroring `PaceRecipeLibrary`. Tries the
    /// synchronized-group layout, the flat layout, then optionally the
    /// source tree (validation/tests only).
    private static func profileResourceURL(
        slug: String,
        bundle: Bundle,
        allowSourceTreeFallback: Bool
    ) -> URL? {
        let candidates = [
            bundle.url(forResource: slug, withExtension: "json", subdirectory: "Resources/\(bundleResourceDirectory)"),
            bundle.url(forResource: slug, withExtension: "json", subdirectory: bundleResourceDirectory),
            bundle.url(forResource: slug, withExtension: "json"),
        ]
        if let bundled = candidates.compactMap({ $0 }).first {
            return bundled
        }

        guard allowSourceTreeFallback else { return nil }
        let sourceTreeURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("leanring-buddy")
            .appendingPathComponent("Resources")
            .appendingPathComponent(bundleResourceDirectory)
            .appendingPathComponent("\(slug).json")
        return FileManager.default.fileExists(atPath: sourceTreeURL.path) ? sourceTreeURL : nil
    }

    private static let decoder = JSONDecoder()
}
