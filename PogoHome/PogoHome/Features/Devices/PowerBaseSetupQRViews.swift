import PhotosUI
import PowerBaseBLEKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
#endif

/// The rows under the setup code field that read the code from the selected Power Base's QR
/// code: with the camera (iPhone, iPad) or from a picture -- a photo the user picks (iPhone,
/// iPad) or an image file (Mac).
///
/// They only fill the field in (`PowerBaseSetupQRIntake`): no Bluetooth, no hub, no registration.
/// The camera permission is asked for when the camera row is tapped, never before. A photo
/// comes from the system's picker, which hands over only the picture that was picked: the app
/// asks for no access to the photo library.
///
/// Every row is a button that begins a scan; the scanner or the picker is shown *for that scan*
/// and reports back to that scan only. Nothing here makes a scan when a picker returns.
struct PowerBaseSetupQRRows: View {
    @Binding var field: PowerBaseSetupCodeField
    /// The selected board; `nil` while there is none to read a code for.
    let target: PowerBaseSetupQRIntake.Target?
    let intake: PowerBaseSetupQRIntake

    private typealias T = PowerBaseSetupQRText

    var body: some View {
        if intake.camera != nil {
            Button {
                Self.begin(.camera, intake: intake, target: target, field: $field)
            } label: {
                SheetIconRow(systemImage: "qrcode.viewfinder") { Text(verbatim: T.scanButton) }
            }
            .disabled(!isOffered)
            .background {
                if let ticket = intake.scan, ticket.source == .camera {
                    PowerBaseSetupQRScannerPresenter(intake: intake, ticket: ticket).id(ticket.serial)
                }
            }
        }
        let picker = Self.imagePicker
        Button {
            Self.begin(.image(picker), intake: intake, target: target, field: $field)
        } label: {
            SheetIconRow(systemImage: picker == .file ? "doc.viewfinder" : "photo") { Text(verbatim: picker == .file ? T.fileButton : T.photoButton) }
        }
        .disabled(!isOffered)
        .background {
            // One presenter per scan, there for as long as that scan may still hear from its
            // picker. A new scan gets a new one; the old one's late callbacks carry the old scan.
            if let ticket = intake.choosingImageTicket {
                PowerBaseSetupQRImagePickerPresenter(intake: intake, ticket: ticket).id(ticket.serial)
            }
        }
        if intake.imageStage == .reading {
            SheetIconRow {
                SheetRowProgress()
            } content: {
                Text(verbatim: T.readingImage).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } else if intake.scan?.source != .camera, let problem = intake.problem {
            SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                Text(verbatim: T.problemMessage(problem)).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        } else if intake.didFill {
            SheetIconRow(systemImage: "checkmark.circle.fill", iconStyle: .green) {
                Text(verbatim: T.filled).sheetParagraph()
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Where a picture comes from on this platform.
    static var imagePicker: PowerBaseSetupQRIntake.ImagePicker { PlatformSupport.isMacCatalyst ? .file : .photos }

    /// A code can be read only for a selected board with a well-formed identity, and not while
    /// a chosen picture is being read.
    private var isOffered: Bool { target?.isUsable == true && intake.imageStage != .reading }

    /// The row's tap: begins a scan whose result goes into `field` -- and only there. The field
    /// itself refuses a code that is not the selected board's.
    @discardableResult
    static func begin(
        _ source: PowerBaseSetupQRIntake.Source, intake: PowerBaseSetupQRIntake, target: PowerBaseSetupQRIntake.Target?,
        field: Binding<PowerBaseSetupCodeField>
    ) -> PowerBaseSetupQRIntake.Ticket? {
        intake.begin(source, for: target) { payload in field.wrappedValue.fill(from: payload) }
    }
}

/// What a picker hands back, and how it is read. One value per kind of picker, so that what
/// the views do with a choice is one line -- and the same line a test calls.
enum PowerBaseSetupQRPickedImage {
    /// A photo from the system's photo picker: loaded into memory, read, dropped.
    static func chose(_ item: PhotosPickerItem, for ticket: PowerBaseSetupQRIntake.Ticket, intake: PowerBaseSetupQRIntake) {
        intake.imagePickerDidChoose(ticket) {
            await PowerBaseSetupQRImageReader.read(try? await item.loadTransferable(type: Data.self))
        }
    }

    /// The answer of a file panel: a file to read, or nothing usable.
    static func chose(_ result: Result<URL?, any Error>, for ticket: PowerBaseSetupQRIntake.Ticket, intake: PowerBaseSetupQRIntake) {
        switch result {
        case let .success(url?):
            intake.imagePickerDidChoose(ticket) { await PowerBaseSetupQRImageReader.read(fileAt: url) }
        case .success(nil), .failure:
            intake.imagePickerDidCancel(ticket)
        }
    }
}

/// The picker of one scan. It is in the view tree only while that scan may still hear from its
/// picker, it shows the picker only while the intake says so, and everything the picker reports
/// -- a choice, a cancellation, its closing -- is reported for `ticket`, the scan it was opened
/// for. It keeps no selection: the same photo or file can be chosen again.
private struct PowerBaseSetupQRImagePickerPresenter: View {
    let intake: PowerBaseSetupQRIntake
    let ticket: PowerBaseSetupQRIntake.Ticket

    private var isPresented: Binding<Bool> {
        Binding(get: { intake.openImagePicker?.ticket == ticket }, set: { if !$0 { intake.imagePickerDidClose(ticket) } })
    }

    var body: some View {
        switch ticket.source {
        case .image(.photos):
            Color.clear.photosPicker(
                isPresented: isPresented,
                selection: Binding<PhotosPickerItem?>(get: { nil }, set: { item in
                    if let item { PowerBaseSetupQRPickedImage.chose(item, for: ticket, intake: intake) }
                }),
                matching: .images
            )
        case .image(.file):
            // The form of the modifier that also says when the user gave up.
            Color.clear.fileImporter(isPresented: isPresented, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                PowerBaseSetupQRPickedImage.chose(result.map(\.first), for: ticket, intake: intake)
            } onCancellation: {
                intake.imagePickerDidCancel(ticket)
            }
        case .camera:
            EmptyView()
        }
    }
}

/// The scanner sheet of one camera scan: shown while that scan is the current one, and closing
/// it ends that scan only.
private struct PowerBaseSetupQRScannerPresenter: View {
    let intake: PowerBaseSetupQRIntake
    let ticket: PowerBaseSetupQRIntake.Ticket

    var body: some View {
        Color.clear.sheet(isPresented: Binding(get: { intake.scan == ticket }, set: { if !$0 { intake.cancel(ticket) } })) {
            PowerBaseSetupQRScannerSheet(
                intake: intake, boardLabel: PowerBaseSetupPresentation.label(forAdvertisedEUI64: ticket.target.boardEUI64), ticket: ticket
            )
        }
    }
}

/// The camera scanner: a viewfinder, what to show it, and why the last code was not taken. It
/// closes by itself when the selected board's code was read; closing it by hand ends the scan at
/// once.
struct PowerBaseSetupQRScannerSheet: View {
    let intake: PowerBaseSetupQRIntake
    let boardLabel: String
    /// The scan this scanner was opened for; closing it ends that scan. `nil`: whatever scan
    /// is current (a scanner drawn by itself, in a test).
    var ticket: PowerBaseSetupQRIntake.Ticket?

    private typealias T = PowerBaseSetupQRText

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    viewfinder
                    Text(verbatim: T.scannerHint(boardLabel))
                        .sheetParagraph()
                    if let problem = intake.problem {
                        SheetIconRow(systemImage: "exclamationmark.triangle.fill", iconStyle: .orange) {
                            Text(verbatim: T.problemMessage(problem)).sheetParagraph()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text(verbatim: T.scannerFootnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .sheetParagraph()
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Text(verbatim: T.scannerTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if let ticket { intake.cancel(ticket) } else { intake.cancel() }
                    } label: {
                        Text(verbatim: T.close)
                    }
                }
            }
        }
    }

    private var state: PowerBaseSetupQRCamera.State { intake.camera?.state ?? .unavailable }

    @ViewBuilder
    private var viewfinder: some View {
        switch state {
        case .running:
            preview
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 360)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(Text(verbatim: T.viewfinderLabel))
        case .idle, .askingPermission, .starting:
            notice(systemImage: nil, T.cameraPreparing)
        case .paused:
            notice(systemImage: "pause.circle", T.cameraPaused)
        case .denied:
            notice(systemImage: "video.slash", T.cameraDenied)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Label {
                    Text(verbatim: PowerBaseSetupText.openSettings)
                } icon: {
                    Image(systemName: "gearshape")
                }
            }
            .buttonStyle(.bordered)
        case .restricted:
            notice(systemImage: "video.slash", T.cameraRestricted)
        case .unavailable:
            notice(systemImage: "video.slash", T.cameraUnavailable)
        case .failed:
            notice(systemImage: "exclamationmark.triangle", T.cameraFailed)
        }
    }

    @ViewBuilder
    private var preview: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if let session = intake.camera?.previewSource as? AVCaptureSession {
            PowerBaseSetupQRCameraPreview(session: session)
        } else {
            previewPlaceholder
        }
        #else
        previewPlaceholder
        #endif
    }

    /// Where there is no picture to show (a scripted camera in a test).
    private var previewPlaceholder: some View {
        ZStack {
            Color.black
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func notice(systemImage: String?, _ text: String) -> some View {
        VStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ProgressView()
            }
            Text(verbatim: text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// What the camera sees, drawn by the system's own preview layer: the app's code never sees a
/// frame.
struct PowerBaseSetupQRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        /// Keeps the picture upright as the interface turns.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection, let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation else { return }
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
#endif

/// The wording of the QR code entry, in the app's language. No message contains anything a QR
/// code said.
nonisolated enum PowerBaseSetupQRText {
    typealias Problem = PowerBaseSetupQRIntake.Problem

    static var scanButton: String { String(localized: "카메라로 QR 코드 읽기", comment: "Setup code QR: button that opens the camera scanner") }
    static var photoButton: String { String(localized: "사진에서 QR 코드 가져오기", comment: "Setup code QR: button that opens the photo picker") }
    static var fileButton: String { String(localized: "QR 코드 이미지 파일 불러오기", comment: "Setup code QR (Mac): button that opens the file panel") }
    static var readingImage: String { String(localized: "이미지에서 QR 코드를 찾는 중입니다.", comment: "Setup code QR: a picked image is being read") }
    static var filled: String { String(localized: "QR 코드에서 설정 코드를 입력했습니다. 아직 아무것도 시작하지 않았습니다. 계속하려면 아래 버튼을 누르세요.", comment: "Setup code QR: the code was entered; nothing else was started") }
    static var scannerTitle: String { String(localized: "QR 코드 읽기", comment: "Setup code QR: title of the camera scanner") }
    static var close: String { String(localized: "닫기", comment: "Setup code QR: closes the camera scanner") }
    static var viewfinderLabel: String { String(localized: "카메라 화면", comment: "Setup code QR: accessibility label of the camera preview") }
    static var scannerFootnote: String { String(localized: "QR 코드를 읽으면 설정 코드만 입력됩니다. 촬영한 화면은 저장하지 않습니다.", comment: "Setup code QR: what the scanner does and does not do") }
    static var cameraPreparing: String { String(localized: "카메라를 준비하고 있습니다.", comment: "Setup code QR: the camera is starting or the permission is being asked") }
    static var cameraPaused: String { String(localized: "앱이 다시 화면에 보이면 카메라를 다시 켭니다.", comment: "Setup code QR: the camera is off while the app is in the background") }
    static var cameraDenied: String { String(localized: "이 앱의 카메라 사용이 허용되어 있지 않습니다. 설정에서 조각보 홈의 카메라를 허용하거나, 이 화면을 닫고 사진에서 QR 코드를 가져오세요.", comment: "Setup code QR: camera permission denied") }
    static var cameraRestricted: String { String(localized: "이 기기에서는 카메라 사용이 제한되어 있습니다. 이 화면을 닫고 사진에서 QR 코드를 가져오거나 설정 코드를 직접 입력하세요.", comment: "Setup code QR: camera restricted") }
    static var cameraUnavailable: String { String(localized: "이 기기에는 사용할 수 있는 카메라가 없습니다. 이 화면을 닫고 사진에서 QR 코드를 가져오거나 설정 코드를 직접 입력하세요.", comment: "Setup code QR: no camera") }
    static var cameraFailed: String { String(localized: "카메라를 시작하지 못했습니다. 이 화면을 닫고 다시 시도하세요.", comment: "Setup code QR: the camera did not start") }

    static func scannerHint(_ boardLabel: String) -> String {
        String(localized: "\(boardLabel)의 설정 QR 코드 하나만 화면 안에 비추세요.", comment: "Setup code QR: what to point the camera at; the argument is the selected Power Base's short label")
    }

    static func problemMessage(_ problem: Problem) -> String {
        switch problem {
        case .notPowerBaseCode:
            return String(localized: "Power Base 설정 QR 코드가 아닙니다. 설정 코드는 바뀌지 않았습니다.", comment: "Setup code QR problem: some other QR code")
        case .unsupportedVersion:
            return String(localized: "이 앱이 읽을 수 없는 형식의 Power Base QR 코드입니다. 앱을 업데이트하거나 26자리 설정 코드를 직접 입력하세요.", comment: "Setup code QR problem: a newer format version")
        case .damagedCode:
            return String(localized: "QR 코드의 내용이 올바르지 않습니다. 설정 코드는 바뀌지 않았습니다. 26자리 설정 코드를 직접 입력할 수 있습니다.", comment: "Setup code QR problem: malformed content")
        case .differentBoard:
            return String(localized: "이 QR 코드는 선택한 Power Base의 것이 아닙니다. 설정 코드와 선택은 바뀌지 않았습니다. 선택한 Power Base의 QR 코드인지 확인하세요.", comment: "Setup code QR problem: a valid code of another board")
        case .severalCodes:
            return String(localized: "서로 다른 QR 코드가 여러 개 보입니다. 선택한 Power Base의 QR 코드 하나만 보이게 하세요.", comment: "Setup code QR problem: more than one different code in view")
        case .noCodeInImage:
            return String(localized: "이미지에서 QR 코드를 찾지 못했습니다.", comment: "Setup code QR problem: no QR code in the picked image")
        case .unreadableImage:
            return String(localized: "읽을 수 있는 이미지가 아닙니다.", comment: "Setup code QR problem: the picked file is not a readable image")
        case .imageTooLarge:
            return String(localized: "이미지가 너무 큽니다. 32MB, 6,400만 화소 이하의 이미지를 사용하세요.", comment: "Setup code QR problem: the picked image exceeds the size limits")
        case .interrupted:
            return String(localized: "앱이 화면에서 벗어나 QR 코드 읽기를 중단했습니다. 다시 시도하세요.", comment: "Setup code QR problem: the app went to the background while an image was read")
        }
    }
}
