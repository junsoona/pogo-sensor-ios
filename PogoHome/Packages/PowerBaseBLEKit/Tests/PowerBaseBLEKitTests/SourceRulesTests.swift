#if DEBUG && os(macOS)
import XCTest

/// Rules about the package's own source text: nothing in it can log, the vendored copy contains no
/// weaker security scheme and none of the SDK's networking, and every file stays DEBUG-only.
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

    func testEverySourceFileIsDebugOnly() throws {
        for file in try swiftFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
            XCTAssertTrue(lines.first?.hasPrefix("#if DEBUG") == true, "\(file.lastPathComponent) starts with #if DEBUG")
            XCTAssertEqual(lines.last, "#endif", "\(file.lastPathComponent) ends with #endif")
        }
    }
}
#endif
