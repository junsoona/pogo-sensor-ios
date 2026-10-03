#if DEBUG
import SwiftUI
import UIKit
import XCTest
@testable import PogoHome

/// Renders the DEBUG "Power Base 등록 시험" section in each state to PNG, for checking that buttons,
/// the PSKd and the states are never cut off — only when `POGO_SCREEN_RENDER_DIR` is set (pass
/// `TEST_RUNNER_POGO_SCREEN_RENDER_DIR=…` to `xcodebuild test`; add `-testLanguage en|es` for the
/// other languages). Run it on a small iPhone and on "My Mac (Mac Catalyst)". Nothing is sent
/// anywhere: every session comes from a scripted hub.
@MainActor
final class PowerBaseEnrollmentRenderingTests: XCTestCase {
    private struct Variant {
        let name: String
        let size: CGSize
        var contentSize: UIContentSizeCategory = .large
        var style: UIUserInterfaceStyle = .light
    }

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var platform: String { PlatformSupport.isMacCatalyst ? "mac" : isPhone ? "iphone" : "ipad" }

    private var variants: [Variant] {
        if PlatformSupport.isMacCatalyst {
            return [
                Variant(name: "narrow", size: CGSize(width: 480, height: 1500)),
                Variant(name: "wide-dark", size: CGSize(width: 820, height: 1300), style: .dark),
                Variant(name: "narrow-axxl", size: CGSize(width: 480, height: 1400), contentSize: .accessibilityExtraExtraExtraLarge),
            ]
        }
        let screenWidth = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen.bounds.width ?? 375
        let width = isPhone ? screenWidth : 504
        return [
            Variant(name: "regular", size: CGSize(width: width, height: 1600)),
            Variant(name: "axxl", size: CGSize(width: width, height: 1600), contentSize: .accessibilityExtraExtraExtraLarge),
        ]
    }

    func testRenderEnrollmentTestStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["POGO_SCREEN_RENDER_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SCREEN_RENDER_DIR to render screens")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "ko"

        for variant in variants {
            for state in ["not-paired", "invalid-input", "running", "earlier-session", "expired", "heartbeat", "failed", "certificate"] {
                let (controller, input) = try await makeController(for: state)
                let view = NavigationStack {
                    List {
                        PowerBaseEnrollmentTestSection(controller: controller, eui64Input: .constant(input))
                    }
                    .sheetListSpacing()
                    .navigationTitle(Text(verbatim: state))
                    .navigationBarTitleDisplayMode(.inline)
                }
                try await render(view, variant: variant, named: "\(platform)-\(language)-enrollment-\(state)-\(variant.name)", in: output)
                controller.leave()
            }
        }
    }

    private func makeController(for state: String) async throws -> (PowerBaseEnrollmentController, String) {
        let hub = FakeEnrollmentHub()
        let credentials = InMemoryHubCredentialStore([EnrollmentFixtures.credential()])
        let controller = PowerBaseEnrollmentController(transport: hub, credentials: credentials, clipboard: FakeEnrollmentClipboard(), pollInterval: .seconds(30))
        var target = EnrollmentFixtures.pairedTarget()
        let input = EnrollmentFixtures.eui64
        switch state {
        case "not-paired":
            target.isPaired = false
            controller.targetDidChange(target)
            return (controller, "")
        case "invalid-input":
            controller.targetDidChange(target)
            return (controller, "00:12:4b:00:01")
        case "running":
            hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
            hub.scriptStatus(.failure(.unreachable("timeout")))
        case "earlier-session":
            hub.scriptStart(.failure(.enrollmentInProgress(ownSession: EnrollmentFixtures.session(.waitingForHeartbeat, id: EnrollmentFixtures.otherSessionID))))
        case "expired":
            hub.scriptStart(.success(EnrollmentFixtures.session(.expired, joinerEntry: "removed")))
        case "heartbeat":
            hub.scriptStart(.success(EnrollmentFixtures.session(.heartbeatReceived, joinerEntry: "removed")))
        case "failed":
            hub.scriptStart(.success(EnrollmentFixtures.session(.failed, error: "commissioner_rejected", joinerEntry: "remove_failed")))
        default:
            hub.scriptStart(.failure(.certificateMismatch))
        }
        controller.targetDidChange(target)
        controller.start(eui64: input)
        try await eventually { controller.phase != .starting }
        if state == "running" {
            // Shows the "status check failed, session continues" row as well.
            let fast = PowerBaseEnrollmentController(transport: hub, credentials: credentials, clipboard: FakeEnrollmentClipboard(), pollInterval: .milliseconds(10))
            controller.leave()
            hub.scriptStart(.success(EnrollmentFixtures.session(.waitingForHeartbeat)))
            fast.targetDidChange(target)
            fast.start(eui64: input)
            try await eventually { fast.pollProblem != nil }
            return (fast, input)
        }
        return (controller, input)
    }

    /// One PNG per screenful, scrolling the list until its end (very tall windows draw blank).
    private func render(_ view: some View, variant: Variant, named name: String, in directory: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        #if targetEnvironment(macCatalyst)
        scene.sizeRestrictions?.minimumSize = CGSize(width: 300, height: 300)
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 40, y: 40), size: variant.size)))
        try await Task.sleep(for: .milliseconds(600))
        #endif
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: variant.size)
        let host = UIHostingController(rootView: view)
        host.traitOverrides.userInterfaceStyle = variant.style
        host.traitOverrides.preferredContentSizeCategory = variant.contentSize
        if isPhone { host.traitOverrides.horizontalSizeClass = .compact }
        window.overrideUserInterfaceStyle = variant.style
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let bounds = window.bounds
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        format.scale = 1
        let scrollView = Self.firstScrollView(in: window)
        var page = 1
        while true {
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name)-p\(page).png"))
            guard let scrollView, page < 8 else { break }
            let maxOffset = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            let current = scrollView.contentOffset.y
            guard current < maxOffset - 1 else { break }
            // Overlap a little, so no line falls between two pages.
            scrollView.setContentOffset(CGPoint(x: 0, y: min(current + scrollView.bounds.height * 0.8, maxOffset)), animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            page += 1
        }
        window.isHidden = true
        window.rootViewController = nil
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView, scrollView.contentSize.height > 0 { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
#endif
