import SwiftUI

/// "기기 추가". Only paths that really exist are offered: a Matter accessory through Apple's own
/// Apple Home setup flow (see `MatterAccessorySetupSection`), a Power Base, which the app
/// registers with the paired hub over Bluetooth (see `PowerBaseSetupView`), and moving a
/// registered Power Base to another hub (see `PowerBaseReenrollView`). The older way --
/// writing a configuration image from a computer -- is still described in
/// `PowerBaseConnectionView`. Sensor modules need no entry here — they pair automatically when
/// docked onto a Power Base.
struct AddDeviceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppleHomeModel.self) private var appleHome

    var body: some View {
        NavigationStack {
            List {
                SheetTitleRow(title: "기기 추가")

                MatterAccessorySetupSection()

                Section {
                    NavigationLink {
                        PowerBaseSetupView(onFinished: { dismiss() })
                    } label: {
                        SheetIconRow {
                            IconCircle.powerBase(diameter: 24)
                        } content: {
                            Text("Power Base 추가")
                            Text("새 Power Base를 Bluetooth로 찾아 설정 코드로 허브에 등록합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                    }
                    .sheetRowInsets()
                    NavigationLink {
                        PowerBaseReenrollView(onFinished: { dismiss() })
                    } label: {
                        SheetIconRow(systemImage: "arrow.triangle.swap", iconStyle: .tint) {
                            Text(verbatim: PowerBaseReenrollText.entryTitle)
                            Text(verbatim: PowerBaseReenrollText.entrySubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                    }
                    .sheetRowInsets()
                    NavigationLink {
                        PowerBaseConnectionView()
                    } label: {
                        SheetIconRow(systemImage: "desktopcomputer", iconStyle: .secondary) {
                            Text("컴퓨터로 Power Base 연결")
                            Text("설정 이미지를 기록해 연결하는 기존 방법과, 허브가 인식한 Power Base를 확인합니다.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                        }
                    }
                    .sheetRowInsets()
                } header: {
                    Text("조각보 센서")
                } footer: {
                    Text("센서 모듈은 Power Base에 끼우면 자동으로 페어링되므로 따로 추가할 필요가 없습니다.")
                        .sheetFooter()
                }
            }
            .sheetListSpacing()
            .sheetTitle("기기 추가")
            // Clears a previous visit's result; never while Apple's setup flow is running.
            .onAppear { appleHome.clearSetupState() }
            .sheetCloseAction { dismiss() }
        }
    }
}

/// The "컴퓨터로 Power Base 연결" path: a Base that is not registered from the app (see
/// `PowerBaseSetupView`) joins the Thread network and learns the Linux bridge's address from the
/// configuration image flashed onto it from a computer. This screen states that procedure
/// plainly, then shows only what the bridge actually reports — the Bases it hears and any that
/// appeared since the screen opened. It never shows a success state the bridge hasn't reported.
/// A Base connected this way has no management credential, so the app cannot remove it.
struct PowerBaseConnectionView: View {
    @Environment(AppModel.self) private var appModel
    @State private var discovery: PowerBaseDiscovery?
    #if DEBUG
    @State private var enrollment: PowerBaseEnrollmentController?
    @State private var enrollmentEUI64 = ""
    /// What the clean-up achieved after the BLE test screen was left with a run under way.
    @State private var bleCleanupReport: PowerBaseEnrollmentBLEController.CleanupReport?
    #endif

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        List {
            Section {
                Text("Bluetooth 등록을 쓰지 않는 Power Base는 컴퓨터에서 펌웨어와 설정 이미지를 기록해 연결할 수 있습니다. 이렇게 연결한 Power Base는 앱에서 삭제할 수 없습니다.")
                    .sheetParagraph()
                    .sheetRowInsets()
                #if DEBUG
                Text("이 DEBUG 빌드에는 제품용 'Power Base 추가' 화면과 별개로, 미리 준비한 여분 보드로 등록 경로를 확인하는 시험 두 가지(BLE, USB 콘솔)가 맨 아래에 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: separates the product registration from the DEBUG tests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
                    .sheetRowInsets()
                #endif
            } header: {
                Text("컴퓨터로 연결하는 방법")
            }

            Section {
                SheetNumberedStep(number: 1, text: "OTBR에서 Thread Active Dataset과 허브 주소(Mesh-Local EID)를 확인합니다.")
                SheetNumberedStep(number: 2, text: "컴퓨터에서 Power Base 설정 이미지를 만듭니다. 이미 쓰고 있는 Power Base와 같은 이미지를 써도 됩니다. 각 Power Base의 식별자는 칩에 기록된 EUI-64라서 서로 겹치지 않습니다.")
                SheetNumberedStep(number: 3, text: "새 Power Base에 USB로 Power Base 펌웨어와 설정 이미지를 기록합니다.")
                SheetNumberedStep(number: 4, text: "전원을 켜면 Power Base가 Thread 네트워크에 합류하고 10초마다 허브에 신호를 보냅니다. 그러면 아래 목록에 나타납니다.")
                SheetNumberedStep(number: 5, text: "센서 모듈을 새 Power Base에 끼우면 기존처럼 자동으로 페어링되어 그 Power Base 아래에 표시됩니다.")
            } header: {
                Text("등록 절차")
            } footer: {
                Text("명령어와 파일 이름은 펌웨어 저장소의 README와 docs/power-base.md에 있습니다.")
                    .sheetFooter()
            }
            .sheetRowInsets()

            detectionSection

            Section {
                if snapshot.powerBases.isEmpty {
                    Text(snapshot.reportsPowerBases ? "허브가 아직 어떤 Power Base의 신호도 받지 못했습니다." : "확인할 수 없음")
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                } else {
                    ForEach(snapshot.powerBases) { base in
                        PowerBaseHeader(base: base, isCurrentStateVerified: appModel.isPowerBaseStateVerified)
                    }
                }
            } header: {
                Text("허브가 인식한 Power Base")
            }
            .sheetRowInsets()

            #if DEBUG
            bleTestEntrySection

            if let enrollment {
                PowerBaseEnrollmentTestSection(controller: enrollment, eui64Input: $enrollmentEUI64)
            }
            #endif
        }
        .sheetListSpacing()
        .navigationTitle("컴퓨터로 Power Base 연결")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if discovery == nil {
                discovery = PowerBaseDiscovery(baseline: snapshot)
            }
            #if DEBUG
            if enrollment == nil {
                enrollment = PowerBaseEnrollmentController(clipboard: SystemEnrollmentClipboard())
            }
            enrollment?.targetDidChange(enrollmentTarget)
            #endif
        }
        #if DEBUG
        // The screen, not a row: list rows come and go while scrolling.
        .onChange(of: enrollmentTarget) { _, target in enrollment?.targetDidChange(target) }
        .onDisappear { enrollment?.leave() }
        #endif
    }

    #if DEBUG
    /// The source as the enrollment tests see it: only a hub picked in "Find hubs" (by `hub_id`)
    /// that this device is paired with qualifies.
    private var enrollmentTarget: PowerBaseEnrollmentController.Target {
        PowerBaseEnrollmentController.Target(appModel: appModel)
    }

    /// The way into the BLE test, and what its last clean-up reported. Going there leaves this
    /// screen, which ends a USB-console test under way (one test at a time; the hub runs one
    /// session at a time anyway).
    private var bleTestEntrySection: some View {
        Section {
            NavigationLink {
                PowerBaseEnrollmentBLETestView(onCleanupReport: { bleCleanupReport = $0 })
            } label: {
                SheetIconRow(systemImage: "dot.radiowaves.left.and.right", iconStyle: .tint) {
                    Text("BLE 등록 시험", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: screen title")
                    Text("미등록 여분 보드를 Bluetooth로 찾아 설정 코드로 인증하고, 한 번 쓰는 가입 코드를 전달합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: entry row subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
            }
            if let report = bleCleanupReport {
                SheetIconRow(systemImage: "info.circle", iconStyle: .secondary) {
                    Text("BLE 시험 화면을 나가면서 진행 중이던 시험을 정리했습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: a run was cleaned up when its screen was left")
                        .sheetParagraph()
                    if !report.eui64.isEmpty {
                        Text(verbatim: "eui64: \(report.eui64)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .sheetParagraph()
                    }
                }
                .accessibilityElement(children: .combine)
                PowerBaseEnrollmentBLECleanupRows(cleanup: report.cleanup)
            }
        } header: {
            Text("BLE 등록 시험 (DEBUG)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: first section header")
        } footer: {
            Text("DEBUG 빌드에만 있습니다. 아래 USB 콘솔 시험과는 별개의 경로이며, 이 화면으로 들어가면 진행 중인 USB 콘솔 시험은 취소됩니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG BLE enrollment test: entry section footer")
                .sheetFooter()
        }
        .sheetRowInsets()
    }
    #endif

    @ViewBuilder
    private var detectionSection: some View {
        Section {
            if !snapshot.reportsPowerBases {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    Text("연결된 허브가 Power Base 정보를 보내지 않습니다. 새 Power Base를 확인하려면 허브를 업데이트해야 합니다.")
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
            } else if appModel.connectionStatus != .connected {
                SheetIconRow(systemImage: "wifi.exclamationmark", iconStyle: .orange) {
                    Text("허브에 연결되어 있지 않아 새 Power Base를 확인할 수 없습니다.")
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
            } else if let discovery {
                let found = discovery.newPowerBases(in: snapshot)
                if found.isEmpty {
                    SheetIconRow {
                        SheetRowProgress()
                    } content: {
                        Text("새 Power Base의 신호를 기다리는 중입니다.")
                            .sheetParagraph()
                    }
                } else {
                    ForEach(found) { base in
                        SheetIconRow(systemImage: "checkmark.circle.fill", iconStyle: .green) {
                            Text("\(base.shortLabel) 신호 수신", comment: "A new Power Base was heard by the bridge; the label is its short identifier")
                            Text(PowerBaseConnectionText.summary(of: base))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .sheetParagraph()
                            Text(verbatim: base.hardwareIdentifier)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .sheetParagraph()
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        } header: {
            Text("이 화면을 연 뒤 새로 나타난 Power Base")
        }
        .sheetRowInsets()
    }
}

#Preview {
    AddDeviceSheet()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
