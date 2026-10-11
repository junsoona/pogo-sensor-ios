import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// What the app says about its own build (docs/versioning.md): the numbers come from the bundle,
/// a value the build did not record is "not known" rather than a guess, and a hub that says
/// nothing -- or nonsense -- about its own build is still the same hub.
@MainActor
final class AppBuildInfoTests: XCTestCase {
    typealias F = HubFixtures

    private let commit = "05375341f70d93c788b5f08889e312a023f83202"
    private let fingerprint = "381fa7d77f002d5205dbac720de17ce29f79701c1a6d07522c244395e54cda43"

    private func plist(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "2", "PogoBuildKind": "development", "PogoBuildCommit": commit,
            "PogoBuildDirty": "true", "PogoBuildSourceFingerprint": fingerprint, "PogoBuildID": "05375341f70d+dirty.381fa7d77f00",
        ]
        for (key, value) in overrides { info[key] = value }
        return info
    }

    // MARK: - The bundle's own values

    func testARecordedBuildIsReadAsItIs() {
        let info = AppBuildInfo(infoDictionary: plist())
        XCTAssertEqual(info.version, "1.0.0")
        XCTAssertEqual(info.buildNumber, "2")
        XCTAssertEqual(info.versionAndBuild, "1.0.0 (2)")
        XCTAssertEqual(info.kind, .development)
        XCTAssertEqual(info.commit, commit)
        XCTAssertEqual(info.isDirty, true)
        XCTAssertEqual(info.sourceFingerprint, fingerprint)
        XCTAssertEqual(info.buildID, "05375341f70d+dirty.381fa7d77f00")
        XCTAssertTrue(info.hasSourceIdentity)

        let release = AppBuildInfo(infoDictionary: plist(["PogoBuildKind": "release", "PogoBuildDirty": "false", "PogoBuildID": "05375341f70d.381fa7d77f00"]))
        XCTAssertEqual(release.kind, .release)
        XCTAssertEqual(release.isDirty, false)
        XCTAssertEqual(release.buildID, "05375341f70d.381fa7d77f00")
    }

    func testABuildThatWasNotMadeWithTheToolSaysUnknownAndNothingIsGuessed() {
        // What Version.xcconfig gives every build that does not pass the settings in.
        let unknown = ["PogoBuildKind": "unknown", "PogoBuildCommit": "unknown", "PogoBuildDirty": "unknown", "PogoBuildSourceFingerprint": "unknown", "PogoBuildID": "unknown"]
        let info = AppBuildInfo(infoDictionary: plist(unknown))
        XCTAssertEqual(info.version, "1.0.0", "the numbers are still the bundle's")
        XCTAssertEqual(info.buildNumber, "2")
        XCTAssertEqual(info.kind, .unknown, "never taken for a release")
        XCTAssertNil(info.commit)
        XCTAssertNil(info.isDirty)
        XCTAssertNil(info.sourceFingerprint)
        XCTAssertNil(info.buildID)
        XCTAssertFalse(info.hasSourceIdentity)

        let empty = AppBuildInfo(infoDictionary: nil)
        XCTAssertEqual(empty.version, AppBuildInfo.unknownValue)
        XCTAssertEqual(empty.buildNumber, AppBuildInfo.unknownValue)
        XCTAssertEqual(empty.kind, .unknown)
        XCTAssertFalse(empty.hasSourceIdentity)
    }

    func testMalformedValuesAreNotKnownRatherThanShownAsIfTheyWereReal() {
        let bad: [(String, Any)] = [
            ("PogoBuildCommit", "05375341f70d"),                               // a short SHA is not a commit
            ("PogoBuildCommit", commit.uppercased()),
            ("PogoBuildCommit", String(commit.dropLast()) + "g"),
            ("PogoBuildCommit", "$(POGO_BUILD_COMMIT)"),                       // a setting that was never expanded
            ("PogoBuildCommit", 5),
            ("PogoBuildSourceFingerprint", String(fingerprint.dropLast())),
            ("PogoBuildSourceFingerprint", fingerprint + "0"),
            ("PogoBuildDirty", "yes"),
            ("PogoBuildDirty", true),
            ("PogoBuildKind", "Release"),
            ("PogoBuildKind", "official"),
            ("PogoBuildID", "05375341f70d"),
            ("PogoBuildID", "05375341f70d+dirty.381fa7d77f0"),
            ("PogoBuildID", "05375341f70d+clean.381fa7d77f00"),
            ("PogoBuildID", "05375341f70d+dirty.381fa7d77f00.extra"),
            ("PogoBuildID", "1.0.0"),
        ]
        for (key, value) in bad {
            let info = AppBuildInfo(infoDictionary: plist([key: value]))
            switch key {
            case "PogoBuildCommit": XCTAssertNil(info.commit, "\(value)")
            case "PogoBuildSourceFingerprint": XCTAssertNil(info.sourceFingerprint, "\(value)")
            case "PogoBuildDirty": XCTAssertNil(info.isDirty, "\(value)")
            case "PogoBuildKind": XCTAssertEqual(info.kind, .unknown, "\(value)")
            default: XCTAssertNil(info.buildID, "\(value)")
            }
        }
        // A source bundle without Git: no commit, but the fingerprint is still the sources'.
        let bundle = AppBuildInfo(infoDictionary: plist(["PogoBuildCommit": "unknown", "PogoBuildDirty": "unknown", "PogoBuildID": "unknown.381fa7d77f00"]))
        XCTAssertNil(bundle.commit)
        XCTAssertEqual(bundle.buildID, "unknown.381fa7d77f00")
        XCTAssertTrue(bundle.hasSourceIdentity)
    }

    // MARK: - This very build

    private func isPlainVersion(_ text: String?) -> Bool {
        guard let parts = text?.split(separator: ".", omittingEmptySubsequences: false), parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) && ($0 == "0" || $0.first != "0") }
    }

    func testTheRunningAppHasAThreePartVersionAndANumericBuildNumber() throws {
        let info = AppBuildInfo.current
        XCTAssertTrue(isPlainVersion(info.version), "CFBundleShortVersionString is \(info.version)")
        let build = try XCTUnwrap(Int(info.buildNumber), "CFBundleVersion is \(info.buildNumber)")
        XCTAssertGreaterThanOrEqual(build, 2, "the build number never goes back below the baseline")
        XCTAssertFalse(info.version.contains("dev"))
        // Whatever the build recorded about its sources was expanded: never the raw "$(…)".
        for key in ["PogoBuildCommit", "PogoBuildDirty", "PogoBuildID", "PogoBuildKind", "PogoBuildSourceFingerprint"] {
            let value = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: key) as? String, "\(key) is missing from the app's Info.plist")
            XCTAssertFalse(value.isEmpty || value.contains("$("), "\(key) = \(value)")
        }
        if info.kind == .release {
            XCTAssertEqual(info.isDirty, false, "a release build comes from a clean tree")
            XCTAssertNotNil(info.commit)
        }
    }

    func testEveryBundleOfTheAppCarriesTheSameVersionAndBuildNumber() throws {
        let app = AppBuildInfo.current
        var checked = [String]()
        // The tests' own bundle, the widgets, and (where it is embedded) the Watch app and its widgets.
        var bundles = [Bundle(for: AppBuildInfoTests.self).bundleURL]
        let enumerator = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "appex" || url.pathExtension == "app" { bundles.append(url) }
        }
        for url in bundles {
            let plistURL = [url.appendingPathComponent("Info.plist"), url.appendingPathComponent("Contents/Info.plist")]
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let info = try XCTUnwrap(plistURL.flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }, url.lastPathComponent)
            XCTAssertEqual(info["CFBundleShortVersionString"] as? String, app.version, url.lastPathComponent)
            XCTAssertEqual(info["CFBundleVersion"] as? String, app.buildNumber, url.lastPathComponent)
            checked.append(url.lastPathComponent)
        }
        XCTAssertTrue(checked.contains { $0.hasSuffix(".appex") }, "the widgets are part of the app: \(checked)")
    }

    // MARK: - A hub's word about its own build

    private func health(extra: String) -> Data {
        Data("{\"schema_version\":1,\"service\":\"pogohome\",\"registry_generation\":3,\"module_count\":1,\"hub_id\":\"\(F.hubA)\"\(extra)}".utf8)
    }

    func testAHubFromBeforeTheBuildFieldIsRecognizedAsBefore() throws {
        let answer = try HubHealthCheck.verify(F.health(hubID: F.hubA), expectedHubID: F.hubA)
        XCTAssertEqual(answer.hubID, F.hubA)
        XCTAssertNil(answer.build, "an old hub says nothing about its build, and nothing is made up for it")
    }

    func testAHubThatReportsItsBuildIsReadAndStillRecognizedByItsID() throws {
        let extra = ",\"build\":{\"component\":\"linux_bridge\",\"version\":\"0.1.0\",\"build_id\":\"590e2a11d2cb+dirty.0123456789ab\",\"build_kind\":\"development\"}"
        let answer = try HubHealthCheck.verify(health(extra: extra), expectedHubID: F.hubA)
        XCTAssertEqual(answer.hubID, F.hubA)
        XCTAssertEqual(answer.build, HubBuildDTO(component: "linux_bridge", version: "0.1.0", buildID: "590e2a11d2cb+dirty.0123456789ab", buildKind: "development"))

        // Fields the app does not know, and a build with only the two required ones.
        let more = try HubHealthCheck.verify(health(extra: ",\"build\":{\"component\":\"linux_bridge\",\"version\":\"9.9.9\",\"future\":[1,2]},\"later\":true"), expectedHubID: F.hubA)
        XCTAssertEqual(more.build?.version, "9.9.9")
        XCTAssertNil(more.build?.buildID)
        XCTAssertNil(more.build?.buildKind)
    }

    func testABuildFieldThatIsNotTheDocumentedObjectNeverStopsAHubFromBeingRecognized() throws {
        let malformed = ["\"0.1.0\"", "7", "null", "[]", "{}", "{\"component\":\"linux_bridge\"}", "{\"component\":1,\"version\":2}", "{\"component\":\"linux_bridge\",\"version\":\"0.1.0\",\"build_id\":5}"]
        for build in malformed {
            let answer = try HubHealthCheck.verify(health(extra: ",\"build\":\(build)"), expectedHubID: F.hubA)
            XCTAssertEqual(answer.hubID, F.hubA, build)
            XCTAssertNil(answer.build, "not the documented object: \(build)")
        }
    }

    func testTheVersionAHubReportsDecidesNothing() {
        // The rules that accept or refuse a hub see the same thing whatever the hub says its build is.
        for version in ["0.0.1", "0.1.0", "99.0.0", "not-a-version"] {
            let extra = ",\"build\":{\"component\":\"linux_bridge\",\"version\":\"\(version)\"}"
            XCTAssertEqual(try? HubHealthCheck.verify(health(extra: extra), expectedHubID: F.hubA).hubID, F.hubA, version)
            XCTAssertThrowsError(try HubHealthCheck.verify(health(extra: extra), expectedHubID: F.hubB), version)
        }
    }

    // MARK: - Wording

    private typealias T = BuildDetailsText

    private var allTexts: [String] {
        [T.title, T.buildHeader, T.version, T.buildNumber, T.kindLabel, T.sourceHeader, T.buildID, T.commit, T.sourceStateLabel, T.fingerprint, T.unknown, T.sourceFooter]
            + [AppBuildInfo.Kind.development, .release].flatMap { [T.kind($0), T.kindFooter($0)] } + [T.kindFooter(.unknown)]
            + [T.sourceState(true), T.sourceState(false)]
    }

    func testEveryWordOfTheBuildDetailsIsTranslatedToEnglishAndSpanish() throws {
        guard AppLanguage.current == .korean else { throw XCTSkip("looks the Korean texts up; run in Korean") }
        for language in ["en", "es"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: "Localizable.strings", withExtension: nil, subdirectory: nil, localization: language))
            let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
            for text in allTexts {
                let translated = strings[text] as? String
                XCTAssertNotNil(translated, "\(language) has no translation for: \(text)")
                XCTAssertNotEqual(translated, text, "\(language): \(text)")
            }
        }
    }

    func testTheWordsAreInTheLanguageTheAppRunsInAndTellTheKindsApart() {
        let hangul = CharacterSet(charactersIn: "\u{AC00}"..."\u{D7A3}")
        for text in allTexts {
            XCTAssertFalse(text.isEmpty)
            if AppLanguage.current != .korean {
                XCTAssertNil(text.rangeOfCharacter(from: hangul), "left in Korean: \(text)")
            }
        }
        XCTAssertNotEqual(T.kind(.development), T.kind(.release))
        XCTAssertNotEqual(T.kind(.unknown), T.kind(.release), "a build of unknown kind is never worded as a release")
        XCTAssertEqual(Set([T.kindFooter(.development), T.kindFooter(.release), T.kindFooter(.unknown)]).count, 3)
        XCTAssertEqual(Set([T.sourceState(true), T.sourceState(false), T.sourceState(nil)]).count, 3)
    }

    // MARK: - Screens (only with TEST_RUNNER_POGO_SCREEN_RENDER_DIR)

    func testRenderBuildDetails() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let platform = PlatformSupport.isMacCatalyst ? "mac" : UIDevice.current.userInterfaceIdiom == .phone ? "iphone" : "ipad"
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.width ?? 375
        let width = PlatformSupport.isMacCatalyst ? 480 : min(screen, 504)
        let states: [(String, AppBuildInfo)] = [
            ("development", AppBuildInfo(infoDictionary: plist())),
            ("release", AppBuildInfo(infoDictionary: plist(["PogoBuildKind": "release", "PogoBuildDirty": "false", "PogoBuildID": "05375341f70d.381fa7d77f00"]))),
            ("unknown", AppBuildInfo(infoDictionary: plist(["PogoBuildKind": "unknown", "PogoBuildCommit": "unknown", "PogoBuildDirty": "unknown", "PogoBuildSourceFingerprint": "unknown", "PogoBuildID": "unknown"]))),
        ]
        for (name, info) in states {
            for (variant, contentSize) in [("regular", UIContentSizeCategory.large), ("axxl", .accessibilityExtraExtraExtraLarge)] {
                let view = NavigationStack { BuildDetailsView(info: info) }
                try await render(view, size: CGSize(width: width, height: 900), contentSize: contentSize,
                                 to: output.appendingPathComponent("\(language)-\(platform)-build-details-\(name)-\(variant).png"))
            }
        }
    }

    private func render(_ view: some View, size: CGSize, contentSize: UIContentSizeCategory, to url: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        host.traitOverrides.horizontalSizeClass = .compact
        host.traitOverrides.preferredContentSizeCategory = contentSize
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(900))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        window.isHidden = true
        window.rootViewController = nil
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
