import SwiftData
import XCTest
@testable import PogoHome

/// The PogoHome-only home name shown as the Dashboard title (Settings → 집 이름).
@MainActor
final class HomeNameTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(SwiftDataHomeConfigurationStore.modelTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testDefaultHomeNameFollowsTheLanguage() {
        XCTAssertEqual(HomeConfigurationDefaults.homeName(in: .korean), "우리 집")
        XCTAssertEqual(HomeConfigurationDefaults.homeName(in: .english), "My Home")
        XCTAssertEqual(HomeConfigurationDefaults.homeName(in: .spanish), "Mi casa")

        for language in AppLanguage.supported {
            let model = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: language), language: language)
            XCTAssertEqual(model.homeName, HomeConfigurationDefaults.homeName(in: language))
            XCTAssertNil(model.customHomeName)
        }
    }

    func testSavedNameIsShownImmediatelyAndVerbatim() async throws {
        let model = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean)
        try await model.updateHomeName(input: "  바닷가 별장  ")
        XCTAssertEqual(model.homeName, "바닷가 별장", "the Dashboard title reads `homeName`, so it updates without a relaunch")
        XCTAssertEqual(model.customHomeName, "바닷가 별장", "the editor pre-fills exactly the stored name")
    }

    func testEmptyOrDefaultInputGoesBackToTheLocalizedDefault() async throws {
        let model = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: .english), language: .english)
        try await model.updateHomeName(input: "Cabin")
        try await model.updateHomeName(input: "   ")
        XCTAssertNil(model.customHomeName)
        XCTAssertEqual(model.homeName, "My Home")

        try await model.updateHomeName(input: "My Home")
        XCTAssertNil(model.customHomeName, "retyping the default keeps following the language")
    }

    func testOverlongNameIsRejectedAndKeepsThePreviousName() async throws {
        let model = AppModel(dataSource: MockSensorDataSource(), configurationStore: InMemoryHomeConfigurationStore(language: .korean), language: .korean)
        try await model.updateHomeName(input: "본가")
        let overlong = String(repeating: "집", count: HomeConfigurationValidation.maximumNameLength + 1)
        await XCTAssertThrowsErrorAsync(try await model.updateHomeName(input: overlong)) { error in
            XCTAssertEqual(error as? HomeConfigurationError, .nameTooLong(maximum: HomeConfigurationValidation.maximumNameLength))
        }
        XCTAssertEqual(model.homeName, "본가")
    }

    func testCustomNameSurvivesRelaunchAndLanguageChange() async throws {
        let container = try makeContainer()
        let first = AppModel(
            dataSource: MockSensorDataSource(),
            configurationStore: try SwiftDataHomeConfigurationStore(container: container, language: .korean),
            language: .korean
        )
        try await first.updateHomeName(input: "바닷가 별장")

        let relaunchedInSpanish = AppModel(
            dataSource: MockSensorDataSource(),
            configurationStore: try SwiftDataHomeConfigurationStore(container: container, language: .spanish),
            language: .spanish
        )
        XCTAssertEqual(relaunchedInSpanish.homeName, "바닷가 별장", "a typed home name is never translated")

        try await relaunchedInSpanish.updateHomeName(input: "")
        let relaunchedInEnglish = AppModel(
            dataSource: MockSensorDataSource(),
            configurationStore: try SwiftDataHomeConfigurationStore(container: container, language: .english),
            language: .english
        )
        XCTAssertEqual(relaunchedInEnglish.homeName, "My Home")
    }

    /// Reconnecting (Settings URL/mode change, or the Linux service restarting and the stream
    /// resuming) replaces sensor data only — never the local home name.
    func testHomeNameIsUnaffectedByDataSourceReplacementAndNewSnapshots() async throws {
        let model = AppModel(
            dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)),
            configurationStore: InMemoryHomeConfigurationStore(language: .korean),
            language: .korean
        )
        try await model.updateHomeName(input: "작업실 집")
        model.start()
        try await waitUntil { !model.snapshot.modules.isEmpty }
        model.replace(dataSource: MockSensorDataSource(tickInterval: .milliseconds(20)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.homeName, "작업실 집")
        model.stop()
    }
}
