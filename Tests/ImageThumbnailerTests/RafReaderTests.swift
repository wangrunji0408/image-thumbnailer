import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import ImageThumbnailer

final class RafReaderTests: XCTestCase {
    private func jpeg(width: Int, height: Int, properties: [CFString: Any] = [:]) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func put(_ value: UInt32, into data: inout Data, at offset: Int, bytes: Int = 4, little: Bool = false) {
        for i in 0..<bytes {
            let shift = (little ? i : bytes - i - 1) * 8
            data[offset + i] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    private func preview(orientation: UInt32 = 1, little: Bool = false, thumbnail: Bool = true) throws -> Data {
        let small = thumbnail ? try jpeg(width: 16, height: 12) : Data()
        // IFD0 contains orientation; IFD1 contains JPEG offset and length.
        var tiff = Data(repeating: 0, count: thumbnail ? 56 : 26)
        tiff[0] = little ? 0x49 : 0x4D
        tiff[1] = tiff[0]
        put(42, into: &tiff, at: 2, bytes: 2, little: little)
        put(8, into: &tiff, at: 4, little: little)
        put(1, into: &tiff, at: 8, bytes: 2, little: little)
        put(0x112, into: &tiff, at: 10, bytes: 2, little: little)
        put(3, into: &tiff, at: 12, bytes: 2, little: little)
        put(1, into: &tiff, at: 14, little: little)
        put(orientation, into: &tiff, at: 18, bytes: 2, little: little)
        if thumbnail {
            put(26, into: &tiff, at: 22, little: little)
            put(2, into: &tiff, at: 26, bytes: 2, little: little)
            for (i, tag) in [UInt32(0x201), 0x202].enumerated() {
                let offset = 28 + i * 12
                put(tag, into: &tiff, at: offset, bytes: 2, little: little)
                put(4, into: &tiff, at: offset + 2, bytes: 2, little: little)
                put(1, into: &tiff, at: offset + 4, little: little)
                put(i == 0 ? 56 : UInt32(small.count), into: &tiff, at: offset + 8, little: little)
            }
            tiff.append(small)
        }
        var app1 = Data([0xFF, 0xE1, 0, 0])
        put(UInt32(tiff.count + 8), into: &app1, at: 2, bytes: 2)
        app1.append(Data("Exif\0\0".utf8))
        app1.append(tiff)
        let main = try jpeg(width: 64, height: 48)
        return Data(main.prefix(2)) + app1 + main.dropFirst(2)
    }

    private func raf(_ preview: Data, directory: Bool = true) -> Data {
        var data = Data(repeating: 0, count: 256)
        data.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        put(256, into: &data, at: 84)
        put(UInt32(preview.count), into: &data, at: 88)
        if directory {
            put(128, into: &data, at: 92)
            put(20, into: &data, at: 96)
            put(2, into: &data, at: 128)
            for (i, tag) in [UInt32(0x111), 0x100].enumerated() {
                let offset = 132 + i * 8
                put(tag, into: &data, at: offset, bytes: 2)
                put(4, into: &data, at: offset + 2, bytes: 2)
                put(i == 0 ? 4000 : 4032, into: &data, at: offset + 4, bytes: 2)
                put(i == 0 ? 6000 : 6160, into: &data, at: offset + 6, bytes: 2)
            }
        }
        data.append(preview)
        return data
    }

    private func reader(_ data: Data) -> RafReader {
        RafReader { offset, length in
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))
        }
    }

    func testThumbnailsCropOrientationAndByteOrder() async throws {
        for little in [false, true] {
            let preview = try preview(orientation: 6, little: little)
            let reader = reader(raf(preview))
            let thumbnails = try await reader.getThumbnailList()
            XCTAssertEqual(thumbnails.count, 2)
            XCTAssertEqual(thumbnails.map(\.width), [16, 64])
            XCTAssertEqual(thumbnails.map(\.height), [12, 48])
            XCTAssertEqual(thumbnails.map(\.rotation), [90, 90])
            let metadata = try await reader.getMetadata()
            XCTAssertEqual(metadata.width, 6000)
            XCTAssertEqual(metadata.height, 4000)
            for index in thumbnails.indices {
                let data = try await reader.getThumbnail(at: index)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
                if index == 1 { XCTAssertEqual(data, preview) }
            }
        }
    }

    func testPreviewWithoutSmallThumbnailOrRawDirectory() async throws {
        let preview = try preview(orientation: 8, thumbnail: false)
        let reader = reader(raf(preview, directory: false))
        let thumbnails = try await reader.getThumbnailList()
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(thumbnails[0].rotation, 270)
        let metadata = try await reader.getMetadata()
        XCTAssertEqual(metadata.width, 64)
        XCTAssertEqual(metadata.height, 48)
        let data = try await reader.getThumbnail(at: 0)
        XCTAssertEqual(data, preview)
    }

    func testGPSFromEmbeddedJPEG() async throws {
        let preview = try jpeg(width: 64, height: 48, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 31.25, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E",
                kCGImagePropertyGPSAltitude: 10,
            ],
        ])
        let metadata = try await reader(raf(preview)).getMetadata()
        let location = try XCTUnwrap(metadata.location)
        XCTAssertEqual(location.latitude, 31.25, accuracy: 0.0001)
        XCTAssertEqual(location.longitude, 121.5, accuracy: 0.0001)
    }

    func testInvalidIndices() async throws {
        let reader = reader(raf(try preview()))
        for index in [-1, 2, Int.max] {
            do {
                _ = try await reader.getThumbnail(at: index)
                XCTFail("Accepted invalid index \(index)")
            } catch ImageReaderError.indexOutOfBounds {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testMalformedContainers() async throws {
        let valid = raf(try preview())
        var cases = [Data(valid.prefix(10)), Data(valid.prefix(100)), Data(valid.prefix(260))]
        for (offset, value) in [(0, UInt32(0)), (84, 4), (84, UInt32.max), (88, 2),
                                (92, 4), (96, 3), (128, UInt32.max)] {
            var data = valid
            put(value, into: &data, at: offset)
            cases.append(data)
        }
        var badTagLength = valid
        put(65535, into: &badTagLength, at: 134, bytes: 2)
        cases.append(badTagLength)
        // Nested JPEG must not read SOF/EXIF bytes beyond the declared preview.
        var shortPreview = valid
        put(4, into: &shortPreview, at: 88)
        cases.append(shortPreview)
        for data in cases {
            do {
                _ = try await reader(data).getMetadata()
                XCTFail("Accepted malformed RAF")
            } catch {}
        }
    }

    func testPublicCameraSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["RAF_SAMPLE_DIR"] else {
            throw XCTSkip("Run Tests/download_raf_samples.py, then set RAF_SAMPLE_DIR to its output directory")
        }
        // CC0 raw.pixls.us samples; see Tests/raf-samples.json for sources and checksums.
        let samples: [(Int, UInt32, UInt32, UInt32, UInt32)] = [
            (864, 6000, 4000, 1920, 1280), (865, 6000, 4000, 1920, 1280),
            (6122, 7728, 5152, 4416, 2944), (6123, 7728, 5152, 4416, 2944),
            (6124, 7728, 5152, 4416, 2944), (7271, 6000, 4000, 4416, 2944),
            (3773, 11648, 8736, 4000, 3000), (2634, 1440, 960, 1440, 960),
        ]
        for (id, width, height, previewWidth, previewHeight) in samples {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(id).RAF")
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var readCount = 0
            var readBytes = 0
            let reader = RafReader { offset, length in
                try file.seek(toOffset: offset)
                let data = file.readData(ofLength: Int(length))
                readCount += 1
                readBytes += data.count
                return data
            }
            let metadata = try await reader.getMetadata()
            XCTAssertEqual(metadata.width, width, "sample \(id)")
            XCTAssertEqual(metadata.height, height, "sample \(id)")
            let thumbnails = try await reader.getThumbnailList()
            XCTAssertEqual(thumbnails.count, 2)
            XCTAssertEqual(thumbnails.last?.width, previewWidth)
            XCTAssertEqual(thumbnails.last?.height, previewHeight)
            XCTAssertLessThan(readBytes, 64 * 1024, "Metadata should not download the preview or sensor data")
            for index in thumbnails.indices {
                let data = try await reader.getThumbnail(at: index)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, Int(thumbnails[index].width!))
                XCTAssertEqual(image.height, Int(thumbnails[index].height!))
            }
            XCTAssertLessThan(readCount, 12)
            XCTAssertLessThan(readBytes, Int(thumbnails.last!.size) + 100 * 1024)
            let countBefore = readCount
            _ = try await reader.getMetadata()
            _ = try await reader.getThumbnailList()
            XCTAssertEqual(readCount, countBefore, "Metadata should be cached")
            print("RAF \(id): \(width)x\(height), \(readCount) reads, \(readBytes) bytes for both JPEGs")
        }
    }
}
