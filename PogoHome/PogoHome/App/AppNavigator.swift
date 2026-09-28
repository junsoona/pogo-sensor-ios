import SwiftUI
import Observation

/// The selected tab and the Dashboard's navigation stack, so a widget tap (`HomeGlanceLink`)
/// can open the screen it shows.
@MainActor
@Observable
final class AppNavigator {
    enum Tab: Hashable {
        case home
        case rooms
        case devices
        case settings
    }

    var selectedTab: Tab = .home
    var dashboardPath = NavigationPath()

    /// Opens a glance link. A device that no longer exists (or isn't loaded yet) lands on its
    /// detail screen's own "not found / not synchronized yet" state, never a blank screen.
    func open(_ link: HomeGlanceLink) {
        switch link {
        case .dashboard:
            selectedTab = .home
            dashboardPath = NavigationPath()
        case let .device(id):
            var path = NavigationPath()
            switch id.source {
            case .pogoLinuxAPI:
                path.append(AppRoute.module(id.rawValue))
            case .appleHome:
                path.append(AppleHomeRoute.accessory(id.rawValue))
            }
            selectedTab = .home
            dashboardPath = path
        case .devices:
            selectedTab = .devices
        }
    }

    /// Returns `false` for a URL that isn't a PogoHome link.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = HomeGlanceLink(url: url) else { return false }
        open(link)
        return true
    }
}
