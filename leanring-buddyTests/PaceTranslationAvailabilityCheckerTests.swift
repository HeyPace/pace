//
//  PaceTranslationAvailabilityCheckerTests.swift
//  leanring-buddyTests
//
//  The live Translation framework probe can't be tested without
//  controlling the on-device model catalogue, but the pure
//  user-target-language resolver IS unit-testable in isolation.
//  Regressing it would silently change which language we ask
//  Apple to translate INTO.
//

import Foundation
import Testing
@testable import Pace

struct PaceTranslationAvailabilityCheckerTests {

    @Test func returnsRootLanguageCodeFromBCP47TagWithRegion() async throws {
        // Locale.preferredLanguages typically hands back BCP-47
        // tags shaped "en-US", "de-DE", "ja-JP". The availability
        // probe wants just the root code.
        let resolved = PaceTranslationAvailabilityChecker.resolveUserTargetLanguageCode(
            preferredLanguagesFromLocale: ["de-DE", "en-US"]
        )
        #expect(resolved == "de")
    }

    @Test func returnsBareLanguageCodeWhenAlreadyBare() async throws {
        let resolved = PaceTranslationAvailabilityChecker.resolveUserTargetLanguageCode(
            preferredLanguagesFromLocale: ["fr", "en-US"]
        )
        #expect(resolved == "fr")
    }

    @Test func handlesMultiSegmentBCP47TagsLikeZhHansCN() async throws {
        // BCP-47 supports script + region: "zh-Hans-CN" (Simplified
        // Chinese, China). Translation API expects just "zh".
        let resolved = PaceTranslationAvailabilityChecker.resolveUserTargetLanguageCode(
            preferredLanguagesFromLocale: ["zh-Hans-CN"]
        )
        #expect(resolved == "zh")
    }

    @Test func fallsBackToEnglishWhenPreferenceListIsEmpty() async throws {
        let resolved = PaceTranslationAvailabilityChecker.resolveUserTargetLanguageCode(
            preferredLanguagesFromLocale: []
        )
        #expect(resolved == "en")
    }

    @Test func usesFirstPreferredLanguageNotMostCommon() async throws {
        // First entry wins — that's the user's actual top
        // preference. We must NOT pick "en" just because it's
        // present somewhere in the list.
        let resolved = PaceTranslationAvailabilityChecker.resolveUserTargetLanguageCode(
            preferredLanguagesFromLocale: ["ja-JP", "en-US", "en-GB"]
        )
        #expect(resolved == "ja")
    }
}
