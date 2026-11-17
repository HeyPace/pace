import AppKit
import WebKit

@MainActor
final class PaceGeneratedSVGRenderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    var onRenderFailure: (() -> Void)?
    private var readiness: CheckedContinuation<Void, Error>?
    private var ruleReadiness: CheckedContinuation<WKContentRuleList, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var permitsInitialNavigation = true
    private var stopped = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 320), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .clear
    }

    func prepare(_ svg: PaceGeneratedSVG) async throws {
        guard !stopped, permitsInitialNavigation, ruleReadiness == nil, readiness == nil else { throw CancellationError() }
        try await withTaskCancellationHandler {
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
            let rules = #"[{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document"]},"action":{"type":"block"}},{"trigger":{"url-filter":"^data:image/svg\\+xml;base64,","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]"#
            let list: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
                ruleReadiness = continuation
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "pace-generated-svg-v1", encodedContentRuleList: rules) { [weak self] list, error in
                    Task { @MainActor [weak self] in
                        guard let self, let pending = self.ruleReadiness else { return }
                        self.ruleReadiness = nil
                        if let list { pending.resume(returning: list) }
                        else { pending.resume(throwing: error ?? CocoaError(.fileReadCorruptFile)) }
                    }
                }
            }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            webView.configuration.userContentController.add(list)
            let encodedSVG = Data(svg.markup.utf8).base64EncodedString()
            let document = """
            <!doctype html><html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}img{display:block;width:100%;height:100%;object-fit:contain}</style></head><body><img alt="Generated Power drawing" src="data:image/svg+xml;base64,\(encodedSVG)"></body></html>
            """
            try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                webView.loadHTMLString(document, baseURL: nil)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        onRenderFailure = nil
        finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.removeFromSuperview()
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let wasPreparing = readiness != nil
        finish(.failure(CocoaError(.fileReadUnknown)))
        if !wasPreparing, !stopped { onRenderFailure?() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if permitsInitialNavigation, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .other, navigationAction.request.url?.absoluteString == "about:blank" {
            permitsInitialNavigation = false
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }
}
