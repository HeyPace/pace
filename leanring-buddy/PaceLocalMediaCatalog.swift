import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A separate local catalog resolves IDs. Planner values never become URLs or filesystem paths.
nonisolated struct PaceLocalMediaCatalog {
    struct Asset: Equatable, Sendable {
        let identifier: String
        let title: String
        let resourceName: String
        let resourceExtension: String
    }
    private struct ImportedAsset: Codable {
        let identifier: String
        let fileName: String
        let sha256: String
        let originalFileName: String
        let importedAt: Date
    }
    static let bundled = [Asset(identifier: "thank-you-dance", title: "Thank you",
        resourceName: "thank-you-dance", resourceExtension: "gif")]
    static let maximumFileBytes = 20 * 1024 * 1024
    let importedDirectoryURL: URL
    init(importedDirectoryURL: URL = PaceUserAutomationStore.defaultDirectoryURL.deletingLastPathComponent().appendingPathComponent("power-media", isDirectory: true)) {
        self.importedDirectoryURL = importedDirectoryURL
    }

    func resourceURL(for identifier: String, bundle: Bundle = .main) -> URL? {
        if let asset = Self.bundled.first(where: { $0.identifier == identifier }) {
            return bundle.url(forResource: asset.resourceName, withExtension: asset.resourceExtension, subdirectory: "media")
                ?? bundle.url(forResource: asset.resourceName, withExtension: asset.resourceExtension)
        }
        guard PaceManagedPowerStore.safeIdentifier(identifier), (try? Self.validateDirectoryChain(importedDirectoryURL)) != nil else { return nil }
        let assetDirectoryURL = importedDirectoryURL.appendingPathComponent(identifier, isDirectory: true)
        guard (try? Self.validateDirectoryChain(assetDirectoryURL)) != nil else { return nil }
        let manifestURL = assetDirectoryURL.appendingPathComponent("asset.json")
        guard Self.isRegularOwnedFile(manifestURL), let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(ImportedAsset.self, from: manifestData),
              manifest.identifier == identifier, ["media.gif", "media.png"].contains(manifest.fileName) else { return nil }
        let assetURL = assetDirectoryURL.appendingPathComponent(manifest.fileName)
        guard Self.isRegularOwnedFile(assetURL), let bytes = try? Self.boundedData(at: assetURL),
              PaceManagedPowerStore.fingerprint(bytes) == manifest.sha256,
              (try? Self.validatedMediaExtension(bytes)) != nil else { return nil }
        return assetURL
    }

    func authoringAssetIdentifiers(bundle: Bundle = .main) -> [String] {
        let bundledIdentifiers = Self.bundled.map(\.identifier).filter { resourceURL(for: $0, bundle: bundle) != nil }
        guard (try? Self.validateDirectoryChain(importedDirectoryURL)) != nil,
              let importedURLs = try? FileManager.default.contentsOfDirectory(at: importedDirectoryURL, includingPropertiesForKeys: nil) else { return bundledIdentifiers }
        let importedIdentifiers = importedURLs.map(\.lastPathComponent).sorted().prefix(32)
            .filter { resourceURL(for: $0, bundle: bundle) != nil }
        return bundledIdentifiers + importedIdentifiers
    }

    /// This API is reached only by the explicit local import command, never by a tool call or planner path.
    func importAsset(from sourceURL: URL, identifier: String) throws {
        guard sourceURL.isFileURL, sourceURL.path.hasPrefix("/"), Self.isRegularOwnedFile(sourceURL),
              PaceManagedPowerStore.safeIdentifier(identifier) else { throw PaceManagedPowerError.invalid("choose a regular GIF or PNG file and a lowercase asset ID") }
        guard !Self.bundled.contains(where: { $0.identifier == identifier }) else { throw PaceManagedPowerError.collision }
        try Self.validateDirectoryChain(importedDirectoryURL)
        let destinationDirectoryURL = importedDirectoryURL.appendingPathComponent(identifier, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destinationDirectoryURL.path) else { throw PaceManagedPowerError.collision }
        let bytes = try Self.boundedData(at: sourceURL)
        let fileExtension = try Self.validatedMediaExtension(bytes)
        try FileManager.default.createDirectory(at: importedDirectoryURL, withIntermediateDirectories: true)
        let temporaryDirectoryURL = importedDirectoryURL.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectoryURL, withIntermediateDirectories: false)
        do {
            let fileName = "media." + fileExtension
            try bytes.write(to: temporaryDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            let manifest = ImportedAsset(identifier: identifier, fileName: fileName,
                sha256: PaceManagedPowerStore.fingerprint(bytes), originalFileName: sourceURL.lastPathComponent, importedAt: Date())
            try JSONEncoder().encode(manifest).write(to: temporaryDirectoryURL.appendingPathComponent("asset.json"), options: .atomic)
            try FileManager.default.moveItem(at: temporaryDirectoryURL, to: destinationDirectoryURL)
        } catch {
            // Only this unfinished import directory is owned by this operation.
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            throw error
        }
    }
    private static func boundedData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= maximumFileBytes else { throw PaceManagedPowerError.invalid("media must be at most twenty megabytes") }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= maximumFileBytes else { throw PaceManagedPowerError.invalid("media exceeded the size limit") }
        return bytes
    }
    private static func validatedMediaExtension(_ bytes: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, [UTType.gif.identifier, UTType.png.identifier].contains(type) else {
            throw PaceManagedPowerError.invalid("file contents must be GIF or PNG")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard (1...300).contains(frameCount) else { throw PaceManagedPowerError.invalid("media must have one to three hundred frames") }
        var totalPixels = 0
        for frameIndex in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height),
                  CGImageSourceCreateImageAtIndex(source, frameIndex, nil) != nil else {
                throw PaceManagedPowerError.invalid("media frames must decode and fit within four thousand ninety-six pixels per side")
            }
            totalPixels += width * height
            guard totalPixels <= 100_000_000 else { throw PaceManagedPowerError.invalid("media has too many total decoded pixels") }
        }
        return type == UTType.gif.identifier ? "gif" : "png"
    }
    private static func isRegularOwnedFile(_ url: URL) -> Bool {
        PaceManagedPowerStore.isRegularFileWithoutFollowingSymlinks(at: url)
    }
    private static func validateDirectoryChain(_ directoryURL: URL) throws {
        // URL.standardizedFileURL rewrites macOS /private/var back to /var.
        // Walk literal ancestors so an OS alias cannot hide a managed child link.
        var ancestorPath = directoryURL.path
        let systemAliases = ["/var": "/private/var", "/tmp": "/private/tmp", "/etc": "/private/etc"]
        while !ancestorPath.isEmpty && ancestorPath != "/" {
            let ancestorURL = URL(fileURLWithPath: ancestorPath)
            if PaceManagedPowerStore.isSymbolicLink(at: ancestorURL) {
                let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: ancestorPath)
                let absoluteLinkDestination = linkDestination.hasPrefix("/") ? linkDestination : "/" + linkDestination
                guard systemAliases[ancestorPath] == absoluteLinkDestination else {
                    throw PaceManagedPowerError.invalid("a media directory is a symbolic link")
                }
            }
            ancestorPath = (ancestorPath as NSString).deletingLastPathComponent
        }
    }
}
