import XCTest
@testable import PogoHome

/// Following the chosen hub to a new address after the connection drops — only ever the same
/// hub_id, verified. Scripted browser and network; not a real Bonjour search.
@MainActor
final class HubRelocatorTests: XCTestCase {
    typealias F = HubFixtures

    private final class Box {
        var selection: SelectedHub?
        var relocations: [SelectedHub] = []
    }

    private func makeRelocator(
        box: Box,
        browser: FakeHubBrowser,
        resolver: FakeHubResolver,
        transport: FakeHealthTransport,
        retryInterval: Duration = .seconds(30)
    ) -> HubRelocator {
        HubRelocator(
            browser: browser,
            verifier: HubVerifier(resolver: resolver, health: transport),
            retryInterval: retryInterval,
            selection: { box.selection },
            onRelocate: { box.relocations.append($0) }
        )
    }

    func testAddressTypedByHandIsNeverSearchedFor() {
        let box = Box()
        let browser = FakeHubBrowser()
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver([:]), transport: FakeHealthTransport([:]))
        relocator.connectionStatusDidChange(.failed("down"))
        relocator.connectionStatusDidChange(.reconnecting(attempt: 3))
        XCTAssertEqual(browser.browseCount, 0)
        XCTAssertFalse(relocator.isSearching)
    }

    func testNoSearchWhileConnectedOrConnecting() {
        let box = Box()
        box.selection = F.selection()
        let browser = FakeHubBrowser()
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver([:]), transport: FakeHealthTransport([:]))
        relocator.connectionStatusDidChange(.connecting)
        relocator.connectionStatusDidChange(.connected)
        relocator.connectionStatusDidChange(.idle)
        XCTAssertEqual(browser.browseCount, 0)
    }

    func testTheSameHubAtANewAddressIsFollowed() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let relocator = makeRelocator(
            box: box,
            browser: browser,
            resolver: FakeHubResolver(["a": .success(F.urlA2)]),
            transport: FakeHealthTransport([F.urlA2: F.health(hubID: F.hubA)])
        )
        relocator.connectionStatusDidChange(.failed("down"))
        relocator.connectionStatusDidChange(.reconnecting(attempt: 1))
        XCTAssertEqual(browser.browseCount, 1, "one search, however many failures")
        browser.send(.results([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "a")]))
        try await waitUntil { box.relocations.count == 1 }
        XCTAssertEqual(box.relocations[0].hubID, F.hubA)
        XCTAssertEqual(box.relocations[0].baseURL, F.urlA2.absoluteString)
        XCTAssertFalse(relocator.isSearching, "the search ends once the hub is found")
        try await waitUntil { browser.activeSessions == 0 }
    }

    func testAnotherHubIsNeverSwitchedTo() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let resolver = FakeHubResolver(["b": .success(F.urlB)])
        let transport = FakeHealthTransport([F.urlB: F.health(hubID: F.hubB)])
        let relocator = makeRelocator(box: box, browser: browser, resolver: resolver, transport: transport)
        relocator.connectionStatusDidChange(.failed("down"))
        browser.send(.results([F.result("Jogakbo Hub (other)", hubID: F.hubB, key: "b")]))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(resolver.resolveCount, 0, "another hub's announcement isn't even resolved")
        XCTAssertTrue(box.relocations.isEmpty)
        XCTAssertTrue(relocator.isSearching)
    }

    func testAnAnnouncementWhoseHealthAnswersForAnotherHubIsRejected() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let transport = FakeHealthTransport([F.urlB: F.health(hubID: F.hubB)])
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver(["spoof": .success(F.urlB)]), transport: transport)
        relocator.connectionStatusDidChange(.failed("down"))
        browser.send(.results([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "spoof")]))
        try await waitUntil { await transport.fetchCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(box.relocations.isEmpty)
    }

    func testTheHubStillAtTheSameAddressChangesNothing() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let transport = FakeHealthTransport([F.urlA: F.health(hubID: F.hubA)])
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver(["a": .success(F.urlA)]), transport: transport)
        relocator.connectionStatusDidChange(.failed("down"))
        browser.send(.results([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "a")]))
        try await waitUntil { await transport.fetchCount == 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(box.relocations.isEmpty)
        let fetchCount = await transport.fetchCount
        XCTAssertEqual(fetchCount, 1, "not re-checked before the retry interval")
    }

    func testFailedChecksAreRetriedAtTheRetryInterval() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let resolver = FakeHubResolver(["a": .failure(.resolveFailed("not yet"))])
        let transport = FakeHealthTransport([F.urlA2: F.health(hubID: F.hubA)])
        let relocator = makeRelocator(box: box, browser: browser, resolver: resolver, transport: transport, retryInterval: .milliseconds(60))
        relocator.connectionStatusDidChange(.failed("down"))
        browser.send(.results([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "a")]))
        try await waitUntil { resolver.resolveCount == 1 }
        resolver.set("a", .success(F.urlA2))
        try await waitUntil { box.relocations.count == 1 }
        XCTAssertEqual(box.relocations[0].baseURL, F.urlA2.absoluteString)
    }

    func testRecoveringBeforeTheCheckEndsDropsItsResult() async throws {
        let box = Box()
        box.selection = F.selection(url: F.urlA)
        let browser = FakeHubBrowser()
        let gate = AsyncGate()
        let relocator = makeRelocator(
            box: box,
            browser: browser,
            resolver: FakeHubResolver(["a": .success(F.urlA2)], gate: gate),
            transport: FakeHealthTransport([F.urlA2: F.health(hubID: F.hubA)])
        )
        relocator.connectionStatusDidChange(.failed("down"))
        browser.send(.results([F.result("Jogakbo Hub (pogo)", hubID: F.hubA, key: "a")]))
        try await Task.sleep(for: .milliseconds(30))
        relocator.connectionStatusDidChange(.connected)
        XCTAssertFalse(relocator.isSearching)
        await gate.open()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(box.relocations.isEmpty, "a late result after recovery must not move the connection")
        try await waitUntil { browser.activeSessions == 0 }
    }

    func testClearingTheChoiceStopsTheSearch() async throws {
        let box = Box()
        box.selection = F.selection()
        let browser = FakeHubBrowser()
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver([:]), transport: FakeHealthTransport([:]))
        relocator.connectionStatusDidChange(.failed("down"))
        XCTAssertTrue(relocator.isSearching)
        box.selection = nil
        relocator.selectionDidChange()
        XCTAssertFalse(relocator.isSearching)
        try await waitUntil { browser.activeSessions == 0 }
    }

    func testBackgroundStopsTheSearch() async throws {
        let box = Box()
        box.selection = F.selection()
        let browser = FakeHubBrowser()
        let relocator = makeRelocator(box: box, browser: browser, resolver: FakeHubResolver([:]), transport: FakeHealthTransport([:]))
        relocator.connectionStatusDidChange(.reconnecting(attempt: 2))
        relocator.suspend()
        XCTAssertFalse(relocator.isSearching)
        try await waitUntil { browser.activeSessions == 0 }
    }
}
