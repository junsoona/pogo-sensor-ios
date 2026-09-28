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

    private var snapshot: HomeSnapshot { appModel.snapshot }

    var body: some View {
        List {
            Section {
                Text("조각보 홈 앱은 아직 Power Base를 직접 등록할 수 없습니다. 새 Power Base는 컴퓨터에서 펌웨어와 설정 이미지를 기록해야 Thread 네트워크와 Linux Bridge에 연결됩니다.")
                    .sheetParagraph()
                    .sheetRowInsets()
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

            Section {
                limitation("Bluetooth·QR 코드로 Power Base를 등록하는 기능은 아직 없습니다.")
                limitation("앱에서 Thread 네트워크 정보를 Power Base로 보낼 수 없습니다.")
                limitation("Linux Bridge API는 읽기 전용이라 앱에서 등록을 요청할 수 없습니다.")
            } header: {
                Text("앱에서 아직 할 수 없는 것")
            }
            .sheetRowInsets()
        }
        .sheetListSpacing()
        .navigationTitle("조각보 Power Base 연결")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if discovery == nil {
                discovery = PowerBaseDiscovery(baseline: snapshot)
            }
        }
    }

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

    private func limitation(_ text: LocalizedStringKey) -> some View {
        SheetIconRow(systemImage: "xmark.circle", iconStyle: .secondary) {
            Text(text)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    AddDeviceSheet()
        .environment(AppModel.preview)
        .environment(AppleHomeModel.preview)
}
