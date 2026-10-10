import Foundation
import XCTest
@testable import AssetTimeMachineResearchSupport

/// Encoding and admission plumbing only: no price preparation, solver or funded fixture.
final class CORNCoreScreenTests: XCTestCase {
    typealias Screen = CORNCoreScreen

    func testFiniteBinary64JSONRoundTripIncludesNegativeZeroAndSubnormals() throws {
        let patterns: [UInt64] = [0, 0x8000000000000000, 1, 0x8000000000000001,
            0x0010000000000000, 0x3fb999999999999a, 0x3fd5555555555555,
            0xbff0000000000000, 0x7fefffffffffffff]
        let values = patterns.map { Double(bitPattern: $0) }
        let data = try Screen.doubles(values).data()
        let decoded = try JSONDecoder().decode([Double].self, from: data)
        XCTAssertEqual(decoded.map(\.bitPattern), patterns)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("-0.0"))
        XCTAssertEqual(try Screen.JSONValue.number(Double(bitPattern: 0x8000000000000000)).data(), Data("-0.0".utf8))
    }

    func testNonfiniteJSONIsRejectedBeforeWriting() {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            XCTAssertThrowsError(try Screen.JSONValue.number(value).data())
        }
    }

    func testCertificatesRemainWholeNullAndAllThreeTargetZerosRemainPresent() throws {
        let target = Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0, Screen.JSONValue.number(0)) })
        let data = try Screen.JSONValue.object(["target": .object(target),
            "initialCertificate": Screen.certificateJSON(nil),
            "preNormalizationCertificate": Screen.certificateJSON(nil),
            "postNormalizationCertificate": Screen.certificateJSON(nil)]).data()
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let decoded = object["target"] as! [String: Double]
        XCTAssertEqual(Set(decoded.keys), Set(Screen.coreSymbols))
        XCTAssertEqual(decoded.values.map(\.bitPattern), [0, 0, 0])
        for name in ["initialCertificate", "preNormalizationCertificate", "postNormalizationCertificate"] {
            XCTAssertTrue(object[name] is NSNull)
        }
    }

    func testTenByteCorrelationNullUsesReservedZeroBits() throws {
        let data = try Screen.correlationBytes(.init(value: nil, zeroVariance: true, matched: false))
        XCTAssertEqual(Array(data), [0, 0, 0, 0, 0, 0, 0, 0, 1, 0])
        XCTAssertThrowsError(try Screen.correlationBytes(.init(value: 0, zeroVariance: true, matched: false)))
        XCTAssertThrowsError(try Screen.correlationBytes(.init(value: nil, zeroVariance: true, matched: true)))
    }

    func testTenByteCorrelationPreservesRawLittleEndianBitsAndExactFlags() throws {
        let value = Double(bitPattern: 0x3fb999999999999a)
        let data = try Screen.correlationBytes(.init(value: value, zeroVariance: false, matched: true))
        XCTAssertEqual(Array(data), [0x9a, 0x99, 0x99, 0x99, 0x99, 0x99, 0xb9, 0x3f, 0, 1])
        let negativeZero = Double(bitPattern: 0x8000000000000000)
        let negative = try Screen.correlationBytes(.init(value: negativeZero, zeroVariance: false, matched: false))
        XCTAssertEqual(Array(negative), [0, 0, 0, 0, 0, 0, 0, 0x80, 0, 0])
        XCTAssertThrowsError(try Screen.correlationBytes(.init(value: value, zeroVariance: false, matched: false)))
        XCTAssertThrowsError(try Screen.correlationBytes(.init(value: .infinity, zeroVariance: false, matched: true)))
    }

    func testExclusiveMetadataReservationCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("reservation.json").path
        let original = Data("{\"attempt\":1}\n".utf8)
        try Screen.exclusive(path, data: original)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
        XCTAssertThrowsError(try Screen.exclusive(path, data: Data("{}".utf8)))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), original)
    }

    func testArtifactWriterRetainsCompletedBytesAndRejectsDuplicateOrPartial() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("metadata.json").path
        let data = Data("{\"metadataOnly\":true}\n".utf8)
        let writer = try Screen.ArtifactWriter(path)
        XCTAssertThrowsError(try Screen.ArtifactWriter(path))
        try writer.write(data); try writer.seal()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".partial"))
        XCTAssertThrowsError(try Screen.ArtifactWriter(path))
    }

    func testPhysicalBindingDetectsChangedBytesAndMissingDirectPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("metadata.json").path
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: path))
        let digest = try Screen.shaFile(path)
        try Screen.requireBinding(path, sha: digest, files: [path: digest])
        XCTAssertThrowsError(try Screen.requireBinding(path, files: [:]))
        try Data("[]\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try Screen.requireBinding(path, sha: digest, files: [path: digest]))
    }

    func testGateCannotDecodeWithoutActualRuntimeAndBindingFields() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(Screen.Gate.self, from: Data("{\"status\":\"PASS\"}".utf8)))
    }

    func testMetadataBooleanCannotPretendToBeIntegerToolExit() throws {
        let object = try JSONSerialization.jsonObject(with: Data("{\"exit\":0,\"flag\":true,\"number\":1}".utf8)) as! [String: Any]
        XCTAssertEqual(Screen.metadataInteger(object["exit"]), 0)
        XCTAssertNil(Screen.metadataInteger(object["flag"]))
        XCTAssertEqual(Screen.metadataBoolean(object["flag"]), true)
        XCTAssertNil(Screen.metadataBoolean(object["number"]))
    }
}
