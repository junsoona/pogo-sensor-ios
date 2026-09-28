import XCTest
@testable import PogoHome

/// What a widget may say about stored data as time passes: nothing is ever presented as live,
/// old data is labeled old on time, and unreadable Apple Home data is never shown.
final class HomeGlancePresentationTests: XCTestCase {
    private typealias F = GlanceFixtures
    private let staleAfter = HomeGlanceFreshness.staleAfter

    private var healthy: HomeGlanceSnapshot { F.build(pogo: F.pogoInput(F.home([F.climate()]))) }

    // MARK: - Freshness

    func testFreshnessBoundaries() {
        XCTAssertEqual(HomeGlanceFreshness.of(nil, now: F.t0), .unknown)
        XCTAssertEqual(HomeGlanceFreshness.of(F.t0, now: F.t0), .recent)
        XCTAssertEqual(HomeGlanceFreshness.of(F.t0, now: F.t0.addingTimeInterval(staleAfter)), .recent)
        XCTAssertEqual(HomeGlanceFreshness.of(F.t0, now: F.t0.addingTimeInterval(staleAfter + 1)), .stale)
        XCTAssertEqual(HomeGlanceFreshness.of(F.t0, now: F.t0.addingTimeInterval(-3600)), .stale, "a confirmation 'in the future' isn't trusted")
    }

    // MARK: - POGO status

    func testAHealthyStateIsHealthyOnlyWhileRecentThenStale() {
        let glance = healthy
        XCTAssertEqual(glance.pogoStatus(at: F.t0.addingTimeInterval(60)).verdict, .healthy)
        XCTAssertTrue(glance.pogoStatus(at: F.t0.addingTimeInterval(60)).isVerifiedFine)

        let later = glance.pogoStatus(at: F.t0.addingTimeInterval(staleAfter + 1))
        XCTAssertEqual(later.verdict, .stale)
        XCTAssertFalse(later.isVerifiedFine)
        XCTAssertFalse(later.showsCounts, "old counts aren't stated as facts")
    }

    func testUnverifiedAndWaitingStatesNeverShowCounts() {
        var glance = healthy
        glance.pogo.state = .unverified
        XCTAssertEqual(glance.pogoStatus(at: F.t0).verdict, .unverified)
        XCTAssertFalse(glance.pogoStatus(at: F.t0).showsCounts)

        let empty = F.build(pogo: F.pogoInput(F.home([]), health: .waitingForData))
        XCTAssertEqual(empty.pogoStatus(at: F.t0).verdict, .waitingForData)
    }

    func testAttentionNeededKeepsItsItems() {
        let glance = F.build(pogo: F.pogoInput(F.home([F.climate(), F.air(online: false)]), health: .attentionNeeded))
        let status = glance.pogoStatus(at: F.t0)
        XCTAssertEqual(status.verdict, .attentionNeeded)
        XCTAssertEqual(status.attention.map(\.device), [.pogoModule(F.airID)])
        XCTAssertFalse(status.isVerifiedFine)
    }

    // MARK: - Apple Home status

    func testAppleHomeStatus() {
        XCTAssertEqual(healthy.appleHomeStatus(at: F.t0), .allResponding(total: 2, verifiedAt: F.t0))
        XCTAssertEqual(healthy.appleHomeStatus(at: F.t0.addingTimeInterval(staleAfter + 1)), .stale(verifiedAt: F.t0))

        let unreachable = F.build(pogo: F.pogoInput(F.home([])), appleHome: F.appleHomeInput([AppleHomeFixtures.light(reachable: false), AppleHomeFixtures.sensor()]))
        XCTAssertEqual(unreachable.appleHomeStatus(at: F.t0), .someNotResponding(notResponding: 1, total: 2, verifiedAt: F.t0))

        let denied = F.build(pogo: F.pogoInput(F.home([])), appleHome: F.appleHomeInput(state: .denied))
        XCTAssertEqual(denied.appleHomeStatus(at: F.t0), .unavailable(.denied))
    }

    /// Defense in depth: even a file that still carried Apple Home values next to a
    /// non-readable access state never shows them.
    func testAppleHomeValuesAreNeverShownWithoutReadableAccess() {
        var glance = healthy
        glance.appleHome.access = .denied
        XCTAssertNotNil(glance.sensor(with: F.appleHomeTemperatureID))
        XCTAssertEqual(glance.sensorLookup(F.appleHomeTemperatureID, at: F.t0), .sourceUnavailable(.denied))
        XCTAssertEqual(glance.appleHomeStatus(at: F.t0), .unavailable(.denied))
        // POGO values are unaffected.
        guard case .found = glance.sensorLookup(F.temperatureID, at: F.t0) else {
            return XCTFail("POGO value must still be found")
        }
    }

    // MARK: - Sensor lookup

    func testSensorLookupStates() {
        let glance = healthy
        XCTAssertEqual(glance.sensorLookup(nil, at: F.t0), .notConfigured)
        XCTAssertEqual(glance.sensorLookup(.pogo(module: UUID(), kind: .temperature), at: F.t0), .missing)

        let temperature = glance.sensor(with: F.temperatureID)!
        XCTAssertEqual(glance.sensorLookup(F.temperatureID, at: F.t0.addingTimeInterval(60)), .found(temperature, .recent))
        XCTAssertEqual(glance.sensorLookup(F.temperatureID, at: F.t0.addingTimeInterval(staleAfter + 1)), .found(temperature, .stale))

        var unverified = glance
        unverified.pogo.state = .unverified
        XCTAssertEqual(unverified.sensorLookup(F.temperatureID, at: F.t0), .found(temperature, .sourceUnverified))
    }

    func testAppleHomeValueTurnsStaleWithItsSectionEvenIfItsOwnReadWasRecent() {
        var glance = healthy
        glance.appleHome.verifiedAt = F.t0.addingTimeInterval(-staleAfter - 60)
        let sensor = glance.sensor(with: F.appleHomeTemperatureID)!
        XCTAssertEqual(glance.condition(of: sensor, at: F.t0), .stale)
    }

    // MARK: - Timeline

    func testPresentationChangeDatesDowngradeTheWidgetOnTimeWithoutAReload() {
        let glance = healthy
        let now = F.t0.addingTimeInterval(60)
        let dates = glance.presentationChangeDates(after: now, sensorID: F.temperatureID)

        let staleMoment = F.t0.addingTimeInterval(staleAfter + 1)
        XCTAssertTrue(dates.contains(staleMoment))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertTrue(dates.allSatisfy { $0 > now })
        XCTAssertEqual(Set(dates).count, dates.count)
        // At that entry the widget must no longer claim a healthy state.
        XCTAssertEqual(glance.pogoStatus(at: staleMoment).verdict, .stale)
        XCTAssertEqual(glance.condition(of: glance.sensor(with: F.temperatureID)!, at: staleMoment), .stale)
        // …and the day change is in there too (times then need a date).
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)!
        XCTAssertTrue(dates.contains(midnight))
    }

    func testAlreadyStaleDataNeedsNoFurtherStaleEntries() {
        let dates = healthy.presentationChangeDates(after: F.t0.addingTimeInterval(3600))
        XCTAssertTrue(dates.allSatisfy { $0 > F.t0.addingTimeInterval(3600) })
        XCTAssertFalse(dates.contains(F.t0.addingTimeInterval(staleAfter + 1)))
    }

    // MARK: - Identifiers and text

    func testValueIdentifierRoundTripsAndRejectsGarbage() {
        let ids = [F.temperatureID, F.appleHomeTemperatureID]
        for id in ids {
            XCTAssertEqual(HomeGlanceValueID(stringValue: id.stringValue), id)
        }
        for garbage in ["", "pogoLinuxAPI", "unknown/\(UUID().uuidString)/temperature", "pogoLinuxAPI/not-a-uuid/temperature", "appleHome/\(UUID().uuidString)/"] {
            XCTAssertNil(HomeGlanceValueID(stringValue: garbage), garbage)
        }
    }

    func testCompactAndSensitiveValues() {
        let glance = healthy
        let temperature = glance.sensor(with: F.temperatureID)!
        XCTAssertEqual(HomeGlanceValueText.compactValueText(of: temperature, locale: Locale(identifier: "en_US")), "23.4°")
        XCTAssertEqual(HomeGlanceValueText.compactValueText(of: temperature, locale: Locale(identifier: "es_ES")), "23,4°")
        XCTAssertEqual(HomeGlanceValueText.valueText(of: temperature, locale: Locale(identifier: "en_US")), "23.4 °C")
        XCTAssertFalse(HomeGlanceValueText.isSecuritySensitive(temperature))

        let lock = HomeGlanceBuilder.sensors(of: AppleHomeFixtures.lock())
        XCTAssertEqual(lock.count, 1)
        XCTAssertTrue(HomeGlanceValueText.isSecuritySensitive(lock[0]), "lock state is redacted on a locked phone")
    }

    // MARK: - Links

    func testLinksRoundTripAndIgnoreForeignURLs() {
        let links: [HomeGlanceLink] = [.dashboard, .devices, .device(.pogoModule(F.climateID)), .device(.appleHomeAccessory(F.climateID))]
        for link in links {
            XCTAssertEqual(HomeGlanceLink(url: link.url), link, link.url.absoluteString)
        }
        XCTAssertNotEqual(HomeGlanceLink.device(.pogoModule(F.climateID)).url, HomeGlanceLink.device(.appleHomeAccessory(F.climateID)).url)
        for foreign in ["https://example.com/dashboard", "pogohome://device/pogoLinuxAPI", "pogohome://device/other/\(UUID().uuidString)", "pogohome://settings"] {
            XCTAssertNil(HomeGlanceLink(url: URL(string: foreign)!), foreign)
        }
    }
}
