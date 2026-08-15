//
//  PaceTaughtObjectStore.swift
//  leanring-buddy
//
//  Template and error types for objects the user explicitly teaches to
//  companion mode. Vision feature-print archives are retained; source
//  camera pixels are never written to disk.
//

import Foundation

nonisolated enum PaceTaughtObjectError: Error, Equatable, LocalizedError {
    case emptyLabel
    case cameraNotActive
    case featurePrintUnavailable

    var errorDescription: String? {
        switch self {
        case .emptyLabel:
            return "Enter a short object name first."
        case .cameraNotActive:
            return "Enable companion mode and its Camera source before teaching an object."
        case .featurePrintUnavailable:
            return "Pace could not capture a usable view. Center the object and try again."
        }
    }
}

nonisolated struct PaceTaughtObjectTemplate: Codable, Equatable, Sendable {
    let label: String
    let featurePrintArchive: Data
    let taughtAt: Date

    init(label: String, featurePrintArchive: Data, taughtAt: Date = Date()) throws {
        let normalizedLabel = Self.normalizedLabel(label)
        guard normalizedLabel.isEmpty == false else { throw PaceTaughtObjectError.emptyLabel }
        guard featurePrintArchive.isEmpty == false else {
            throw PaceTaughtObjectError.featurePrintUnavailable
        }
        self.label = normalizedLabel
        self.featurePrintArchive = featurePrintArchive
        self.taughtAt = taughtAt
    }

    static func normalizedLabel(_ label: String) -> String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
    }

    var trackIdentifier: String {
        let slug = label.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let compact = String(slug).split(separator: "-").joined(separator: "-")
        return "taught-object-\(compact.isEmpty ? "object" : compact)"
    }
}
