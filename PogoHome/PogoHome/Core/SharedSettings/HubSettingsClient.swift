import Foundation
import Security

/// Why a shared-settings request didn't give a usable answer.
nonisolated enum HubSettingsError: Error, Equatable, Sendable {
    /// Someone saved first; `current` is the hub's settings now.
    case conflict(current: HubSettingsState)
    /// The token is unknown to the hub (revoked, or the hub's device list was reset).
    case unauthorized
    /// The hub presented a certificate other than the one pinned at pairing. Nothing was sent.
    case certificateMismatch
    /// The hub's settings (or its device list) can't be used right now: `reason` is `corrupt`, `io`,
    /// `startup`, … (`503`).
    case unavailable(reason: String)
    /// The hub could not store the change; nothing changed on the hub (`500`).
    case saveFailed
    /// The hub refused the request's content (`400`/`413`/`422`); `detail` is its code.
    case invalid(detail: String)
    /// Pairing refused: `no_active_code`, `expired` or `bad_proof`.
    case pairingRejected(reason: String)
    case tooManyDevices
    /// The hub answered as a different hub, or its pairing answer did not prove it knows the code.
    case hubIdentityMismatch
    /// This hub has no settings API (an older bridge, or sharing turned off there).
    case notSupported
    /// No answer (hub off, network down, timeout) or an unusable one.
    case unreachable(String)
}

/// The network side of settings sharing. Separate from `URLSession` so tests can script it.
nonisolated protocol HubSettingsTransport: Sendable {
    func fetchSettings(baseURL: URL, credential: HubCredential) async throws -> HubSettingsState
    /// `baseRevision` `nil` is the first upload.
    func putSettings(baseURL: URL, credential: HubCredential, baseRevision: String?, settings: HubSettingsDocument) async throws -> HubSettingsState
    func pair(baseURL: URL, hubID: String, code: String, deviceName: String) async throws -> HubCredential
    func unpair(baseURL: URL, credential: HubCredential) async throws
}

/// The real transport: HTTPS to the hub's API port (the same port as the sensor API — the hub tells
/// TLS from plain HTTP by the first byte).
///
/// Certificate trust is decided per request, never globally: after pairing, a request succeeds only
/// if the hub's leaf certificate hashes to the pinned SHA-256 (`PinnedCertificateDelegate`). During
/// pairing the hub's self-signed certificate is recorded (not trusted by itself) and bound into the
/// proof; the token is kept only when the hub's own proof checks out (`HubPairingProof`).
nonisolated struct URLSessionHubSettingsTransport: HubSettingsTransport {
    var timeout: TimeInterval = 10

    func fetchSettings(baseURL: URL, credential: HubCredential) async throws -> HubSettingsState {
        let request = try makeRequest(baseURL: baseURL, path: "api/v1/settings", method: "GET", token: credential.token)
        let (data, status) = try await send(request, pinning: credential.certificateSHA256)
        return try Self.decodeState(data: data, status: status, hubID: credential.hubID)
    }

    func putSettings(baseURL: URL, credential: HubCredential, baseRevision: String?, settings: HubSettingsDocument) async throws -> HubSettingsState {
        var request = try makeRequest(baseURL: baseURL, path: "api/v1/settings", method: "PUT", token: credential.token)
        request.httpBody = try JSONEncoder().encode(PutBody(baseRevision: baseRevision, settings: settings))
        let (data, status) = try await send(request, pinning: credential.certificateSHA256)
        return try Self.decodeState(data: data, status: status, hubID: credential.hubID)
    }

    func unpair(baseURL: URL, credential: HubCredential) async throws {
        let request = try makeRequest(baseURL: baseURL, path: "api/v1/devices/self", method: "DELETE", token: credential.token)
        let (data, status) = try await send(request, pinning: credential.certificateSHA256)
        guard status == 200 else { throw Self.error(status: status, data: data) }
    }

    func pair(baseURL: URL, hubID: String, code: String, deviceName: String) async throws -> HubCredential {
        let nonce = HubPairingProof.makeNonce()
        let recorder = PairingCertificateRecorder()
        let session = URLSession(configuration: Self.sessionConfiguration(timeout: timeout), delegate: recorder, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // The proof needs the certificate this connection presents, so the TLS handshake happens first
        // (an authenticated-nothing health request), then the claim goes over that same session.
        let probe = try makeRequest(baseURL: baseURL, path: "api/v1/health", method: "GET", token: nil)
        let (_, probeStatus) = try await Self.perform(probe, session: session)
        guard probeStatus == 200, let certificate = recorder.onlyCertificate else {
            throw HubSettingsError.unreachable("TLS")
        }

        var claim = try makeRequest(baseURL: baseURL, path: "api/v1/pairing/claim", method: "POST", token: nil)
        claim.httpBody = try JSONEncoder().encode(ClaimBody(
            deviceName: deviceName,
            clientNonce: nonce,
            proof: HubPairingProof.client(code: code, hubID: hubID, certificateSHA256: certificate, clientNonce: nonce, deviceName: deviceName)
        ))
        let (data, status) = try await Self.perform(claim, session: session)
        guard status == 200 else { throw Self.error(status: status, data: data) }
        // Every connection of this session must have shown the same certificate the proof covered.
        guard recorder.onlyCertificate == certificate else { throw HubSettingsError.hubIdentityMismatch }
        guard let reply = try? JSONDecoder().decode(ClaimReply.self, from: data) else {
            throw HubSettingsError.unreachable("pairing reply")
        }
        let expected = HubPairingProof.server(code: code, hubID: hubID, certificateSHA256: certificate, clientNonce: nonce, deviceID: reply.deviceID, token: reply.token)
        guard reply.hubID.lowercased() == hubID.lowercased(),
              HubPairingProof.constantTimeEquals(expected, reply.serverProof) else {
            throw HubSettingsError.hubIdentityMismatch
        }
        return HubCredential(hubID: hubID.lowercased(), deviceID: reply.deviceID, token: reply.token, certificateSHA256: certificate, pairedAt: Date())
    }

    // MARK: - Requests

    /// `https://<the hub's host and port>/<path>` — the hub's address is `http://…`, the settings API
    /// is TLS on the same port.
    private func makeRequest(baseURL: URL, path: String, method: String, token: String?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false), components.host != nil else {
            throw HubSettingsError.unreachable("URL")
        }
        components.scheme = "https"
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + path
        components.query = nil
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

    private func send(_ request: URLRequest, pinning expected: String) async throws -> (Data, Int) {
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

    private static func perform(_ request: URLRequest, session: URLSession) async throws -> (Data, Int) {
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

    private static func sessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return configuration
    }

    // MARK: - Responses

    static func decodeState(data: Data, status: Int, hubID: String) throws -> HubSettingsState {
        guard status == 200 else { throw error(status: status, data: data) }
        guard let state = try? JSONDecoder().decode(HubSettingsState.self, from: data) else {
            throw HubSettingsError.unreachable("settings reply")
        }
        guard state.schemaVersion == 1 else { throw HubSettingsError.notSupported }
        guard state.hubID.lowercased() == hubID.lowercased() else { throw HubSettingsError.hubIdentityMismatch }
        return state
    }

    static func error(status: Int, data: Data) -> HubSettingsError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch status {
        case 401:
            return .unauthorized
        case 403:
            if body?.error == "pairing_rejected" { return .pairingRejected(reason: body?.reason ?? "") }
            return .unreachable("HTTP 403")
        case 404:
            return .notSupported
        case 409:
            if body?.error == "too_many_devices" { return .tooManyDevices }
            if let current = body?.current { return .conflict(current: current) }
            return .unreachable("HTTP 409")
        case 400, 411, 413, 422:
            return .invalid(detail: body?.detail ?? body?.error ?? "HTTP \(status)")
        case 500:
            return .saveFailed
        case 503:
            return .unavailable(reason: body?.reason ?? body?.error ?? "unavailable")
        default:
            return .unreachable("HTTP \(status)")
        }
    }

    private struct PutBody: Encodable {
        let baseRevision: String?
        let settings: HubSettingsDocument

        enum CodingKeys: String, CodingKey {
            case baseRevision = "base_revision"
            case settings
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(baseRevision, forKey: .baseRevision)
            try container.encode(settings, forKey: .settings)
        }
    }

    private struct ClaimBody: Encodable {
        let deviceName: String
        let clientNonce: String
        let proof: String

        enum CodingKeys: String, CodingKey {
            case deviceName = "device_name"
            case clientNonce = "client_nonce"
            case proof
        }
    }

    private struct ClaimReply: Decodable {
        let hubID: String
        let deviceID: String
        let token: String
        let serverProof: String

        enum CodingKeys: String, CodingKey {
            case hubID = "hub_id"
            case deviceID = "device_id"
            case token
            case serverProof = "server_proof"
        }
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let reason: String?
        let detail: String?
        let current: HubSettingsState?
    }
}

/// Trusts a server only when its leaf certificate hashes to the SHA-256 pinned at pairing. Used by
/// exactly one short-lived session; nothing else in the app is affected.
nonisolated final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expectedSHA256: String
    private let lock = NSLock()
    private var mismatch = false

    init(expectedSHA256: String) {
        self.expectedSHA256 = expectedSHA256.lowercased()
    }

    var sawMismatch: Bool { lock.withLock { mismatch } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let leaf = HubCertificate.leaf(of: trust),
              HubCertificate.sha256Hex(of: leaf) == expectedSHA256 else {
            lock.withLock { mismatch = true }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// Pairing only: records the certificate each connection presents, so the proof can be bound to it.
/// The certificate is not trusted because of this — the exchange fails unless the hub's answer
/// proves knowledge of the code over this very certificate.
nonisolated final class PairingCertificateRecorder: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    /// The certificate hash, if every connection so far presented the same one.
    var onlyCertificate: String? {
        lock.withLock { Set(seen).count == 1 ? seen.first : nil }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            return (.performDefaultHandling, nil)
        }
        guard let trust = challenge.protectionSpace.serverTrust, let leaf = HubCertificate.leaf(of: trust) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let hash = HubCertificate.sha256Hex(of: leaf)
        lock.withLock { seen.append(hash) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
