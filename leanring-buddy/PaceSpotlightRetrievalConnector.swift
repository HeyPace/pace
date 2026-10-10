//
//  PaceSpotlightRetrievalConnector.swift
//  leanring-buddy
//
//  Spotlight-backed file discovery for local retrieval. It is intentionally
//  scoped to explicit user-approved roots; Pace never starts a broad home-disk
//  crawl from this connector.
//

import Foundation

nonisolated struct PaceSpotlightRetrievalRequest {
    let rootURLs: [URL]
    let allowedPathExtensions: Set<String>
    let maximumCandidateCount: Int
    let timeoutSeconds: TimeInterval
}

nonisolated struct PaceSpotlightRetrievalConnector {
    let rootURLs: [URL]
    let fileManager: FileManager
    let allowedPathExtensions: Set<String>
    let candidateURLProvider: ((PaceSpotlightRetrievalRequest) -> [URL])?

    init(
        rootURLs: [URL],
        fileManager: FileManager = .default,
        allowedPathExtensions: Set<String> = ["txt", "md", "markdown", "json", "pdf", "rtf"],
        candidateURLProvider: ((PaceSpotlightRetrievalRequest) -> [URL])? = nil
    ) {
        self.rootURLs = rootURLs
        self.fileManager = fileManager
        self.allowedPathExtensions = allowedPathExtensions
        self.candidateURLProvider = candidateURLProvider
    }

    @MainActor
    func loadDocumentsAsync(
        maximumDocumentCount: Int = 200,
        maximumBytesPerFile: Int = 64_000,
        timeoutSeconds: TimeInterval = 1.0
    ) async -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let request = PaceSpotlightRetrievalRequest(
            rootURLs: rootURLs.filter { !PaceSecretPathExclusionPolicy.shouldExclude(localURL: $0) },
            allowedPathExtensions: allowedPathExtensions,
            maximumCandidateCount: maximumDocumentCount * 4,
            timeoutSeconds: timeoutSeconds
        )
        let candidateURLs: [URL]
        if let candidateURLProvider {
            candidateURLs = candidateURLProvider(request)
        } else {
            candidateURLs = await PaceSpotlightQueryGatherer().gather(request)
        }
        let rootURLs = request.rootURLs
        let allowedPathExtensions = allowedPathExtensions
        // Spotlight gathering needs the main run loop. Only file reads and
        // extraction leave the main actor; NSMetadataQuery never does.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                if candidateURLs.isEmpty {
                    // Explicitly chosen folders may be excluded from Spotlight
                    // (for example a temporary fixture folder). Bound fallback
                    // traversal to those same roots instead of reporting a
                    // successful empty read without trying the approved files.
                    let fallback = PaceFileRetrievalConnector(
                        rootURLs: rootURLs, allowedPathExtensions: allowedPathExtensions
                    )
                    .loadDocuments(maximumDocumentCount: maximumDocumentCount, maximumBytesPerFile: maximumBytesPerFile)
                    let failure = fallback.statuses.first(where: { $0.lastError != nil })
                    continuation.resume(
                        returning: (
                            fallback.documents,
                            failure
                                ?? .enabled(
                                    source: .file, displayName: PaceRetrievalSource.file.displayName,
                                    documentCount: fallback.documents.count
                                )
                        ))
                    return
                }
                let connector = PaceSpotlightRetrievalConnector(
                    rootURLs: rootURLs, allowedPathExtensions: allowedPathExtensions,
                    candidateURLProvider: { _ in candidateURLs }
                )
                continuation.resume(
                    returning: connector.loadDocuments(
                        maximumDocumentCount: maximumDocumentCount, maximumBytesPerFile: maximumBytesPerFile
                    ))
            }
        }
    }

    func loadDocuments(
        maximumDocumentCount: Int = 200,
        maximumBytesPerFile: Int = 64_000,
        timeoutSeconds: TimeInterval = 1.0
    ) -> (documents: [PaceRetrievalDocument], status: PaceRetrievalSourceStatus) {
        let safeRootURLs = rootURLs.filter { rootURL in
            guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: rootURL) else {
                return false
            }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }

        guard !safeRootURLs.isEmpty else {
            return (
                [],
                .skipped(
                    source: .file,
                    displayName: PaceRetrievalSource.file.displayName,
                    reason: "No safe Spotlight roots configured."
                )
            )
        }

        let candidateURLs = uniqueFileURLs(
            (candidateURLProvider ?? Self.discoverCandidateURLs)(
                PaceSpotlightRetrievalRequest(
                    rootURLs: safeRootURLs,
                    allowedPathExtensions: allowedPathExtensions,
                    maximumCandidateCount: maximumDocumentCount * 4,
                    timeoutSeconds: timeoutSeconds
                )
            )
        )
        .filter { candidateURL in
            isCandidateURL(candidateURL, insideAnyRoot: safeRootURLs)
        }

        let documents = loadDocuments(
            fromCandidateURLs: candidateURLs,
            maximumDocumentCount: maximumDocumentCount,
            maximumBytesPerFile: maximumBytesPerFile
        )

        return (
            documents,
            .enabled(
                source: .file,
                displayName: PaceRetrievalSource.file.displayName,
                documentCount: documents.count
            )
        )
    }

    nonisolated static func fileNamePredicate(allowedPathExtensions: Set<String>) -> NSPredicate {
        let sortedExtensions =
            allowedPathExtensions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .sorted()
        guard !sortedExtensions.isEmpty else {
            return NSPredicate(value: false)
        }

        let extensionPredicates = sortedExtensions.map { pathExtension in
            NSPredicate(
                format: "%K LIKE[cd] %@",
                NSMetadataItemFSNameKey,
                "*.\(pathExtension)"
            )
        }
        return NSCompoundPredicate(orPredicateWithSubpredicates: extensionPredicates)
    }

    nonisolated private static func discoverCandidateURLs(
        request: PaceSpotlightRetrievalRequest
    ) -> [URL] {
        let query = NSMetadataQuery()
        query.searchScopes = request.rootURLs
        query.predicate = fileNamePredicate(
            allowedPathExtensions: request.allowedPathExtensions
        )

        let semaphore = DispatchSemaphore(value: 0)
        var observer: NSObjectProtocol?
        // The observer only signals the semaphore — it intentionally does
        // NOT capture `query` so this `@Sendable` notification block stays
        // free of the non-Sendable NSMetadataQuery. The query is stopped on
        // the calling thread right after the semaphore wait below, so the
        // gathering pass is still torn down deterministically.
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: nil
        ) { _ in
            semaphore.signal()
        }

        guard query.start() else {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            return []
        }

        _ = semaphore.wait(timeout: .now() + request.timeoutSeconds)
        query.disableUpdates()
        query.stop()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }

        return query.results
            .prefix(request.maximumCandidateCount)
            .compactMap { result in
                guard let metadataItem = result as? NSMetadataItem,
                    let path = metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String
                else {
                    return nil
                }
                return URL(fileURLWithPath: path)
            }
    }

    private func loadDocuments(
        fromCandidateURLs candidateURLs: [URL],
        maximumDocumentCount: Int,
        maximumBytesPerFile: Int
    ) -> [PaceRetrievalDocument] {
        var documents: [PaceRetrievalDocument] = []
        for candidateURL in candidateURLs {
            guard documents.count < maximumDocumentCount else { break }
            let connector = PaceFileRetrievalConnector(
                rootURLs: [candidateURL],
                fileManager: fileManager,
                allowedPathExtensions: allowedPathExtensions
            )
            let result = connector.loadDocuments(
                maximumDocumentCount: 1,
                maximumBytesPerFile: maximumBytesPerFile
            )
            documents.append(contentsOf: result.documents)
        }
        return documents
    }

    private func uniqueFileURLs(_ fileURLs: [URL]) -> [URL] {
        var seenPaths = Set<String>()
        var uniqueURLs: [URL] = []
        for fileURL in fileURLs {
            let standardizedPath = fileURL.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else { continue }
            uniqueURLs.append(fileURL.standardizedFileURL)
        }
        return uniqueURLs
    }

    private func isCandidateURL(_ candidateURL: URL, insideAnyRoot rootURLs: [URL]) -> Bool {
        guard !PaceSecretPathExclusionPolicy.shouldExclude(localURL: candidateURL),
            allowedPathExtensions.contains(candidateURL.pathExtension.lowercased())
        else {
            return false
        }

        let candidatePath = candidateURL.resolvingSymlinksInPath().standardizedFileURL.path
        return rootURLs.contains { rootURL in
            let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
        }
    }
}

@MainActor
private final class PaceSpotlightQueryGatherer {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<[URL], Never>?
    private var maximumCandidateCount = 0

    func gather(_ request: PaceSpotlightRetrievalRequest) async -> [URL] {
        guard !request.rootURLs.isEmpty else { return [] }
        maximumCandidateCount = request.maximumCandidateCount
        query.searchScopes = request.rootURLs
        query.predicate = PaceSpotlightRetrievalConnector.fileNamePredicate(
            allowedPathExtensions: request.allowedPathExtensions)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
            guard query.start() else {
                finish()
                return
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, request.timeoutSeconds)))
                guard !Task.isCancelled else { return }
                finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        query.disableUpdates()
        let candidateURLs = query.results.prefix(maximumCandidateCount).compactMap { result -> URL? in
            guard let item = result as? NSMetadataItem,
                let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { return nil }
            return URL(fileURLWithPath: path)
        }
        query.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        continuation.resume(returning: candidateURLs)
    }
}
