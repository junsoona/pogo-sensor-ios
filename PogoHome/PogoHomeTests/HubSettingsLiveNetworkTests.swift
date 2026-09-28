import XCTest
@testable import PogoHome

/// The real `URLSessionHubSettingsTransport` against a real hub (the Linux `pogohome_api::Server`):
/// TLS on the API port, the pairing proofs, certificate pinning, tokens, revisions and conflicts.
/// Skipped unless a hub and a fresh pairing code are given (set as environment variables of the
/// `xcodebuild` process):
///
///     TEST_RUNNER_POGO_SETTINGS_E2E_URL=http://127.0.0.1:18787
///     TEST_RUNNER_POGO_SETTINGS_E2E_HUB_ID=<hub_id>
///     TEST_RUNNER_POGO_SETTINGS_E2E_CODE=<code from `pogohome-hubctl pair`>
///     TEST_RUNNER_POGO_SETTINGS_E2E_FP=<`pogohome-hubctl fingerprint`>
///
/// The hub must have no shared settings yet; the test uploads some.
final class HubSettingsLiveNetworkTests: XCTestCase {
    func testPairUploadConflictPinAndRevokeAgainstARealHub() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let urlString = env["POGO_SETTINGS_E2E_URL"], let baseURL = URL(string: urlString),
              let hubID = env["POGO_SETTINGS_E2E_HUB_ID"], let code = env["POGO_SETTINGS_E2E_CODE"],
              let fingerprint = env["POGO_SETTINGS_E2E_FP"] else {
            throw XCTSkip("set TEST_RUNNER_POGO_SETTINGS_E2E_URL/_HUB_ID/_CODE/_FP to run against a real hub")
        }
        let transport = URLSessionHubSettingsTransport()

        // A wrong code is refused and nothing is issued.
        do {
            _ = try await transport.pair(baseURL: baseURL, hubID: hubID, code: "000000000000", deviceName: "E2E")
            XCTFail("a wrong code must not pair")
        } catch let error as HubSettingsError {
            XCTAssertEqual(error, .pairingRejected(reason: "bad_proof"))
        }

        let normalized = try XCTUnwrap(HubPairingCode.normalized(code))
        let credential = try await transport.pair(baseURL: baseURL, hubID: hubID, code: normalized, deviceName: "E2E iPhone")
        XCTAssertEqual(credential.certificateSHA256, fingerprint, "the pinned certificate is the hub's")

        let empty = try await transport.fetchSettings(baseURL: baseURL, credential: credential)
        XCTAssertFalse(empty.initialized)

        let room = HubRoomSetting(id: UUID(), nameKind: .custom, name: "E2E 거실 🛋", suggestionSymbol: nil, suggestionOrdinal: nil, symbol: "sofa.fill")
        let first = HubSettingsDocument(homeName: "E2E 집", rooms: [room], modules: [HubModuleSetting(uuid: "744dbdfffe65d357", name: "공기", roomID: room.id)])
        let created = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: nil, settings: first)
        XCTAssertEqual(created.settings, first, "the hub stores exactly what was sent")
        let revision1 = try XCTUnwrap(created.revision)

        var second = first
        second.homeName = "E2E 집 2"
        let updated = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: revision1, settings: second)
        XCTAssertNotEqual(updated.revision, revision1)

        do {
            _ = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: revision1, settings: first)
            XCTFail("a stale revision must conflict")
        } catch let HubSettingsError.conflict(current) {
            XCTAssertEqual(current.settings?.homeName, "E2E 집 2")
        }

        do {
            var bad = second
            bad.modules = [HubModuleSetting(uuid: "744dbdfffe65d357", name: nil, roomID: UUID())]
            _ = try await transport.putSettings(baseURL: baseURL, credential: credential, baseRevision: updated.revision, settings: bad)
            XCTFail("an unknown room must be rejected")
        } catch let error as HubSettingsError {
            XCTAssertEqual(error, .invalid(detail: "unknown_room_id"))
        }

        let wrongPin = HubCredential(hubID: hubID, deviceID: credential.deviceID, token: credential.token, certificateSHA256: String(repeating: "0", count: 64), pairedAt: Date())
        do {
            _ = try await transport.fetchSettings(baseURL: baseURL, credential: wrongPin)
            XCTFail("another certificate pin must fail before anything is sent")
        } catch let error as HubSettingsError {
            XCTAssertEqual(error, .certificateMismatch)
        }

        try await transport.unpair(baseURL: baseURL, credential: credential)
        do {
            _ = try await transport.fetchSettings(baseURL: baseURL, credential: credential)
            XCTFail("a removed device must be refused")
        } catch let error as HubSettingsError {
            XCTAssertEqual(error, .unauthorized)
        }
    }
}
