import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Renders the app's tabs and editor sheets, in real windows of this test host, to PNG for visual
/// review of the iPad and Mac layouts — only when `POGO_SCREEN_RENDER_DIR` is set (pass
/// `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to `xcodebuild test`). Run it on an iPad simulator
/// and on "My Mac (Mac Catalyst)"; the file names say which.
///
/// The data is fixed: two Power Bases (one offline), the preview rooms, and the preview Apple
/// Home (a light, a sensor, an unreachable outlet).
@MainActor
final class AdaptiveScreenRenderingTests: XCTestCase {
    private struct Variant {
        let name: String
        let size: CGSize
        var style: UIUserInterfaceStyle = .light
        /// `nil` keeps the device's own (always regular on the Mac).
        var horizontalSizeClass: UIUserInterfaceSizeClass?
        var contentSize: UIContentSizeCategory = .large
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    private var platform: String {
        PlatformSupport.isMacCatalyst ? "mac" : isPhone ? "iphone" : "ipad"
    }

    private var tabVariants: [Variant] {
        if PlatformSupport.isMacCatalyst {
            return [
                Variant(name: "wide-light", size: CGSize(width: 1180, height: 780)),
                Variant(name: "wide-dark", size: CGSize(width: 1180, height: 780), style: .dark),
                Variant(name: "medium-light", size: CGSize(width: 820, height: 700)),
                Variant(name: "narrow-dark", size: CGSize(width: 520, height: 700), style: .dark),
                Variant(name: "wide-axxl-light", size: CGSize(width: 1180, height: 780), contentSize: .accessibilityExtraExtraExtraLarge),
            ]
        }
        if isPhone {
            // The phone layout must be unchanged: compact width, card grids, tab bar.
            let portrait = UIScreen.main.bounds.size
            return [
                Variant(name: "portrait-light", size: portrait, horizontalSizeClass: .compact),
                Variant(name: "portrait-dark", size: portrait, style: .dark, horizontalSizeClass: .compact),
                Variant(name: "portrait-axxl-light", size: portrait, horizontalSizeClass: .compact, contentSize: .accessibilityExtraExtraExtraLarge),
            ]
        }
        return [
            Variant(name: "landscape-light", size: CGSize(width: 1194, height: 834)),
            Variant(name: "landscape-dark", size: CGSize(width: 1194, height: 834), style: .dark),
            Variant(name: "portrait-light", size: CGSize(width: 834, height: 1194)),
            Variant(name: "portrait-dark", size: CGSize(width: 834, height: 1194), style: .dark),
            // Split View / Slide Over and small iPadOS windows are compact.
            Variant(name: "splitview-light", size: CGSize(width: 504, height: 834), horizontalSizeClass: .compact),
            Variant(name: "splitview-dark", size: CGSize(width: 504, height: 834), style: .dark, horizontalSizeClass: .compact),
            Variant(name: "portrait-axxl-light", size: CGSize(width: 834, height: 1194), contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    private var sheetVariants: [Variant] {
        if isPhone {
            let portrait = UIScreen.main.bounds.size
            return [
                Variant(name: "light", size: portrait, horizontalSizeClass: .compact),
                Variant(name: "dark", size: portrait, style: .dark, horizontalSizeClass: .compact),
            ]
        }
        return [
            Variant(name: "light", size: CGSize(width: 580, height: 760)),
            Variant(name: "dark", size: CGSize(width: 580, height: 760), style: .dark),
            Variant(name: "axxl-light", size: CGSize(width: 580, height: 760), contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    func testRenderTabsAndSheets() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let tabs: [(String, AppNavigator.Tab)] = [("1-home", .home), ("2-rooms", .rooms), ("3-devices", .devices), ("4-settings", .settings)]
        for variant in tabVariants {
            for (tabName, tab) in tabs {
                let models = Self.makeModels()
                let navigator = AppNavigator()
                navigator.selectedTab = tab
                let view = AppRootView()
                    .environment(models.app)
                    .environment(models.appleHome)
                    .environment(navigator)
                try await render(view, variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(tabName)-\(variant.name).png"))
            }
        }

        let module = try XCTUnwrap(Self.makeModels().app.snapshot.modules.first)
        let sheets: [(String, () -> AnyView)] = [
            ("sheet-room-editor", { AnyView(RoomEditorSheet(mode: .create)) }),
            ("sheet-module-editor", { AnyView(ModuleEditorSheet(moduleID: module.id)) }),
            ("sheet-add-device", { AnyView(AddDeviceSheet()) }),
            ("sheet-power-base", { AnyView(NavigationStack { PowerBaseConnectionView() }) }),
            ("sheet-home-name", { AnyView(HomeNameEditorSheet()) }),
            ("sheet-room-management", { AnyView(NavigationStack { RoomManagementView() }) }),
        ]
        for variant in sheetVariants {
            for (sheetName, makeSheet) in sheets {
                let models = Self.makeModels()
                let view = makeSheet()
                    .environment(models.app)
                    .environment(models.appleHome)
                try await render(view, variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(sheetName)-\(variant.name).png"))
            }
            // Add Device as this device's real HomeKit reports it (on a Mac before macOS 27:
            // setup unavailable, with the explanation), over the same preview Apple Home.
            let models = Self.makeModels(setupSupport: HomeKitAppleHomeProvider().accessorySetupSupport)
            let view = AddDeviceSheet()
                .environment(models.app)
                .environment(models.appleHome)
            try await render(view, variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-sheet-add-device-this-os-\(variant.name).png"))
        }

        // Settings › Apple Watch and its value picker exist only where a Watch can pair.
        if isPhone {
            let defaults = UserDefaults.standard
            let savedSelection = defaults.stringArray(forKey: WatchSettingsKeys.selectedValueIDs)
            defer { defaults.set(savedSelection, forKey: WatchSettingsKeys.selectedValueIDs) }
            PhoneWatchSettings.setSelection([GlanceFixtures.temperatureID.stringValue, GlanceFixtures.appleHomeTemperatureID.stringValue], in: defaults)
            for variant in sheetVariants {
                let models = Self.makeModels()
                let store = InMemoryGlanceStore()
                store.snapshot = GlanceFixtures.build(pogo: GlanceFixtures.pogoInput(GlanceFixtures.home([GlanceFixtures.climate(), GlanceFixtures.air()])), now: Date())
                let publisher = HomeGlancePublisher(appModel: models.app, appleHome: models.appleHome, store: store, reloader: CountingReloader(), isSimulatedData: { false })
                let relay = PhoneWatchRelay(appModel: models.app, publisher: publisher)
                relay.activate()
                let screens: [(String, AnyView)] = [
                    ("settings-watch", AnyView(NavigationStack { List { WatchSettingsSection() } })),
                    ("watch-value-picker", AnyView(NavigationStack { WatchValuePickerView() })),
                ]
                for (name, screen) in screens {
                    let view = screen
                        .environment(models.app)
                        .environment(models.appleHome)
                        .environment(publisher)
                        .environment(relay)
                    try await render(view, variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(name)-\(variant.name).png"))
                }
            }
        }
    }

    /// Settings › 앱 정보 (the tab, tall enough to reach the bottom) and the name story it opens.
    func testRenderNameMeaning() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let width = PlatformSupport.isMacCatalyst ? 820 : isPhone ? UIScreen.main.bounds.width : 834
        let variants = tabVariants + [
            Variant(name: "tall-light", size: CGSize(width: width, height: 2600), horizontalSizeClass: isPhone ? .compact : nil),
            Variant(name: "tall-axxl-light", size: CGSize(width: width, height: 2600), horizontalSizeClass: isPhone ? .compact : nil, contentSize: .accessibilityExtraExtraExtraLarge),
        ]
        for variant in variants {
            let models = Self.makeModels()
            let screens: [(String, AnyView)] = [
                ("name-meaning", AnyView(NavigationStack { NameMeaningView() })),
                ("settings", AnyView(SettingsView())),
            ]
            for (name, screen) in screens {
                try await render(screen.environment(models.app).environment(models.appleHome), variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(language)-\(name)-\(variant.name).png"))
            }
        }
    }

    /// The lists behind the Dashboard's tiles and Apple Home card, their empty and unverified
    /// states, and the Apple Home detail screen's feature and same-sensor sections — each pushed
    /// on the Dashboard's own stack, exactly as a tap would.
    func testRenderDashboardListsAndDeviceDetails() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"

        let issues = Self.issueRichAppleHome()
        let firstModule = try XCTUnwrap(Self.makeModels().app.snapshot.modules.first)
        let empty = HomeSnapshot(timestamp: Date(), rooms: MockSensorFixtures.rooms, modules: [])
        let base = Self.makeModels().app.snapshot
        let allOffline = HomeSnapshot(
            timestamp: Date(),
            rooms: base.rooms,
            modules: base.modules.map { module in
                SensorModule(id: module.id, name: module.name, hardwareName: module.hardwareName, roomID: module.roomID, readings: module.readings, isOnline: false, lastSeen: module.lastSeen)
            }
        )
        let fine = AppleHomeSnapshot(
            accessState: .ready,
            homes: PreviewAppleHomeProvider.sampleSnapshot.homes,
            accessories: PreviewAppleHomeProvider.sampleSnapshot.accessories.filter(\.isReachable)
        )
        typealias Screen = (name: String, pogo: HomeSnapshot?, appleHome: AppleHomeSnapshot?, link: (UUID, UUID)?, starts: Bool, path: [AnyHashable])
        let screens: [Screen] = [
            ("home-with-issues", nil, issues, nil, true, []),
            ("list-online", nil, nil, nil, true, [DashboardRoute.onlineModules]),
            ("list-attention", nil, nil, nil, true, [DashboardRoute.attention]),
            ("list-readings", nil, nil, nil, true, [DashboardRoute.readings]),
            ("list-applehome-issues", nil, issues, nil, true, [DashboardRoute.appleHomeIssues]),
            ("list-online-empty", empty, nil, nil, true, [DashboardRoute.onlineModules]),
            ("list-online-all-offline", allOffline, nil, nil, true, [DashboardRoute.onlineModules]),
            ("list-readings-empty", empty, nil, nil, true, [DashboardRoute.readings]),
            ("list-attention-unverified", nil, nil, nil, false, [DashboardRoute.attention]),
            ("list-applehome-issues-empty", nil, fine, nil, true, [DashboardRoute.appleHomeIssues]),
            ("detail-applehome-only", nil, issues, nil, true, [DashboardRoute.appleHomeIssues, AppleHomeRoute.accessory(Self.thermostatID)]),
            ("detail-partial", nil, issues, nil, true, [AppleHomeRoute.accessory(Self.tvLightID)]),
            ("detail-same-sensor-unlinked", nil, nil, nil, true, [AppleHomeRoute.accessory(Self.previewSensorID)]),
            ("detail-same-sensor-linked", nil, nil, (Self.previewSensorID, firstModule.id), true, [AppleHomeRoute.accessory(Self.previewSensorID)]),
            ("detail-module-from-readings", nil, nil, nil, true, [DashboardRoute.readings, AppRoute.module(firstModule.id)]),
        ]
        let variants: [Variant] = isPhone
            // A tall window as well, to see sections below the first screen.
            ? tabVariants + [Variant(name: "tall-light", size: CGSize(width: UIScreen.main.bounds.width, height: 2400), horizontalSizeClass: .compact)]
            : [Variant(name: "narrow-light", size: CGSize(width: 390, height: 844), horizontalSizeClass: .compact),
               Variant(name: "narrow-dark", size: CGSize(width: 390, height: 844), style: .dark, horizontalSizeClass: .compact)]
        for variant in variants {
            for screen in screens {
                let suite = "PogoHome.tests.dashboardRendering.\(UUID().uuidString)"
                defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
                let models = Self.makeModels(pogo: screen.pogo, appleHome: screen.appleHome, defaultsSuite: suite, starts: screen.starts)
                if let (accessoryID, moduleID) = screen.link {
                    models.appleHome.link(accessoryID: accessoryID, toPogoModule: moduleID)
                }
                let navigator = AppNavigator()
                var path = NavigationPath()
                for route in screen.path {
                    if let route = route as? DashboardRoute { path.append(route) }
                    if let route = route as? AppleHomeRoute { path.append(route) }
                    if let route = route as? AppRoute { path.append(route) }
                }
                navigator.dashboardPath = path
                // `AppRootView` starts the data source; a screen that must stay unverified is
                // rendered on its own.
                let view = screen.starts
                    ? AnyView(AppRootView().environment(navigator))
                    : AnyView(NavigationStack { DashboardAttentionView() })
                try await render(view.environment(models.app).environment(models.appleHome), variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(language)-\(screen.name)-\(variant.name).png"))
            }
        }
    }

    /// The Devices tab's sensor cards with the texts that stress a card: a name of two lines, a
    /// long room name, no room, a chain position of two lines and none at all, an offline module
    /// and an offline Power Base — one PNG per screenful (`…-p1.png`, `…-p2.png`, …), at the
    /// default and the largest text size. Add `-testLanguage ko|en|es`.
    func testRenderDeviceCards() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        // The phone's width, taller than its screen: fewer pages, the same cards.
        let tall = CGSize(width: UIScreen.main.bounds.width, height: 1500)
        let variants: [Variant] = isPhone
            ? [Variant(name: "light", size: tall, horizontalSizeClass: .compact),
               Variant(name: "dark", size: tall, style: .dark, horizontalSizeClass: .compact),
               Variant(name: "axxl-light", size: tall, horizontalSizeClass: .compact, contentSize: .accessibilityExtraExtraExtraLarge)]
            : tabVariants
        for variant in variants {
            let suite = "PogoHome.tests.deviceCardRendering.\(UUID().uuidString)"
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            let models = Self.makeDeviceCardModels(language: language, defaultsSuite: suite)
            let navigator = AppNavigator()
            navigator.selectedTab = .devices
            let view = AppRootView()
                .environment(models.app)
                .environment(models.appleHome)
                .environment(navigator)
            try await render(view, variant: variant, to: outputDirectory.appendingPathComponent("\(platform)-\(language)-device-cards-\(variant.name).png"), paged: true)
        }
    }

    // MARK: - Rendering

    /// `paged`: one PNG per screenful of the screen's list, named `<url>-p<n>.png`.
    private func render(_ view: some View, variant: Variant, to url: URL, paged: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        #if targetEnvironment(macCatalyst)
        // A Mac window's size is the scene's; resize the scene itself.
        scene.sizeRestrictions?.minimumSize = CGSize(width: 300, height: 300)
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 40, y: 40), size: variant.size)))
        try await Task.sleep(for: .milliseconds(600))
        #endif
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: variant.size)
        let host = UIHostingController(rootView: view)
        host.traitOverrides.userInterfaceStyle = variant.style
        host.traitOverrides.preferredContentSizeCategory = variant.contentSize
        if let sizeClass = variant.horizontalSizeClass {
            host.traitOverrides.horizontalSizeClass = sizeClass
        }
        window.overrideUserInterfaceStyle = variant.style
        window.rootViewController = host
        window.makeKeyAndVisible()
        // Lets `.task` / `.onAppear` run (first-row selection, Apple Home snapshot) and lists load.
        try await Task.sleep(for: .milliseconds(900))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = 2
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        func draw(to url: URL) throws {
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: url)
        }
        guard paged else { return try draw(to: url) }
        let scrollView = Self.scrollViews(in: window).max { $0.contentSize.height < $1.contentSize.height }
        let base = url.deletingPathExtension().lastPathComponent
        var page = 1
        while true {
            try draw(to: url.deletingLastPathComponent().appendingPathComponent("\(base)-p\(page).png"))
            guard let scrollView, page < 40 else { break }
            let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            let current = scrollView.contentOffset.y
            guard current < maxOffset - 1 else { break }
            // Overlap a little, so no card falls between two pages.
            scrollView.setContentOffset(CGPoint(x: 0, y: min(current + scrollView.bounds.height * 0.7, maxOffset)), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            page += 1
        }
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    // MARK: - Fixtures

    private static let previewSensorID = UUID(uuidString: "A0000000-0000-0000-0000-000000000020")!
    private static let thermostatID = UUID(uuidString: "A0000000-0000-0000-0000-0000000000F1")!
    private static let tvLightID = UUID(uuidString: "A0000000-0000-0000-0000-0000000000F2")!

    /// The preview Apple Home plus one accessory per line of the Dashboard card (read failed,
    /// retrying, first read, blocked), a device nothing of which is shown here, and a light that
    /// also has a feature only the Home app offers.
    private static func issueRichAppleHome() -> AppleHomeSnapshot {
        let sample = PreviewAppleHomeProvider.sampleSnapshot
        let homeID = PreviewAppleHomeProvider.homeID
        let roomID = UUID(uuidString: "A0000000-0000-0000-0000-0000000000B1")!
        func sensor(_ n: Int, _ name: String, blocked: Bool = false, error: String? = nil, autoRead: AppleHomeAutoReadState? = nil) -> AppleHomeAccessory {
            AppleHomeAccessory(
                id: UUID(uuidString: "A0000000-0000-0000-0000-0000000000E\(n)")!,
                homeID: homeID, name: name, roomID: roomID, roomName: "거실",
                isReachable: true, isBlocked: blocked, isMatter: true,
                services: [AppleHomeService(id: UUID(), kind: .humiditySensor, name: name, characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .currentRelativeHumidity, value: error == nil && autoRead == nil ? .double(41) : nil, confirmedAt: error == nil && autoRead == nil ? Date() : nil),
                ])],
                lastReadError: error,
                autoRead: autoRead
            )
        }
        let thermostat = AppleHomeAccessory(
            id: thermostatID, homeID: homeID, name: "보일러", roomID: roomID, roomName: "거실", isReachable: true,
            services: [AppleHomeService(id: UUID(), kind: .other, name: "보일러", typeDescription: "Thermostat", characteristics: [], unsupportedCharacteristicCount: 4)]
        )
        let tvLight = AppleHomeAccessory(
            id: tvLightID, homeID: homeID, name: "TV 조명", roomID: roomID, roomName: "거실", isReachable: true, isMatter: true,
            services: [
                AppleHomeService(id: UUID(), kind: .lightbulb, name: "TV 조명", characteristics: [
                    AppleHomeCharacteristic(id: UUID(), kind: .powerState, isWritable: true, value: .bool(true), confirmedAt: Date()),
                ]),
                AppleHomeService(id: UUID(), kind: .other, name: "장면 버튼", typeDescription: "Stateless Programmable Switch", characteristics: []),
                AppleHomeService(id: UUID(), kind: .other, name: "Identify", typeDescription: "Identify", isUserInteractive: false, characteristics: []),
            ]
        )
        return AppleHomeSnapshot(
            accessState: .ready,
            homes: sample.homes,
            accessories: sample.accessories + [
                sensor(1, "욕실 습도", error: String(localized: "값을 제시간에 읽지 못했습니다.", comment: "Apple Home: reading a value timed out (the accessory may still be listed as responding)")),
                sensor(2, "현관 습도", autoRead: .waiting(nextAttempt: 2, maxAttempts: 3)),
                sensor(3, "주방 습도", autoRead: .waiting(nextAttempt: 1, maxAttempts: 3)),
                sensor(4, "창고 센서", blocked: true),
                thermostat,
                tvLight,
            ]
        )
    }

    private static func makeModels(pogo: HomeSnapshot?, appleHome: AppleHomeSnapshot?, defaultsSuite: String, starts: Bool) -> (app: AppModel, appleHome: AppleHomeModel) {
        let base = makeModels()
        let snapshot = pogo ?? base.app.snapshot
        let app = AppModel(
            dataSource: StaticSensorDataSource(snapshot: snapshot),
            initialSnapshot: snapshot,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        if starts { app.start() }
        let model = AppleHomeModel(
            provider: PreviewAppleHomeProvider(snapshot: appleHome ?? PreviewAppleHomeProvider.sampleSnapshot),
            defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard
        )
        model.enable()
        return (app, model)
    }

    /// Seven modules for `testRenderDeviceCards`: four chained on an online Power Base, one on an
    /// offline Base and two the hub lists without a Base (no chain position). No Apple Home.
    private static func makeDeviceCardModels(language: String, defaultsSuite: String) -> (app: AppModel, appleHome: AppleHomeModel) {
        func text(_ ko: String, _ en: String, _ es: String) -> String {
            language == "en" ? en : language == "es" ? es : ko
        }
        let study = Room(id: UUID(), name: text("컴퓨터 방", "Computer Room", "Sala del ordenador"), symbolName: "desktopcomputer", sortOrder: 0)
        let longRoom = Room(
            id: UUID(),
            name: text("2층 남쪽 베란다 옆 작은 작업실 겸 서재", "Small Upstairs Workshop and Study by the South Balcony", "Pequeño taller y estudio junto al balcón sur de la planta alta"),
            symbolName: "books.vertical.fill", sortOrder: 1
        )
        // Not among the rooms: the card says "방 미지정".
        let noRoom = UUID()
        let gas = text("SGP41 가스 센서", "SGP41 Gas Sensor", "Sensor de gases SGP41")
        let particles = text("PMS5003 미세먼지 센서", "PMS5003 Particle Sensor", "Sensor de partículas PMS5003")
        let long = text(
            "안방 창가 온습도·조도 통합 측정 모듈 2호",
            "Master Bedroom Window Temperature, Humidity and Light Module No. 2",
            "Módulo de temperatura, humedad y luz de la ventana del dormitorio principal n.º 2"
        )
        let light = text("조도 센서", "Light Sensor", "Sensor de luz")
        let climate = text("온습도 센서", "Climate Sensor", "Sensor de clima")

        let baseA = "a0a0a0fffe000001"
        let baseB = "b0b0b0fffe000002"
        let readings = MockSensorFixtures.modules(referenceDate: Date()).map(\.readings)
        func identifier(_ number: Int) -> String { String(format: "744dbdfffe65%04x", number) }
        func module(_ number: Int, _ name: String, room: UUID, isOnline: Bool = true, base: String?, parent: String?) -> SensorModule {
            SensorModule(
                id: UUID(uuidString: String(format: "8A3B1C10-00%02d-4000-8000-0000000000%02d", number, number))!,
                name: name,
                hardwareIdentifier: identifier(number),
                roomID: room,
                readings: readings[number % readings.count],
                isOnline: isOnline,
                lastSeen: Date(),
                powerBaseIdentifier: base,
                parentIdentifier: parent
            )
        }
        let modules = [
            module(1, gas, room: study.id, base: baseA, parent: baseA),
            module(2, particles, room: study.id, base: baseA, parent: identifier(1)),
            module(3, long, room: longRoom.id, base: baseA, parent: identifier(2)),
            module(4, light, room: noRoom, isOnline: false, base: baseA, parent: identifier(3)),
            module(5, climate, room: study.id, isOnline: false, base: baseB, parent: baseB),
            module(6, light, room: longRoom.id, base: nil, parent: nil),
            module(7, long, room: noRoom, base: nil, parent: nil),
        ]
        let snapshot = HomeSnapshot(
            timestamp: Date(),
            rooms: [study, longRoom],
            modules: modules,
            powerBases: [
                PowerBase(hardwareIdentifier: baseA, isOnline: true, moduleCount: 4, onlineModuleCount: 3),
                PowerBase(hardwareIdentifier: baseB, isOnline: false, moduleCount: 1, onlineModuleCount: 0),
            ],
            reportsPowerBases: true
        )
        let app = AppModel(
            dataSource: StaticSensorDataSource(snapshot: snapshot),
            initialSnapshot: snapshot,
            configurationStore: InMemoryHomeConfigurationStore(rooms: [study, longRoom])
        )
        app.start()
        let appleHome = AppleHomeModel(
            provider: PreviewAppleHomeProvider(snapshot: AppleHomeSnapshot(accessState: .ready, homes: [], accessories: [])),
            defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard
        )
        appleHome.enable()
        return (app, appleHome)
    }

    /// A POGO home on two Power Bases — the second offline — plus the preview Apple Home.
    private static func makeModels(setupSupport: AppleHomeAccessorySetupSupport = .available) -> (app: AppModel, appleHome: AppleHomeModel) {
        let preview = MockSensorFixtures.previewSnapshot
        let baseA = "a0a0a0fffe000001"
        let baseB = "b0b0b0fffe000002"
        let modules = preview.modules.enumerated().map { index, module in
            let onA = index < (preview.modules.count + 1) / 2
            let identifier = module.hardwareIdentifier ?? String(format: "744dbdfffe65%04x", index + 1)
            let previous = index == 0 || index == (preview.modules.count + 1) / 2
                ? nil
                : preview.modules[index - 1].hardwareIdentifier ?? String(format: "744dbdfffe65%04x", index)
            return SensorModule(
                id: module.id,
                name: module.name,
                hardwareName: module.hardwareName,
                hardwareIdentifier: identifier,
                roomID: module.roomID,
                readings: module.readings,
                isOnline: onA ? module.isOnline : false,
                lastSeen: module.lastSeen,
                roleDescription: module.roleDescription,
                powerBaseIdentifier: onA ? baseA : baseB,
                parentIdentifier: previous ?? (onA ? baseA : baseB)
            )
        }
        let countA = modules.filter { $0.powerBaseIdentifier == baseA }.count
        let countB = modules.count - countA
        let snapshot = HomeSnapshot(
            timestamp: Date(),
            rooms: preview.rooms,
            modules: modules,
            powerBases: [
                PowerBase(hardwareIdentifier: baseA, isOnline: true, moduleCount: countA, onlineModuleCount: modules.filter { $0.powerBaseIdentifier == baseA && $0.isOnline }.count),
                PowerBase(hardwareIdentifier: baseB, isOnline: false, moduleCount: countB, onlineModuleCount: 0),
            ],
            reportsPowerBases: true
        )
        let app = AppModel(
            dataSource: StaticSensorDataSource(snapshot: snapshot),
            initialSnapshot: snapshot,
            configurationStore: InMemoryHomeConfigurationStore()
        )
        // `.connected` and the snapshot arrive from the data source once `AppRootView` starts it.
        app.start()
        let appleHome = AppleHomeModel(
            provider: SetupSupportOverridingProvider(base: PreviewAppleHomeProvider(), setupSupport: setupSupport),
            defaults: UserDefaults(suiteName: "PogoHome.tests.screenRendering") ?? .standard
        )
        appleHome.enable()
        return (app, appleHome)
    }
}

/// Serves one fixed snapshot and never changes it, so a render shows exactly the fixture.
private struct StaticSensorDataSource: SensorDataSource {
    let snapshot: HomeSnapshot

    func currentSnapshot() async throws -> HomeSnapshot { snapshot }

    func updates() -> AsyncStream<HomeSnapshot> {
        AsyncStream { continuation in
            continuation.yield(snapshot)
        }
    }
}

/// The preview Apple Home, with the accessory-setup availability a test chooses.
@MainActor
private final class SetupSupportOverridingProvider: AppleHomeProvider {
    private let base: PreviewAppleHomeProvider
    let accessorySetupSupport: AppleHomeAccessorySetupSupport

    init(base: PreviewAppleHomeProvider, setupSupport: AppleHomeAccessorySetupSupport) {
        self.base = base
        self.accessorySetupSupport = setupSupport
    }

    var isAccessorySetupAvailable: Bool { accessorySetupSupport.isAvailable }
    func start(onChange: @escaping @MainActor (AppleHomeSnapshot) -> Void) { base.start(onChange: onChange) }
    func stop() { base.stop() }
    func refresh(accessoryID: UUID) async throws { try await base.refresh(accessoryID: accessoryID) }
    func write(_ value: AppleHomeRawValue, characteristicID: UUID, accessoryID: UUID) async throws {
        try await base.write(value, characteristicID: characteristicID, accessoryID: accessoryID)
    }
    func performAccessorySetup() async throws -> AppleHomeSetupResult { try await base.performAccessorySetup() }
}
