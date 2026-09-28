import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PogoHomeWatch

/// States the Watch can be in, built from plain values (no network, no HomeKit).
enum WatchRenderFixtures {
    static let climateID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let airID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    static let doorID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    static let doorStateID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    static let homeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    static var temperature: HomeGlanceValueID { .pogo(module: climateID, kind: .temperature) }
    static var pm25: HomeGlanceValueID { .pogo(module: airID, kind: .pm2_5) }
    static var door: HomeGlanceValueID { .appleHome(accessory: doorID, characteristic: doorStateID) }
    static var gone: HomeGlanceValueID { .pogo(module: UUID(uuidString: "20000000-0000-0000-0000-0000000000FF")!, kind: .humidity) }

    static func glance(confirmedAt: Date, state: HomeGlancePogoState = .healthy, airOnline: Bool = true, simulated: Bool = false) -> HomeGlanceSnapshot {
        let attention = airOnline ? [] : [HomeGlanceAttentionItem(device: .pogoModule(airID), name: "PMS5003", reason: .offline)]
        return HomeGlanceSnapshot(
            writtenAt: confirmedAt,
            homeName: String(localized: "우리 집", comment: "Default home name"),
            pogo: HomeGlancePogoSection(state: state, verifiedAt: confirmedAt, moduleCount: 2, onlineCount: airOnline ? 2 : 1, attention: attention, isSimulated: simulated),
            appleHome: HomeGlanceAppleHomeSection(access: .ready, verifiedAt: confirmedAt, accessoryCount: 2, notRespondingCount: 0),
            sensors: [
                HomeGlanceSensor(id: temperature, deviceName: String(localized: "거실 환경 모듈", comment: "Mock data module name"), roomName: String(localized: "거실", comment: "Default room name"), kindRawValue: SensorKind.temperature.rawValue, value: 23.4, status: .normal, isDeviceConnected: true, checkedAt: confirmedAt),
                HomeGlanceSensor(id: pm25, deviceName: "PMS5003", roomName: String(localized: "거실", comment: "Default room name"), kindRawValue: SensorKind.pm2_5.rawValue, value: 7, status: .normal, isDeviceConnected: airOnline, checkedAt: confirmedAt),
                HomeGlanceSensor(id: door, deviceName: "현관문", roomName: "현관", kindRawValue: AppleHomeCharacteristicKind.contactState.rawValue, value: 1, status: .normal, isDeviceConnected: true, checkedAt: confirmedAt),
            ]
        )
    }

    static func settings(mode: WatchSettings.DataSourceMode = .live, selection: [HomeGlanceValueID] = [temperature, pm25, door]) -> WatchSettings {
        WatchSettings(updatedAt: .distantPast, dataSourceMode: mode, hubBaseURL: "http://192.168.50.129:8787", selectedValueIDs: selection.map(\.stringValue), moduleLabels: [])
    }

    static func record(_ round: WatchSyncRound?) -> WatchSyncRecord {
        WatchSyncRecord(lastRound: round, lastConfirmation: nil, lastPushAt: nil)
    }

    /// (name, state, connection) for the home page and the complications.
    static func homeStates(now: Date) -> [(String, WatchStoredState, WatchConnectionStatus)] {
        let recent = now.addingTimeInterval(-60)
        let fiveMinutes = now.addingTimeInterval(-5 * 60)
        let hoursAgo = now.addingTimeInterval(-3 * 3600)
        let unreachable = WatchSyncRound(at: now.addingTimeInterval(-10), direct: .failed(.hubUnreachable), phone: .failed(.phoneCannotReachHub))
        return [
            ("direct", WatchStoredState(glance: glance(confirmedAt: recent), settings: settings(), record: record(nil)), .confirmed(.direct, at: recent)),
            ("phone", WatchStoredState(glance: glance(confirmedAt: recent), settings: settings(), record: record(nil)), .confirmed(.phone, at: recent)),
            ("attention", WatchStoredState(glance: glance(confirmedAt: recent, state: .attentionNeeded, airOnline: false), settings: settings(), record: record(nil)), .confirmed(.direct, at: recent)),
            ("notConfirmed", WatchStoredState(glance: glance(confirmedAt: fiveMinutes, state: .unverified), settings: settings(), record: record(unreachable)),
             .unreachable(direct: unreachable.direct, phone: unreachable.phone, at: unreachable.at)),
            ("stale", WatchStoredState(glance: glance(confirmedAt: hoursAgo, state: .unverified), settings: settings(), record: record(unreachable)),
             .unreachable(direct: .failed(.hubUnreachable), phone: .failed(.phoneUnreachable), at: unreachable.at)),
            ("simulated", WatchStoredState(glance: glance(confirmedAt: recent, simulated: true), settings: settings(mode: .mock), record: record(nil)), .simulated),
            ("notConfigured", .empty, .notConfigured),
            ("nothingSelected", WatchStoredState(glance: glance(confirmedAt: recent), settings: settings(selection: []), record: record(nil)), .confirmed(.direct, at: recent)),
        ]
    }

    static func target(_ index: Int, name: String, room: String?, kind: AppleHomePowerTargetKind) -> AppleHomePowerTarget {
        let accessory = UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", index))!
        let characteristic = UUID(uuidString: String(format: "40000000-0000-0000-0001-%012d", index))!
        return AppleHomePowerTarget(id: AppleHomePowerTargetID(homeID: homeID, accessoryID: accessory, characteristicID: characteristic), name: name, roomName: room, homeName: "우리 집", kind: kind)
    }

    static func powerRows(now: Date) -> [WatchPowerRow] {
        [
            WatchPowerRow(target: target(1, name: "거실 조명", room: String(localized: "거실", comment: "Default room name"), kind: .light), state: .known(isOn: true, checkedAt: now.addingTimeInterval(-30)), lastResult: .confirmed, resultAt: now.addingTimeInterval(-10)),
            WatchPowerRow(target: target(2, name: "전기포트 플러그", room: "주방", kind: .outlet), state: .known(isOn: false, checkedAt: now.addingTimeInterval(-40))),
            WatchPowerRow(target: target(3, name: "현관 스위치", room: nil, kind: .switch), state: .unknown, lastResult: .noResponse(.notReachable), resultAt: now),
            WatchPowerRow(target: target(4, name: "침실 스탠드", room: "침실", kind: .light), state: .unknown, lastResult: .unconfirmed(.unconfirmed), resultAt: now),
            WatchPowerRow(target: target(5, name: "서재 조명", room: "서재", kind: .light), state: .known(isOn: false, checkedAt: now.addingTimeInterval(-60)), activity: .switching(toOn: true)),
            WatchPowerRow(target: target(6, name: "베란다 콘센트", room: "베란다", kind: .outlet), state: .known(isOn: true, checkedAt: now.addingTimeInterval(-7200))),
        ]
    }
}

/// Renders the Watch app's pages and every complication in every state to PNG — written only when
/// `POGO_WATCH_RENDER_DIR` is set (`TEST_RUNNER_POGO_WATCH_RENDER_DIR=…` for `xcodebuild test`, with
/// `-testLanguage ko|en|es`). Always checks that every combination lays out.
///
/// Variants: the Watch's dark look, the largest accessibility text size, Always On (luminance
/// reduced: names and security-sensitive values redacted) and locked (system privacy redaction).
@MainActor
final class WatchRenderingTests: XCTestCase {
    private typealias R = WatchRenderFixtures

    private let now = Date()

    private struct Variant {
        let name: String
        var typeSize: DynamicTypeSize = .large
        var luminanceReduced = false
        var locked = false
    }

    private let variants = [
        Variant(name: "normal"),
        Variant(name: "largeText", typeSize: .accessibility3),
        Variant(name: "alwaysOn", luminanceReduced: true),
        Variant(name: "locked", locked: true),
    ]

    /// 40 mm (the smallest current Watch) and 46 mm screens, in points.
    private let screens: [(String, CGSize)] = [("40mm", CGSize(width: 162, height: 197)), ("46mm", CGSize(width: 208, height: 248))]

    private let complicationSizes: [WatchComplicationLayout: CGSize] = [
        .circular: CGSize(width: 50, height: 50),
        .rectangular: CGSize(width: 184, height: 60),
        .inline: CGSize(width: 184, height: 22),
        .corner: CGSize(width: 44, height: 44),
    ]

    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["POGO_WATCH_RENDER_DIR"].map {
            URL(filePath: $0, directoryHint: .isDirectory).appending(path: Bundle.main.preferredLocalizations.first ?? "ko")
        }
    }

    func testRenderTheAppPages() throws {
        var rendered = 0
        for (screenName, size) in screens {
            for variant in variants where variant.name != "locked" || screenName == "46mm" {
                for (name, state, connection) in R.homeStates(now: now) {
                    let view = WatchHomeContent(state: state, connection: connection, isRefreshing: false, now: now, refresh: {}, isInList: false)
                    try render(view, size: size, variant: variant, file: "app-home-\(name)-\(screenName)-\(variant.name)")
                    rendered += 1
                }
                let pages: [(String, WatchPowerController.Access, [WatchPowerRow])] = [
                    ("ready", .ready, R.powerRows(now: now)),
                    ("off", .off, []),
                    ("loading", .loading, []),
                    ("denied", .denied, []),
                    ("noHome", .noHome, []),
                    ("empty", .ready, []),
                ]
                for (name, access, rows) in pages {
                    let view = WatchAppleHomeContent(access: access, rows: rows, now: now, enable: {}, reload: {}, disable: {}, tap: { _ in }, isInList: false)
                    try render(view, size: size, variant: variant, file: "app-applehome-\(name)-\(screenName)-\(variant.name)")
                    rendered += 1
                }
            }
        }
        XCTAssertGreaterThan(rendered, 80)
    }

    func testRenderEveryComplication() throws {
        var rendered = 0
        let sensorSelections: [(String, String?)] = [
            ("first", nil),
            ("pm25", R.pm25.stringValue),
            ("door", R.door.stringValue),
            ("gone", R.gone.stringValue),
        ]
        for variant in variants {
            for layout in WatchComplicationLayout.allCases {
                let size = complicationSizes[layout]!
                for (name, state, _) in R.homeStates(now: now) {
                    try render(WatchHomeStatusComplication(state: state, now: now, layout: layout), size: size, variant: variant, isComplication: true, file: "complication-home-\(name)-\(layout)-\(variant.name)")
                    rendered += 1
                    guard ["direct", "notConfirmed", "stale", "notConfigured", "nothingSelected"].contains(name) else { continue }
                    for (selectionName, selection) in sensorSelections where name == "direct" || selection == nil {
                        try render(WatchSensorComplication(state: state, selection: selection, now: now, layout: layout), size: size, variant: variant, isComplication: true, file: "complication-sensor-\(name)-\(selectionName)-\(layout)-\(variant.name)")
                        rendered += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(rendered, 150)
    }

    /// Complications at their exact size; app pages at the screen's width and their full scrolling
    /// height, so everything the wearer can scroll to is in the picture.
    private func render(_ view: some View, size: CGSize, variant: Variant, isComplication: Bool = false, file: String) throws {
        let framed = view
            .frame(width: size.width, height: isComplication ? size.height : nil)
            .fixedSize(horizontal: false, vertical: !isComplication)
            .padding(.vertical, isComplication ? 0 : 12)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: isComplication ? (size.width == size.height ? size.width / 2 : 8) : 28, style: .continuous))
            .environment(\.colorScheme, .dark)
            .environment(\.dynamicTypeSize, variant.typeSize)
            .environment(\.isLuminanceReduced, variant.luminanceReduced)
            .redacted(reason: variant.locked ? .privacy : [])
            .padding(4)
            .background(Color.gray.opacity(0.4))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, file)
        guard let outputDirectory else { return }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appending(path: "\(file).png") as CFURL
        // A write occasionally fails right after the directory is created; one retry is enough.
        for attempt in 1...2 {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { return }
            XCTAssertLessThan(attempt, 2, "PNG write failed: \(file)")
        }
    }
}

/// The shared rules, run on watchOS itself: the Watch's own App Group store, the settings its
/// bundle ships with, and a round against scripted paths.
@MainActor
final class WatchPlatformTests: XCTestCase {
    private typealias R = WatchRenderFixtures

    func testTheWatchAppCanReachALocalHubAndAskForHomeKit() {
        let info = Bundle.main.infoDictionary ?? [:]
        let ats = info["NSAppTransportSecurity"] as? [String: Any]
        XCTAssertEqual(ats?["NSAllowsLocalNetworking"] as? Bool, true, "http:// to the bridge's LAN address")
        XCTAssertNotNil(info["NSHomeKitUsageDescription"])
        XCTAssertEqual(info["WKCompanionAppBundleIdentifier"] as? String, "com.junsoona.PogoHome")
    }

    func testTheWatchShipsKoreanEnglishAndSpanish() {
        XCTAssertTrue(Set(["ko", "en", "es"]).isSubset(of: Set(Bundle.main.localizations)), "\(Bundle.main.localizations)")
        for language in ["en", "es"] {
            let bundle = Bundle(url: Bundle.main.url(forResource: language, withExtension: "lproj")!)!
            for key in ["허브에 연결할 수 없음", "집 네트워크에서 직접 확인", "상태 미확인", "오래된 정보"] {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: nil), key, "\(language): \(key)")
            }
        }
    }

    func testTheStoreRoundTripsInTheWatchsAppGroup() throws {
        let store = try XCTUnwrap(WatchStateStore.shared(), "App Group entitlement missing on the Watch")
        let previous = store.load()
        defer { try? store.save(previous) }
        let state = WatchStoredState(glance: R.glance(confirmedAt: Date(timeIntervalSince1970: 1_800_000_000)), settings: R.settings(), record: .empty)
        try store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testARoundOnWatchOSKeepsTheLastValueWhenNothingIsReachable() async {
        final class NoHub: WatchHubFetching {
            func fetchSnapshot(from baseURL: URL) async throws -> HomeSnapshot { throw URLError(.notConnectedToInternet) }
        }
        final class NoPhone: WatchPhoneRelaying {
            var isPhoneReachable: Bool { false }
            func requestRefresh() async throws -> WatchRelayReply { throw WatchPhoneRelayError.unreachable }
        }
        final class NoReload: WatchWidgetReloading { func reloadWidgets() {} }
        let confirmedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let sync = WatchSyncEngine(store: nil, hub: NoHub(), phone: NoPhone(), reloader: NoReload(), now: { confirmedAt.addingTimeInterval(60) })
        sync.receivePush(WatchSyncPayload(sentAt: confirmedAt, glance: R.glance(confirmedAt: confirmedAt), settings: R.settings()))

        let round = await sync.refresh()

        XCTAssertNil(round?.confirmedBy)
        XCTAssertEqual(sync.glance?.sensor(with: R.temperature)?.value, 23.4)
        XCTAssertEqual(WatchGlancePresentation.headline(sync.glance, now: confirmedAt.addingTimeInterval(60)), .notConfirmed(lastConfirmedAt: confirmedAt))
        XCTAssertEqual(WatchGlancePresentation.headline(sync.glance, now: confirmedAt.addingTimeInterval(3600)), .stale(lastConfirmedAt: confirmedAt))
    }
}
