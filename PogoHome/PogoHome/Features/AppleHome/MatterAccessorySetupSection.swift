import SwiftUI

/// "Matter 기기 추가" in the Add Device sheet. The button opens Apple's own setup flow
/// (`HMAccessorySetupManager`): the user scans the Matter QR code or types the setup code, then
/// picks the home and room there. PogoHome creates no device of its own — the result below only
/// repeats what Apple Home reported, and the device is listed once HomeKit lists it.
struct MatterAccessorySetupSection: View {
    @Environment(AppleHomeModel.self) private var appleHome

    private var isSetupDisabled: Bool {
        appleHome.setupState == .running || !appleHome.isAccessorySetupAvailable
    }

    var body: some View {
        Section {
            Button {
                Task { await appleHome.startAccessorySetup() }
            } label: {
                // The icon keeps the button's own style, so a disabled button dims as a whole.
                SheetIconRow(systemImage: "qrcode.viewfinder") {
                    Text("Matter 기기 추가")
                    Text("Apple 홈의 기기 추가 화면에서 Matter QR 코드나 설정 코드로 등록합니다.")
                        .font(.caption)
                        // A concrete gray: `.secondary` inside a Button derives from its tint.
                        // Dimmed with the button, apart from the reason row below it.
                        .foregroundStyle(isSetupDisabled ? Color(.tertiaryLabel) : Color(.secondaryLabel))
                        .sheetParagraph()
                }
            }
            .disabled(isSetupDisabled)

            result
        } header: {
            Text("Matter 기기")
        } footer: {
            Text("기기는 Apple 홈에 등록되며 Apple 홈 앱에서도 보입니다. Apple 홈에서 Matter 기기를 쓰려면 홈 허브(HomePod 또는 Apple TV)가 필요할 수 있고, Thread 기기는 Thread 경계 라우터가 필요합니다.")
                .sheetFooter()
        }
        .sheetRowInsets()
    }

    @ViewBuilder
    private var result: some View {
        switch appleHome.setupState {
        case .idle:
            unavailableExplanation
        case .running:
            SheetIconRow {
                SheetRowProgress()
            } content: {
                Text("Apple 홈 기기 추가 화면에서 진행 중입니다.")
                    .sheetParagraph()
            }
        case .cancelled:
            SheetIconRow(systemImage: "xmark.circle", iconStyle: .secondary) {
                Text("기기 추가를 취소했습니다. 추가된 기기는 없습니다.")
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
        case let .failed(message):
            SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .red) {
                Text("기기를 추가하지 못했습니다: \(message)", comment: "Matter setup failed; the argument is the reason")
                    .foregroundStyle(.red)
                    .sheetParagraph()
            }
        case let .succeeded(setup):
            succeeded(setup)
        }
    }

    /// Says why the button is disabled and what to do instead. Only adding is affected: devices
    /// already in Apple Home are still listed and controlled here.
    @ViewBuilder
    private var unavailableExplanation: some View {
        switch appleHome.accessorySetupSupport {
        case .available:
            EmptyView()
        case .requiresNewerMacOS:
            // The reason, in its own row: full-contrast title with a warning icon, the paragraphs
            // on the title's left edge — not mistaken for the disabled button's description.
            SheetIconRow(systemImage: "desktopcomputer.trianglebadge.exclamationmark", iconStyle: .orange) {
                Text("이 Mac에서는 Matter 기기를 추가할 수 없습니다")
                    .font(.subheadline.weight(.semibold))
                    .sheetParagraph()
                VStack(alignment: .leading, spacing: SheetRowLayout.paragraphSpacing) {
                    Text("Apple 홈의 기기 추가 화면은 macOS 27 이상에서만 앱에서 열 수 있습니다. iPhone이나 iPad의 조각보 홈 또는 홈 앱에서 추가하면, 같은 Apple 계정의 Apple 홈을 쓰는 이 Mac에도 자동으로 표시됩니다.")
                        .sheetParagraph()
                    Text("이미 Apple 홈에 있는 기기는 이 Mac에서도 그대로 보고 켜고 끌 수 있습니다.")
                        .sheetParagraph()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .unsupportedOnThisDevice:
            SheetIconRow(systemImage: "exclamationmark.circle", iconStyle: .orange) {
                Text("이 기기에서는 Apple 홈 기기 추가를 사용할 수 없습니다.")
                    .font(.subheadline.weight(.semibold))
                    .sheetParagraph()
                Text("이미 Apple 홈에 있는 기기는 이 기기에서도 그대로 보고 켜고 끌 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func succeeded(_ setup: AppleHomeSetupResult) -> some View {
        SheetIconRow(systemImage: "checkmark.circle.fill", iconStyle: .green) {
            Text("Apple 홈이 기기 \(setup.accessoryIDs.count)개를 추가했다고 알렸습니다.", comment: "Matter setup finished; number of accessories Apple Home reports as added (plural)")
                .sheetParagraph()
        }
        switch appleHome.snapshot.accessState {
        case .ready:
            ForEach(setup.accessoryIDs, id: \.self) { id in
                if let accessory = appleHome.snapshot.accessory(with: id) {
                    NavigationLink {
                        AppleHomeAccessoryDetailView(accessoryID: id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: accessory.name)
                            Text(AppleHomeText.connection(of: accessory))
                                .font(.caption)
                                .foregroundStyle(accessory.isOperable ? Color.secondary : Color.red)
                        }
                    }
                } else {
                    SheetIconRow {
                        SheetRowProgress()
                    } content: {
                        Text("Apple 홈이 이 기기의 정보를 보내기를 기다리는 중입니다.")
                            .foregroundStyle(.secondary)
                            .sheetParagraph()
                    }
                }
            }
        case .off:
            Text("조각보 홈에서 이 기기를 보려면 Apple 홈 연결을 켜세요.")
                .foregroundStyle(.secondary)
            Button("Apple 홈 연결") { appleHome.enable() }
        default:
            Text("Apple 홈 접근 상태: \(AppleHomeText.accessStateSummary(appleHome.snapshot.accessState))", comment: "Matter setup result: Apple Home access state in PogoHome")
                .foregroundStyle(.secondary)
        }
    }
}
