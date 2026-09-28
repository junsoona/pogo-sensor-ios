import Foundation

/// What a device tile's icon may do for an Apple Home accessory. Decided from
/// `AppleHomeCapabilities.controls(of:)` only, so the tile offers nothing the detail screen
/// wouldn't.
///
/// The icon toggles only when there is exactly one on/off control (`.power` or `.active`),
/// HomeKit marks it readable and writable, the accessory responds, and its current state has
/// been read back. Every other case sends nothing: an unread state asks for a read, and several
/// on/off controls (e.g. a power strip's outlets) leave the choice to the detail screen.
nonisolated enum AppleHomeQuickControl: Hashable, Sendable {
    /// Tapping sends the opposite of `isOn`.
    case toggle(DeviceAvailableControl, isOn: Bool)
    /// One on/off control whose current state isn't known (never read, or a write whose
    /// result couldn't be read back).
    case needsStateCheck(DeviceAvailableControl)
    /// One on/off control, but the accessory doesn't respond (or Apple Home isn't available).
    case unavailable(DeviceAvailableControl)
    /// More than one on/off control — which one the icon means would be a guess.
    case multipleControls(count: Int)
    /// Nothing on it can be switched on or off (sensors, locks, read-only characteristics).
    case readOnly

    static func onOffControls(of accessory: AppleHomeAccessory) -> [DeviceAvailableControl] {
        AppleHomeCapabilities.controls(of: accessory).filter { $0.kind == .power || $0.kind == .active }
    }

    /// - Parameter confirmedValue: the value to trust for a control (see
    ///   `AppleHomeModel.confirmedValue(of:accessoryID:)`); `nil` = unknown.
    static func resolve(
        _ accessory: AppleHomeAccessory,
        isAccessReady: Bool,
        confirmedValue: (DeviceAvailableControl) -> DeviceControlValue?
    ) -> AppleHomeQuickControl {
        let controls = onOffControls(of: accessory)
        guard let control = controls.first else { return .readOnly }
        guard controls.count == 1 else { return .multipleControls(count: controls.count) }
        guard isAccessReady, accessory.isOperable, control.isEnabled else { return .unavailable(control) }
        guard case let .bool(isOn)? = confirmedValue(control) else { return .needsStateCheck(control) }
        return .toggle(control, isOn: isOn)
    }

    var control: DeviceAvailableControl? {
        switch self {
        case let .toggle(control, _), let .needsStateCheck(control), let .unavailable(control): return control
        case .multipleControls, .readOnly: return nil
        }
    }
}

/// The two separate tap targets of an Apple Home tile. The tile body always opens the detail
/// screen; the icon does `iconAction`.
nonisolated enum AppleHomeTileAction: Hashable, Sendable {
    case send(DeviceCommand)
    /// Read the accessory again to learn its state; nothing is written.
    case readState(accessoryID: UUID)
    case openDetail(AppleHomeRoute)
    /// The icon is shown but does nothing (the accessory doesn't respond).
    case none

    static func bodyAction(for accessory: AppleHomeAccessory) -> AppleHomeTileAction {
        .openDetail(.accessory(accessory.id))
    }

    static func iconAction(for accessory: AppleHomeAccessory, quickControl: AppleHomeQuickControl) -> AppleHomeTileAction {
        switch quickControl {
        case let .toggle(control, isOn):
            return .send(DeviceCommand(device: .appleHomeAccessory(accessory.id), controlID: control.id, kind: control.kind, value: .bool(!isOn)))
        case .needsStateCheck:
            return .readState(accessoryID: accessory.id)
        case .unavailable:
            return .none
        case .multipleControls, .readOnly:
            return .openDetail(.accessory(accessory.id))
        }
    }
}

/// Navigation values for Apple Home screens. A separate type from `AppRoute` (whose ids are
/// POGO room/module UUIDs) so an Apple Home id can never resolve to a POGO screen.
nonisolated enum AppleHomeRoute: Hashable, Sendable {
    case accessory(UUID)
    case room(AppleHomeRoomKey)
}

/// The Dashboard's Apple Home verdict, kept apart from the POGO `HomeHealthState`: POGO health
/// never counts Apple Home devices, and this never counts POGO sensors.
nonisolated enum AppleHomeStatusSummary: Equatable, Sendable {
    /// Apple Home isn't readable right now (off, loading, denied, restricted, unsupported);
    /// nothing is known about its devices.
    case unavailable(AppleHomeAccessState)
    case noHome
    case noDevices
    case allResponding(total: Int)
    case someNotResponding(notResponding: Int, total: Int)

    static func evaluate(state: AppleHomeAccessState, layout: AppleHomeLayout) -> AppleHomeStatusSummary {
        switch state {
        case .ready:
            let accessories = layout.visibleAccessories
            guard !accessories.isEmpty else { return .noDevices }
            // The same verdict as the list behind the card (`AppleHomeIssueList`).
            let notResponding = AppleHomeIssueList.evaluate(accessories).count(.notResponding)
            return notResponding == 0
                ? .allResponding(total: accessories.count)
                : .someNotResponding(notResponding: notResponding, total: accessories.count)
        case .noHome:
            return .noHome
        case .off, .unsupported, .loading, .denied, .restricted:
            return .unavailable(state)
        }
    }

    /// Only a readable Apple Home with every listed device responding counts as fine.
    var isVerifiedFine: Bool {
        if case .allResponding = self { return true }
        return false
    }
}
