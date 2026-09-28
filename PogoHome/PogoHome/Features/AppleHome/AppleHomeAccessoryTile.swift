import SwiftUI

/// One Apple Home accessory as a tile — the same component on the Dashboard, in an Apple Home
/// room, and in the Devices tab.
///
/// Two separate tap targets, laid side by side in a `ZStack` rather than nested:
/// - the tile body is a `NavigationLink` to the accessory's detail screen;
/// - the device icon on top of it runs `AppleHomeTileAction.iconAction` — switch on/off when
///   that is unambiguous (`AppleHomeQuickControl.toggle`), read the state again when it isn't
///   known, and otherwise it isn't a button at all (taps fall through to the body).
///
/// State shown is only what the device reported: "on"/"off" appear (as icon color *and* text)
/// only after being read back; a running command shows "turning on…" with a spinner, never the
/// requested state; a failed or unconfirmed command leaves its message on the tile.
struct AppleHomeAccessoryTile: View {
    @Environment(AppleHomeModel.self) private var appleHome
    let accessory: AppleHomeAccessory
    /// Off inside a room's own screen, where the room is the title.
    var showsRoom = true

    var body: some View {
        let quick = appleHome.quickControl(for: accessory)
        let isBusy = appleHome.isQuickControlBusy(accessory)
        ZStack(alignment: .topLeading) {
            NavigationLink(value: AppleHomeRoute.accessory(accessory.id)) {
                AppleHomeTileBody(accessory: accessory, quick: quick, isBusy: isBusy, showsRoom: showsRoom)
            }
            .buttonStyle(.plain)
            .accessibilitySortPriority(1)

            AppleHomeTileIcon(accessory: accessory, quick: quick, isBusy: isBusy)
                .padding(PogoTheme.cardPadding - AppleHomeTileIcon.hitSlop)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Wording shared by the tile's visible text and its VoiceOver description.
enum AppleHomeTileText {
    static func roomName(of accessory: AppleHomeAccessory) -> String {
        accessory.roomName ?? String(localized: "방 미지정", comment: "Device card: module has no room")
    }

    /// The tile's state line; `nil` when there is nothing current to say.
    static func state(
        of accessory: AppleHomeAccessory,
        quick: AppleHomeQuickControl,
        pending: DeviceControlValue?,
        isReading: Bool
    ) -> String? {
        if let pending, let control = quick.control {
            return AppleHomeControlText.pending(pending, kind: control.kind)
        }
        if isReading {
            return String(localized: "상태 확인 중…", comment: "Apple Home tile: reading the device's state")
        }
        if !accessory.isOperable {
            return AppleHomeText.connection(of: accessory)
        }
        switch quick {
        case let .toggle(control, isOn):
            return AppleHomeControlText.state(.bool(isOn), kind: control.kind)
        case .needsStateCheck:
            return String(localized: "상태 미확인 · 아이콘을 눌러 확인", comment: "Apple Home tile: on/off state not known; tapping the icon reads it")
        case let .multipleControls(count):
            return String(localized: "전원 제어 \(count)개 · 상세 화면에서 제어", comment: "Apple Home tile: several on/off controls (always 2 or more); control them on the detail screen")
        case .unavailable:
            return AppleHomeText.connection(of: accessory)
        case .readOnly:
            return AppleHomeCapabilities.values(of: accessory).first { $0.displayValue != nil }
                .map { String(localized: "\($0.label) \($0.displayValue ?? "")", comment: "Apple Home tile: a value's label followed by the value") }
        }
    }

    static func stateSymbol(quick: AppleHomeQuickControl, accessory: AppleHomeAccessory) -> String? {
        guard accessory.isOperable else { return "exclamationmark.circle" }
        switch quick {
        case let .toggle(_, isOn): return isOn ? "power.circle.fill" : "power.circle"
        case .needsStateCheck: return "questionmark.circle"
        case .multipleControls: return "slider.horizontal.3"
        case .unavailable: return "exclamationmark.circle"
        case .readOnly: return nil
        }
    }

    /// The message of the last failed or unconfirmed command (or read) for this tile. A read
    /// failure that is still being retried automatically is `readProgress`, not a problem yet.
    static func problem(of accessory: AppleHomeAccessory, quick: AppleHomeQuickControl, messages: [UUID: String]) -> String? {
        if let control = quick.control, let message = messages[control.id] { return message }
        if accessory.autoRead != nil { return nil }
        return accessory.lastReadError.map {
            String(localized: "마지막 읽기 실패: \($0)", comment: "Apple Home: the latest read failed; the argument is the reason")
        }
    }

    /// Shown while a slow or timed-out automatic read is retried.
    static func readProgress(of accessory: AppleHomeAccessory) -> String? {
        guard case let .retrying(attempt, maxAttempts) = AppleHomeValueStatus.resolve(accessory) else { return nil }
        return AppleHomeText.retrying(attempt: attempt, maxAttempts: maxAttempts)
    }
}

private struct AppleHomeTileBody: View {
    @Environment(AppleHomeModel.self) private var appleHome
    let accessory: AppleHomeAccessory
    let quick: AppleHomeQuickControl
    let isBusy: Bool
    let showsRoom: Bool

    private var pending: DeviceControlValue? { quick.control.flatMap { appleHome.pendingValues[$0.id] } }
    /// A read the user asked for, or an automatic one (queued, running or retrying).
    private var isReading: Bool { appleHome.refreshingAccessoryIDs.contains(accessory.id) || accessory.autoRead != nil }

    var body: some View {
        let state = AppleHomeTileText.state(of: accessory, quick: quick, pending: pending, isReading: isReading)
        let problem = AppleHomeTileText.problem(of: accessory, quick: quick, messages: appleHome.controlMessages)
        let readProgress = AppleHomeTileText.readProgress(of: accessory)
        let valueCheck = accessory.isOperable ? AppleHomeText.valueCheckLine(of: accessory) : nil
        let roomName = AppleHomeTileText.roomName(of: accessory)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                // Keeps the icon's place; the real icon is drawn on top by the tile.
                AppleHomeTileIconFace(accessory: accessory, quick: quick, isBusy: isBusy)
                    .hidden()
                Spacer(minLength: 4)
                Image(systemName: accessory.isOperable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(accessory.isOperable ? .green : .secondary)
            }

            Spacer(minLength: 10)

            DeviceSourceBadge(text: AppleHomeText.source(of: accessory))
                .padding(.bottom, 4)
            Text(accessory.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if showsRoom {
                Text(roomName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let state {
                stateLabel(state)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.top, 2)
            } else if let readProgress {
                Label(readProgress, systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.top, 2)
            }
            if let valueCheck {
                Text(valueCheck)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            HStack {
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(PogoTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 170, alignment: .topLeading)
        .background(PogoTheme.tile, in: RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PogoTheme.cardCornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessory.name))
        .accessibilityValue(Text(verbatim: [
            roomName,
            AppleHomeText.source(of: accessory),
            state,
            problem ?? readProgress,
            valueCheck,
        ].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityHint(Text("상세 정보를 엽니다", comment: "VoiceOver hint of an Apple Home tile body"))
    }

    @ViewBuilder
    private func stateLabel(_ text: String) -> some View {
        let isProblem = !accessory.isOperable
        Group {
            if let symbol = AppleHomeTileText.stateSymbol(quick: quick, accessory: accessory), pending == nil, !isReading {
                Label(text, systemImage: symbol)
            } else {
                Text(text)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isProblem ? Color.red : Color.primary)
        .lineLimit(3)
        .padding(.top, 4)
    }
}

/// The device icon: a button when it has something to do, plain artwork otherwise.
struct AppleHomeTileIcon: View {
    /// Extra tappable margin around the circle so the target reaches 44pt.
    static let hitSlop: CGFloat = 4

    @Environment(AppleHomeModel.self) private var appleHome
    let accessory: AppleHomeAccessory
    let quick: AppleHomeQuickControl
    let isBusy: Bool

    var body: some View {
        switch AppleHomeTileAction.iconAction(for: accessory, quickControl: quick) {
        case .send, .readState:
            Button {
                Task { await appleHome.performQuickAction(for: accessory.id) }
            } label: {
                face
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(accessibilityHint)
        case .none:
            // Shown so the user sees it is normally switchable, but it does nothing now.
            Button {} label: { face }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
        case .openDetail:
            // Not a control: taps reach the tile body underneath, which opens the detail.
            face
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var face: some View {
        AppleHomeTileIconFace(accessory: accessory, quick: quick, isBusy: isBusy)
            .padding(Self.hitSlop)
            .contentShape(Rectangle())
    }

    private var accessibilityLabel: Text {
        Text("\(accessory.name) 전원", comment: "VoiceOver label of an Apple Home tile's on/off button; the argument is the device name")
    }

    private var accessibilityValue: Text {
        let pending = quick.control.flatMap { appleHome.pendingValues[$0.id] }
        let text = AppleHomeTileText.state(
            of: accessory,
            quick: quick,
            pending: pending,
            isReading: appleHome.refreshingAccessoryIDs.contains(accessory.id) || accessory.autoRead != nil
        )
        switch quick {
        case .unavailable where accessory.isOperable:
            return Text("제어할 수 없음", comment: "VoiceOver: this on/off button can't be used now")
        default:
            return Text(verbatim: text ?? "")
        }
    }

    private var accessibilityHint: Text {
        switch quick {
        case let .toggle(_, isOn):
            return isOn
                ? Text("두 번 탭하면 끕니다", comment: "VoiceOver hint: turns the Apple Home device off")
                : Text("두 번 탭하면 켭니다", comment: "VoiceOver hint: turns the Apple Home device on")
        case .needsStateCheck:
            return Text("현재 전원 상태를 다시 읽습니다. 기기를 켜거나 끄지 않습니다.", comment: "VoiceOver hint: reads the on/off state without changing it")
        default:
            return Text(verbatim: "")
        }
    }
}

/// The circle itself — also used, hidden, to reserve its space in the tile body.
private struct AppleHomeTileIconFace: View {
    let accessory: AppleHomeAccessory
    let quick: AppleHomeQuickControl
    let isBusy: Bool

    private var background: Color {
        guard accessory.isOperable else { return Color(.systemGray3) }
        switch quick {
        case let .toggle(_, isOn): return isOn ? .orange : Color(.systemGray)
        case .needsStateCheck, .unavailable: return Color(.systemGray)
        case .multipleControls, .readOnly: return .orange
        }
    }

    var body: some View {
        IconCircle(
            systemName: SymbolAvailability.resolvedName(for: AppleHomeText.symbolName(for: accessory)),
            diameter: 40,
            background: background
        )
        .overlay {
            if isBusy {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
        }
    }
}

extension View {
    /// Registers the Apple Home screens on a `NavigationStack` (one handler per stack, like
    /// `AppRoute`).
    func appleHomeNavigationDestinations() -> some View {
        navigationDestination(for: AppleHomeRoute.self) { route in
            switch route {
            case let .accessory(accessoryID):
                AppleHomeAccessoryDetailView(accessoryID: accessoryID)
            case let .room(key):
                AppleHomeRoomDetailView(key: key)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ScrollView {
            let model = AppleHomeModel.preview
            LazyVGrid(columns: PogoTheme.cardColumns(for: .large), spacing: PogoTheme.gridSpacing) {
                ForEach(model.snapshot.accessories) { accessory in
                    AppleHomeAccessoryTile(accessory: accessory)
                }
            }
            .padding()
            .environment(model)
        }
        .background(PogoTheme.canvas)
    }
}
