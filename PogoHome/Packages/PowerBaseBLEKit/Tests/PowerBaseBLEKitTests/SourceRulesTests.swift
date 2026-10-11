#if os(macOS)
import XCTest

/// Rules about the package's own source text: nothing in it can log, the vendored copy contains no
/// weaker security scheme and none of the SDK's networking, and no file is DEBUG-only -- a Release
/// build compiles exactly the code these tests ran.
final class SourceRulesTests: XCTestCase {
    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The code without comments, so a comment that mentions `print` doesn't count.
    private func code(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let comment = line.range(of: "//") else { return String(line) }
                return String(line[..<comment.lowerBound])
            }
            .joined(separator: "\n")
    }

    func testNoSourceFileCanWriteALog() throws {
        let files = try swiftFiles()
        XCTAssertGreaterThan(files.count, 20)
        let forbidden = ["print(", "debugPrint(", "NSLog(", "os_log(", "Logger(", "dump(", "OSLog", "FileHandle.standard", "fputs(", "isLogEnabled"]
        for file in files {
            let text = try code(file)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
        }
    }

    func testTheVendoredCopyHasNoOtherSecuritySchemeAndNoSDKTransport() throws {
        let names = Set(try swiftFiles().map(\.lastPathComponent))
        for absent in ["ESPSecurity0.swift", "ESPSecurity1.swift", "ESPDevice.swift", "ESPProvisionManager.swift", "ESPSoftAPTransport.swift",
                       "ESPBleTransport.swift", "ESPSession.swift", "ESPProvision.swift", "ESPWiFiManager.swift", "ESPThreadManager.swift"] {
            XCTAssertFalse(names.contains(absent), absent)
        }
        for file in try swiftFiles() {
            let text = try code(file)
            for framework in ["import NetworkExtension", "import SystemConfiguration", "import CoreBluetooth", "import AVFoundation", "import UIKit",
                              "import CoreLocation", "import CloudKit", "import Network", "import SwiftProtobuf"] {
                XCTAssertFalse(text.contains(framework), "\(file.lastPathComponent): \(framework)")
            }
        }
    }

    /// The product enrollment screen uses this package, so nothing in it may depend on the build
    /// configuration: no `#if DEBUG` anywhere (code or comment), in any source file.
    func testNoSourceFileDependsOnTheBuildConfiguration() throws {
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("#if DEBUG"), "\(file.lastPathComponent) has a DEBUG-only part")
            XCTAssertFalse(text.contains("#if !DEBUG"), "\(file.lastPathComponent) has a Release-only part")
        }
    }

    /// Nothing in the package shows, copies or stores a secret: no pasteboard, no keychain, no
    /// user defaults, no file writing.
    func testNoSourceFileCanPersistOrExposeASecret() throws {
        let forbidden = ["UIPasteboard", "NSPasteboard", "UserDefaults", "SecItemAdd", "SecItemUpdate", "FileManager", ".write(to:"]
        for file in try swiftFiles() {
            let text = try code(file)
            for word in forbidden {
                XCTAssertFalse(text.contains(word), "\(file.lastPathComponent) contains \(word)")
            }
        }
    }
}
#endif
