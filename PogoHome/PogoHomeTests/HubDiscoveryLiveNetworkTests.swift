import XCTest
@testable import PogoHome

/// The real Bonjour path — `NWBrowser`, `NWConnection` resolution and `/api/v1/health` over
/// URLSession — against a hub actually announced on this network. Skipped unless
/// `TEST_RUNNER_POGO_HUB_E2E_HUB_ID` names the `hub_id` to expect (set it on the `xcodebuild`
/// process, see the Bonjour section of the Linux repo's `docs/pogohome-api-v1.md`); a real hub, or
/// `dns-sd -R` plus a small HTTP server on a Mac, must be announcing it.
@MainActor
final class HubDiscoveryLiveNetworkTests: XCTestCase {
    func testFindsAndVerifiesTheAnnouncedHub() async throws {
        guard let hubID = ProcessInfo.processInfo.environment["POGO_HUB_E2E_HUB_ID"], !hubID.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POGO_HUB_E2E_HUB_ID to run against a real announced hub")
        }
        let model = HubDiscoveryModel(browser: NetworkHubBrowser(), verifier: .live())
        model.start()
        defer { model.stop() }

        try await waitUntil(timeout: 20) {
            model.hubs.contains { $0.hubID == hubID } || model.searchState != .searching
        }
        XCTAssertEqual(model.searchState, .searching, "browse state: \(model.searchState)")
        let hub = try XCTUnwrap(model.hubs.first { $0.hubID == hubID }, "found: \(model.hubs.map(\.serviceName))")
        print("=== found \(hub.serviceName) on \(hub.endpoints.count) endpoint(s); list: \(model.hubs.map { "\($0.serviceName) problem=\(String(describing: $0.problem))" })")

        let selection = await model.select(hub)
        let verified = try XCTUnwrap(selection, "check failed: \(model.verificationFailure?.message ?? "-")")
        print("=== verified \(verified.hubID) at \(verified.baseURL)")
        XCTAssertEqual(verified.hubID, hubID)
        XCTAssertNotNil(verified.usableBaseURL)
    }
}
