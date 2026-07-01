import Foundation
import XCTest
@testable import Waterm

// Test Context:
// These tests protect the VoiceInput Whisper NPY header parser used before
// constructing MLX mel-filter arrays. The parser sits at a binary-data boundary:
// malformed length fields must fail as invalid input instead of trapping on
// unsafe loads or out-of-range Data slices. Update these tests only if the app
// intentionally changes the supported NPY header formats.

final class WhisperNpyHeaderParserTests: XCTestCase {
    func testParsesVersionOneHeaderLengthWithoutUnsafeAlignmentAssumptions() throws {
        let header = "{'descr': '<f4', 'fortran_order': False, 'shape': (80, 201), }"
        let data = npyData(version: 1, header: header, payload: Data([0xAA, 0xBB]))

        // Given a valid little-endian v1 NPY header for the Whisper mel filters.
        let result = try WhisperNpyHeaderParser.parse(data)

        // Then parsing reports the shape and payload offset without depending
        // on pointer alignment inside the Data storage.
        XCTAssertEqual(result.shape, [80, 201])
        XCTAssertEqual(result.dataOffset, data.count - 2)
    }

    func testParsesVersionTwoHeaderLengthWithoutUnsafeAlignmentAssumptions() throws {
        let header = "{'descr': '<f4', 'fortran_order': False, 'shape': (1, 2, 3), }"
        let data = npyData(version: 2, header: header, payload: Data([0xCC]))

        // Given a valid little-endian v2 NPY header with a four-byte length.
        let result = try WhisperNpyHeaderParser.parse(data)

        // Then parsing uses the byte-level length field and preserves all
        // dimensions from the tuple-shaped header.
        XCTAssertEqual(result.shape, [1, 2, 3])
        XCTAssertEqual(result.dataOffset, data.count - 1)
    }

    func testRejectsTruncatedVersionTwoLengthFieldWithoutTrapping() {
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 0x02, 0x00])
        data.append(contentsOf: [0x10, 0x00])

        // Given a malformed v2 NPY header whose four-byte length field is cut short.
        XCTAssertThrowsError(try WhisperNpyHeaderParser.parse(data)) { error in
            // Then the binary boundary reports invalid input instead of
            // trapping while reading the length field.
            guard case WhisperNpyHeaderParser.ParseError.invalidNpy = error else {
                XCTFail("Expected invalidNpy for truncated NPY length, got \(error).")
                return
            }
        }
    }

    func testRejectsUnsupportedMajorVersion() {
        let data = npyData(version: 0, header: "{'descr': '<f4', 'shape': (80, 201), }", payload: Data())

        // Given an NPY header with a major version the parser does not support.
        XCTAssertThrowsError(try WhisperNpyHeaderParser.parse(data)) { error in
            // Then the binary boundary rejects the format explicitly instead
            // of accidentally treating every non-v1 header as v2-compatible.
            guard case WhisperNpyHeaderParser.ParseError.invalidNpy = error else {
                XCTFail("Expected invalidNpy for unsupported NPY version, got \(error).")
                return
            }
        }
    }

    private func npyData(version: UInt8, header: String, payload: Data) -> Data {
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, version, 0x00])
        let headerBytes = Array(header.utf8)
        if version == 1 {
            let length = UInt16(headerBytes.count)
            data.append(UInt8(length & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
        } else {
            let length = UInt32(headerBytes.count)
            data.append(UInt8(length & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            data.append(UInt8((length >> 16) & 0xFF))
            data.append(UInt8((length >> 24) & 0xFF))
        }
        data.append(contentsOf: headerBytes)
        data.append(payload)
        return data
    }
}
