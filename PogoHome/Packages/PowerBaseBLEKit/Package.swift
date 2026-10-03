// swift-tools-version: 5.9
import PackageDescription

// The DEBUG-only Power Base BLE enrollment test's protocol side: Espressif's Security 2 client
// (vendored, see Sources/ESPProvisionSecurity2/VENDORED.md) and the pb-status / pb-start /
// pb-cancel messages of the firmware repository's docs/power-base.md "BLE 등록 전달 경로".
//
// Every source file is wrapped in `#if DEBUG`: a Release build of the app compiles this package to
// nothing. It has no dependencies, so nothing else is linked into the app because of it either. There is no CoreBluetooth here, so the same code that runs in the app also runs on the
// Mac against the firmware repository's host harness (`swift test`, see README.md).
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
            // This code only ever runs in a DEBUG build, where it would be compiled unoptimised
            // and one handshake would take several seconds; optimise this one target.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .target(
            name: "PowerBaseBLEKit",
            dependencies: ["ESPProvisionSecurity2"]
        ),
        .testTarget(
            name: "PowerBaseBLEKitTests",
            dependencies: ["PowerBaseBLEKit", "ESPProvisionSecurity2"],
            exclude: ["Support/make_harness_fixture.py"]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
