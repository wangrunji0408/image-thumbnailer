import ImageIO
@testable import ImageThumbnailer
import XCTest

final class Mp4ThumbnailTests: XCTestCase {
    private func fixture(_ name: String, ext: String = "mp4") throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"))
        return try Data(contentsOf: url)
    }

    private func reader(_ data: Data) -> Mp4Reader {
        Mp4Reader { offset, length in
            guard offset < data.count else { return Data() }
            return data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + Int(length)))
        }
    }

    /// Decode with the API used by clients and inspect pixels, since a successful
    /// ImageIO decode alone also accepts the old, all-black AVC-in-HEIF output.
    private func pixels(_ data: Data, format: String) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, format)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 64)
        var bytes = [UInt8](repeating: 0, count: 96 * 64 * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 96 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        return bytes
    }

    private func assertColors(_ data: Data, format: String = "public.avci") throws {
        let bytes = try pixels(data, format: format)
        // Allow YUV matrix / color-management differences across Apple decoders.
        let left = (32 * 96 + 24) * 4
        let right = (32 * 96 + 72) * 4
        XCTAssertGreaterThan(bytes[left], 200, "Left half should be red")
        XCTAssertLessThan(bytes[left + 1], 60)
        XCTAssertLessThan(bytes[left + 2], 60)
        XCTAssertLessThan(bytes[right], 60)
        XCTAssertLessThan(bytes[right + 1], 60)
        XCTAssertGreaterThan(bytes[right + 2], 200, "Right half should be blue")
    }

    func testAVCProducesVisibleHEIFWithUnchangedSampleAndRangeReads() async throws {
        var data = try fixture("AVC_Color")
        // Unrelated trailing payload must not be fetched to decode the first sample.
        data.append(contentsOf: [0, 16, 0, 8, 102, 114, 101, 101]) // 1 MiB free box
        data.append(Data(repeating: 0, count: 1024 * 1024))
        var bytesRead = 0
        let reader = Mp4Reader { offset, length in
            guard offset < data.count else { return Data() }
            let chunk = data.subdata(in: Int(offset) ..< min(data.count, Int(offset) + Int(length)))
            bytesRead += chunk.count
            return chunk
        }
        let thumbnails = try await reader.getThumbnailList()
        let info = try XCTUnwrap(thumbnails.first)
        XCTAssertEqual(thumbnails.count, 1)
        XCTAssertEqual(info.format, "heif")
        XCTAssertEqual(info.width, 96)
        XCTAssertEqual(info.height, 64)
        let output = try await reader.getThumbnail(at: 0)
        try assertColors(output)
        XCTAssertEqual(String(decoding: output[8 ..< 12], as: UTF8.self), "avci")
        XCTAssertEqual(String(decoding: output[16 ..< 24], as: UTF8.self), "mif1avci")
        let sampleStart = try XCTUnwrap(data.range(of: Data("mdat".utf8))).upperBound
        let outputStart = try XCTUnwrap(output.range(of: Data("mdat".utf8))).upperBound
        XCTAssertEqual(output[outputStart...], data[sampleStart ..< sampleStart + Int(info.size)],
                       "The compressed video sample must remain byte-for-byte unchanged")
        XCTAssertEqual(try boxPayload("avcC", in: output), try boxPayload("avcC", in: data))
        XCTAssertLessThan(bytesRead, 64 * 1024)
    }

    func testAVC1AndAVC3PreserveRotationInContainer() async throws {
        let original = try fixture("AVC_Color")
        for codec in ["avc1", "avc3"] {
            for (degrees, a, b, c, d) in [
                (0, 1, 0, 0, 1), (90, 0, 1, -1, 0),
                (180, -1, 0, 0, -1), (270, 0, -1, 1, 0),
            ] {
                var data = original
                let codecRange = try XCTUnwrap(data.range(of: Data("avc1".utf8)))
                data.replaceSubrange(codecRange, with: Data(codec.utf8))
                let tkhd = try XCTUnwrap(data.range(of: Data("tkhd".utf8)))
                let matrix = tkhd.upperBound + 40 // version 0 tkhd payload
                let values: [Int32] = [Int32(a * 65536), Int32(b * 65536), 0,
                                       Int32(c * 65536), Int32(d * 65536), 0, 0, 0, 1 << 30]
                for (index, value) in values.enumerated() {
                    data.replaceSubrange(matrix + index * 4 ..< matrix + index * 4 + 4,
                                         with: withUnsafeBytes(of: value.bigEndian) { Data($0) })
                }
                let reader = reader(data)
                let thumbnails = try await reader.getThumbnailList()
                XCTAssertNil(thumbnails.first?.rotation, "HEIF carries rotation internally")
                let output = try await reader.getThumbnail(at: 0)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 96,
                ] as CFDictionary))
                XCTAssertEqual(image.width, degrees % 180 == 0 ? 96 : 64)
                XCTAssertEqual(image.height, degrees % 180 == 0 ? 64 : 96)
                if degrees == 0 {
                    try assertColors(output)
                } else {
                    XCTAssertEqual(try boxPayload("irot", in: output), Data([UInt8((360 - degrees) / 90)]))
                }
            }
        }
    }

    func testLegitimateBlackAVCFrameIsStillReturned() async throws {
        let reader = try reader(fixture("AVC_Black"))
        let bytes = try pixels(await reader.getThumbnail(at: 0), format: "public.avci")
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            XCTAssertLessThan(bytes[offset], 5)
            XCTAssertLessThan(bytes[offset + 1], 5)
            XCTAssertLessThan(bytes[offset + 2], 5)
        }
    }

    func testHEVCAndMJPEGStillDecodeCorrectly() async throws {
        for (name, ext, format, type) in [
            ("HEVC_Color", "mp4", "heic", "public.heic"),
            ("MJPEG_Color", "mov", "jpeg", "public.jpeg"),
        ] {
            let reader = try reader(fixture(name, ext: ext))
            let thumbnails = try await reader.getThumbnailList()
            XCTAssertEqual(thumbnails.first?.format, format)
            try assertColors(await reader.getThumbnail(at: 0), format: type)
        }
    }

    private func boxPayload(_ type: String, in data: Data) throws -> Data {
        let typeRange = try XCTUnwrap(data.range(of: Data(type.utf8)))
        let start = typeRange.lowerBound - 4
        let size = data[start ..< start + 4].reduce(0) { ($0 << 8) | Int($1) }
        return data.subdata(in: typeRange.upperBound ..< start + size)
    }
}
