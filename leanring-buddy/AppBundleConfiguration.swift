//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    nonisolated static func stringValue(forKey key: String, preferences: UserDefaults = .standard) -> String? {
        if let persistedVoiceSetting = persistedVoiceSetting(forKey: key, preferences: preferences) {
            return persistedVoiceSetting
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    nonisolated static func persistedVoiceSetting(forKey key: String, preferences: UserDefaults) -> String? {
        // Only voice playback choices can override bundle configuration. Cloud
        // consent, screen access and action permissions keep their existing gates.
        let preferenceKey: String
        switch key {
        case "TTSProvider": preferenceKey = "pace.voice.provider"
        case "LocalTTSServerVoice": preferenceKey = "pace.voice.kokoro.voice"
        case "LocalTTSServerSpeed": preferenceKey = "pace.voice.kokoro.speed"
        default: return nil
        }
        guard let configuredValue = preferences.string(forKey: preferenceKey) else { return nil }
        let trimmedValue = configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }
        if key == "TTSProvider" {
            let normalizedProvider = trimmedValue.lowercased()
            guard ["apple", "localserver"].contains(normalizedProvider) else { return nil }
            return normalizedProvider
        }
        if key == "LocalTTSServerSpeed" {
            guard let speed = Double(trimmedValue), speed.isFinite, speed > 0.25, speed < 4.0 else { return nil }
        }
        return trimmedValue
    }
}
