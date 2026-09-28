import XCTest
@testable import PogoHome

/// The "Find hubs" sheet's model against a scripted browser: states, the list, and that closing or
/// re-searching never lets an old browse or check change anything. Not a real Bonjour search.
@MainActor
final class HubDiscoveryModelTests: XCTestCase {
    typealias F = HubFixtures

    private func makeModel(
        browser: FakeHubBrowser = FakeHubBrowser(),
        resolver: FakeHubResolver = FakeHubResolver([:]),
        transport: FakeHealthTransport = FakeHealthTransport([:]),
        quietPeriod: Duration = .seconds(30)
    ) -> HubDiscoveryModel {
        HubDiscoveryModel(browser: browser, verifier: HubVerifier(resolver: resolver, health: transport), quietPeriod: quietPeriod)
    }

    func testSearchingThenNothingFoundAfterTheQuietPeriod() async throws {
        let model = makeModel(quietPeriod: .milliseconds(50))
        model.start()
        XCTAssertEqual(model.searchState, .searching)
        XCTAssertFalse(model.showsNoResults, "not 'nothing found' the instant the search starts")
        try await waitUntil { model.showsNoResults }
        XCTAssertTrue(model.hubs.isEmpty)
    }

    func testFoundHubsAreListedWithoutDuplicatesAndRemovalsShow() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(browser: browser)
        model.start()
        browser.send(.ready)
        browser.send(.results([
            F.result("Jogakbo Hub (a)", hubID: F.hubA, key: "en0"),
            F.result("Jogakbo Hub (a)", hubID: F.hubA, key: "en1"),
            F.result("Jogakbo Hub (b)", hubID: F.hubB),
        ]))
        try await waitUntil { model.hubs.count == 2 }
        XCTAssertEqual(model.hubs.map(\.hubID), [F.hubA, F.hubB])
        XCTAssertFalse(model.showsNoResults)

        browser.send(.results([F.result("Jogakbo Hub (b)", hubID: F.hubB)]))
        try await waitUntil { model.hubs.count == 1 }
        XCTAssertEqual(model.hubs.first?.hubID, F.hubB)
    }

    func testLocalNetworkDeniedThenGrantedResumesTheSearch() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(browser: browser)
        model.start()
        browser.send(.waiting(.localNetworkDenied))
        try await waitUntil { model.searchState == .localNetworkDenied }
        browser.send(.results([F.result("Jogakbo Hub (a)", hubID: F.hubA)]))
        try await waitUntil { model.searchState == .searching && model.hubs.count == 1 }
    }

    func testBrowseFailureIsShownAndSearchAgainStartsAFreshBrowse() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(browser: browser)
        model.start()
        browser.send(.failed(.other("NoAuth")))
        try await waitUntil { model.searchState == .failed("NoAuth") }
        model.restart()
        XCTAssertEqual(model.searchState, .searching)
        XCTAssertEqual(browser.browseCount, 2)
    }

    func testRepeatedStartKeepsOneBrowseAndClosingEndsIt() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(browser: browser)
        model.start()
        model.start()
        model.start()
        XCTAssertEqual(browser.browseCount, 1)
        model.stop()
        try await waitUntil { browser.activeSessions == 0 }
        XCTAssertEqual(model.searchState, .idle)

        // Opening the sheet again: exactly one new browse.
        model.start()
        XCTAssertEqual(browser.browseCount, 2)
        XCTAssertEqual(browser.activeSessions, 1)
    }

    func testEventsFromAClosedSearchAreIgnored() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(browser: browser)
        model.start()
        model.stop()
        model.start()
        browser.send(.results([F.result("Late", hubID: F.hubB)]), session: 0)
        browser.send(.results([F.result("Current", hubID: F.hubA)]), session: 1)
        try await waitUntil { model.hubs.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.hubs.map(\.hubID), [F.hubA], "only the current search's results")
    }

    func testChoosingAHubChecksItAndReturnsTheSelection() async throws {
        let browser = FakeHubBrowser()
        let gate = AsyncGate()
        let model = makeModel(
            browser: browser,
            resolver: FakeHubResolver(["a": .success(F.urlA)], gate: gate),
            transport: FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        )
        model.start()
        browser.send(.results([F.result("Jogakbo Hub (a)", hubID: F.hubA, key: "a")]))
        try await waitUntil { model.hubs.count == 1 }

        let choice = Task { await model.select(model.hubs[0]) }
        try await waitUntil { model.verifyingHubID == "hub:" + F.hubA }
        await gate.open()
        let selection = await choice.value
        XCTAssertEqual(selection?.hubID, F.hubA)
        XCTAssertEqual(selection?.baseURL, F.urlA.absoluteString)
        XCTAssertNil(model.verifyingHubID)
    }

    func testHubIDMismatchIsReportedAndNothingIsReturned() async throws {
        let browser = FakeHubBrowser()
        let model = makeModel(
            browser: browser,
            resolver: FakeHubResolver(["a": .success(F.urlA)]),
            transport: FakeHealthTransport([F.urlA: F.health(hubID: F.hubB)])
        )
        model.start()
        browser.send(.results([F.result("Jogakbo Hub (a)", hubID: F.hubA, key: "a")]))
        try await waitUntil { model.hubs.count == 1 }
        let selection = await model.select(model.hubs[0])
        XCTAssertNil(selection)
        XCTAssertEqual(model.verificationFailure?.hubID, "hub:" + F.hubA)
        XCTAssertEqual(model.verificationFailure?.message, HubVerificationError.hubIDMismatch(expected: F.hubA, answered: F.hubB).message)
    }

    func testClosingDuringTheCheckDropsItsLateResult() async throws {
        let browser = FakeHubBrowser()
        let gate = AsyncGate()
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        let model = makeModel(browser: browser, resolver: FakeHubResolver(["a": .success(F.urlA)], gate: gate), transport: transport)
        model.start()
        browser.send(.results([F.result("Jogakbo Hub (a)", hubID: F.hubA, key: "a")]))
        try await waitUntil { model.hubs.count == 1 }

        let choice = Task { await model.select(model.hubs[0]) }
        try await waitUntil { model.verifyingHubID != nil }
        model.stop()
        await gate.open()
        let selection = await choice.value
        XCTAssertNil(selection, "a check finishing after the sheet closed must not connect")
        XCTAssertNil(model.verifyingHubID)
    }

    func testPickingAnotherHubAbandonsTheFirstCheck() async throws {
        let browser = FakeHubBrowser()
        let gate = AsyncGate()
        let resolver = FakeHubResolver(["a": .success(F.urlA), "b": .success(F.urlB)], gate: gate)
        let model = makeModel(
            browser: browser,
            resolver: resolver,
            transport: FakeHealthTransport([F.urlA: F.health(hubID: F.hubA), F.urlB: F.health(hubID: F.hubB)])
        )
        model.start()
        browser.send(.results([F.result("A", hubID: F.hubA, key: "a"), F.result("B", hubID: F.hubB, key: "b")]))
        try await waitUntil { model.hubs.count == 2 }

        let first = Task { await model.select(model.hubs[0]) }
        try await waitUntil { resolver.resolveCount == 1 }
        let second = Task { await model.select(model.hubs[1]) }
        try await waitUntil { model.verifyingHubID == "hub:" + F.hubB }
        await gate.open()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(secondResult?.hubID, F.hubB)
    }

    func testAnUnusableAnnouncementIsExplainedAndNeverChecked() async throws {
        let browser = FakeHubBrowser()
        let resolver = FakeHubResolver([:])
        let model = makeModel(browser: browser, resolver: resolver)
        model.start()
        browser.send(.results([F.result("Old Hub", hubID: nil)]))
        try await waitUntil { model.hubs.count == 1 }
        let selection = await model.select(model.hubs[0])
        XCTAssertNil(selection)
        XCTAssertNotNil(model.verificationFailure)
        XCTAssertEqual(resolver.resolveCount, 0)
    }
}
