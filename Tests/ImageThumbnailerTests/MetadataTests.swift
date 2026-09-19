import Foundation
import XCTest

@testable import ImageThumbnailer

final class MetadataTests: XCTestCase {
    private func readerType(for ext: String) throws -> ImageReader.Type {
        switch ext.lowercased() {
        case "jpg", "jpeg": return JpegReader.self
        case "heic", "hif", "heif": return HeifReader.self
        case "arw": return ArwReader.self
        case "cr3": return Cr3Reader.self
        case "dng": return DngReader.self
        case "nef": return NefReader.self
        case "orf": return OrfReader.self
        case "pef": return PefReader.self
        case "raf": return RafReader.self
        case "rw2": return Rw2Reader.self
        case "mov", "mp4": return Mp4Reader.self
        default: throw ImageReaderError.unsupportedFormat
        }
    }

    func testEveryResourceAgainstExifTool() async throws {
        let manifest = try XCTUnwrap(
            Bundle.module.url(forResource: "ResourceManifest", withExtension: "json"))
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 35)
        let requireAll = ProcessInfo.processInfo.environment["REQUIRE_ALL_RESOURCES"] == "1"
        var tested = 0
        for row in rows {
            let name = try XCTUnwrap(row["file"] as? String)
            let expected = try XCTUnwrap(row["standard"] as? [String: Any])
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: nil, subdirectory: "Resources")
            else {
                if requireAll {
                    XCTFail("Missing required resource: \(name)")
                } else {
                    print("Local resource not installed: \(name)")
                }
                continue
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var bytes = 0
            var reads = 0
            let type = try readerType(for: url.pathExtension)
            let reader = type.init { offset, length in
                try file.seek(toOffset: offset)
                let data = file.readData(ofLength: Int(length))
                bytes += data.count
                reads += 1
                return data
            }
            let metadata: Metadata
            do { metadata = try await reader.getMetadata() } catch {
                XCTFail("\(name): \(error)")
                continue
            }
            XCTAssertGreaterThan(metadata.width, 0, name)
            XCTAssertGreaterThan(metadata.height, 0, name)
            XCTAssertLessThan(
                bytes, 512 * 1024, "\(name): metadata should not download media payloads")
            let before = reads
            _ = try await reader.getMetadata()
            XCTAssertEqual(reads, before, "\(name): metadata must be cached")

            let camera =
                try JSONSerialization.jsonObject(
                    with: JSONEncoder().encode(metadata.camera), options: .fragmentsAllowed)
                as? [String: Any] ?? [:]
            let tags = [
                "Make": "make", "Model": "model", "LensMake": "lensMake", "LensModel": "lensModel",
                "Orientation": "orientation", "Software": "software", "Artist": "artist",
                "Copyright": "copyright",
                "ExposureTime": "exposureTime", "FNumber": "fNumber", "ISO": "iso",
                "ExposureCompensation": "exposureCompensation", "FocalLength": "focalLength",
                "FocalLengthIn35mmFormat": "focalLengthIn35mm",
                "ExposureProgram": "exposureProgram",
                "MeteringMode": "meteringMode", "Flash": "flash", "WhiteBalance": "whiteBalance",
            ]
            for (tag, field) in tags {
                let baseline =
                    expected["ExifIFD:" + tag] ?? expected["IFD0:" + tag]
                    ?? expected["Keys:" + tag] ?? expected["VideoKeys:" + tag]
                guard let baseline else { continue }
                if ["make", "model", "lensMake", "lensModel", "software", "artist", "copyright"]
                    .contains(field)
                {
                    let text = String(describing: baseline).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    XCTAssertEqual(
                        camera[field] as? String, text.isEmpty ? nil : text, "\(name): \(tag)")
                    continue
                }
                // ExifTool spells zero-denominator rationals "undef"; readers represent these as nil.
                if let text = baseline as? String, text == "undef" {
                    XCTAssertNil(camera[field], "\(name): \(tag)")
                } else if let number = baseline as? NSNumber {
                    let actual = try XCTUnwrap(
                        camera[field] as? NSNumber, "\(name): missing \(tag)")
                    XCTAssertEqual(
                        actual.doubleValue, number.doubleValue,
                        accuracy: max(1e-7, abs(number.doubleValue) * 1e-7), "\(name): \(tag)")
                } else if let text = baseline as? String {
                    XCTAssertEqual(
                        camera[field] as? String,
                        text.trimmingCharacters(in: .whitespacesAndNewlines), "\(name): \(tag)")
                }
            }
            if let original = expected["ExifIFD:DateTimeOriginal"] as? String {
                XCTAssertEqual(metadata.captureTime?.value, original, name)
                if let offset = expected["ExifIFD:OffsetTimeOriginal"] as? String {
                    XCTAssertEqual(metadata.captureTime?.utcOffset, offset, name)
                    XCTAssertNotNil(metadata.captureTime?.date, name)
                }
                if let subsecond = expected["ExifIFD:SubSecTimeOriginal"] {
                    XCTAssertEqual(
                        metadata.captureTime?.subseconds, String(describing: subsecond), name)
                }
            } else if let creation = expected["Keys:CreationDate"] as? String {
                let time = try XCTUnwrap(metadata.captureTime, name)
                XCTAssertEqual(time.value, String(creation.prefix(19)), name)
                XCTAssertEqual(time.utcOffset, String(creation.suffix(6)), name)
                XCTAssertNotNil(time.date, name)
            }
            if ["MOV", "MP4"].contains(url.pathExtension),
                let creation = expected["QuickTime:CreateDate"] as? String
            {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                XCTAssertEqual(metadata.creationTime, formatter.date(from: creation), name)
                XCTAssertGreaterThan(metadata.duration ?? 0, 0, name)
            }
            if let lat = expected["GPS:GPSLatitude"] as? NSNumber,
                let lon = expected["GPS:GPSLongitude"] as? NSNumber
            {
                let location = try XCTUnwrap(metadata.location, name)
                XCTAssertEqual(
                    Double(location.latitude),
                    lat.doubleValue * ((expected["GPS:GPSLatitudeRef"] as? String) == "S" ? -1 : 1),
                    accuracy: 0.00002, name)
                XCTAssertEqual(
                    Double(location.longitude),
                    lon.doubleValue
                        * ((expected["GPS:GPSLongitudeRef"] as? String) == "W" ? -1 : 1),
                    accuracy: 0.00002, name)
            }
            print("Metadata \(name): \(reads) reads / \(bytes) bytes")
            tested += 1
        }
        XCTAssertGreaterThan(tested, 0)
        if requireAll {
            XCTAssertEqual(tested, rows.count, "Full resource validation must not skip files")
        }
    }

    func testCaptureTimePreservesUnknownZoneAndSubseconds() throws {
        let unknown = CaptureTime(value: "2025:01:02 03:04:05", subseconds: "007")
        XCTAssertNil(unknown.date)
        let zoned = CaptureTime(
            value: unknown.value, subseconds: unknown.subseconds, utcOffset: "+08:00")
        let formatter = ISO8601DateFormatter()
        let expected = try XCTUnwrap(formatter.date(from: "2025-01-01T19:04:05Z"))
        XCTAssertEqual(
            try XCTUnwrap(zoned.date).timeIntervalSince(expected), 0.007, accuracy: 0.000001)
        XCTAssertNil(CaptureTime(value: "not a date", utcOffset: "Z").date)
        XCTAssertNil(CaptureTime(value: unknown.value, utcOffset: "nonsense").date)
    }

    func testQuickTimeVersionOneCreationAndDuration() async throws {
        func put(_ value: UInt64, into data: inout Data, at offset: Int, bytes: Int = 4) {
            for i in 0..<bytes {
                data[offset + i] = UInt8(truncatingIfNeeded: value >> ((bytes - i - 1) * 8))
            }
        }
        func box(_ type: String, _ payload: Data) -> Data {
            var header = Data(repeating: 0, count: 4)
            put(UInt64(payload.count + 8), into: &header, at: 0)
            return header + Data(type.utf8) + payload
        }
        for creation: UInt64 in [0, 8_000_000_000] {
            var mvhd = Data(repeating: 0, count: 32)
            mvhd[0] = 1
            put(creation, into: &mvhd, at: 4, bytes: 8)
            put(creation == 0 ? 0 : 1000, into: &mvhd, at: 20)
            put(3000, into: &mvhd, at: 24, bytes: 8)
            var tkhd = Data(repeating: 0, count: 84)
            put(640 << 16, into: &tkhd, at: 76)
            put(480 << 16, into: &tkhd, at: 80)
            var hdlr = Data(repeating: 0, count: 16)
            hdlr.replaceSubrange(8..<12, with: Data("vide".utf8))
            let track = box("trak", box("tkhd", tkhd) + box("mdia", box("hdlr", hdlr)))
            let data = box("ftyp", Data("isom0000".utf8)) + box("moov", box("mvhd", mvhd) + track)
            let reader = Mp4Reader { offset, length in
                guard offset < data.count else { return Data() }
                return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))
            }
            let metadata = try await reader.getMetadata()
            XCTAssertEqual(metadata.width, 640)
            if creation == 0 {
                XCTAssertNil(metadata.creationTime)
                XCTAssertNil(metadata.duration, "A zero timescale must not produce infinity")
            } else {
                XCTAssertEqual(
                    metadata.creationTime,
                    Date(timeIntervalSince1970: Double(creation) - 2_082_844_800))
                XCTAssertEqual(metadata.duration, 3)
            }
            XCTAssertNil(
                metadata.captureTime, "Container creation must not be labelled capture time")
        }
    }

    func testExifRejectsCyclesAndOutOfBoundsValues() async throws {
        // Little-endian TIFF with an EXIF pointer pointing back to IFD0.
        let cycle = Data([
            0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0,
            0x69, 0x87, 4, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0,
        ])
        var outside = cycle
        outside[10] = 0x0F
        outside[11] = 0x01  // Make, ASCII, length 8, invalid payload offset
        outside[12] = 2
        outside[14] = 8
        outside[18] = 200
        for data in [cycle, outside, Data(cycle.prefix(16))] {
            let source = Reader { offset, length in
                guard offset < data.count else { return Data() }
                return data.subdata(in: Int(offset)..<min(data.count, Int(offset) + Int(length)))
            }
            var parser = ExifParser(reader: source, offset: 0, length: UInt64(data.count))
            do {
                _ = try await parser.parse()
                XCTFail("Accepted malformed EXIF")
            } catch {}
        }
    }
}
