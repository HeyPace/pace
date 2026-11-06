//
//  PaceTTSVoiceResolver.swift
//  leanring-buddy
//
//  Shared voice-picking logic for LocalTTSClient and the panel's voice
//  quality preflight row.
//

import AVFoundation
import Foundation

enum PaceTTSVoiceResolver {
    static func bestAvailableVoice(preferredVoiceIdentifier: String?) -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        if let preferredVoiceIdentifier,
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier),
           preferredVoice.quality == .premium || preferredVoice.quality == .enhanced {
            return preferredVoice
        }

        let preferredVoiceNamesInOrder = ["Ava", "Evan", "Samantha", "Zoe", "Nathan", "Joelle", "Noelle"]
        for preferredName in preferredVoiceNamesInOrder {
            if let namedPremiumVoice = englishVoices.first(where: {
                $0.name == preferredName && $0.quality == .premium
            }) {
                return namedPremiumVoice
            }
        }
        for preferredName in preferredVoiceNamesInOrder {
            if let namedEnhancedVoice = englishVoices.first(where: {
                $0.name == preferredName && $0.quality == .enhanced
            }) {
                return namedEnhancedVoice
            }
        }

        if let premiumVoice = englishVoices.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = englishVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }

        if let preferredVoiceIdentifier,
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredVoiceIdentifier) {
            return preferredVoice
        }

        return AVSpeechSynthesisVoice(language: "en-US")
    }
}

struct PaceTTSVoiceSummary: Equatable {
    let voiceName: String
    let qualityName: String
    let needsUpgrade: Bool

    var displayText: String {
        "\(voiceName) · \(qualityName)"
    }

    var recommendationText: String {
        if qualityName == "Kokoro" {
            return "Kokoro speech runs locally on this Mac."
        }
        if qualityName == "Local model" {
            return "Speech runs locally on this Mac."
        }
        return needsUpgrade
            ? "Install an Enhanced or Premium Apple voice for better playback."
            : "High-quality local Apple voice active."
    }

    static func current() -> PaceTTSVoiceSummary {
        if AppBundleConfiguration.stringValue(forKey: "TTSProvider")?.lowercased() == "localserver" {
            let configuration = LocalServerTTSConfiguration.fromBundle()
            return localServerSummary(voiceIdentifier: configuration.voiceIdentifier, modelIdentifier: configuration.modelIdentifier)
        }
        let preferredVoiceIdentifier = AppBundleConfiguration.stringValue(forKey: "LocalTTSVoiceIdentifier")
        guard let voice = PaceTTSVoiceResolver.bestAvailableVoice(
            preferredVoiceIdentifier: preferredVoiceIdentifier
        ) else {
            return PaceTTSVoiceSummary(
                voiceName: "System voice",
                qualityName: "unknown",
                needsUpgrade: true
            )
        }

        switch voice.quality {
        case .premium:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Premium", needsUpgrade: false)
        case .enhanced:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Enhanced", needsUpgrade: false)
        default:
            return PaceTTSVoiceSummary(voiceName: voice.name, qualityName: "Compact", needsUpgrade: true)
        }
    }

    static func localServerSummary(
        voiceIdentifier: String,
        modelIdentifier: String = LocalServerTTSConfiguration.defaultModelIdentifier
    ) -> PaceTTSVoiceSummary {
        let isKokoro = modelIdentifier.lowercased().contains("kokoro")
        return PaceTTSVoiceSummary(
            voiceName: isKokoro && voiceIdentifier == "af_heart" ? "Heart" : voiceIdentifier,
            qualityName: isKokoro ? "Kokoro" : "Local model",
            needsUpgrade: false
        )
    }
}
