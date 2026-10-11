import Foundation

/// The network side of Power Base removal. Separate from `URLSession` so tests can script it.
///
/// Every call takes this device's credential for the hub: its bearer token goes only into the
/// `Authorization` header, and the request goes only to a server presenting the certificate
/// pinned at pairing (`PinnedHubHTTPS`) -- the same rules as settings sharing and enrollment.
nonisolated protocol PowerBaseRemovalTransport: Sendable {
    /// `POST /api/v1/power-base-removals` → `202` (new job) or `200` (the job this request
    /// created before, or the removal of that registration that is under way already).
    ///
    /// The request names the registration the user confirmed and that registration's removal
    /// serial (`binding`), and carries an id of its own (`requestID`). **Safe to repeat exactly
    /// as it is**: the hub carries it out only for that registration and at most once, so the same
    /// request again is answered with its job or refused (`staleRecord`) -- it never removes a
    /// registration that came after. A new confirmation by the user is a new `requestID`.
    func request(
        baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, binding: PowerBaseRemovalBinding, requestID: String
    ) async throws -> PowerBaseRemoval
    /// `GET /api/v1/power-base-removals` → every job the hub still lists.
    func list(baseURL: URL, credential: HubCredential) async throws -> [PowerBaseRemoval]
    /// `DELETE /api/v1/power-base-removals/<id>` → `200` + job (`cancelled`). Only a job whose
    /// command was never given to the board can be cancelled; otherwise `.notCancellable`.
    func cancel(baseURL: URL, credential: HubCredential, removalID: String) async throws -> PowerBaseRemoval
    /// `POST /api/v1/power-base-removals/receipt` → `200` + the job, completed. `receiptHex` is the
    /// board's release receipt (192 lower-case hex digits) exactly as it was read from the board.
    /// Safe to repeat: the same receipt is the same answer.
    func submitReceipt(baseURL: URL, credential: HubCredential, receiptHex: String) async throws -> PowerBaseRemoval
    /// `POST /api/v1/power-base-forgets` → `201` (carried out) or `200` (the same request again):
    /// the hub took the offline Base out of its list. Not a removal; errors are
    /// `PowerBaseForgetError`. Safe to repeat with the same `requestID`.
    func forget(baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, record: String, requestID: String) async throws -> PowerBaseForget
}

extension PowerBaseRemovalTransport {
    /// A transport that knows nothing of list removals carries none out.
    func forget(baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, record: String, requestID: String) async throws -> PowerBaseForget {
        throw PowerBaseForgetError.notSupported
    }

    /// A transport that knows nothing of receipts relays none.
    func submitReceipt(baseURL: URL, credential: HubCredential, receiptHex: String) async throws -> PowerBaseRemoval {
        throw PowerBaseRemovalError.notSupported
    }
}

/// The real transport: pinned HTTPS to the paired hub's API port.
nonisolated struct URLSessionPowerBaseRemovalTransport: PowerBaseRemovalTransport {
    static let collectionPath = "api/v1/power-base-removals"

    var https = PinnedHubHTTPS(timeout: 10)

    func request(
        baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, binding: PowerBaseRemovalBinding, requestID: String
    ) async throws -> PowerBaseRemoval {
        // Checked here too, so a malformed value never leaves the device.
        guard Self.isValidPowerBaseIdentifier(powerBaseIdentifier) else { throw PowerBaseRemovalError.rejected("invalid_power_base_uuid") }
        guard binding.isValid else { throw PowerBaseRemovalError.rejected("invalid_record") }
        guard PowerBaseRemovalID.isValid(requestID) else { throw PowerBaseRemovalError.rejected("invalid_request_id") }
        var request = try makeRequest(baseURL: baseURL, path: Self.collectionPath, method: "POST", credential: credential)
        request.httpBody = try Self.requestBody(powerBaseIdentifier: powerBaseIdentifier, binding: binding, requestID: requestID)
        let (data, status) = try await send(request, credential: credential)
        guard status == 202 || status == 200 else { throw Self.error(status: status, data: data) }
        let removal = try Self.decodeRemoval(data)
        guard removal.powerBaseIdentifier == powerBaseIdentifier else { throw PowerBaseRemovalError.badResponse("power_base_uuid") }
        return removal
    }

    func list(baseURL: URL, credential: HubCredential) async throws -> [PowerBaseRemoval] {
        let request = try makeRequest(baseURL: baseURL, path: Self.collectionPath, method: "GET", credential: credential)
        let (data, status) = try await send(request, credential: credential)
        guard status == 200 else { throw Self.error(status: status, data: data) }
        guard let body = try? JSONDecoder().decode(ListBody.self, from: data) else { throw PowerBaseRemovalError.badResponse("removals") }
        // A job this app cannot read (a state from a newer hub) is left out, not guessed at.
        return body.removals.compactMap(\.removal)
    }

    func cancel(baseURL: URL, credential: HubCredential, removalID: String) async throws -> PowerBaseRemoval {
        guard PowerBaseRemovalID.isValid(removalID) else { throw PowerBaseRemovalError.badResponse("removal_id") }
        let request = try makeRequest(baseURL: baseURL, path: Self.collectionPath + "/" + removalID, method: "DELETE", credential: credential)
        let (data, status) = try await send(request, credential: credential)
        guard status == 200 else { throw Self.error(status: status, data: data) }
        let removal = try Self.decodeRemoval(data)
        guard removal.id == removalID, removal.state == .cancelled else { throw PowerBaseRemovalError.badResponse("cancel reply") }
        return removal
    }

    func submitReceipt(baseURL: URL, credential: HubCredential, receiptHex: String) async throws -> PowerBaseRemoval {
        // Checked here too, so nothing but a receipt-shaped value leaves the device.
        guard Self.isValidReceiptHex(receiptHex) else { throw PowerBaseRemovalError.rejected("invalid_receipt") }
        var request = try makeRequest(baseURL: baseURL, path: Self.collectionPath + "/receipt", method: "POST", credential: credential)
        request.httpBody = try Self.receiptBody(receiptHex: receiptHex)
        let (data, status) = try await send(request, credential: credential)
        guard status == 200 else { throw Self.error(status: status, data: data) }
        let removal = try Self.decodeRemoval(data)
        // The hub answers with the job the receipt completed, and with nothing else.
        guard removal.state == .completed else { throw PowerBaseRemovalError.badResponse("receipt reply") }
        return removal
    }

    func forget(baseURL: URL, credential: HubCredential, powerBaseIdentifier: String, record: String, requestID: String) async throws -> PowerBaseForget {
        // Checked here too, so nothing malformed leaves the device.
        guard Self.isValidPowerBaseIdentifier(powerBaseIdentifier) else { throw PowerBaseForgetError.rejected("invalid_power_base_uuid") }
        guard PowerBaseRemovalID.isValid(record) else { throw PowerBaseForgetError.rejected("invalid_record") }
        guard PowerBaseRemovalID.isValid(requestID) else { throw PowerBaseForgetError.rejected("invalid_request_id") }
        var request: URLRequest
        do {
            request = try https.makeRequest(baseURL: baseURL, path: Self.forgetCollectionPath, method: "POST", token: credential.token)
        } catch {
            throw PowerBaseForgetError.unreachable("URL")
        }
        request.httpBody = try Self.forgetBody(powerBaseIdentifier: powerBaseIdentifier, record: record, requestID: requestID)
        let data: Data
        let status: Int
        do {
            (data, status) = try await https.send(request, pinning: credential.certificateSHA256)
        } catch HubSettingsError.certificateMismatch {
            throw PowerBaseForgetError.certificateMismatch
        } catch let HubSettingsError.unreachable(detail) {
            throw PowerBaseForgetError.unreachable(detail)
        } catch {
            throw PowerBaseForgetError.unreachable("HTTP")
        }
        guard status == 201 || status == 200 else { throw Self.forgetError(status: status, data: data) }
        guard let forget = (try? JSONDecoder().decode(PowerBaseForgetDTO.self, from: data))?.forget else {
            throw PowerBaseForgetError.badResponse("forget")
        }
        // The hub answers with the record of this very request, and with nothing else.
        guard forget.powerBaseIdentifier == powerBaseIdentifier, forget.requestID == requestID else {
            throw PowerBaseForgetError.badResponse("forget reply")
        }
        return forget
    }

    // MARK: - Requests

    static let forgetCollectionPath = "api/v1/power-base-forgets"

    /// Exactly `{"power_base_uuid":"…","record":"…","request_id":"…"}`.
    static func forgetBody(powerBaseIdentifier: String, record: String, requestID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ForgetBody(power_base_uuid: powerBaseIdentifier, record: record, request_id: requestID))
    }

    /// The documented error answers of the forget routes. Anything else is `.badResponse`.
    static func forgetError(status: Int, data: Data) -> PowerBaseForgetError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(code ?? "HTTP 403")
        case 404:
            // Only the hub's own word means "not listed"; any other 404 is a hub without the routes.
            return code == "unknown_power_base" ? .notListed : .notSupported
        case 405:
            return .notSupported
        case 409:
            switch code {
            case "power_base_online": return .online
            case "stale_record": return .staleRecord
            case "enrollment_in_progress": return .enrollmentInProgress
            case "request_id_conflict": return .requestConflict
            case "forget_capacity_full": return .capacityFull
            default: return .badResponse("HTTP 409")
            }
        case 400, 411, 413, 422:
            return .rejected(code ?? "HTTP \(status)")
        case 503:
            return .unavailable(body?.reason ?? code ?? "unavailable")
        default:
            return .badResponse("HTTP \(status)")
        }
    }

    static func isValidReceiptHex(_ value: String) -> Bool {
        value.unicodeScalars.count == 192 && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Exactly `{"receipt":"…"}`.
    static func receiptBody(receiptHex: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ReceiptBody(receipt: receiptHex))
    }

    static func isValidPowerBaseIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.count == 16 && value != String(repeating: "0", count: 16)
            && value.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Exactly `{"power_base_uuid":"…","record":"…","removal_serial":…,"request_id":"…"}`: the
    /// Base, the registration the user confirmed, how many removals had been asked of it then,
    /// and the id of this confirmation. There is no request that names the Base alone.
    static func requestBody(powerBaseIdentifier: String, binding: PowerBaseRemovalBinding, requestID: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(RequestBody(
            power_base_uuid: powerBaseIdentifier, record: binding.record, removal_serial: binding.serial, request_id: requestID
        ))
    }

    private func makeRequest(baseURL: URL, path: String, method: String, credential: HubCredential) throws -> URLRequest {
        do {
            return try https.makeRequest(baseURL: baseURL, path: path, method: method, token: credential.token)
        } catch {
            throw PowerBaseRemovalError.unreachable("URL")
        }
    }

    private func send(_ request: URLRequest, credential: HubCredential) async throws -> (Data, Int) {
        do {
            return try await https.send(request, pinning: credential.certificateSHA256)
        } catch HubSettingsError.certificateMismatch {
            throw PowerBaseRemovalError.certificateMismatch
        } catch let HubSettingsError.unreachable(detail) {
            throw PowerBaseRemovalError.unreachable(detail)
        } catch {
            throw PowerBaseRemovalError.unreachable("HTTP")
        }
    }

    // MARK: - Responses

    static func decodeRemoval(_ data: Data) throws -> PowerBaseRemoval {
        guard let removal = (try? JSONDecoder().decode(PowerBaseRemovalDTO.self, from: data))?.removal else {
            throw PowerBaseRemovalError.badResponse("removal")
        }
        return removal
    }

    /// The documented error answers. Anything else is `.badResponse`, never a guess.
    static func error(status: Int, data: Data) -> PowerBaseRemovalError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        let code = body?.error
        switch status {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden(code ?? "HTTP 403")
        case 404:
            switch code {
            case "unknown_power_base": return .unknownPowerBase
            case "removal_not_found": return .removalNotFound
            default: return .notSupported
            }
        case 405:
            return .notSupported
        case 409:
            switch code {
            case "power_base_management_unsupported": return .managementUnsupported
            case "enrollment_in_progress": return .enrollmentInProgress
            case "removal_not_cancellable": return .notCancellable(body?.removal?.removal)
            case "removal_capacity_full": return .capacityFull
            case "receipt_rejected": return .receiptRejected
            case "stale_record": return .staleRecord
            // A refusal, not a missing answer: the id is in use for another Base.
            case "request_id_conflict": return .rejected("request_id_conflict")
            default: return .badResponse("HTTP 409")
            }
        case 400, 411, 413, 422:
            return .rejected(code ?? "HTTP \(status)")
        case 503:
            return .unavailable(code == "too_many_removals" ? "too_many_removals" : (body?.reason ?? code ?? "unavailable"))
        default:
            return .badResponse("HTTP \(status)")
        }
    }

    private struct RequestBody: Encodable {
        let power_base_uuid: String
        let record: String
        let removal_serial: Int
        let request_id: String
    }

    private struct ReceiptBody: Encodable {
        let receipt: String
    }

    private struct ForgetBody: Encodable {
        let power_base_uuid: String
        let record: String
        let request_id: String
    }

    private struct ListBody: Decodable {
        let removals: [PowerBaseRemovalDTO]
    }

    private struct ErrorBody: Decodable {
        let error: String?
        let reason: String?
        let removal: PowerBaseRemovalDTO?

        enum CodingKeys: String, CodingKey {
            case error, reason, removal
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
            reason = try? container.decodeIfPresent(String.self, forKey: .reason)
            removal = try? container.decodeIfPresent(PowerBaseRemovalDTO.self, forKey: .removal)
        }
    }
}
