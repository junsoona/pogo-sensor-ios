import SwiftUI
import UIKit

/// The few things that differ between iPhone/iPad and the Mac Catalyst build.
enum PlatformSupport {
    static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Where the user grants PogoHome access to Apple Home data: the app's own page in Settings
    /// on iPhone/iPad, System Settings › Privacy & Security › Home on the Mac (the iOS settings
    /// URL doesn't reach that pane there).
    static var appleHomePermissionSettingsURL: URL? {
        #if targetEnvironment(macCatalyst)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_HomeKit")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    /// Shown by "Find hubs" when Local Network access is off: browsing can't see any hub then.
    static var localNetworkDeniedMessage: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "로컬 네트워크 권한이 없어 허브를 찾을 수 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 조각보 홈을 켜세요.", comment: "Mac: hub discovery without Local Network permission")
        #else
        String(localized: "로컬 네트워크 권한이 없어 허브를 찾을 수 없습니다. 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 조각보 홈을 켜세요.", comment: "iPhone/iPad: hub discovery without Local Network permission")
        #endif
    }

    /// Where Local Network access is turned on: the app's own Settings page on iPhone/iPad, the
    /// Local Network privacy pane on the Mac.
    static var localNetworkSettingsURL: URL? {
        #if targetEnvironment(macCatalyst)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }

    /// Where the user allows PogoHome to reach the Linux bridge on the local network. There's
    /// no API to read that permission, so the app can only point to it when it can't connect.
    static var localNetworkPermissionHint: String {
        #if targetEnvironment(macCatalyst)
        String(localized: "연결되지 않으면 이 Mac이 Linux Bridge와 같은 네트워크에 있는지, 시스템 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 조각보 홈이 켜져 있는지 확인하세요.", comment: "Mac: hint shown while Live mode isn't connected")
        #else
        String(localized: "연결되지 않으면 이 기기가 Linux Bridge와 같은 Wi-Fi에 있는지, 설정 > 개인정보 보호 및 보안 > 로컬 네트워크에서 조각보 홈이 켜져 있는지 확인하세요.", comment: "iPhone/iPad: hint shown while Live mode isn't connected")
        #endif
    }
}

extension View {
    /// Keeps a Mac window from shrinking below `size`. Narrower windows (and iPad windows at any
    /// size) are handled by the layouts themselves; this only stops a Mac window from being
    /// dragged so small that no layout can hold the tab bar and a card.
    func macMinimumWindowSize(_ size: CGSize) -> some View {
        #if targetEnvironment(macCatalyst)
        background(WindowSceneSizeRestrictor(minimumSize: size).frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}

extension View {
    /// Mac: puts a tab's navigation bar back into the window's title bar each time the tab is
    /// shown. A tab shown again at another window size than it was last shown at (the window
    /// resized from another tab) otherwise came back with its bar as a second row under the title
    /// bar, which kept the app's or the other tab's title. Hiding and showing the bar once makes
    /// UIKit place it again. Nothing elsewhere.
    func placesNavigationBarInMacTitleBar() -> some View {
        #if targetEnvironment(macCatalyst)
        background(NavigationBarTitlebarPlacer().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct NavigationBarTitlebarPlacer: UIViewRepresentable {
    func makeUIView(context: Context) -> PlacerView { PlacerView() }
    func updateUIView(_ uiView: PlacerView, context: Context) {}

    final class PlacerView: UIView {
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            // After the tab switch has put the tab's views in place.
            DispatchQueue.main.async { [weak self] in
                guard let navigation = self?.tabNavigationController() else { return }
                navigation.setNavigationBarHidden(true, animated: false)
                navigation.setNavigationBarHidden(false, animated: false)
            }
        }

        /// The tab's navigation stack: the first navigation controller under the view controller
        /// that shows this view (the tab's).
        private func tabNavigationController() -> UINavigationController? {
            var responder: UIResponder? = next
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let owner = responder as? UIViewController else { return nil }
            return owner.navigationController ?? Self.firstNavigationController(in: owner)
        }

        private static func firstNavigationController(in controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController { return navigation }
            for child in controller.children {
                if let navigation = firstNavigationController(in: child) { return navigation }
            }
            return nil
        }
    }
}

private struct WindowSceneSizeRestrictor: UIViewRepresentable {
    let minimumSize: CGSize

    func makeUIView(context: Context) -> RestrictorView {
        RestrictorView(minimumSize: minimumSize)
    }

    func updateUIView(_ uiView: RestrictorView, context: Context) {}

    final class RestrictorView: UIView {
        private let minimumSize: CGSize

        init(minimumSize: CGSize) {
            self.minimumSize = minimumSize
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.windowScene?.sizeRestrictions?.minimumSize = minimumSize
        }
    }
}
#endif
