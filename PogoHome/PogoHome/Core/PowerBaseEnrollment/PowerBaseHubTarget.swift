import Foundation

/// The hub the app reads now, as Power Base enrollment and removal see it. Only a hub picked in
/// "Find hubs" (it has a `hub_id`), with a known address, that this device is paired with can be
/// asked to enroll or unenroll a Power Base; requests then use this device's own credential for
/// that hub and its pinned certificate.
///
/// Shared by the product screens and the DEBUG enrollment tests, so the rule is one rule.
nonisolated struct PowerBaseHubTarget: Equatable, Sendable {
    var hubID: String?
    var baseURL: URL?
    var isSimulated: Bool
    /// This device holds a credential for `hubID`.
    var isPaired: Bool

    static let none = PowerBaseHubTarget(hubID: nil, baseURL: nil, isSimulated: false, isPaired: false)

    /// Why this source can't be used; `nil` when it can.
    var ineligibility: PowerBaseHubIneligibility? {
        if isSimulated { return .simulatedData }
        guard hubID != nil else { return .typedAddress }
        guard baseURL != nil else { return .noAddress }
        guard isPaired else { return .notPaired }
        return nil
    }
}

/// Why enrollment or removal can't start with the current source.
nonisolated enum PowerBaseHubIneligibility: Equatable, Sendable {
    case simulatedData
    /// A typed address, not a hub picked in "Find hubs" (no `hub_id`).
    case typedAddress
    case noAddress
    case notPaired
}

extension PowerBaseHubTarget {
    /// The source the app reads now.
    @MainActor
    init(appModel: AppModel) {
        let identity = appModel.sourceIdentity
        let shared = appModel.sharedSettings
        let hubID = identity.hubID
        self.init(
            hubID: hubID,
            baseURL: hubID == nil ? nil : appModel.sourceAddress,
            isSimulated: identity.isSimulated,
            isPaired: hubID != nil && shared.hubID == hubID && shared.isPaired
        )
    }
}
