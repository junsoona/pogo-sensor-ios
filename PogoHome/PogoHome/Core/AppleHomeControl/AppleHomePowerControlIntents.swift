import AppIntents
import Foundation

// The App Intents behind the Control Center power toggle. Compiled into the app and the widget
// extension: the extension needs the types to build the control, the app runs the toggle.
// See `AppleHomePowerControlModels.swift` for who does what.

/// An Apple Home device the control can switch, identified by `AppleHomePowerTargetID`.
nonisolated struct AppleHomePowerTargetEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Apple 홈 전원 기기", comment: "Control Center: an Apple Home device the power control switches")
    )
    static let defaultQuery = AppleHomePowerTargetQuery()

    /// `AppleHomePowerTargetID.stringValue`.
    let id: String
    let name: String
    let subtitle: String

    var targetID: AppleHomePowerTargetID? { AppleHomePowerTargetID(stringValue: id) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(id: String, name: String, subtitle: String) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
    }

    init(_ target: AppleHomePowerTarget, showsHomeName: Bool) {
        let place = [showsHomeName ? target.homeName : nil, target.roomName].compactMap { $0 }
        self.init(
            id: target.id.stringValue,
            name: target.name,
            subtitle: ([target.kind.label] + place).joined(separator: " · ")
        )
    }
}

/// Offers only what the app last found eligible in Apple Home (lights, outlets and switches with
/// exactly one readable and writable on/off control). Reads the stored catalog only, so it works
/// in the widget extension; the toggle itself checks the target again in HomeKit.
nonisolated struct AppleHomePowerTargetQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AppleHomePowerTargetEntity] {
        Self.entities(for: identifiers, in: Self.load())
    }

    func entities(matching string: String) async throws -> [AppleHomePowerTargetEntity] {
        Self.selectable(in: Self.load()).filter {
            $0.name.localizedStandardContains(string) || $0.subtitle.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [AppleHomePowerTargetEntity] {
        Self.selectable(in: Self.load())
    }

    private static func load() -> AppleHomePowerStore.LoadResult {
        AppleHomePowerStore.shared()?.load() ?? .missing
    }

    static func selectable(in load: AppleHomePowerStore.LoadResult) -> [AppleHomePowerTargetEntity] {
        guard let catalog = load.catalog, catalog.availability == .ready else { return [] }
        let showsHomeName = Set(catalog.targets.map(\.id.homeID)).count > 1
        return catalog.targets.map { AppleHomePowerTargetEntity($0, showsHomeName: showsHomeName) }
    }

    /// Every identifier resolves, so a configured control keeps its target (and says it's
    /// unavailable) instead of silently losing it.
    static func entities(for identifiers: [String], in load: AppleHomePowerStore.LoadResult) -> [AppleHomePowerTargetEntity] {
        let selectable = selectable(in: load)
        return identifiers.compactMap { id in
            if let entity = selectable.first(where: { $0.id == id }) { return entity }
            guard AppleHomePowerTargetID(stringValue: id) != nil else { return nil }
            let name = load.catalog?.knownNames[id]
                ?? String(localized: "Apple 홈 전원 기기", comment: "Control Center: an Apple Home device the power control switches")
            return AppleHomePowerTargetEntity(
                id: id,
                name: name,
                subtitle: String(localized: "사용할 수 없음", comment: "Control Center value: the target can't be used")
            )
        }
    }
}

/// The control's configuration: which device it switches.
struct SelectAppleHomePowerTargetIntent: ControlConfigurationIntent {
    static let title = LocalizedStringResource("Apple 홈 기기 선택", comment: "Control configuration title")
    static let description = IntentDescription(
        LocalizedStringResource("제어 센터에서 켜고 끌 조명, 콘센트 또는 스위치를 고릅니다.", comment: "Control configuration description")
    )
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("대상 기기", comment: "Control configuration parameter: the device"))
    var target: AppleHomePowerTargetEntity?

    init() {}

    init(target: AppleHomePowerTargetEntity?) {
        self.target = target
    }
}

/// The toggle's action. Runs only in the app process (`allowedExecutionTargets`), launched in
/// the background if needed — HomeKit refuses a widget extension. It needs the iPhone to be
/// unlocked (`authenticationPolicy`), so it never runs against a locked HomeKit.
///
/// `value` is the state the person asked for. `isShownStateKnown` is `false` when the control
/// showed no state; then the tap only reads the device and nothing is written.
struct SetAppleHomePowerIntent: SetValueIntent {
    static let title = LocalizedStringResource("Apple 홈 기기 켜기/끄기", comment: "Control action title")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: LocalizedStringResource("대상 기기", comment: "Control configuration parameter: the device"))
    var target: AppleHomePowerTargetEntity?

    @Parameter(title: LocalizedStringResource("켜짐", comment: "Apple Home: on"))
    var value: Bool

    @Parameter(title: LocalizedStringResource("표시된 상태", comment: "Control action parameter: whether the control showed a known state"), default: true)
    var isShownStateKnown: Bool

    init() {}

    init(target: AppleHomePowerTargetEntity?, isShownStateKnown: Bool) {
        self.target = target
        self.isShownStateKnown = isShownStateKnown
    }

    func perform() async throws -> some IntentResult {
        try await Self.run(target: target?.targetID, requestedOn: value, isShownStateKnown: isShownStateKnown)
        return .result()
    }

    private static func run(target: AppleHomePowerTargetID?, requestedOn: Bool, isShownStateKnown: Bool) async throws {
        #if POGO_WIDGET_EXTENSION
        // HomeKit refuses the widget extension; never pretend the tap did anything here.
        throw AppleHomePowerFailure.requiresApp
        #else
        try await AppleHomePowerControlRunner.shared.perform(target: target, requestedOn: requestedOn, isShownStateKnown: isShownStateKnown)
        #endif
    }
}

extension AppleHomePowerFailure: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { messageResource }
}
