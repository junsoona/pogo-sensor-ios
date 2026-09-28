import SwiftUI

enum AppleHomeControlText {
    static func state(_ value: DeviceControlValue, kind: DeviceControlKind) -> String {
        switch (kind, value) {
        case let (.power, .bool(on)):
            return on ? String(localized: "켜짐", comment: "Apple Home: on") : String(localized: "꺼짐", comment: "Apple Home: off")
        case let (.active, .bool(on)):
            return on ? String(localized: "작동 중", comment: "Apple Home: active") : String(localized: "꺼짐", comment: "Apple Home: off")
        case let (_, .percent(percent)):
            return AppleHomeCapabilities.percentText(Double(percent))
        case let (_, .bool(on)):
            return on ? String(localized: "켜짐", comment: "Apple Home: on") : String(localized: "꺼짐", comment: "Apple Home: off")
        }
    }

    static func pending(_ value: DeviceControlValue, kind: DeviceControlKind) -> String {
        switch value {
        case let .bool(on):
            return on ? String(localized: "켜는 중…", comment: "Apple Home control: turning on") : String(localized: "끄는 중…", comment: "Apple Home control: turning off")
        case let .percent(percent):
            let target = AppleHomeCapabilities.percentText(Double(percent))
            return String(localized: "\(target)(으)로 바꾸는 중…", comment: "Apple Home control: changing to a percentage")
        }
    }

    static func title(for control: DeviceAvailableControl) -> String {
        switch control.kind {
        case .power, .active: return control.label
        case .brightness:
            return String(localized: "\(control.label) 밝기", comment: "Brightness control title; the argument is the light's name")
        }
    }
}

/// One control. It shows the last *confirmed* state; while a request is running it shows the
/// requested value as "…ing" with a spinner, and afterwards it falls back to whatever the
/// device reports — so a failed, timed-out or unconfirmed request never looks applied.
struct AppleHomeControlRow: View {
    @Environment(AppleHomeModel.self) private var appleHome
    let accessoryID: UUID
    let control: DeviceAvailableControl

    /// The slider's position while the user drags, before anything is sent.
    @State private var draftPercent: Double?

    private var pending: DeviceControlValue? { appleHome.pendingValues[control.id] }
    private var message: String? { appleHome.controlMessages[control.id] }
    /// The last read-back value, or `nil` if unknown — including after a write whose result
    /// couldn't be read back.
    private var confirmedValue: DeviceControlValue? { appleHome.confirmedValue(of: control, accessoryID: accessoryID) }
    private var isInteractive: Bool { control.isEnabled && pending == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch control.kind {
            case .power, .active:
                toggleRow
            case .brightness:
                brightnessRow
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if let pending { return AppleHomeControlText.pending(pending, kind: control.kind) }
        if !control.isEnabled { return String(localized: "기기가 응답하지 않아 제어할 수 없습니다", comment: "Apple Home control: device unreachable") }
        guard let confirmed = confirmedValue else {
            return String(localized: "현재 상태를 아직 확인하지 못했습니다", comment: "Apple Home control: state not read yet")
        }
        return AppleHomeControlText.state(confirmed, kind: control.kind)
    }

    private var toggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: AppleHomeControlText.title(for: control))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if pending != nil {
                ProgressView()
            } else if case let .bool(on)? = confirmedValue {
                Button(on ? String(localized: "끄기", comment: "Apple Home control button") : String(localized: "켜기", comment: "Apple Home control button")) {
                    send(.bool(!on))
                }
                .buttonStyle(.bordered)
                .disabled(!isInteractive)
            } else {
                // State unknown: offer both explicitly rather than a toggle that implies one.
                HStack(spacing: 8) {
                    Button(String(localized: "켜기", comment: "Apple Home control button")) { send(.bool(true)) }
                    Button(String(localized: "끄기", comment: "Apple Home control button")) { send(.bool(false)) }
                }
                .buttonStyle(.bordered)
                .disabled(!isInteractive)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var range: ClosedRange<Int> { control.range ?? 0...100 }

    private var confirmedPercent: Double? {
        if case let .percent(percent)? = confirmedValue { return Double(percent) }
        return nil
    }

    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: AppleHomeControlText.title(for: control))
                Spacer()
                if pending != nil { ProgressView() }
            }
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { draftPercent ?? pendingPercent ?? confirmedPercent ?? Double(range.lowerBound) },
                    set: { draftPercent = $0 }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            ) {
                Text(verbatim: AppleHomeControlText.title(for: control))
            } onEditingChanged: { editing in
                if !editing, let draft = draftPercent {
                    send(.percent(Int(draft.rounded())))
                }
            }
            .disabled(!isInteractive)
            .accessibilityValue(Text(verbatim: statusText))
            .accessibilityAdjustableAction { direction in
                // VoiceOver adjusts in 10% steps and sends each step, since it has no "drag end".
                let current = Int((confirmedPercent ?? Double(range.lowerBound)).rounded())
                let next = direction == .increment ? current + 10 : current - 10
                send(.percent(min(max(next, range.lowerBound), range.upperBound)))
            }
        }
    }

    private var pendingPercent: Double? {
        if case let .percent(percent)? = pending { return Double(percent) }
        return nil
    }

    private func send(_ value: DeviceControlValue) {
        guard isInteractive else { return }
        let command = DeviceCommand(device: .appleHomeAccessory(accessoryID), controlID: control.id, kind: control.kind, value: value)
        Task {
            _ = await appleHome.perform(command)
            // Whatever happened, show the device's reported value from now on.
            draftPercent = nil
        }
    }
}
