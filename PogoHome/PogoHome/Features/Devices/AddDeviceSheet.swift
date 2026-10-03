import SwiftUI

/// "기기 추가". Only paths that really exist are offered: a Matter accessory through Apple's own
/// Apple Home setup flow (see `MatterAccessorySetupSection`), and a POGO Power Base, which is
/// registered outside the app today (see `PowerBaseConnectionView`). Sensor modules need no
/// entry here — they pair automatically when docked onto a Power Base.
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
                        PowerBaseConnectionView()
                    } label: {
                        SheetIconRow(systemImage: "powerplug.fill", iconStyle: .tint) {
                            Text("조각보 Power Base 연결")
                            Text("새 Power Base를 Thread 네트워크와 Linux Bridge에 연결합니다.")
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

/// The "POGO Power Base 연결" path. The app can't register a Power Base itself: a Base joins
/// the Thread network and learns the Linux bridge's address only from the configuration image
/// flashed onto it from a computer. So this screen states that procedure plainly, then shows
/// only what the bridge actually reports — the Bases it hears and any that appeared since the
/// screen opened. It never shows a success state the bridge hasn't reported.
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
                Text("조각보 홈 앱은 아직 Power Base를 직접 등록할 수 없습니다. 새 Power Base는 컴퓨터에서 펌웨어와 설정 이미지를 기록해야 Thread 네트워크와 Linux Bridge에 연결됩니다.")
                    .sheetParagraph()
                    .sheetRowInsets()
                #if DEBUG
                Text("이 문단과 아래 절차는 출시용 앱의 현재 등록 방법입니다. 이 DEBUG 빌드에는 그와 별개로, 미리 준비한 여분 보드로 등록 경로를 확인하는 시험 두 가지(BLE, USB 콘솔)가 맨 아래에 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: separates the Release registration procedure from the DEBUG tests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
                    .sheetRowInsets()
                #endif
            } header: {
                Text("현재 등록 방법")
            }

            Section {
                SheetNumberedStep(number: 1, text: "Linux OTBR 호스트에서 Thread Active Dataset과 Bridge 주소(Mesh-Local EID)를 확인합니다.")
                SheetNumberedStep(number: 2, text: "컴퓨터에서 Power Base 설정 이미지를 만듭니다. 이미 쓰고 있는 Power Base와 같은 이미지를 써도 됩니다. 각 Power Base의 식별자는 칩에 기록된 EUI-64라서 서로 겹치지 않습니다.")
                SheetNumberedStep(number: 3, text: "새 Power Base에 USB로 Power Base 펌웨어와 설정 이미지를 기록합니다.")
                SheetNumberedStep(number: 4, text: "전원을 켜면 Power Base가 Thread 네트워크에 합류하고 10초마다 Linux Bridge에 신호를 보냅니다. 그러면 아래 목록에 나타납니다.")
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
                    Text(snapshot.reportsPowerBases ? "Linux Bridge가 아직 어떤 Power Base의 신호도 받지 못했습니다." : "확인할 수 없음")
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                } else {
                    ForEach(snapshot.powerBases) { base in
                        PowerBaseHeader(base: base, isCurrentStateVerified: appModel.health.isCurrentStateVerified)
                    }
                }
            } header: {
                Text("Linux Bridge가 인식한 Power Base")
            }
            .sheetRowInsets()

            #if DEBUG
            // In a DEBUG build the three statements of the Release build would contradict the
            // tests below, so they are worded for what a DEBUG build really has. The Release
            // wording (the `#else` branch) is unchanged.
            Section {
                debugLimitation(Text("출시용 앱에는 Bluetooth·QR 코드로 Power Base를 등록하는 기능이 없습니다. 이 DEBUG 빌드에는 아래의 시험 두 가지만 있고, QR 등록은 어디에도 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: limitation 1, scoped against the DEBUG tests"))
                debugLimitation(Text("앱은 Thread 네트워크 정보(Dataset, Network Key)를 Power Base로 보내지 않습니다. DEBUG 시험이 전달하는 것은 한 번 쓰는 가입 코드(PSKd)뿐입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: limitation 2, scoped against the DEBUG tests"))
                debugLimitation(Text("앱의 일반 기능은 Linux Bridge에 등록을 요청하지 않습니다. 허브의 등록 세션 API는 아래 DEBUG 시험에서만, 페어링한 허브에만 사용합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: limitation 3, scoped against the DEBUG tests"))
            } header: {
                Text("출시용 앱에서 아직 할 수 없는 것", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG build: header of the limitations section")
            }
            .sheetRowInsets()

            bleTestEntrySection

            if let enrollment {
                PowerBaseEnrollmentTestSection(controller: enrollment, eui64Input: $enrollmentEUI64)
            }
            #else
            Section {
                limitation("Bluetooth·QR 코드로 Power Base를 등록하는 기능은 아직 없습니다.")
                limitation("앱에서 Thread 네트워크 정보를 Power Base로 보낼 수 없습니다.")
                limitation("Linux Bridge API는 읽기 전용이라 앱에서 등록을 요청할 수 없습니다.")
            } header: {
                Text("앱에서 아직 할 수 없는 것")
            }
            .sheetRowInsets()
            #endif
        }
        .sheetListSpacing()
        .navigationTitle("조각보 Power Base 연결")
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

    private func debugLimitation(_ text: Text) -> some View {
        SheetIconRow(systemImage: "xmark.circle", iconStyle: .secondary) {
            text
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }
    #endif

    @ViewBuilder
    private var detectionSection: some View {
        Section {
            if !snapshot.reportsPowerBases {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    Text("연결된 Linux Bridge가 Power Base 정보를 보내지 않습니다. 새 Power Base를 확인하려면 Bridge를 이 버전 이상으로 업데이트해야 합니다.")
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
            } else if appModel.connectionStatus != .connected {
                SheetIconRow(systemImage: "wifi.exclamationmark", iconStyle: .orange) {
                    Text("Linux Bridge에 연결되어 있지 않아 새 Power Base를 확인할 수 없습니다.")
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

    #if !DEBUG
    private func limitation(_ text: LocalizedStringKey) -> some View {
        SheetIconRow(systemImage: "xmark.circle", iconStyle: .secondary) {
            Text(text)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }
    #endif
}

#Preview {
    AddDeviceSheet()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
