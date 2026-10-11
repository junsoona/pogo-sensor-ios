#if os(iOS) && !targetEnvironment(macCatalyst)
import AVFoundation
import Foundation

/// The device's camera, looking for QR codes only (AVFoundation's metadata output). There is no
/// photo and no video output: no frame ever reaches the app's code, and nothing is kept.
final class PowerBaseSetupQRSystemCamera: PowerBaseSetupQRCameraProviding {
    private let engine = PowerBaseSetupQRCaptureEngine()

    var hasCamera: Bool { PowerBaseSetupQRCaptureEngine.device() != nil }

    var access: PowerBaseSetupQRCameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    func start(onSymbols: @escaping @Sendable ([String?]) -> Void) async -> Bool {
        await engine.start(onSymbols: onSymbols)
    }

    func stop() {
        engine.stop()
    }

    var previewSource: AnyObject? { engine.session }
}

/// The capture session and the one queue everything about it happens on: configuring, the
/// blocking `startRunning()` / `stopRunning()`, and the detection callbacks. Nothing of it runs
/// on the main thread.
nonisolated final class PowerBaseSetupQRCaptureEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    /// Read by the preview layer only.
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.junsoona.PogoHome.setup-qr-capture")
    private let lock = NSLock()
    /// Raised by every start and every stop, under `lock`: a start whose number is no longer the
    /// latest does not turn the camera on, however late the queue gets to it.
    private var latest = 0
    // On `queue` only:
    private var isConfigured = false
    private var onSymbols: (@Sendable ([String?]) -> Void)?

    static func device() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ?? AVCaptureDevice.default(for: .video)
    }

    func start(onSymbols: @escaping @Sendable ([String?]) -> Void) async -> Bool {
        let mine = lock.withLock { () -> Int in
            latest += 1
            return latest
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard self.isLatest(mine), self.configure() else {
                    continuation.resume(returning: false)
                    return
                }
                self.onSymbols = onSymbols
                self.session.startRunning()
                // Stopped while it was starting: off again, here, before anything else.
                guard self.isLatest(mine) else {
                    self.onSymbols = nil
                    self.session.stopRunning()
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() {
        lock.withLock { latest += 1 }
        queue.async {
            self.onSymbols = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func isLatest(_ number: Int) -> Bool {
        lock.withLock { latest == number }
    }

    /// One input (the camera) and one output (QR metadata). On `queue`.
    private func configure() -> Bool {
        if isConfigured { return true }
        guard let device = Self.device(), let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            return false
        }
        output.metadataObjectTypes = [.qr]
        output.setMetadataObjectsDelegate(self, queue: queue)
        isConfigured = true
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        // Every QR symbol of this frame together, so that two different codes in view are seen
        // as two.
        let symbols = metadataObjects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }.filter { $0.type == .qr }.map(\.stringValue)
        guard !symbols.isEmpty else { return }
        onSymbols?(symbols)
    }
}
#endif
