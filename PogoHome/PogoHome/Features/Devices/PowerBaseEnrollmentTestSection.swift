#if DEBUG
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "USB 콘솔 등록 시험" in `PowerBaseConnectionView`, DEBUG builds only: starts an enrollment
/// session on the paired hub for a spare board and shows the PSKd for the tester to type into that
/// board's USB console, then what the hub reports. The production procedure on the same screen is
/// unchanged — this is a test tool, not registration. The BLE test is a separate screen
/// (`PowerBaseEnrollmentBLETestView`) with its own controller.
///
/// Strings live in their own table, `PowerBaseEnrollmentDebug.xcstrings`, which a Release build
/// leaves out (`EXCLUDED_SOURCE_FILE_NAMES`).
struct PowerBaseEnrollmentTestSection: View {
    let controller: PowerBaseEnrollmentController
    @Binding var eui64Input: String
    @State private var copied = false

    private var normalizedEUI64: String? { PowerBaseEUI64.normalized(eui64Input) }

    var body: some View {
        Section {
            if let reason = controller.ineligibility {
                SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                    PowerBaseEnrollmentText.ineligibility(reason)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }

            eui64Field

            Button {
                copied = false
                controller.start(eui64: eui64Input)
            } label: {
                SheetIconRow(systemImage: "play.circle.fill") {
                    Text("등록 시험 시작", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: start button")
                        .sheetParagraph()
                    Text("시작할 때마다 새 PSKd를 만듭니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: start button subtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
            }
            .disabled(!controller.canStart || normalizedEUI64 == nil)

            phaseRows

            if let problem = controller.pollProblem, controller.canCancel {
                SheetIconRow(systemImage: "wifi.exclamationmark", iconStyle: .orange) {
                    PowerBaseEnrollmentText.error(problem)
                        .foregroundStyle(.orange)
                        .sheetParagraph()
                    Text("세션은 허브에서 계속 진행됩니다. 약 1초마다 상태를 다시 확인합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: a status check failed but the session continues")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("USB 콘솔 등록 시험 (DEBUG)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG USB-console enrollment test: section header")
        } footer: {
            Text("DEBUG 빌드에만 있는 시험 기능입니다. 아래에 표시되는 PSKd를 여분 보드의 USB 직렬 콘솔에 직접 입력해 허브의 등록 API를 시험합니다. 성공은 Linux Bridge가 heartbeat를 받았다고 허브가 답할 때만 표시합니다. mode 2 시험 펌웨어(pb_join)는 등록을 마치면 heartbeat를 보내고, Joiner만 실행하는 프로브 펌웨어는 보내지 않으므로 Thread에 가입해도 ‘만료’로 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: section footer")
                .sheetFooter()
        }
        .sheetRowInsets()
        .onChange(of: controller.pskd) { _, _ in copied = false }
    }

    private var eui64Field: some View {
        VStack(alignment: .leading, spacing: SheetRowLayout.paragraphSpacing) {
            Text("여분 보드의 EUI-64", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: EUI-64 field title")
                .font(.subheadline.weight(.semibold))
                .sheetParagraph()
            // Vertical, so 16 digits wrap instead of being cut off at large text sizes.
            TextField(text: $eui64Input, prompt: Text(verbatim: "0123456789abcdef"), axis: .vertical) {
                Text("EUI-64 (16자리 16진수)", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: EUI-64 field label")
            }
            .font(.body.monospaced())
            .lineLimit(1...3)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .textContentType(nil)
            .disabled(controller.isBusy)
            if !eui64Input.isEmpty && normalizedEUI64 == nil {
                Text("16자리 16진수만 입력하세요. 구분자(:, -), *, 모두 0인 값은 쓸 수 없습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: EUI-64 validation message")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .sheetParagraph()
            }
            Text("보드 직렬 콘솔의 pb_join status(프로브 펌웨어는 ot eui64)로 확인한 값입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: where the EUI-64 comes from; 'pb_join status' and 'ot eui64' are console commands")
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
    }

    @ViewBuilder
    private var phaseRows: some View {
        switch controller.phase {
        case .idle:
            EmptyView()
        case .starting:
            SheetIconRow {
                SheetRowProgress()
            } content: {
                Text("허브에 등록 세션을 요청하는 중입니다. PSKd는 허브가 요청을 받아들인 뒤에 표시됩니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: POST in flight")
                    .sheetParagraph()
            }
        case let .running(session):
            stateRow(session)
            if let code = controller.pskd {
                codeRow(code)
            }
            remainingRow
            detailsRow(session)
            cancelButton
        case let .earlierSessionRunning(session):
            SheetIconRow(systemImage: "info.circle.fill", iconStyle: .orange) {
                Text("이 기기가 이전에 시작한 세션이 아직 진행 중입니다(409 enrollment_in_progress). 그 PSKd는 다시 표시할 수 없으니 취소한 뒤 새로 시작하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: this device's earlier session is still running")
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
            stateRow(session)
            remainingRow
            detailsRow(session)
            cancelButton
        case let .cancelling(session):
            SheetIconRow {
                SheetRowProgress()
            } content: {
                Text("허브에 세션 취소를 요청하는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: DELETE in flight")
                    .sheetParagraph()
            }
            detailsRow(session)
        case let .finished(session):
            finalRow(session)
            detailsRow(session)
        case let .failed(failure):
            SheetIconRow(systemImage: "xmark.octagon.fill", iconStyle: .red) {
                PowerBaseEnrollmentText.failure(failure)
                    .sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func stateRow(_ session: PowerBaseEnrollmentSession) -> some View {
        SheetIconRow {
            SheetRowProgress()
        } content: {
            PowerBaseEnrollmentText.stateTitle(session.state)
                .font(.headline)
                .sheetParagraph()
            PowerBaseEnrollmentText.stateDescription(session.state)
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func finalRow(_ session: PowerBaseEnrollmentSession) -> some View {
        let (symbol, style): (String, Color) = switch session.state {
        case .heartbeatReceived: ("checkmark.circle.fill", .green)
        case .expired: ("clock.badge.exclamationmark", .orange)
        case .cancelled: ("xmark.circle", .secondary)
        case .failed: ("xmark.octagon.fill", .red)
        case .preparing, .waitingForHeartbeat: ("questionmark.circle", .secondary)
        }
        SheetIconRow(systemImage: symbol, iconStyle: style) {
            PowerBaseEnrollmentText.stateTitle(session.state)
                .font(.headline)
                .sheetParagraph()
            PowerBaseEnrollmentText.stateDescription(session.state)
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
            if session.state == .failed {
                Text(verbatim: "error: \(session.error ?? "null")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .sheetParagraph()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func codeRow(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: SheetRowLayout.paragraphSpacing) {
            Text("보드 직렬 콘솔에 입력할 PSKd", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: title above the Joiner passphrase")
                .font(.subheadline.weight(.semibold))
                .sheetParagraph()
            // One line when it fits; two halves otherwise (large text, a narrow window). Never cut.
            ViewThatFits(in: .horizontal) {
                codeText(code)
                VStack(alignment: .leading, spacing: 2) {
                    codeText(String(code.prefix(code.count / 2)))
                    codeText(String(code.suffix(code.count - code.count / 2)))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: code.map(String.init).joined(separator: " ")))
            .textSelection(.enabled)
            .privacySensitive()
            Button {
                controller.copyCode()
                copied = true
            } label: {
                Label {
                    if copied {
                        Text("복사됨", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: the PSKd was copied")
                    } else {
                        Text("PSKd 복사", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: copy button")
                    }
                } icon: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
            .buttonStyle(.bordered)
            Text("허브가 요청을 받아들였을 때만 표시되며, 세션이 끝나거나 이 화면을 나가면 지워집니다. 어디에도 저장하지 않습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: how the PSKd is handled")
                .font(.caption)
                .foregroundStyle(.secondary)
                .sheetParagraph()
        }
    }

    private func codeText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.title2.monospaced().weight(.semibold))
            .kerning(2)
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder
    private var remainingRow: some View {
        if let expiresAround = controller.expiresAround {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(expiresAround.timeIntervalSince(context.date).rounded(.up))
                SheetIconRow(systemImage: "timer", iconStyle: .secondary) {
                    if remaining > 0 {
                        Text("허브 기준 약 \(remaining)초 남음", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: seconds left in the hub's Joiner window (guidance)")
                            .monospacedDigit()
                            .sheetParagraph()
                    } else {
                        Text("허브의 제한 시간이 지났을 수 있습니다. 허브의 최종 상태를 기다리는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: local countdown ran out; the hub decides the end")
                            .sheetParagraph()
                    }
                }
            }
        }
    }

    private func detailsRow(_ session: PowerBaseEnrollmentSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "state: \(session.state.rawValue)")
            Text(verbatim: "eui64: \(session.eui64)")
            Text(verbatim: "joiner_entry: \(session.joinerEntry)")
            Text(verbatim: "session: \(session.sessionID.prefix(8))…")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .sheetParagraph()
    }

    private var cancelButton: some View {
        Button(role: .destructive) {
            controller.cancel()
        } label: {
            SheetIconRow(systemImage: "stop.circle") {
                Text("세션 취소", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: cancel button")
                    .sheetParagraph()
            }
        }
        .disabled(!controller.canCancel)
    }
}

/// The test's messages, from the `PowerBaseEnrollmentDebug` table (a literal at every use, so
/// Xcode files each key into that table and not into `Localizable`).
enum PowerBaseEnrollmentText {
    static func ineligibility(_ reason: PowerBaseEnrollmentController.Ineligibility) -> Text {
        switch reason {
        case .simulatedData:
            return Text("시뮬레이션 데이터를 쓰는 중이라 시험할 수 없습니다. 설정에서 실제 허브를 선택하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: not available with simulated data")
        case .typedAddress:
            return Text("직접 입력한 주소로 연결 중입니다. ‘허브 찾기’로 선택한 허브에서만 시험할 수 있습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: not available with a typed address")
        case .noAddress:
            return Text("선택한 허브의 주소를 아직 모릅니다. 허브를 찾은 뒤 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: the picked hub has no address")
        case .notPaired:
            return Text("이 기기가 선택한 허브와 연결(페어링)되어 있지 않습니다. 설정에서 이 허브에 연결하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test: this device isn't paired with the hub")
        }
    }

    static func stateTitle(_ state: PowerBaseEnrollmentSession.State) -> Text {
        switch state {
        case .preparing:
            return Text("준비 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state preparing")
        case .waitingForHeartbeat:
            return Text("heartbeat 대기 중", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state waiting_for_heartbeat")
        case .heartbeatReceived:
            return Text("heartbeat 수신", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state heartbeat_received (the only success)")
        case .cancelled:
            return Text("취소됨", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state cancelled")
        case .expired:
            return Text("만료", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state expired")
        case .failed:
            return Text("실패", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state failed")
        }
    }

    static func stateDescription(_ state: PowerBaseEnrollmentSession.State) -> Text {
        switch state {
        case .preparing:
            return Text("허브가 Commissioner를 확인하고 이 EUI-64를 Joiner로 추가하는 중입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state preparing, description")
        case .waitingForHeartbeat:
            return Text("OTBR이 이 EUI-64의 Thread 가입을 허용했습니다. 아래 PSKd를 보드 직렬 콘솔에 입력하세요. Thread 가입만으로는 성공이 아닙니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state waiting_for_heartbeat, description")
        case .heartbeatReceived:
            return Text("세션 시작 뒤 Linux Bridge가 이 Power Base의 heartbeat를 받았습니다. 모듈과 센서가 동작하는지는 따로 확인해야 합니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state heartbeat_received, description")
        case .cancelled:
            return Text("이 기기가 세션을 취소했습니다. 허브가 Joiner 항목을 지웁니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state cancelled, description")
        case .expired:
            return Text("제한 시간 안에 새 heartbeat가 오지 않았습니다. 허브는 보드의 Thread 가입 여부를 알 수 없습니다. heartbeat를 보내지 않는 Joiner 프로브 펌웨어라면 Thread에 가입했더라도 이 결과가 정상입니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state expired, description")
        case .failed:
            return Text("허브가 세션을 진행하지 못했습니다. 아래 오류 코드를 확인하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment state failed, description")
        }
    }

    static func failure(_ failure: PowerBaseEnrollmentController.Failure) -> Text {
        switch failure {
        case .invalidEUI64:
            return Text("EUI-64 형식이 올바르지 않아 요청을 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case .randomnessUnavailable:
            return Text("안전한 난수를 만들 수 없어 요청을 보내지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case .credentialUnavailable:
            return Text("이 기기의 허브 인증 정보를 읽을 수 없어 요청을 보내지 않았습니다. 설정에서 허브에 다시 연결하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure")
        case .sourceChanged:
            return Text("데이터 소스가 바뀌어 진행 중이던 세션을 중단했습니다. 원래 허브에 취소를 요청했고, 전달되지 않았다면 허브의 제한 시간이 지나면 끝납니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment test failure: the app switched source during a session")
        case let .request(error):
            return self.error(error)
        }
    }

    static func error(_ error: PowerBaseEnrollmentError) -> Text {
        switch error {
        case .unauthorized:
            return Text("허브가 이 기기의 인증 정보를 거부했습니다(401). 설정에서 허브에 다시 연결하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error 401")
        case let .forbidden(code):
            return Text("허브가 요청을 거부했습니다(403, \(code)).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error 403; argument is the hub's code")
        case .enrollmentDisabled:
            return Text("이 허브에서 Power Base 등록이 꺼져 있습니다(404 enrollment_disabled).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .sessionNotFound:
            return Text("허브에서 이 세션을 찾을 수 없습니다(404 session_not_found). 허브가 다시 시작되었거나 세션이 잊혔습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .notSupported:
            return Text("이 허브는 Power Base 등록 API를 지원하지 않습니다(404).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .enrollmentInProgress:
            return Text("다른 기기가 시작한 등록 세션이 진행 중입니다(409 enrollment_in_progress). 끝난 뒤 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .powerBaseAlreadyConnected:
            return Text("이 EUI-64의 Power Base가 이미 Linux Bridge에 온라인 상태입니다(409 power_base_already_connected).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .sessionAlreadyFinal:
            return Text("세션이 이미 끝났습니다(409 session_already_final).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case let .rejected(code):
            return Text("허브가 요청 내용을 거부했습니다. (\(code))", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error 400/411/413/422; argument is the hub's code")
        case .bridgeEndpointNotSupported:
            return Text("이 허브는 Thread 목적지 자동 전달을 지원하지 않습니다. 허브(Linux Bridge와 OTBR helper)를 업데이트해야 합니다. 세션은 만들어지지 않았고, 주소를 추정하거나 이전 방식으로 바꿔 요청하지 않았습니다.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error: the hub refused the request for its bridge endpoint")
        case let .unavailable(reason):
            return Text("허브가 지금 등록을 처리할 수 없습니다(503, \(reason)). 잠시 후 다시 시도하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error 503; argument is the hub's reason")
        case .internalError:
            return Text("허브 내부 오류가 발생했습니다(500).", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error")
        case .certificateMismatch:
            return Text("허브의 인증서가 페어링할 때와 다릅니다. 안전을 위해 아무것도 보내지 않았습니다. 설정에서 허브에 다시 연결하세요.", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error: pinned certificate mismatch")
        case let .unreachable(detail):
            return Text("허브에 연결할 수 없습니다. (\(detail))", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error: no answer; argument is a technical detail")
        case let .badResponse(detail):
            return Text("허브의 응답이 API 계약과 맞지 않습니다. (\(detail))", tableName: "PowerBaseEnrollmentDebug", comment: "DEBUG enrollment error: malformed answer; argument is a technical detail")
        }
    }
}

/// The system pasteboard. The copied PSKd expires with the hub's window, and is removed when the
/// session ends unless something else was copied since (checked by `changeCount`, so the app never
/// reads the pasteboard).
@MainActor
final class SystemEnrollmentClipboard: PowerBaseEnrollmentClipboard {
    private var copiedChangeCount: Int?

    func copySecret(_ value: String, expiresAt: Date?) {
        var options: [UIPasteboard.OptionsKey: Any] = [:]
        if let expiresAt, expiresAt > Date() {
            options[.expirationDate] = expiresAt
        }
        UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: value]], options: options)
        copiedChangeCount = UIPasteboard.general.changeCount
    }

    func clearSecretIfUnchanged() {
        guard let count = copiedChangeCount else { return }
        copiedChangeCount = nil
        if UIPasteboard.general.changeCount == count {
            UIPasteboard.general.items = []
        }
    }
}
#endif
