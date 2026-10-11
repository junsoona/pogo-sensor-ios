// swift-tools-version: 5.9
import PackageDescription

// The protocol side of Power Base enrollment over Bluetooth: Espressif's Security 2 client
// (vendored, see Sources/ESPProvisionSecurity2/VENDORED.md) and the pb-status / pb-start /
// pb-cancel messages of the firmware repository's docs/power-base.md "BLE 등록 전달 경로" and
// docs/power-base-management.md.
//
// The app's product enrollment screen uses it, so it is compiled into Debug and Release builds
// alike (no source file is DEBUG-only any more). It has no dependencies, so nothing else is linked
// into the app because of it. There is no CoreBluetooth here, so the same code that runs in the
// app also runs on the Mac against the firmware repository's host harness (`swift test`, see
// README.md).
let package = Package(
    name: "PowerBaseBLEKit",
    platforms: [.iOS(.v16), .macCatalyst(.v16), .macOS(.v13)],
    products: [
        .library(name: "PowerBaseBLEKit", targets: ["PowerBaseBLEKit"]),
    ],
    targets: [
        .target(
            name: "ESPProvisionSecurity2",
            exclude: ["LICENSE", "VENDORED.md", "verify_against_upstream.sh"],
            // The SRP arithmetic is a pure-Swift big integer (3072-bit modular exponentiation).
            // Compiled unoptimised -- as a Debug build would -- one handshake takes several
            // seconds, long enough to miss the board's timeouts; so this one target is always
            // optimised. In a Release build the flag changes nothing (it is -O already): the
            // arithmetic and its results are the same in both configurations, which
            // `swift test` and `swift test -c release` check against the same vectors.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .target(
            name: "PowerBaseBLEKit",
            dependencies: ["ESPProvisionSecurity2"]
        ),
        .testTarget(
            name: "PowerBaseBLEKitTests",
            dependencies: ["PowerBaseBLEKit", "ESPProvisionSecurity2"],
            exclude: ["Support/make_harness_fixture.py", "Support/power-base-setup-qr-vectors.json"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
