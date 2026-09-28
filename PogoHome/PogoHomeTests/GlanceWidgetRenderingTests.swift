import SwiftUI
import XCTest
@testable import PogoHome

/// Renders every widget layout and state to PNG for visual review — only when
/// `POGO_WIDGET_RENDER_DIR` is set (pass `TEST_RUNNER_POGO_WIDGET_RENDER_DIR=…` to
/// `xcodebuild test`, with `-testLanguage ko|en|es` for each language). Always checks that
/// every combination lays out at all.
@MainActor
final class GlanceWidgetRenderingTests: XCTestCase {
    private typealias F = GlanceFixtures

    private static let sizes: [GlanceWidgetLayout: CGSize] = [
        .small: CGSize(width: 170, height: 170),
        .medium: CGSize(width: 364, height: 170),
        .circular: CGSize(width: 76, height: 76),
        .rectangular: CGSize(width: 172, height: 76),
        .inline: CGSize(width: 257, height: 26),
    ]

    private let now = Date()

    private func glance(
        _ modules: [SensorModule] = [F.climate(), F.air()],
        health: HomeHealthState = .healthy,
        appleHome: HomeGlanceBuilder.AppleHomeInput = F.appleHomeInput([AppleHomeFixtures.light(), temperatureSensor(), contactSensor()]),
        at date: Date? = nil
    ) -> HomeGlanceSnapshot {
        let at = date ?? now
        return HomeGlanceBuilder.build(
            homeName: String(localized: "우리 집"),
            pogo: F.pogoInput(F.home(modules), health: health, lastSyncAt: at, sessionStartedAt: at.addingTimeInterval(-1)),
            appleHome: appleHome,
            previous: nil,
            now: at
        )
    }

    private static let contactID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private static let contactStateID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!

    /// `AppleHomeFixtures.sensor()` with a read time of now (the shared fixture's is fixed).
    private static func temperatureSensor() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: AppleHomeFixtures.sensorID, homeID: AppleHomeFixtures.homeID, name: "PMS5003", roomID: AppleHomeFixtures.bedroomID, roomName: "침실",
            isReachable: true, isBridged: true, isMatter: true,
            services: [AppleHomeService(id: UUID(), kind: .temperatureSensor, name: "온도", characteristics: [
                AppleHomeCharacteristic(id: AppleHomeFixtures.temperatureID, kind: .currentTemperature, value: .double(23.4), confirmedAt: Date()),
            ])]
        )
    }

    private static func contactSensor() -> AppleHomeAccessory {
        AppleHomeAccessory(
            id: contactID, homeID: AppleHomeFixtures.homeID, name: "현관문", roomID: AppleHomeFixtures.livingRoomID, roomName: "현관",
            isReachable: true,
            services: [AppleHomeService(id: UUID(), kind: .contactSensor, name: "문", characteristics: [
                AppleHomeCharacteristic(id: contactStateID, kind: .contactState, value: .int(1), confirmedAt: Date()),
            ])]
        )
    }

    private var homeStates: [(String, HomeGlanceStore.LoadResult)] {
        var unverified = glance()
        unverified.pogo.state = .unverified
        return [
            ("healthy", .snapshot(glance())),
            ("attention", .snapshot(glance([F.climate(), F.air(online: false)], health: .attentionNeeded, appleHome: F.appleHomeInput([AppleHomeFixtures.light(reachable: false), Self.temperatureSensor()])))),
            ("unverified", .snapshot(unverified)),
            ("stale", .snapshot(glance(at: now.addingTimeInterval(-3 * 3600)))),
            ("appleHomeDenied", .snapshot(glance(appleHome: F.appleHomeInput(state: .denied)))),
            ("noData", .missing),
        ]
    }

    private var sensorStates: [(String, HomeGlanceStore.LoadResult, HomeGlanceValueID?)] {
        var unverified = glance()
        unverified.pogo.state = .unverified
        let contact = HomeGlanceValueID.appleHome(accessory: Self.contactID, characteristic: Self.contactStateID)
        return [
            ("pogoRecent", .snapshot(glance()), F.temperatureID),
            ("pogoStale", .snapshot(glance(at: now.addingTimeInterval(-26 * 3600))), F.temperatureID),
            ("pogoUnverified", .snapshot(unverified), F.temperatureID),
            ("pogoOffline", .snapshot(glance([F.climate(online: false)], health: .attentionNeeded)), F.temperatureID),
            ("appleHomeRecent", .snapshot(glance()), F.appleHomeTemperatureID),
            ("appleHomeContact", .snapshot(glance()), contact),
            ("appleHomeNotRead", .snapshot(glance(appleHome: F.appleHomeInput([AppleHomeFixtures.sensor(temperature: nil)]))), F.appleHomeTemperatureID),
            ("appleHomeDenied", .snapshot(glance(appleHome: F.appleHomeInput(state: .denied))), F.appleHomeTemperatureID),
            ("deleted", .snapshot(glance([F.air()])), F.temperatureID),
            ("notConfigured", .snapshot(glance()), nil),
            ("noData", .missing, F.temperatureID),
        ]
    }

    func testRenderEveryLayoutAndState() throws {
        let outputDirectory = ProcessInfo.processInfo.environment["POGO_WIDGET_RENDER_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        if let outputDirectory {
            try FileManager.default.createDirectory(at: outputDirectory.appending(path: language), withIntermediateDirectories: true)
        }

        let variants: [(String, ColorScheme, DynamicTypeSize, Bool)] = [
            ("light", .light, .large, false),
            ("dark", .dark, .large, false),
            ("largeText", .light, .accessibility2, false),
            ("locked", .dark, .large, true),
        ]
        var rendered = 0
        for (variantName, scheme, typeSize, locked) in variants {
            for layout in GlanceWidgetLayout.allCases where !locked || layout.isAccessory {
                for (name, content) in homeStates {
                    let view = HomeStatusGlanceView(content: content, now: now, layout: layout)
                    try render(view, layout: layout, scheme: scheme, typeSize: typeSize, locked: locked, file: "home-\(name)-\(layout)-\(variantName)", into: outputDirectory?.appending(path: language))
                    rendered += 1
                }
                for (name, content, id) in sensorStates where layout != .medium {
                    let view = SensorGlanceView(content: content, selection: id?.stringValue, now: now, layout: layout)
                    try render(view, layout: layout, scheme: scheme, typeSize: typeSize, locked: locked, file: "sensor-\(name)-\(layout)-\(variantName)", into: outputDirectory?.appending(path: language))
                    rendered += 1
                }
            }
        }
        XCTAssertGreaterThan(rendered, 100)
    }

    private func render(
        _ view: some View,
        layout: GlanceWidgetLayout,
        scheme: ColorScheme,
        typeSize: DynamicTypeSize,
        locked: Bool,
        file: String,
        into directory: URL?
    ) throws {
        let size = Self.sizes[layout]!
        let padding: CGFloat = layout.isAccessory ? 0 : 16
        let framed = view
            .padding(padding)
            .frame(width: size.width, height: size.height)
            .background(layout.isAccessory ? Color.black : Color(uiColor: .systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: layout.isAccessory ? (layout == .circular ? size.width / 2 : 8) : 22, style: .continuous))
            .foregroundStyle(layout.isAccessory ? Color.white : Color.primary)
            .redacted(reason: locked ? .privacy : [])
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, typeSize)
            .padding(6)
            .background(Color.gray.opacity(0.3))
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, file)
        guard let directory else { return }
        try XCTUnwrap(image.pngData()).write(to: directory.appending(path: "\(file).png"))
    }
}
