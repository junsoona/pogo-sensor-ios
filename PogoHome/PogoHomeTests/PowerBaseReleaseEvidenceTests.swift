import XCTest
@testable import PogoHome

/// The rule that decides whether a Base missing from the hub's list was released, on its own: one
/// snapshot after the other, as the hub would say them. The same rule through the real receiving
/// path is in `AppModelPowerBaseManagementTests`.
final class PowerBaseReleaseEvidenceTests: XCTestCase {
    private let base = RemovalFixtures.base
    private let other = RemovalFixtures.otherBase
    private let job = RemovalFixtures.removalID
    private let secondJob = RemovalFixtures.otherRemovalID

    private func listed(_ bases: [String], _ removals: [PowerBaseRemoval] = []) -> HomeSnapshot {
        HomeSnapshot(
            timestamp: Date(timeIntervalSince1970: 0), rooms: [], modules: [],
            powerBases: bases.map { PowerBase(hardwareIdentifier: $0, isOnline: true, moduleCount: 0, onlineModuleCount: 0, management: .supported) },
            reportsPowerBases: true, powerBaseRemovals: removals, reportsPowerBaseManagement: true
        )
    }

    private func removal(_ state: PowerBaseRemoval.State, id: String? = nil, base: String? = nil) -> PowerBaseRemoval {
        RemovalFixtures.removal(state, id: id ?? job, base: base ?? self.base)
    }

    func testAJobThatEndsAfterTheBaseWasSeenListedIsTheReason() {
        for end in [PowerBaseRemoval.State.released, .completed] {
            var evidence = PowerBaseReleaseEvidence()
            XCTAssertEqual(evidence.observe(listed([base], [removal(.accepted)])), [])
            XCTAssertEqual(evidence.observe(listed([], [removal(end)])), [base], "\(end)")
            XCTAssertEqual(evidence.observe(listed([], [removal(end)])), [base], "and stays the reason: \(end)")
        }
        // Also a job the app never saw before it ended: the Base was listed without it.
        var evidence = PowerBaseReleaseEvidence()
        XCTAssertEqual(evidence.observe(listed([base])), [])
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed)])), [base])
    }

    func testOnlyReleasedAndCompletedEndAJob() {
        for state in [PowerBaseRemoval.State.pending, .sent, .accepted, .cancelled, .superseded] {
            var evidence = PowerBaseReleaseEvidence()
            _ = evidence.observe(listed([base], [removal(.pending)]))
            XCTAssertEqual(evidence.observe(listed([], [removal(state)])), [], "\(state)")
        }
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(listed([base]))
        XCTAssertEqual(evidence.observe(listed([])), [], "an empty list by itself")
    }

    func testAReleaseUnderWayStaysTheReasonHoweverManySnapshotsStillListTheBase() {
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(listed([base], [removal(.accepted)]))
        for _ in 0..<5 { XCTAssertEqual(evidence.observe(listed([base], [removal(.released)])), []) }
        XCTAssertEqual(evidence.observe(listed([], [removal(.released)])), [base])
    }

    func testAJobSeenCompletedWhileTheBaseIsListedIsSpentForGood() {
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(listed([base], [removal(.accepted)]))
        // Removed and enrolled again unseen.
        XCTAssertEqual(evidence.observe(listed([base], [removal(.completed)])), [])
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed)])), [], "a hub starting again")
        XCTAssertEqual(evidence.observe(listed([base], [removal(.completed)])), [])
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed)])), [], "and again")
        // Another job of the same Base is not spent with it.
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed), removal(.released, id: secondJob)])), [base])
    }

    func testAJobAlreadyEndedWhenTheBaseAppearsIsSpent() {
        // On the first snapshot from the hub.
        for end in [PowerBaseRemoval.State.released, .completed] {
            var evidence = PowerBaseReleaseEvidence()
            XCTAssertEqual(evidence.observe(listed([base], [removal(end)])), [])
            XCTAssertEqual(evidence.observe(listed([], [removal(end)])), [], "\(end)")
        }
        // After the Base had not been listed: released, then enrolled again while the job is
        // still `released` (the new enrollment is not active yet).
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(listed([base], [removal(.accepted)]))
        XCTAssertEqual(evidence.observe(listed([], [removal(.released)])), [base])
        XCTAssertEqual(evidence.observe(listed([base], [removal(.released)])), [])
        XCTAssertEqual(evidence.observe(listed([], [removal(.released)])), [], "the finished removal is not this enrollment's")
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed)])), [], "nor when its receipt arrives later")
    }

    func testEachBaseHasItsOwnHistory() {
        var evidence = PowerBaseReleaseEvidence()
        _ = evidence.observe(listed([base, other], [removal(.completed), removal(.accepted, id: secondJob, base: other)]))
        XCTAssertEqual(evidence.observe(listed([base], [removal(.completed), removal(.released, id: secondJob, base: other)])), [other])
        XCTAssertEqual(evidence.observe(listed([], [removal(.completed), removal(.released, id: secondJob, base: other)])), [other],
                       "the other Base's release says nothing about this one")
    }

    func testAFreshValueKnowsNothingOfAnotherHub() {
        var hubA = PowerBaseReleaseEvidence()
        _ = hubA.observe(listed([base], [removal(.completed)]))
        XCTAssertEqual(hubA.observe(listed([], [removal(.completed)])), [])
        var hubB = PowerBaseReleaseEvidence()
        _ = hubB.observe(listed([base], [removal(.accepted)]))
        XCTAssertEqual(hubB.observe(listed([], [removal(.completed)])), [base])
    }
}
