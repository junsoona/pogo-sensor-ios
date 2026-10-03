import Foundation

/// HTTPS to a paired hub's API port with the certificate pinned at pairing — the one way the app
/// sends a bearer token anywhere. Shared by settings sharing (`URLSessionHubSettingsTransport`) and
/// the DEBUG Power Base enrollment test, so both trust exactly the same thing.
///
/// Trust is decided per request, never globally: every request gets its own short-lived
/// `URLSession` whose delegate accepts the hub only when its leaf certificate hashes to the pinned
/// SHA-256 (`PinnedCertificateDelegate`). A mismatch cancels the TLS handshake, so no header or body
/// reaches that server. Redirects are refused.
nonisolated struct PinnedHubHTTPS: Sendable {
    var timeout: TimeInterval = 10

    /// `https://<the hub's host and port>/<path>` — the hub's address is `http://…`, the
    /// authenticated routes are TLS on the same port.
    func makeRequest(baseURL: URL, path: String, method: String, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), components.host != nil else {
            throw HubSettingsError.unreachable("URL")
        }
        components.scheme = "https"
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + path
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        guard let url = components.url else { throw HubSettingsError.unreachable("URL") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "PUT" || method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Sends `request` only to a server presenting the certificate with SHA-256 `expected`.
    /// Throws `HubSettingsError.certificateMismatch` when it presented another one (nothing was
    /// sent), `.unreachable` for no usable answer.
    func send(_ request: URLRequest, pinning expected: String) async throws -> (Data, Int) {
        let delegate = PinnedCertificateDelegate(expectedSHA256: expected)
        let session = URLSession(configuration: Self.sessionConfiguration(timeout: timeout), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            return try await Self.perform(request, session: session)
        } catch {
            if delegate.sawMismatch { throw HubSettingsError.certificateMismatch }
            throw error
        }
    }

    static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw HubSettingsError.unreachable("HTTP") }
            return (data, http.statusCode)
        } catch let error as HubSettingsError {
            throw error
        } catch let error as URLError {
            throw HubSettingsError.unreachable(error.code == .timedOut ? "timeout" : "\(error.code.rawValue)")
        } catch {
            throw HubSettingsError.unreachable(String(describing: error))
        }
    }

    static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }
}
