import Network
import XCTest
@testable import PogoHome

/// The rules applied to `_jogakbo._tcp` announcements and `/api/v1/health` answers before the app
/// trusts a hub. Pure logic with scripted inputs — not a real Bonjour search.
final class HubDiscoveryRulesTests: XCTestCase {
    typealias F = HubFixtures

    // MARK: - TXT record

    func testAnnouncementWithHubIDSupportedAPIAndPathIsUsable() {
        let ad = HubAdvertisement(txt: F.txt(hubID: F.hubA))
        XCTAssertEqual(ad.hubID, F.hubA)
        XCTAssertNil(ad.problem)
        XCTAssertNil(HubAdvertisement(txt: F.txt(hubID: F.hubA, path: "/api/v1/")).problem, "a trailing slash is the same path")
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: F.hubA.uppercased())).hubID, F.hubA, "hex case doesn't matter")
    }

    func testAnnouncementWithoutAValidHubIDIsNotUsable() {
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: nil)).problem, .missingHubID)
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: "192.168.50.129")).problem, .missingHubID, "an address is not an id")
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: "abc")).problem, .missingHubID)
    }

    func testUnsupportedAPIVersionOrPathIsNotUsable() {
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: F.hubA, api: "2")).problem, .unsupportedAPI(version: "2", path: "/api/v1"))
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: F.hubA, api: nil)).problem, .unsupportedAPI(version: nil, path: "/api/v1"))
        XCTAssertEqual(HubAdvertisement(txt: F.txt(hubID: F.hubA, path: "/v2")).problem, .unsupportedAPI(version: "1", path: "/v2"))
    }

    // MARK: - List

    func testNoResultsMakeAnEmptyList() {
        XCTAssertEqual(DiscoveredHub.merge([]), [])
    }

    func testSeveralHubsAreListedSortedByName() {
        let hubs = DiscoveredHub.merge([F.result("Jogakbo Hub (upstairs)", hubID: F.hubB), F.result("Jogakbo Hub (garage)", hubID: F.hubA)])
        XCTAssertEqual(hubs.map(\.serviceName), ["Jogakbo Hub (garage)", "Jogakbo Hub (upstairs)"])
        XCTAssertEqual(hubs.map(\.hubID), [F.hubA, F.hubB])
    }

    func testTheSameHubSeenOnTwoInterfacesIsOneRowWithBothEndpoints() {
        let hubs = DiscoveredHub.merge([
            F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "en0"),
            F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "en1"),
            F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "en0"),
        ])
        XCTAssertEqual(hubs.count, 1)
        XCTAssertEqual(hubs[0].endpoints.map(\.key), ["en0", "en1"])
    }

    func testTheSameHubUnderAnOldAndARenamedNameIsOneRow() {
        let hubs = DiscoveredHub.merge([F.result("Jogakbo Hub (pogo) #2", hubID: F.hubA), F.result("Jogakbo Hub (pogo)", hubID: F.hubA)])
        XCTAssertEqual(hubs.count, 1)
        XCTAssertEqual(hubs[0].id, "hub:" + F.hubA)
    }

    func testAnnouncementsWithoutHubIDStayApartAndAreMarked() {
        let hubs = DiscoveredHub.merge([F.result("Old Hub", hubID: nil), F.result("Other Old Hub", hubID: nil), F.result("Jogakbo Hub", hubID: F.hubA)])
        XCTAssertEqual(hubs.count, 3)
        XCTAssertEqual(hubs.filter { $0.problem == .missingHubID }.count, 2)
    }

    func testAServiceThatWentAwayIsNoLongerListed() {
        let before = DiscoveredHub.merge([F.result("A", hubID: F.hubA), F.result("B", hubID: F.hubB)])
        let after = DiscoveredHub.merge([F.result("B", hubID: F.hubB)])
        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(after.map(\.hubID), [F.hubB])
    }

    // MARK: - /api/v1/health

    func testHealthOfTheAnnouncedHubPasses() throws {
        XCTAssertEqual(try HubHealthCheck.verify(F.health(hubID: F.hubA), expectedHubID: F.hubA).hubID, F.hubA)
    }

    func testHealthFromAnotherHubIsRejected() {
        XCTAssertThrowsError(try HubHealthCheck.verify(F.health(hubID: F.hubB), expectedHubID: F.hubA)) {
            XCTAssertEqual($0 as? HubVerificationError, .hubIDMismatch(expected: F.hubA, answered: F.hubB))
        }
    }

    func testHealthOfAnotherServiceOrVersionOrWithoutHubIDIsRejected() {
        XCTAssertThrowsError(try HubHealthCheck.verify(F.health(hubID: F.hubA, service: "other"), expectedHubID: F.hubA)) {
            XCTAssertEqual($0 as? HubVerificationError, .notSensorAPI)
        }
        XCTAssertThrowsError(try HubHealthCheck.verify(F.health(hubID: F.hubA, schema: 2), expectedHubID: F.hubA)) {
            XCTAssertEqual($0 as? HubVerificationError, .unsupportedSchemaVersion(2))
        }
        XCTAssertThrowsError(try HubHealthCheck.verify(F.health(hubID: nil), expectedHubID: F.hubA)) {
            XCTAssertEqual($0 as? HubVerificationError, .missingHubID)
        }
        XCTAssertThrowsError(try HubHealthCheck.verify(Data("<html>".utf8), expectedHubID: F.hubA)) {
            XCTAssertEqual($0 as? HubVerificationError, .notSensorAPI)
        }
    }

    // MARK: - Verifier

    private func verifier(_ resolver: FakeHubResolver, _ transport: FakeHealthTransport) -> HubVerifier {
        HubVerifier(resolver: resolver, health: transport, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    func testVerifiedHubBecomesASelectionAtTheResolvedAddress() async throws {
        let resolver = FakeHubResolver(["en0": .success(F.urlA)])
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        let hub = DiscoveredHub.merge([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "en0")])[0]
        let selection = try await verifier(resolver, transport).verify(hub)
        XCTAssertEqual(selection.hubID, F.hubA)
        XCTAssertEqual(selection.baseURL, F.urlA.absoluteString)
        XCTAssertEqual(selection.serviceName, "Jogakbo Hub (pogo)")
        let fetched = await transport.fetchedURLs
        XCTAssertEqual(fetched.map(\.absoluteString), ["http://192.168.50.129:8787/api/v1/health"])
    }

    func testHubIDMismatchIsNeverConnectedAndNotRetriedElsewhere() async {
        let resolver = FakeHubResolver(["en0": .success(F.urlB), "en1": .success(F.urlA)])
        let transport = FakeHealthTransport([F.urlB: F.health(hubID: F.hubB), F.urlA: F.health(hubID: F.hubA)])
        let hub = DiscoveredHub.merge([F.result("Hub", hubID: F.hubA, key: "en0"), F.result("Hub", hubID: F.hubA, key: "en1")])[0]
        do {
            _ = try await verifier(resolver, transport).verify(hub)
            XCTFail("a hub answering with another hub_id must not be accepted")
        } catch {
            XCTAssertEqual(error as? HubVerificationError, .hubIDMismatch(expected: F.hubA, answered: F.hubB))
        }
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 1, "a wrong answer is not worked around through another endpoint")
    }

    func testAnUnreachableEndpointFallsBackToTheNextOne() async throws {
        let resolver = FakeHubResolver(["en0": .failure(.resolveFailed("timeout")), "en1": .success(F.urlA)])
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        let hub = DiscoveredHub.merge([F.result("Hub", hubID: F.hubA, key: "en0"), F.result("Hub", hubID: F.hubA, key: "en1")])[0]
        let selection = try await verifier(resolver, transport).verify(hub)
        XCTAssertEqual(selection.baseURL, F.urlA.absoluteString)
    }

    func testUnusableAnnouncementIsRejectedWithoutAnyRequest() async {
        let resolver = FakeHubResolver(["x": .success(F.urlA)])
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        for result in [F.result("x", hubID: nil), F.result("x", hubID: F.hubA, api: "9")] {
            do {
                _ = try await verifier(resolver, transport).verify(DiscoveredHub.merge([result])[0])
                XCTFail("must not verify")
            } catch {
                XCTAssertNotNil(error as? HubVerificationError)
            }
        }
        XCTAssertEqual(resolver.resolveCount, 0)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testUnsupportedAPIFromHealthIsRejected() async {
        let resolver = FakeHubResolver(["x": .success(F.urlA)])
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA, schema: 2)])
        do {
            _ = try await verifier(resolver, transport).verify(DiscoveredHub.merge([F.result("x", hubID: F.hubA)])[0])
            XCTFail("must not verify")
        } catch {
            XCTAssertEqual(error as? HubVerificationError, .unsupportedSchemaVersion(2))
        }
    }

    // MARK: - Stored selection

    func testSelectionSurvivesStorageAndDamagedValuesAreIgnored() {
        let selection = F.selection()
        XCTAssertEqual(SelectedHub(storedValue: selection.storedValue), selection)
        XCTAssertNil(SelectedHub(storedValue: ""))
        XCTAssertNil(SelectedHub(storedValue: "{not json"))
        XCTAssertNil(SelectedHub(storedValue: F.selection("not-a-hub-id").storedValue))
        XCTAssertNil(SelectedHub(storedValue: SelectedHub(hubID: F.hubA, serviceName: "x", baseURL: "not a url", verifiedAt: .now).storedValue))
    }

    func testResolvedAddressesBecomeBaseURLs() {
        XCTAssertEqual(NetworkHubServiceResolver.baseURL(for: .hostPort(host: "192.168.50.129", port: 8787))?.absoluteString, "http://192.168.50.129:8787")
        XCTAssertEqual(NetworkHubServiceResolver.baseURL(for: .hostPort(host: "fd00::5", port: 8787))?.absoluteString, "http://[fd00::5]:8787")
        XCTAssertEqual(NetworkHubServiceResolver.baseURL(for: .hostPort(host: "pogo.local", port: 8787))?.absoluteString, "http://pogo.local:8787")
    }
}
