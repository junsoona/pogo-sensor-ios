import XCTest
@testable import PogoHome

/// The file the app leaves for its widgets: survives the writing process, rejects what it can't
/// trust, and lives in the App Group container both targets are entitled to.
final class HomeGlanceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "HomeGlanceStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripsASnapshotThroughANewStoreInstance() throws {
        let snapshot = GlanceFixtures.build(pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([GlanceFixtures.climate()])))
        try HomeGlanceStore(directory: directory).save(snapshot)

        // A different instance — as the widget process would create.
        XCTAssertEqual(HomeGlanceStore(directory: directory).load(), .snapshot(snapshot))
    }

    func testMissingFileIsMissingNotAnError() {
        XCTAssertEqual(HomeGlanceStore(directory: directory).load(), .missing)
    }

    func testDamagedFileOrAnotherSchemaVersionIsUnreadable() throws {
        let store = HomeGlanceStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .unreadable)

        var future = GlanceFixtures.build(pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([])))
        future.schemaVersion = HomeGlanceSnapshot.currentSchemaVersion + 1
        try store.save(future)
        XCTAssertEqual(store.load(), .unreadable)
    }

    func testOverwritingReplacesTheWholeSnapshot() throws {
        let store = HomeGlanceStore(directory: directory)
        let first = GlanceFixtures.build(pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([GlanceFixtures.climate()])))
        let second = GlanceFixtures.build(pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([GlanceFixtures.air()])))
        try store.save(first)
        try store.save(second)
        XCTAssertEqual(store.load(), .snapshot(second))
    }

    /// The app (hosting these tests) is signed with the App Group the widget extension also
    /// uses, so the shared container resolves.
    func testTheAppGroupContainerIsAvailableToTheApp() throws {
        let store = try XCTUnwrap(HomeGlanceStore.shared(), "App Group \(HomeGlanceStore.appGroupIdentifier) missing from the app's entitlements")
        XCTAssertTrue(store.fileURL.path().contains(HomeGlanceStore.fileName))
    }
}
