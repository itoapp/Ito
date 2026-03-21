import Foundation
import WebKit
import Combine
import SwiftUI
import UIKit

@MainActor
class CloudflareManager: NSObject, ObservableObject {
    static let shared = CloudflareManager()

    // Using a hidden WKWebView to silently process challenges
    private var webView: WKWebView?
    private var resolveContinuation: CheckedContinuation<(userAgent: String, cookies: [HTTPCookie]), Error>?
    private var targetURL: URL?
    private var isResolving = false

    private let clearanceCookieName = "cf_clearance"

    // We cache the valid UA and cookies per host
    private var cachedUserAgents: [String: String] = [:]

    private var timeoutTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    override private init() {
        super.init()
    }

    func getCachedUserAgent(for host: String) -> String? {
        return cachedUserAgents[host] ?? cachedUserAgents[host.replacingOccurrences(of: "www.", with: "")]
    }

    /// Resolves the Cloudflare challenge for the given URL and returns the solved User-Agent and Cookies.
    func resolveChallenge(for url: URL) async throws -> (userAgent: String, cookies: [HTTPCookie]) {
        // If an existing challenge is being solved, cancel it and start new one
        if isResolving {
            finish(with: URLError(.cancelled))
        }

        isResolving = true

        return try await withCheckedThrowingContinuation { continuation in
            self.resolveContinuation = continuation
            self.targetURL = url

            self.setupAndLoadWebView(with: url)

            // Add a 30 second hard timeout
            self.timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    if self.isResolving {
                        print("[CloudflareManager] Hard timeout reached.")
                        self.finish(with: URLError(.timedOut))
                    }
                } catch { }
            }

            // If not solved in 5 seconds, present the WebView interactively
            Task {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    if self.isResolving {
                        print("[CloudflareManager] Falling back to interactive challenge...")
                        self.presentInteractiveWebView()
                    }
                } catch { }
            }

            // Poll for cookies every 2 seconds
            self.pollingTask = Task {
                while !Task.isCancelled && self.isResolving {
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                    } catch { break }

                    guard let host = self.targetURL?.host else { continue }
                    let baseHost = host.replacingOccurrences(of: "www.", with: "")

                    let cookies = await self.fetchCookies()
                    if cookies.contains(where: { $0.name == self.clearanceCookieName && $0.domain.contains(baseHost) }) {
                        print("[CloudflareManager] Polled and found cf_clearance cookie! Domain: \(baseHost)")
                        self.extractClearanceAndComplete()
                        break
                    }
                }
            }
        }
    }

    private func fetchCookies() async -> [HTTPCookie] {
        return await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private func setupAndLoadWebView(with url: URL) {
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = WKWebsiteDataStore.default()
            config.preferences.javaScriptCanOpenWindowsAutomatically = false

            let prefs = WKWebpagePreferences()
            prefs.allowsContentJavaScript = true
            config.defaultWebpagePreferences = prefs

            // Inject anti-bot evasion techniques and Turnstile auto-clicker
            let evasionJS = """
            Object.defineProperty(navigator, 'webdriver', { get: () => false });
            Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3] });

            // Auto-click Turnstile logic
            var interval = setInterval(function() {
                var btn = document.querySelector('input[type="checkbox"]') ||
                          document.querySelector('#challenge-stage') ||
                          document.querySelector('#cf-stage') ||
                          document.querySelector('.ctp-checkbox-label');
                if (btn) {
                    btn.click();
                    clearInterval(interval);
                }
            }, 500);
            setTimeout(function() { clearInterval(interval); }, 10000);
            """

            let script = WKUserScript(source: evasionJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
            config.userContentController.addUserScript(script)

            let wv = WKWebView(frame: UIScreen.main.bounds, configuration: config)
            wv.navigationDelegate = self
            wv.alpha = 0.01
            wv.isUserInteractionEnabled = false

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                window.insertSubview(wv, at: 0)
            }

            self.webView = wv
        }

        let request = URLRequest(url: url)
        webView?.load(request)
    }

    private func presentInteractiveWebView() {
        guard let wv = webView else { return }
        wv.alpha = 1.0
        wv.isUserInteractionEnabled = true
        wv.backgroundColor = .systemBackground

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            wv.frame = window.bounds
            window.bringSubviewToFront(wv)
        }
    }

    private func extractClearanceAndComplete() {
        guard let wv = webView, let host = targetURL?.host else {
            finish(with: URLError(.badURL))
            return
        }

        wv.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            guard let self = self else { return }

            let userAgent = (result as? String) ?? wv.customUserAgent ?? ""
            self.cachedUserAgents[host] = userAgent

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                let baseHost = host.replacingOccurrences(of: "www.", with: "")
                let domainCookies = cookies.filter { $0.domain.contains(baseHost) }
                self.finish(with: (userAgent, domainCookies))
            }
        }
    }

    private func cleanupWebView() {
        webView?.removeFromSuperview()
        webView = nil
    }

    private func finish(with result: (String, [HTTPCookie])) {
        guard isResolving else { return }
        isResolving = false
        timeoutTask?.cancel()
        pollingTask?.cancel()

        cleanupWebView()

        resolveContinuation?.resume(returning: result)
        resolveContinuation = nil
        targetURL = nil
    }

    private func finish(with error: Error) {
        guard isResolving else { return }
        isResolving = false
        timeoutTask?.cancel()
        pollingTask?.cancel()

        cleanupWebView()

        resolveContinuation?.resume(throwing: error)
        resolveContinuation = nil
        targetURL = nil
    }
}

extension CloudflareManager: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Polling and injected scripts handle the solving
        print("[CloudflareManager] didFinish navigation.")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        print("[CloudflareManager] didFail navigation: \(error.localizedDescription)")
        finish(with: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        print("[CloudflareManager] didFailProvisionalNavigation: \(error.localizedDescription)")
        finish(with: error)
    }
}
