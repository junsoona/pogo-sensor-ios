import UIKit

/// Resolves a persisted SF Symbol name to one guaranteed to render on the running OS.
///
/// Room icons are persisted by name (`Room.symbolName`) across app/OS versions, so a name
/// saved on a newer OS (or a future icon catalog addition) must never crash or render blank
/// on an older one. Every read site that turns a stored symbol name into an `Image` should
/// go through this rather than constructing `Image(systemName:)` directly.
nonisolated enum SymbolAvailability {
    static let fallback = "square.dashed"

    /// `name` if `UIImage(systemName:)` can actually produce it on this OS, else `fallback`.
    /// A real runtime check rather than a compile-time `#available` guess, since SF Symbol
    /// availability doesn't line up cleanly with OS version numbers a call site could easily
    /// keep in sync with.
    static func resolvedName(for name: String) -> String {
        UIImage(systemName: name) != nil ? name : fallback
    }
}
