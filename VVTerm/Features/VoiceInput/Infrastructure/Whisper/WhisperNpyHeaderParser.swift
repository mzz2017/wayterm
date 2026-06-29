import Foundation

nonisolated enum WhisperNpyHeaderParser {
    enum ParseError: Swift.Error {
        case invalidNpy
    }

    struct Header: Equatable {
        let shape: [Int]
        let dataOffset: Int
    }

    nonisolated static func parse(_ data: Data) throws -> Header {
        guard data.count >= 10 else { throw ParseError.invalidNpy }
        let magic = data.prefix(6)
        guard magic == Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) else {
            throw ParseError.invalidNpy
        }

        let version = data[6]
        guard version == 1 || version == 2 || version == 3 else {
            throw ParseError.invalidNpy
        }
        let headerLengthOffset = 8
        let headerLengthSize = version == 1 ? 2 : 4
        guard data.count >= headerLengthOffset + headerLengthSize else {
            throw ParseError.invalidNpy
        }

        let headerLength: Int
        if version == 1 {
            headerLength = Int(littleEndianUInt16(in: data, at: headerLengthOffset))
        } else {
            headerLength = Int(littleEndianUInt32(in: data, at: headerLengthOffset))
        }

        let headerStart = headerLengthOffset + headerLengthSize
        let headerEnd = headerStart + headerLength
        guard headerEnd <= data.count else { throw ParseError.invalidNpy }
        let header = String(decoding: data[headerStart..<headerEnd], as: UTF8.self)

        guard header.contains("'descr': '<f4'") else { throw ParseError.invalidNpy }

        let shapeStart = header.range(of: "(")
        let shapeEnd = header.range(of: ")")
        guard let shapeStart, let shapeEnd else { throw ParseError.invalidNpy }
        let shapeString = header[shapeStart.upperBound..<shapeEnd.lowerBound]
        let dims = shapeString.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !dims.isEmpty else { throw ParseError.invalidNpy }

        return Header(shape: dims, dataOffset: headerEnd)
    }

    private nonisolated static func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) |
            (UInt16(data[offset + 1]) << 8)
    }

    private nonisolated static func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}
