import Foundation
import Observation

nonisolated enum PowerBaseSetupQRCameraAccess: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// The device's camera as the scanner needs it. The app's implementation is
/// `PowerBaseSetupQRSystemCamera` (AVFoundation); tests use a scripted one.
@MainActor
protocol PowerBaseSetupQRCameraProviding: AnyObject {
    /// Whether there is a camera at all. Asked before the permission: a device without one is
    /// never made to ask.
    var hasCamera: Bool { get }
    var access: PowerBaseSetupQRCameraAccess { get }
    /// Shows the system's permission question. `true`: granted.
    func requestAccess() async -> Bool
    /// Starts looking for QR codes; returns when the camera runs (`true`) or cannot (`false`).
    /// `onSymbols` gets the text of every QR symbol of one frame, on any thread; never an empty
    /// list. No frame is kept.
    func start(onSymbols: @escaping @Sendable ([String?]) -> Void) async -> Bool
    /// Stops at once, also a start that has not finished. Does not wait.
    func stop()
    /// What a preview is drawn from (an `AVCaptureSession`); `nil` when there is nothing to draw.
    var previewSource: AnyObject? { get }
}

/// The camera of one scanner: asks for the permission only when the user opened the scanner,
/// runs only while the scanner is open and the app is in the foreground, and never comes on
/// later for a scanner that was closed meanwhile.
@MainActor
@Observable
final class PowerBaseSetupQRCamera {
    nonisolated enum State: Equatable, Sendable {
        case idle
        case askingPermission
        case starting
        case running
        /// The app is in the background: off, and on again when it is back.
        case paused
        case denied
        case restricted
        /// This device has no camera.
        case unavailable
        case failed
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let provider: any PowerBaseSetupQRCameraProviding
    /// The scanner is open.
    @ObservationIgnored private var isWanted = false
    @ObservationIgnored private var isSuspended = false
    /// Raised by everything that ends what was asked for before: whatever comes back for an
    /// older number is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var onSymbols: (([String?]) -> Void)?
    /// Starts that have not come to their end. For tests.
    @ObservationIgnored private(set) var unfinishedStarts = 0

    init(provider: any PowerBaseSetupQRCameraProviding) {
        self.provider = provider
    }

    var previewSource: AnyObject? { provider.previewSource }

    /// The user opened the scanner. `onSymbols` gets every frame's QR texts while it runs.
    func open(onSymbols: @escaping ([String?]) -> Void) {
        close()
        isWanted = true
        self.onSymbols = onSymbols
        begin()
    }

    /// Closed, cancelled, used or left. Immediate, whatever is still under way and whether or
    /// not the app is in the foreground.
    func close() {
        guard isWanted || state != .idle else { return }
        isWanted = false
        generation += 1
        onSymbols = nil
        provider.stop()
        state = .idle
    }

    func sceneDidEnterBackground() {
        isSuspended = true
        guard isWanted else { return }
        generation += 1
        provider.stop()
        switch state {
        case .askingPermission, .starting, .running: state = .paused
        case .idle, .paused, .denied, .restricted, .unavailable, .failed: break
        }
    }

    /// Back in the foreground: on again only for a scanner that is still open.
    func sceneDidBecomeActive() {
        isSuspended = false
        guard isWanted else { return }
        // The permission may have been changed in Settings meanwhile: asked afresh.
        begin()
    }

    private func begin() {
        generation += 1
        let current = generation
        unfinishedStarts += 1
        Task { [weak self] in
            await self?.run(current)
            self?.unfinishedStarts -= 1
        }
    }

    private func isCurrent(_ number: Int) -> Bool { isWanted && generation == number }

    private func run(_ current: Int) async {
        guard isCurrent(current) else { return }
        guard provider.hasCamera else {
            state = .unavailable
            return
        }
        switch provider.access {
        case .denied:
            state = .denied
            return
        case .restricted:
            state = .restricted
            return
        case .notDetermined:
            state = .askingPermission
            let granted = await provider.requestAccess()
            // Answered after the scanner was closed, or while the app was away.
            guard isCurrent(current) else { return }
            guard granted else {
                state = .denied
                return
            }
        case .authorized:
            break
        }
        guard !isSuspended else {
            state = .paused
            return
        }
        state = .starting
        let isRunning = await provider.start { [weak self] symbols in
            Task { @MainActor [weak self] in self?.received(symbols, from: current) }
        }
        guard isCurrent(current) else {
            // Closed (or sent to the background) while it was starting: whoever did that has
            // stopped the camera already, and this start must not leave it on.
            if !isWanted || isSuspended { provider.stop() }
            return
        }
        state = isRunning ? .running : .failed
    }

    private func received(_ symbols: [String?], from number: Int) {
        guard isCurrent(number), state == .running, !isSuspended, !symbols.isEmpty else { return }
        onSymbols?(symbols)
    }
}

extension PowerBaseSetupQRCamera {
    /// The device's own camera, where the app offers a camera scan: iPhone and iPad. On Mac
    /// Catalyst a QR code is read from an image file instead.
    static func system() -> PowerBaseSetupQRCamera? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        PowerBaseSetupQRCamera(provider: PowerBaseSetupQRSystemCamera())
        #else
        nil
        #endif
    }
}
