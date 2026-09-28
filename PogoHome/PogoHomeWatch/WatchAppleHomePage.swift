import SwiftUI

/// Page 2: Apple Home lights, outlets and switches, read and switched by the Watch's own HomeKit
/// connection. A new state is shown only after the device reported it.
struct WatchAppleHomePage: View {
    @Environment(WatchPowerController.self) private var power

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            WatchAppleHomeContent(
                access: power.access,
                rows: power.rows,
                now: context.date,
                enable: { Task { await power.enable() } },
                reload: { Task { await power.load() } },
                disable: { power.disable() },
                tap: { id in Task { await power.tap(id) } }
            )
        }
    }
}

struct WatchAppleHomeContent: View {
    let access: WatchPowerController.Access
    let rows: [WatchPowerRow]
    let now: Date
    let enable: () -> Void
    let reload: () -> Void
    let disable: () -> Void
    let tap: (AppleHomePowerTargetID) -> Void
    /// `false` lays the same rows out flat, for the rendering tests (see `WatchHomeContent`).
    var isInList = true

    var body: some View {
        Group {
            if isInList {
                NavigationStack {
                    List { sections }
                        .navigationTitle(Text("Apple 홈", comment: "Dashboard status source: Apple Home"))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) { sections }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 6)
            }
        }
        // Wrist down (Always On): device names, rooms and on/off states go.
        .watchAlwaysOnPrivacy()
    }

    @ViewBuilder
    private var sections: some View {
        switch access {
        case .off:
            Section {
                Text("Watch에서 Apple 홈의 조명·콘센트·스위치를 켜고 끌 수 있습니다. 켜면 Apple 홈 접근 권한을 묻습니다.", comment: "Watch: explains the Apple Home page before it is turned on")
                    .font(.footnote)
                Button(action: enable) {
                    Label {
                        Text("Apple 홈 켜기", comment: "Watch: turns on Apple Home on the Watch (may ask for permission)")
                    } icon: {
                        Image(systemName: "homekit")
                    }
                }
            }
        case .loading:
            HStack {
                ProgressView()
                    .frame(width: 20, height: 20)
                Text("Apple 홈 불러오는 중…", comment: "Watch: waiting for HomeKit's homes")
            }
        case .denied, .restricted, .noHome, .unavailable:
            Section {
                Label {
                    Text(message(for: access))
                } icon: {
                    Image(systemName: access == .unavailable ? "exclamationmark.triangle" : "lock.fill")
                }
                .font(.footnote)
                Button(action: reload) {
                    Label {
                        Text("다시 시도", comment: "Watch: try reading Apple Home again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        case .ready:
            if rows.isEmpty {
                Text("켜고 끌 수 있는 조명·콘센트·스위치가 없습니다.", comment: "Watch: Apple Home has no device the Watch can switch")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    WatchPowerRowView(row: row, now: now) { tap(row.id) }
                }
            }
            Section {
                Button(action: reload) {
                    Label {
                        Text("상태 다시 읽기", comment: "Watch: read every Apple Home device's state again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        if access != .off {
            Section {
                Button(role: .destructive, action: disable) {
                    Text("Watch에서 Apple 홈 끄기", comment: "Watch: stop showing Apple Home on the Watch (nothing changes in Apple Home)")
                }
            }
        }
    }

    private func message(for access: WatchPowerController.Access) -> String {
        switch access {
        case .denied:
            return String(localized: "Apple 홈 접근 권한이 없습니다. 설정에서 조각보 홈의 홈 데이터 접근을 허용하세요.", comment: "Watch: Apple Home permission declined")
        case .restricted:
            return String(localized: "이 Apple Watch에서는 Apple 홈 접근이 제한되어 있습니다.", comment: "Watch: Apple Home access restricted by the system")
        case .noHome:
            return String(localized: "Apple 홈에 집이 없습니다.", comment: "Sensor widget: Apple Home has no home")
        case .unavailable, .off, .loading, .ready:
            return String(localized: "Apple 홈이 제시간에 응답하지 않았습니다.", comment: "Control Center error: HomeKit didn't load its homes in time")
        }
    }
}

struct WatchPowerRowView: View {
    let row: WatchPowerRow
    let now: Date
    let action: () -> Void

    private var display: WatchPowerStateDisplay { row.stateDisplay(now: now) }

    private var isOn: Bool {
        switch display {
        case .on, .lastSeen(isOn: true, _): return true
        default: return false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.target.name)
                        .lineLimit(2)
                        .privacySensitive()
                    if let room = row.target.roomName {
                        Text(room)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                    Text(stateLine)
                        .font(.caption2)
                        .foregroundStyle(display == .unknown || row.activity != .idle ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .privacySensitive()
                    if let result = row.visibleResult(now: now) {
                        Label {
                            Text(resultTitle(result))
                        } icon: {
                            Image(systemName: result == .confirmed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(result == .confirmed ? Color.green : Color.orange)
                        if let detail = result.failure?.message {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                trailing
            }
        }
        .disabled(row.activity != .idle)
        .accessibilityHint(Text(actionHint))
    }

    @ViewBuilder
    private var trailing: some View {
        if row.activity != .idle {
            ProgressView()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: display == .unknown ? "arrow.clockwise.circle" : row.target.kind.symbolName)
                .font(.title3)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(.secondary))
                .privacySensitive()
                .accessibilityHidden(true)
        }
    }

    private var stateLine: String {
        switch row.activity {
        case .checking:
            return String(localized: "확인 중…", comment: "Control Center value: reading the state")
        case .switching(toOn: true):
            return String(localized: "켜는 중…", comment: "Control Center value: turning on, not confirmed yet")
        case .switching(toOn: false):
            return String(localized: "끄는 중…", comment: "Control Center value: turning off, not confirmed yet")
        case .idle:
            break
        }
        switch display {
        case let .on(at):
            return "\(String(localized: "켜짐", comment: "Apple Home: on")) · \(GlanceTime.string(at, now: now))"
        case let .off(at):
            return "\(String(localized: "꺼짐", comment: "Apple Home: off")) · \(GlanceTime.string(at, now: now))"
        case let .lastSeen(isOn, at):
            let text = isOn
                ? String(localized: "마지막 확인: 켜짐", comment: "Control Center value: last read state (old), on")
                : String(localized: "마지막 확인: 꺼짐", comment: "Control Center value: last read state (old), off")
            return "\(text) · \(GlanceTime.string(at, now: now))"
        case .unknown:
            return String(localized: "상태 모름 · 눌러서 확인", comment: "Watch: the device's state isn't known; tapping reads it")
        }
    }

    private var actionHint: String {
        switch row.tapAction {
        case .none:
            return String(localized: "확인 중…", comment: "Control Center value: reading the state")
        case .check:
            return String(localized: "상태 확인", comment: "Control Center action hint: read the state only")
        case .switchTo(on: true):
            return String(localized: "켜기", comment: "Control Center action hint: turn on")
        case .switchTo(on: false):
            return String(localized: "끄기", comment: "Control Center action hint: turn off")
        }
    }

    /// The group a result belongs to; the failure's own message goes underneath.
    private func resultTitle(_ result: WatchPowerResult) -> String {
        switch result {
        case .confirmed:
            return String(localized: "기기가 새 상태를 보고함", comment: "Watch: the device reported the requested state after the action")
        case .checked:
            return String(localized: "현재 상태를 확인했습니다", comment: "Control Center status: the state was read, nothing was sent")
        case .noPermission:
            return String(localized: "권한 없음", comment: "Watch: Apple Home action failed for lack of permission")
        case .noResponse:
            return String(localized: "응답 없음", comment: "Apple Home accessory state: not reachable")
        case .unconfirmed:
            return String(localized: "상태 미확인", comment: "Watch: after an action the device's state couldn't be confirmed")
        case .unavailable:
            return String(localized: "사용할 수 없음", comment: "Control Center value: the target can't be used")
        }
    }
}
