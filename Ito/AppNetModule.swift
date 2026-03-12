import Foundation
import WebKit
import ito_runner

actor AppNetModule: NetModule {
    func fetch(request: NetRequest) async throws -> NetResponse {
        return try await fetchInternal(request: request, isRetry: false)
    }

    private func fetchInternal(request: NetRequest, isRetry: Bool) async throws -> NetResponse {
        guard let url = URL(string: request.url) else {
            throw URLError(.badURL)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false

        var updatedHeaders = request.headers
        
        // Always apply the cached User-Agent for this host if we have one
        if let host = url.host {
            let cachedUA = await MainActor.run {
                CloudflareManager.shared.getCachedUserAgent(for: host)
            }
            if let ua = cachedUA {
                updatedHeaders["User-Agent"] = ua
            }
        }

        for (key, value) in updatedHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = Data(body)
        }

        let session = URLSession.shared

        if isRetry {
            print("[AppNetModule] --- RETRY REQUEST INFO ---")
            print("[AppNetModule] URL: \(urlRequest.url?.absoluteString ?? "")")
            print("[AppNetModule] Method: \(urlRequest.httpMethod ?? "")")
            print("[AppNetModule] Headers: \(urlRequest.allHTTPHeaderFields ?? [:])")
            print("[AppNetModule] -------------------------")
        }

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // --- Cloudflare Bypass Interception ---
        let statusCode = httpResponse.statusCode
        if !isRetry && (statusCode == 403 || statusCode == 503) {
            let isCloudflare = httpResponse.allHeaderFields.contains { key, value in
                let keyStr = String(describing: key).lowercased()
                let valStr = String(describing: value).lowercased()
                return (keyStr == "server" && valStr.contains("cloudflare")) || keyStr == "cf-ray"
            }

            if isCloudflare {
                print("[AppNetModule] Detected Cloudflare challenge for \(url.host ?? ""). Attempting bypass...")

                // Route to CloudflareManager (which relies on MainActor)
                let bypassResult = try await CloudflareManager.shared.resolveChallenge(for: url)

                var retriedRequest = request
                var retriedHeaders = request.headers
                
                retriedHeaders["User-Agent"] = bypassResult.userAgent

                // Explicitly inject cookies into the request headers because HTTPCookieStorage drops subdomains
                var cookieStrings: [String] = []
                for cookie in bypassResult.cookies {
                    cookieStrings.append("\(cookie.name)=\(cookie.value)")
                }
                
                let cookieHeaderValue = cookieStrings.joined(separator: "; ")
                if !cookieHeaderValue.isEmpty {
                    retriedHeaders["Cookie"] = cookieHeaderValue
                }

                retriedRequest.headers = retriedHeaders

                print("[AppNetModule] Replaying request with Cloudflare clearance.")
                let retriedResponse = try await fetchInternal(request: retriedRequest, isRetry: true)
                print("[AppNetModule] Retry completed with status code: \(retriedResponse.status)")
                return retriedResponse
            }
        }
        // --------------------------------------

        var resHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            resHeaders[String(describing: key)] = String(describing: value)
        }

        return NetResponse(
            status: Int32(statusCode),
            headers: resHeaders,
            body: [UInt8](data)
        )
    }
}
