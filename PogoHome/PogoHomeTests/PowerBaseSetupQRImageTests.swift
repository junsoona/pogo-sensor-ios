#if DEBUG
import CoreImage
import ImageIO
import PowerBaseBLEKit
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import PogoHome

/// Pictures through the app's real reading path (`PowerBaseSetupQRImageReader`: ImageIO, then
/// Vision), and what comes out of it through the real rules (`PowerBaseSetupQRIntake.evaluate`).
///
/// `Fixtures/setup-qr-fake-*.png` were written by the firmware repository's generator
/// (`tools/gen_power_base_setup_qr.swift`) from two of the public, made-up vectors of its
/// `tools/power_base_setup_qr_vectors.json`; they belong to no board. With
/// `POGO_SETUP_QR_ROUNDTRIP_DIR` set (pass `TEST_RUNNER_POGO_SETUP_QR_ROUNDTRIP_DIR=…` to
/// `xcodebuild test`) the same is done with PNGs the generator has just written there.
///
/// No camera is used and nothing is written anywhere.
final class PowerBaseSetupQRImageTests: XCTestCase {
    private typealias F = SetupQRFixtures
    private typealias Reader = PowerBaseSetupQRImageReader
    private typealias Intake = PowerBaseSetupQRIntake

    // MARK: Pictures

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: name, withExtension: "png") ?? bundle.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"),
            "\(name).png is not in the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private struct Gray {
        var width: Int
        var height: Int
        /// Row by row from the top.
        var pixels: [UInt8]

        init(width: Int, height: Int, fill: UInt8 = 255) {
            self.width = width
            self.height = height
            pixels = [UInt8](repeating: fill, count: width * height)
        }

        subscript(row: Int, column: Int) -> UInt8 {
            get { pixels[row * width + column] }
            set { pixels[row * width + column] = newValue }
        }

        mutating func draw(_ other: Gray, atRow row: Int, column: Int) {
            for y in 0..<other.height {
                for x in 0..<other.width { self[row + y, column + x] = other[y, x] }
            }
        }
    }

    private func gray(_ image: CGImage) -> Gray {
        var result = Gray(width: image.width, height: image.height)
        result.pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return result
    }

    private func gray(_ data: Data) throws -> Gray {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return gray(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// `picture` as a file of type `type`, stored as it is, saying `orientation` about itself.
    private func encoded(_ picture: Gray, as type: UTType = .png, orientation: Int? = nil) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(picture.pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: picture.width, height: picture.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: picture.width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// What a file must store so that, shown as EXIF orientation `orientation` says, it is
    /// `upright` (TIFF/EXIF: where the stored row 0 and column 0 are in the picture as seen).
    private func stored(_ upright: Gray, orientation: Int) -> Gray {
        let width = upright.width
        let height = upright.height
        let turned = orientation >= 5
        var result = Gray(width: turned ? height : width, height: turned ? width : height)
        for row in 0..<result.height {
            for column in 0..<result.width {
                switch orientation {
                case 1: result[row, column] = upright[row, column]                              // top, left
                case 2: result[row, column] = upright[row, width - 1 - column]                  // top, right
                case 3: result[row, column] = upright[height - 1 - row, width - 1 - column]     // bottom, right
                case 4: result[row, column] = upright[height - 1 - row, column]                 // bottom, left
                case 5: result[row, column] = upright[column, row]                              // left, top
                case 6: result[row, column] = upright[column, width - 1 - row]                  // right, top
                case 7: result[row, column] = upright[height - 1 - column, width - 1 - row]     // right, bottom
                default: result[row, column] = upright[height - 1 - column, row]                // left, bottom
                }
            }
        }
        return result
    }

    /// A QR code made here, for strings the generator refuses to make (a link, a damaged code).
    private func qrPicture(_ text: String, modulePixels: Int = 10) throws -> Gray {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = try XCTUnwrap(filter.outputImage)
        let image = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let small = gray(image)
        let quiet = 4
        var picture = Gray(width: (small.width + 2 * quiet) * modulePixels, height: (small.height + 2 * quiet) * modulePixels)
        for row in 0..<small.height {
            for column in 0..<small.width where small[row, column] < 128 {
                for y in 0..<modulePixels {
                    for x in 0..<modulePixels { picture[(row + quiet) * modulePixels + y, (column + quiet) * modulePixels + x] = 0 }
                }
            }
        }
        return picture
    }

    private func symbols(_ reading: PowerBaseSetupQRReading, file: StaticString = #filePath, line: UInt = #line) -> [String?] {
        guard case let .symbols(symbols) = reading else {
            XCTFail("\(reading)", file: file, line: line)
            return []
        }
        return symbols
    }

    private func bytes(_ symbols: [String?]) -> [[UInt8]?] { symbols.map { $0.map { Array($0.utf8) } } }

    // MARK: The generator's pictures, read by the app

    func testTheGeneratorsPictureIsReadBackAsExactlyThatBoardsCode() throws {
        for (name, text, target, eui64, code) in [
            ("setup-qr-fake-ascii-letters", F.text, F.target, F.eui64, F.setupCode),
            ("setup-qr-fake-last-quantum-bits-set", F.otherText, F.otherTarget, F.otherEUI64, F.otherSetupCode),
        ] {
            let reading = Reader.scan(try fixture(name))
            XCTAssertEqual(bytes(symbols(reading)), [Array(text.utf8)], "\(name): one QR code, byte for byte what the vector says")
            guard case let .success(payload)? = Intake.evaluate(reading, for: target) else { return XCTFail(name) }
            XCTAssertEqual(payload.eui64.hex, eui64)
            XCTAssertEqual(payload.setupCode, code)
            // The same picture on the screen of the other board: not taken.
            let wrongTarget = target == F.target ? F.otherTarget : F.target
            guard case .failure(.differentBoard)? = Intake.evaluate(reading, for: wrongTarget) else { return XCTFail(name) }
        }
    }

    func testTheAsyncEntryPointsReadOffTheMainThreadAndGiveTheSame() async throws {
        let data = try fixture("setup-qr-fake-ascii-letters")
        let fromData = await Reader.read(data)
        XCTAssertEqual(bytes(symbols(fromData)), [Array(F.text.utf8)])
        let nothing = await Reader.read(nil)
        XCTAssertEqual(nothing, .unreadableImage, "a picker that handed over nothing")
        // A file, as the Mac's panel hands it over.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-qr-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("fake.png")
        try data.write(to: file)
        let fromFile = await Reader.read(fileAt: file)
        XCTAssertEqual(bytes(symbols(fromFile)), [Array(F.text.utf8)])
        XCTAssertEqual(Reader.scan(fileAt: file, limits: .init(maxFileBytes: data.count - 1)), .imageTooLarge, "decided from the file's size, before it is read")
        XCTAssertEqual(Reader.scan(fileAt: directory), .unreadableImage, "a directory")
        XCTAssertEqual(Reader.scan(fileAt: directory.appendingPathComponent("missing.png")), .unreadableImage)
    }

    /// With `POGO_SETUP_QR_ROUNDTRIP_DIR`: PNGs the generator wrote a moment ago, each with what
    /// it was made from in `expected.json` (`[{"png": …, "eui64": …, "setup_code": …}]`).
    func testFreshlyGeneratedPicturesAreReadBack() throws {
        guard let path = ProcessInfo.processInfo.environment["POGO_SETUP_QR_ROUNDTRIP_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_POGO_SETUP_QR_ROUNDTRIP_DIR to a directory of freshly generated QR PNGs")
        }
        struct Expected: Decodable {
            let png: String
            let eui64: String
            let setup_code: String
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let expected = try JSONDecoder().decode([Expected].self, from: Data(contentsOf: directory.appendingPathComponent("expected.json")))
        XCTAssertGreaterThanOrEqual(expected.count, 5)
        for item in expected {
            let reading = Reader.scan(fileAt: directory.appendingPathComponent(item.png))
            XCTAssertEqual(bytes(symbols(reading)), [Array(("POGO-PB:1:" + item.eui64 + ":" + item.setup_code).utf8)], item.png)
            let target = Intake.Target(boardID: UUID(), boardEUI64: item.eui64)
            guard case let .success(payload)? = Intake.evaluate(reading, for: target) else {
                XCTFail(item.png)
                continue
            }
            XCTAssertEqual(payload.eui64.hex, item.eui64, item.png)
            XCTAssertEqual(payload.setupCode, item.setup_code, item.png)
        }
    }

    // MARK: Orientation

    /// A file may store its picture turned or mirrored and say so. The reader looks at the
    /// picture as it is meant to be seen: for each of the eight orientations, the upright
    /// picture comes out pixel for pixel, and its QR code is read.
    func testAPictureIsReadTheWayItsOrientationSaysItIsSeen() throws {
        // Not square, and with a mark in one corner, so that a wrong turn cannot go unnoticed.
        let code = try gray(fixture("setup-qr-fake-ascii-letters"))
        var upright = Gray(width: code.width + 140, height: code.height + 20)
        upright.draw(code, atRow: 10, column: 10)
        for row in 0..<40 {
            for column in (upright.width - 60)..<upright.width { upright[row, column] = 0 }
        }
        for orientation in 1...8 {
            let file = try encoded(stored(upright, orientation: orientation), as: .tiff, orientation: orientation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(file as CFData, nil))
            let seen = gray(try XCTUnwrap(Reader.uprightImage(from: source, longerSide: 2048), "orientation \(orientation)"))
            XCTAssertEqual(seen.width, upright.width, "orientation \(orientation)")
            XCTAssertEqual(seen.height, upright.height, "orientation \(orientation)")
            XCTAssertEqual(seen.pixels.map { $0 < 128 }, upright.pixels.map { $0 < 128 }, "orientation \(orientation): the upright picture, pixel for pixel")
            XCTAssertEqual(bytes(symbols(Reader.scan(file))), [Array(F.text.utf8)], "orientation \(orientation)")
        }
        // The same stored pixels without the note: another picture (turned on its side).
        let unmarked = try encoded(stored(upright, orientation: 6), as: .tiff)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(unmarked as CFData, nil))
        let seen = try XCTUnwrap(Reader.uprightImage(from: source, longerSide: 2048))
        XCTAssertEqual(seen.width, upright.height, "the test's files really differ by their orientation")
        // A JPEG, as a camera writes it.
        let jpeg = try encoded(stored(upright, orientation: 6), as: .jpeg, orientation: 6)
        XCTAssertEqual(bytes(symbols(Reader.scan(jpeg))), [Array(F.text.utf8)])
    }

    // MARK: Several codes, no code, other codes

    func testTwoDifferentCodesInOnePictureAreBothSeenAndNeitherIsTaken() throws {
        let first = try gray(fixture("setup-qr-fake-ascii-letters"))
        let second = try gray(fixture("setup-qr-fake-last-quantum-bits-set"))
        var both = Gray(width: first.width + second.width, height: max(first.height, second.height))
        both.draw(first, atRow: 0, column: 0)
        both.draw(second, atRow: 0, column: first.width)
        let reading = Reader.scan(try encoded(both))
        XCTAssertEqual(Set(bytes(symbols(reading)).compactMap { $0 }), [Array(F.text.utf8), Array(F.otherText.utf8)])
        for target in [F.target, F.otherTarget] {
            guard case .failure(.severalCodes)? = Intake.evaluate(reading, for: target) else { return XCTFail("\(reading)") }
        }
    }

    func testTheSameCodeTwiceInOnePictureIsOneCode() throws {
        let code = try gray(fixture("setup-qr-fake-ascii-letters"))
        var twice = Gray(width: code.width * 2, height: code.height)
        twice.draw(code, atRow: 0, column: 0)
        twice.draw(code, atRow: 0, column: code.width)
        let reading = Reader.scan(try encoded(twice))
        XCTAssertEqual(symbols(reading).count, 2, "Vision sees both")
        guard case let .success(payload)? = Intake.evaluate(reading, for: F.target) else { return XCTFail("\(reading)") }
        XCTAssertEqual(payload.setupCode, F.setupCode)
    }

    func testAPictureWithoutAQRCodeIsSaidToHaveNone() throws {
        XCTAssertEqual(Reader.scan(try encoded(Gray(width: 400, height: 300))), .symbols([]))
        var stripes = Gray(width: 640, height: 480)
        for row in 0..<stripes.height {
            for column in 0..<stripes.width where (row / 16 + column / 16) % 2 == 0 { stripes[row, column] = 0 }
        }
        let reading = Reader.scan(try encoded(stripes, as: .jpeg))
        XCTAssertEqual(reading, .symbols([]))
        XCTAssertNil(Intake.evaluate(reading, for: F.target))
    }

    /// Nothing between the picture and the rules tidies a string up: what a QR code says arrives
    /// as it is, and is refused as it is.
    func testOtherCodesArriveUnchangedAndAreRefused() throws {
        let cases: [(String, Intake.Problem)] = [
            (F.text + "\n", .damagedCode), (" " + F.text, .notPowerBaseCode), (F.text + ":extra", .damagedCode), (F.setupCode, .notPowerBaseCode),
            ("https://example.com/setup?code=" + F.setupCode, .notPowerBaseCode), ("MT:Y.K9042C00KA0648G00", .notPowerBaseCode),
            ("POGO-PB:2:" + F.eui64 + ":" + F.setupCode, .unsupportedVersion), ("POGO-PB:1:" + F.eui64.uppercased() + ":" + F.setupCode, .damagedCode),
            (String(F.text.dropLast()) + "B", .damagedCode),
        ]
        for (text, problem) in cases {
            let reading = Reader.scan(try encoded(qrPicture(text)))
            XCTAssertEqual(bytes(symbols(reading)), [Array(text.utf8)], "read as it is: \(text.debugDescription)")
            guard case let .failure(found)? = Intake.evaluate(reading, for: F.target) else {
                XCTFail("taken: \(text.debugDescription)")
                continue
            }
            XCTAssertEqual(found, problem, text.debugDescription)
        }
        // The generator used here writes a good code as well as the tool does.
        let reading = Reader.scan(try encoded(qrPicture(F.text)))
        guard case .success? = Intake.evaluate(reading, for: F.target) else { return XCTFail("\(reading)") }
    }

    // MARK: What is not a picture, and what is too large

    func testWhatIsNotAPictureIsRefused() throws {
        let png = try fixture("setup-qr-fake-ascii-letters")
        XCTAssertEqual(Reader.scan(nil), .unreadableImage)
        XCTAssertEqual(Reader.scan(Data()), .unreadableImage)
        XCTAssertEqual(Reader.scan(Data(F.text.utf8)), .unreadableImage, "the code as text is not a picture of it")
        XCTAssertEqual(Reader.scan(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })), .unreadableImage)
        XCTAssertEqual(Reader.scan(png.prefix(8)), .unreadableImage, "a PNG signature and nothing else")
        XCTAssertEqual(Reader.scan(Data("%PDF-1.7\n".utf8)), .unreadableImage)
        // The header is there, the picture is not.
        let truncated = Reader.scan(png.prefix(64))
        XCTAssertTrue(truncated == .unreadableImage || truncated == .symbols([]), "\(truncated)")
        guard case .failure = Intake.evaluate(.unreadableImage, for: F.target) else { return XCTFail("unreadable") }
    }

    func testThePicturesSizeIsCheckedBeforeItIsDecoded() throws {
        let png = try fixture("setup-qr-fake-ascii-letters")
        XCTAssertEqual(Reader.Limits.standard.maxFileBytes, 32 * 1024 * 1024)
        XCTAssertEqual(Reader.Limits.standard.maxPixels, 64_000_000)
        XCTAssertEqual(Reader.Limits.standard.passes, [2048, 4096])
        // By bytes.
        XCTAssertEqual(Reader.scan(png, limits: .init(maxFileBytes: png.count - 1)), .imageTooLarge)
        XCTAssertNotEqual(Reader.scan(png, limits: .init(maxFileBytes: png.count)), .imageTooLarge)
        // By what the header says: 492 x 492.
        XCTAssertEqual(Reader.scan(png, limits: .init(maxPixels: 492 * 492 - 1)), .imageTooLarge)
        XCTAssertNotEqual(Reader.scan(png, limits: .init(maxPixels: 492 * 492)), .imageTooLarge)
        XCTAssertEqual(Reader.scan(png, limits: .init(maxSidePixels: 491)), .imageTooLarge)

        // A few bytes that claim to be 60 000 x 60 000 pixels (3.6 gigapixels): refused from the
        // header, in no time, without trying to decode anything.
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + body
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in typed {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            crc ^= 0xFFFF_FFFF
            func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
            return big(UInt32(body.count)) + typed + big(crc)
        }
        func big(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        let bomb = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            + chunk("IHDR", big(60_000) + big(60_000) + [8, 0, 0, 0, 0])
            + chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
            + chunk("IEND", []))
        var started = Date()
        let refusal = Reader.scan(bomb)
        // ImageIO on the Mac reads such a header and the size limit refuses it; ImageIO in an iOS
        // simulator does not accept the file at all. Refused either way, and at once.
        XCTAssertTrue(refusal == .imageTooLarge || refusal == .unreadableImage, "\(refusal)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        // A real picture just over the limit (8200 x 8000 = 65.6 megapixels, all white, a few
        // kilobytes as a PNG): refused by its header, without being decoded.
        let large = try encoded(Gray(width: 8200, height: 8000))
        XCTAssertLessThan(large.count, 1024 * 1024)
        started = Date()
        XCTAssertEqual(Reader.scan(large), .imageTooLarge)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "decided from the header")
        XCTAssertEqual(Reader.scan(large, limits: .init(maxPixels: 70_000_000)), .symbols([]), "within the limit it is read (reduced), and holds no code")
    }

    /// A large picture is looked at reduced. When the first, smaller attempt finds nothing, the
    /// larger one is made -- and only for a picture that is larger than the first attempt.
    func testALargePictureIsReadReducedAndASecondLargerAttemptFollows() throws {
        let png = try fixture("setup-qr-fake-ascii-letters")
        // 32 pixels on the longer side leave nothing of a 41-module symbol to read.
        XCTAssertEqual(Reader.scan(png, limits: .init(passes: [32])), .symbols([]))
        XCTAssertEqual(bytes(symbols(Reader.scan(png, limits: .init(passes: [32, 2048])))), [Array(F.text.utf8)])
        // A photo-sized picture with the code in one corner: found, reduced.
        let code = try gray(png)
        var large = Gray(width: 4000, height: 3000)
        large.draw(code, atRow: 2400, column: 3300)
        let file = try encoded(large)
        XCTAssertEqual(bytes(symbols(Reader.scan(file))), [Array(F.text.utf8)])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(file as CFData, nil))
        let reduced = try XCTUnwrap(Reader.uprightImage(from: source, longerSide: 2048))
        XCTAssertEqual(max(reduced.width, reduced.height), 2048, "what is decoded is bounded by the attempt's size, not by the file")
    }
}
#endif
