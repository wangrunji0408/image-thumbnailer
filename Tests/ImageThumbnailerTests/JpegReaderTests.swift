import CoreGraphics
import Foundation
import ImageIO
@testable import ImageThumbnailer
import XCTest

final class JpegReaderTests: XCTestCase {
    private func jpeg(width: Int = 32, height: Int = 24) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func littleEndian(_ value: UInt32, bytes: Int = 4) -> Data {
        Data((0 ..< bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func segment(_ marker: UInt8, _ payload: Data) -> Data {
        let size = payload.count + 2
        return Data([0xFF, marker, UInt8(size >> 8), UInt8(size & 255)]) + payload
    }

    private func exif(thumbnail: Data) -> Data {
        // IFD0: orientation=6. IFD1: JPEG thumbnail at TIFF offset 56.
        var tiff = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        tiff += littleEndian(1, bytes: 2)
        tiff += Data([0x12, 0x01, 3, 0]) + littleEndian(1) + littleEndian(6)
        tiff += littleEndian(26)
        tiff += littleEndian(2, bytes: 2)
        tiff += Data([0x01, 0x02, 4, 0]) + littleEndian(1) + littleEndian(56)
        tiff += Data([0x02, 0x02, 4, 0]) + littleEndian(1) + littleEndian(UInt32(thumbnail.count))
        tiff += littleEndian(0)
        return segment(0xE1, Data("Exif\0\0".utf8) + tiff + thumbnail)
    }

    private func mpf(offsets: [UInt32], size: UInt32) -> Data {
        var tiff = Data([0x49, 0x49, 42, 0, 8, 0, 0, 0])
        tiff += littleEndian(2, bytes: 2)
        tiff += Data([0x01, 0xB0, 4, 0]) + littleEndian(1) + littleEndian(UInt32(offsets.count))
        tiff += Data([0x02, 0xB0, 7, 0]) + littleEndian(UInt32(offsets.count * 16)) + littleEndian(38)
        tiff += littleEndian(0)
        for offset in offsets {
            tiff += littleEndian(0x010001) + littleEndian(size) + littleEndian(offset) + littleEndian(0)
        }
        return segment(0xE2, Data("MPF\0".utf8) + tiff)
    }

    private func reader(_ data: Data) -> JpegReader {
        JpegReader { offset, length in
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + Int(length)))
        }
    }

    private func assertDecodes(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
    }

    func testFillBytesBeforeExifAndFrameMarkers() async throws {
        let thumbnail = try jpeg(width: 16, height: 12)
        let main = try jpeg()
        // Padding before APP1 and every subsequent marker must not hide EXIF or SOF.
        var padded = Data()
        var offset = 2
        while offset + 4 <= main.count {
            padded += Data([0xFF, 0xFF])
            if main[offset + 1] == 0xDA {
                break
            }
            let length = Int(main[offset + 2]) * 256 + Int(main[offset + 3])
            padded += main.subdata(in: offset ..< (offset + 2 + length))
            offset += 2 + length
        }
        padded += main.dropFirst(offset)
        let data = Data([0xFF, 0xD8, 0xFF, 0xFF]) + exif(thumbnail: thumbnail) + padded
        try assertDecodes(data)
        let source = reader(data)
        let metadata = try await source.getMetadata()
        XCTAssertEqual(metadata.width, 32)
        XCTAssertEqual(metadata.height, 24)
        let thumbnails = try await source.getThumbnailList()
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(thumbnails.first?.rotation, 90)
        let extracted = try await source.getThumbnail(at: 0)
        XCTAssertEqual(extracted, thumbnail)
        try assertDecodes(extracted)
    }

    func testOutOfBoundsMPFDoesNotDiscardExifThumbnail() async throws {
        let thumbnail = try jpeg(width: 16, height: 12)
        let data = try Data([0xFF, 0xD8]) + exif(thumbnail: thumbnail)
            + mpf(offsets: [1_000_000], size: UInt32(thumbnail.count)) + jpeg().dropFirst(2)
        let source = reader(data)
        let metadata = try await source.getMetadata()
        XCTAssertEqual(metadata.width, 32)
        let thumbnails = try await source.getThumbnailList()
        XCTAssertEqual(thumbnails.count, 1)
        let extracted = try await source.getThumbnail(at: 0)
        XCTAssertEqual(extracted, thumbnail)
        try assertDecodes(extracted)
    }

    func testInvalidMPFEntryDoesNotDiscardFollowingValidPreview() async throws {
        let thumbnail = try jpeg(width: 16, height: 12)
        let main = try jpeg()
        let placeholder = mpf(offsets: [UInt32.max, 1_000_000, 1], size: UInt32(thumbnail.count))
        // Add marker padding before APP2; both the TIFF and preview move by two bytes.
        let offset = UInt32(main.count + placeholder.count - 10)
        let data = Data([0xFF, 0xD8, 0xFF, 0xFF]) + mpf(offsets: [UInt32.max, 1_000_000, offset], size: UInt32(thumbnail.count))
            + main.dropFirst(2) + thumbnail
        let source = reader(data)
        let thumbnails = try await source.getThumbnailList()
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(thumbnails.first?.width, 16)
        let extracted = try await source.getThumbnail(at: 0)
        XCTAssertEqual(extracted, thumbnail)
        try assertDecodes(extracted)
    }

    func testNonJpegStillFails() async throws {
        do {
            _ = try await reader(Data(repeating: 0x42, count: 128)).getMetadata()
            XCTFail("Non-JPEG data must not be accepted")
        } catch ImageReaderError.invalidData {
            // Expected.
        }
    }
}
