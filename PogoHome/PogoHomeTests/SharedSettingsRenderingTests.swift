import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// PNGs of the settings-sharing UI for visual review — only with `TEST_RUNNER_POGO_SCREEN_RENDER_DIR`.
/// Settings while sharing and while the hub is off, the upload review, and an editor whose save is
/// off with the reason.
@MainActor
final class SharedSettingsRenderingTests: XCTestCase {
    func testRenderSharedSettingsStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"
        let width = UIScreen.main.bounds.width

        let hub = FakeSettingsHub()
        let phone = SimulatedDevice(hub: hub)
        _ = hub.createCode()
        _ = try await phone.controller.pair(code: "7KQM3XWDPA9T", deviceName: "iPhone")
        let summary = phone.model.sharedSettingsUploadSummary()
        _ = try await phone.controller.uploadAsFirstSettings(summary.document)
        try await phone.model.updateHomeName(input: "바닷가 집")

        try await render(SettingsView().environment(phone.model).environment(AppleHomeModel.preview), size: CGSize(width: width, height: 2400), to: output.appendingPathComponent("\(language)-settings-shared.png"))
        try await render(NavigationStack { Form { SharedSettingsSummarySections(summary: summary) } }.environment(phone.model), size: CGSize(width: width, height: 1200), to: output.appendingPathComponent("\(language)-upload-summary.png"))

        hub.isReachable = false
        phone.controller.connectionStatusDidChange(.failed("offline"))
        try await render(SettingsView().environment(phone.model).environment(AppleHomeModel.preview), size: CGSize(width: width, height: 2400), to: output.appendingPathComponent("\(language)-settings-offline.png"))
        try await render(HomeNameEditorSheet().environment(phone.model), size: CGSize(width: width, height: 900), to: output.appendingPathComponent("\(language)-editor-blocked.png"))
    }

    private func render(_ view: some View, size: CGSize, to url: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: view)
        host.traitOverrides.horizontalSizeClass = .compact
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
