import AppKit
import SwiftUI
import WebKit

@MainActor
final class PaceGeneratedSVGRenderer {
    let page: WebPage
    let view: NSView
    let configuration: WebPage.Configuration
    var onRenderFailure: (() -> Void)?
    private(set) var isStopped = false
    private let navigationDecider: PaceSVGNavigationDecider
    var blockedNavigationCount: Int { navigationDecider.blockedNavigationCount }
    private var readiness: CheckedContinuation<Void, Error>?
    private var ruleReadiness: CheckedContinuation<WKContentRuleList, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var navigationMonitor: Task<Void, Never>?
    private var hasPrepared = false

    init(viewportSize: CGSize = CGSize(width: 240, height: 320)) {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        self.configuration = configuration
        let navigationDecider = PaceSVGNavigationDecider()
        self.navigationDecider = navigationDecider
        let page = WebPage(configuration: configuration, navigationDecider: navigationDecider)
        self.page = page
        let hostingView = NSHostingView(
            rootView: WebView(page)
                .webViewContentBackground(.hidden)
                .webViewBackForwardNavigationGestures(.disabled)
                .webViewMagnificationGestures(.disabled)
                .webViewTextSelection(.disabled)
                .allowsHitTesting(false)
                .frame(width: viewportSize.width, height: viewportSize.height))
        hostingView.sizingOptions = []
        hostingView.frame = CGRect(origin: .zero, size: viewportSize)
        view = hostingView
    }

    func prepare(_ svg: PaceGeneratedSVG) async throws {
        guard !isStopped, !hasPrepared else { throw CancellationError() }
        hasPrepared = true
        try await withTaskCancellationHandler {
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
            let rules =
                #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}},{"trigger":{"url-filter":"^data:image/svg\\+xml;base64,","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]"#
            let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                ruleReadiness = continuation
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "pace-generated-svg-v1", encodedContentRuleList: rules
                ) { [weak self] list, error in
                    Task { @MainActor [weak self] in
                        guard let self, let pending = self.ruleReadiness else { return }
                        self.ruleReadiness = nil
                        if let list {
                            pending.resume(returning: list)
                        } else {
                            pending.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
                        }
                    }
                }
            }
            try Task.checkCancellation()
            guard !isStopped else { throw CancellationError() }
            configuration.userContentController.add(list)
            let encodedSVG = Data(svg.markup.utf8).base64EncodedString()
            let document = """
                <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style></head><body><img alt="Generated Power drawing" src="data:image/svg+xml;base64,\(encodedSVG)"></body></html>
                """
            let events = page.navigations
            navigationMonitor = Task { @MainActor [weak self] in
                do { for try await _ in events { if Task.isCancelled { return } } } catch {
                    if !Task.isCancelled { self?.handleFailure(error) }
                }
            }
            try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                loadTask = Task { @MainActor [weak self, page] in
                    do {
                        for try await event in page.load(html: document) {
                            guard !Task.isCancelled else { return }
                            if event == .finished {
                                self?.finish(.success(()))
                                return
                            }
                        }
                        self?.handleFailure(CocoaError(.fileReadUnknown))
                    } catch { if !Task.isCancelled { self?.handleFailure(error) } }
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        onRenderFailure = nil
        finish(.failure(CancellationError()))
        loadTask?.cancel()
        loadTask = nil
        navigationMonitor?.cancel()
        navigationMonitor = nil
        page.stopLoading()
        navigationDecider.permitEmptyTeardown()
        page.load(html: "<!doctype html><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'\">")
        configuration.userContentController.removeAllContentRuleLists()
        view.removeFromSuperview()
    }

    private func finish(_ result: Result<Void, Error>) {
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .failure(let error) = result {
            let pendingRules = ruleReadiness
            ruleReadiness = nil
            pendingRules?.resume(throwing: error)
        }
        let continuation = readiness
        readiness = nil
        continuation?.resume(with: result)
    }

    private func handleFailure(_ error: Error) {
        guard !isStopped else { return }
        let wasPreparing = ruleReadiness != nil || readiness != nil
        finish(.failure(error))
        if !wasPreparing { onRenderFailure?() }
    }
}

@MainActor
private final class PaceSVGNavigationDecider: WebPage.NavigationDeciding {
    private var permitsHostBlank = true
    private(set) var blockedNavigationCount = 0

    func permitEmptyTeardown() { permitsHostBlank = true }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async
        -> WKNavigationActionPolicy
    {
        preferences.allowsContentJavaScript = false
        guard permitsHostBlank, action.target?.isMainFrame == true, action.navigationType == .other,
            !action.shouldPerformDownload, action.request.url?.absoluteString == "about:blank"
        else {
            blockedNavigationCount += 1
            return .cancel
        }
        permitsHostBlank = false
        return .allow
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        response.response.url?.absoluteString == "about:blank" && response.canShowMimeType ? .allow : .cancel
    }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (
        URLSession.AuthChallengeDisposition, URLCredential?
    ) {
        (.cancelAuthenticationChallenge, nil)
    }
}
