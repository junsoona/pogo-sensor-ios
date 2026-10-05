#if DEBUG
import Foundation

/// The network side of the enrollment test. Separate from `URLSession` so tests can script it.
///
/// Every call takes this device's credential for the hub: its bearer token goes only into the
/// `Authorization` header, and the request goes only to a server presenting the certificate
/// pinned at pairing (`PinnedHubHTTPS`).
nonisolated protocol PowerBaseEnrollmentTransport: Sendable {
    /// `POST /api/v1/power-base-enrollments` → `202` + session.
    func start(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession
    /// The same `POST` with `"bridge_endpoint_version": 1`: the hub also establishes its bridge
    /// endpoint and reports it with the session. A hub that does not know the option answers
    /// `.bridgeEndpointNotSupported`; nothing is started there.
    func startDeliveringBridgeEndpoint(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession
    /// `GET /api/v1/power-base-enrollments/<id>` → `200` + session.
    func status(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession
    /// `DELETE /api/v1/power-base-enrollments/<id>` → `200` + session (`cancelled`).
    func cancel(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession
}

/// The real transport: the same pinned HTTPS as settings sharing, to the same port.
nonisolated struct URLSessionPowerBaseEnrollmentTransport: PowerBaseEnrollmentTransport {
    static let collectionPath = "api/v1/power-base-enrollments"

    var https = PinnedHubHTTPS(timeout: 10)

    func start(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession {
        // Checked here too, so a malformed value never leaves the device.
        guard PowerBaseEUI64.normalized(eui64) == eui64 else { throw PowerBaseEnrollmentError.rejected("invalid_eui64") }
        guard ThreadPSKd.isValid(pskd) else { throw PowerBaseEnrollmentError.rejected("invalid_pskd") }
        var request = try makeRequest(baseURL: baseURL, path: Self.collectionPath, method: "POST", credential: credential)
        request.httpBody = try Self.startBody(eui64: eui64, pskd: pskd)
        let (data, status) = try await send(request, credential: credential)
        guard status == 202 else { throw Self.error(status: status, data: data, deviceID: credential.deviceID) }
        let session = try Self.decodeSession(data, deviceID: credential.deviceID)
        guard session.eui64 == eui64 else { throw PowerBaseEnrollmentError.badResponse("eui64") }
        return session
    }

    func startDeliveringBridgeEndpoint(baseURL: URL, credential: HubCredential, eui64: String, pskd: String) async throws -> PowerBaseEnrollmentSession {
        guard PowerBaseEUI64.normalized(eui64) == eui64 else { throw PowerBaseEnrollmentError.rejected("invalid_eui64") }
        guard ThreadPSKd.isValid(pskd) else { throw PowerBaseEnrollmentError.rejected("invalid_pskd") }
        var request = try makeRequest(baseURL: baseURL, path: Self.collectionPath, method: "POST", credential: credential)
        request.httpBody = try Self.startBody(eui64: eui64, pskd: pskd, bridgeEndpointVersion: PowerBaseEnrollmentBridgeEndpoint.version)
        let (data, status) = try await send(request, credential: credential)
        guard status == 202 else { throw Self.bridgeEndpointStartError(status: status, data: data, deviceID: credential.deviceID) }
        let session = try Self.decodeSession(data, deviceID: credential.deviceID)
        guard session.eui64 == eui64 else { throw PowerBaseEnrollmentError.badResponse("eui64") }
        return session
    }

    func status(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        let request = try makeRequest(baseURL: baseURL, path: try Self.sessionPath(sessionID), method: "GET", credential: credential)
        let (data, status) = try await send(request, credential: credential)
        guard status == 200 else { throw Self.error(status: status, data: data, deviceID: credential.deviceID) }
        let session = try Self.decodeSession(data, deviceID: credential.deviceID)
        guard session.sessionID == sessionID else { throw PowerBaseEnrollmentError.badResponse("session_id") }
        return session
    }

    func cancel(baseURL: URL, credential: HubCredential, sessionID: String) async throws -> PowerBaseEnrollmentSession {
        let request = try makeRequest(baseURL: baseURL, path: try Self.sessionPath(sessionID), method: "DELETE", credential: credential)
        let (data, status) = try await send(request, credential: credential)
        guard status == 200 else { throw Self.error(status: status, data: data, deviceID: credential.deviceID) }
        let session = try Self.decodeSession(data, deviceID: credential.deviceID)
        guard session.sessionID == sessionID, session.state == .cancelled else {
            throw PowerBaseEnrollmentError.badResponse("cancel reply")
        }
        return session
    }

    // MARK: - Requests

    /// Exactly `{"eui64":"…","pskd":"…"}`. Both values are plain ASCII from checked alphabets, so
    /// nothing needs escaping.
    static func startBody(eui64: String, pskd: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(StartBody(eui64: eui64, pskd: pskd))
    }

    /// Exactly `{"bridge_endpoint_version":1,"eui64":"…","pskd":"…"}`: the request that also asks
    /// the hub for its bridge endpoint. It carries no address and no port -- the hub makes both.
    static func startBody(eui64: String, pskd: String, bridgeEndpointVersion: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(BridgeEndpointStartBody(bridge_endpoint_version: bridgeEndpointVersion, eui64: eui64, pskd: pskd))
    }

    /// The error answers to the request with the option. A hub older than the option accepts
    /// exactly two fields and answers `400 invalid_request` -- this request is otherwise well
    /// formed (both values were checked before it left), so that answer means "not supported".
    static func bridgeEndpointStartError(status: Int, data: Data, deviceID: String) -> PowerBaseEnrollmentError {
        let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
        if status == 400, code == "invalid_request" { return .bridgeEndpointNotSupported }
        if status == 422, code == "unsupported_bridge_endpoint_version" { return .bridgeEndpointNotSupported }
        return error(status: status, data: data, deviceID: deviceID)
    }

    /// The session's own path. The id comes from the hub's answer and is checked before it is put
    /// into a URL.
    static func sessionPath(_ sessionID: String) throws -> String {
        guard PowerBaseEnrollmentSessionID.isValid(sessionID) else { throw PowerBaseEnrollmentError.badResponse("session_id") }
        return collectionPath + "/" + sessionID
    }

    private func makeRequest(baseURL: URL, path: String, method: String, credential: HubCredential) throws -> URLRequest {
        do {
            return try https.makeRequest(baseURL: baseURL, path: path, method: method, token: credential.token)
        } catch {
            throw PowerBaseEnrollmentError.unreachable("URL")
        }
    }

    private func send(_ request: URLRequest, credential: HubCredential) async throws -> (Data, Int) {
        do {
            return try await https.send(request, pinning: credential.certificateSHA256)
        } catch HubSettingsError.certificateMismatch {
            throw PowerBaseEnrollmentError.certificateMismatch
        } catch let HubSettingsError.unreachable(detail) {
            throw PowerBaseEnrollmentError.unreachable(detail)
        } catch {
            throw PowerBaseEnrollmentError.unreachable("HTTP")
        }
    }

    // MARK: - Responses

    /// A session of this device's (`started_by_device_id`), or `.badResponse`.
    static func decodeSession(_ data: Data, deviceID: String) throws -> PowerBaseEnrollmentSession {
        guard let session = try? JSONDecoder().decode(PowerBaseEnrollmentSession.self, from: data) else {
            throw PowerBaseEnrollmentError.badResponse("session")
        }
        guard session.startedByDeviceID == deviceID else { throw PowerBaseEnrollmentError.badResponse("started_by_device_id") }
        return session
    }

    /// The documented error answers. Anything else is `.badResponse`, never a guess.
    static func error(status: Int, data: Data, deviceID: String) -> PowerBaseEnrollmentError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(code ?? "HTTP 403")
        case 404:
            switch code {
            case "enrollment_disabled": return .enrollmentDisabled
            case "session_not_found": return .sessionNotFound
            default: return .notSupported
            }
        case 405:
            return .notSupported
        case 409:
            switch code {
            case "enrollment_in_progress":
                // The session is included only for the device that started it; check that anyway.
                let own = body?.session.flatMap { $0.startedByDeviceID == deviceID && !$0.state.isFinal ? $0 : nil }
                return .enrollmentInProgress(ownSession: own)
            case "power_base_already_connected":
                return .powerBaseAlreadyConnected
            case "session_already_final":
                guard let session = body?.session, session.state.isFinal, session.startedByDeviceID == deviceID else {
                    return .badResponse("HTTP 409")
                }
                return .sessionAlreadyFinal(session)
            default:
                return .badResponse("HTTP 409")
            }
        case 400, 411, 413, 422:
            return .rejected(code ?? "HTTP \(status)")
        case 500:
            return .internalError
        case 503:
            return .unavailable(body?.reason ?? code ?? "unavailable")
        default:
            return .badResponse("HTTP \(status)")
        }
    }

    private struct StartBody: Encodable {
        let eui64: String
        let pskd: String
    }

    private struct BridgeEndpointStartBody: Encodable {
        let bridge_endpoint_version: Int
        let eui64: String
        let pskd: String
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let reason: String?
        let session: PowerBaseEnrollmentSession?

        enum CodingKeys: String, CodingKey {
            case error, reason, session
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            // A malformed session is treated as absent, never as this device's session.
            session = try? container.decodeIfPresent(PowerBaseEnrollmentSession.self, forKey: .session)
        }
    }
}
#endif
