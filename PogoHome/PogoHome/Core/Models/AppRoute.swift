import Foundation

/// The one `Hashable` type every `NavigationStack` in this app pushes room/module
/// destinations as.
///
/// Root/room ids and module ids are both plain `UUID`s. Two independent
/// `navigationDestination(for: UUID.self)` modifiers at different depths of the *same*
/// `NavigationStack` — one at a stack's root resolving room ids, another declared inside a
/// pushed detail view (e.g. `RoomDetailView`) resolving module ids — is exactly the "미지정
/// 공간 상세 화면이 빈 화면" bug: `NavigationStack` cannot tell which `navigationDestination`
/// a bare `UUID` push was meant for, so a module id pushed from inside a room's detail view
/// can resolve against the ROOM destination handler instead, look up a room with that id,
/// find none, and render nothing.
///
/// `AppRoute` fixes this at the type level: every screen that can navigate to a room or a
/// module (`RoomsView`, `DevicesView`, `DashboardView`) declares exactly ONE
/// `navigationDestination(for: AppRoute.self)` at its own `NavigationStack` root, and every
/// pushed-in view that links further (`RoomDetailView`) only ever constructs `AppRoute`
/// values — it never declares its own `navigationDestination` — so there is only ever one
/// handler per stack, for one type, and it is always unambiguous which case a push means.
enum AppRoute: Hashable {
    case room(UUID)
    case module(UUID)
}
