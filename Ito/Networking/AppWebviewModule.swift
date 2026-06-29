import Foundation
import WebKit
import ito_runner

actor AppWebviewModule: WebviewModule {
    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        print("AppWebviewModule: loadUrl called for \(request.url)")
        return try await WebviewManager.shared.loadUrl(request: request)
    }

    func executeJs(script: String) async throws -> String {
        print("AppWebviewModule: executeJs called")
        return try await WebviewManager.shared.executeJs(script: script)
    }
}

@MainActor
class WebviewManager: NSObject, WKNavigationDelegate {
    static let shared = WebviewManager()

    private var webView: WKWebView?
    private var resolveContinuation: CheckedContinuation<WebviewResponse, Error>?

    private override init() {
        super.init()
    }

    private func setupWebView() {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()
            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs

            let wv = WKWebView(frame: UIScreen.main.bounds, configuration: config)
            // Use the same fallback UA as CloudflareManager
            wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
            wv.navigationDelegate = self
            wv.alpha = 0.01
            wv.isUserInteractionEnabled = false

            // Wait for window
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.insertSubview(wv, at: 0)
            }
            self.webView = wv
        }
    }

    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        print("WebviewManager: loadUrl requested for \(request.url)")
        if resolveContinuation != nil {
            print("WebviewManager: cancelling previous continuation")
            resolveContinuation?.resume(throwing: URLError(.cancelled))
            resolveContinuation = nil
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.resolveContinuation = continuation
            self.setupWebView()

            guard let url = URL(string: request.url) else {
                print("WebviewManager: bad url \(request.url)")
                continuation.resume(throwing: URLError(.badURL))
                self.resolveContinuation = nil
                return
            }

            print("WebviewManager: loading url request")
            self.webView?.load(URLRequest(url: url))
        }
    }

    func executeJs(script: String) async throws -> String {
        print("WebviewManager: executing js script of length \(script.count)")
        return try await withCheckedThrowingContinuation { continuation in
            guard let wv = webView else {
                print("WebviewManager: webView is nil")
                continuation.resume(throwing: URLError(.badURL))
                return
            }
            wv.evaluateJavaScript(script) { result, error in
                if let error = error {
                    print("WebviewManager: evaluateJavaScript error: \(error)")
                    continuation.resume(throwing: error)
                } else {
                    let resultStr = String(describing: result ?? "")
                    print("WebviewManager: evaluateJavaScript success, result length: \(resultStr.count)")
                    continuation.resume(returning: resultStr)
                }
            }
        }
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        print("WebviewManager: didFinish navigation")
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] htmlResult, _ in
            let html = (htmlResult as? String) ?? ""
            print("WebviewManager: didFinish grabbed html of length \(html.count)")
            let response = WebviewResponse(url: webView.url?.absoluteString ?? "", html: html)
            self?.resolveContinuation?.resume(returning: response)
            self?.resolveContinuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebviewManager: didFail navigation error: \(error)")
        self.resolveContinuation?.resume(throwing: error)
        self.resolveContinuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.resolveContinuation?.resume(throwing: error)
        self.resolveContinuation = nil
    }
}
