import XCTest

@testable import ImageThumbnailer

final class ImageReaderTests: XCTestCase {

    struct TestCase {
        let name: String
        let resource: String
        let ext: String
        let readerType: ImageReader.Type
        let expectedWidth: UInt32?
        let expectedHeight: UInt32?
        let minThumbnails: Int
        let maxReadCount: Int
        let maxBytes: UInt64

        init(
            _ name: String,
            resource: String,
            ext: String,
            reader: ImageReader.Type,
            width: UInt32? = nil,
            height: UInt32? = nil,
            minThumbnails: Int = 1,
            maxReadCount: Int = 15,
            maxBytes: UInt64 = 3 * 1024 * 1024
        ) {
            self.name = name
            self.resource = resource
            self.ext = ext
            self.readerType = reader
            self.expectedWidth = width
            self.expectedHeight = height
            self.minThumbnails = minThumbnails
            self.maxReadCount = maxReadCount
            self.maxBytes = maxBytes
        }
    }

    static let testCases: [TestCase] = [
        TestCase(
            "HEIF (iPhone)", resource: "iPhone", ext: "HEIC", reader: HeifReader.self,
            maxReadCount: 5, maxBytes: 100 * 1024),
        TestCase(
            "HEIF (Canon HIF)", resource: "Canon", ext: "hif", reader: HeifReader.self,
            width: 5472, height: 3648, minThumbnails: 2,
            maxReadCount: 5, maxBytes: 100 * 1024),
        TestCase(
            "JPEG", resource: "iPhone5", ext: "JPG", reader: JpegReader.self,
            maxReadCount: 3, maxBytes: 50 * 1024),
        TestCase(
            "ARW", resource: "DSC04618", ext: "ARW", reader: ArwReader.self,
            maxReadCount: 10, maxBytes: 1024 * 1024),
        TestCase(
            "DNG", resource: "IMG_5885", ext: "DNG", reader: DngReader.self,
            maxReadCount: 10, maxBytes: 10 * 1024 * 1024),
        TestCase(
            "NEF (Nikon Z5 II)", resource: "Nikon_Z5_2", ext: "NEF", reader: NefReader.self,
            width: 6064, height: 4040, minThumbnails: 2,
            maxReadCount: 15, maxBytes: 2 * 1024 * 1024),
        TestCase(
            "NEF (Nikon Z5)", resource: "Nikon_Z5", ext: "NEF", reader: NefReader.self,
            width: 6040, height: 4032, minThumbnails: 2,
            maxReadCount: 15, maxBytes: 3 * 1024 * 1024),
    ]

    func testImageReaders() async throws {
        var testedCount = 0
        for tc in Self.testCases {
            guard let url = Bundle.module.url(forResource: tc.resource, withExtension: tc.ext)
            else {
                print("SKIP \(tc.name): \(tc.resource).\(tc.ext) not found")
                continue
            }

            var readCount = 0
            var totalBytes: UInt64 = 0

            let readAt: (UInt64, UInt32) async throws -> Data = { offset, length in
                readCount += 1
                totalBytes += UInt64(length)
                let fh = try FileHandle(forReadingFrom: url)
                defer { fh.closeFile() }
                try fh.seek(toOffset: offset)
                return fh.readData(ofLength: Int(length))
            }

            let reader = tc.readerType.init(readAt: readAt)

            let metadata = try await reader.getMetadata()
            XCTAssertGreaterThan(metadata.width, 0, "\(tc.name): width should be > 0")
            XCTAssertGreaterThan(metadata.height, 0, "\(tc.name): height should be > 0")
            if let w = tc.expectedWidth {
                XCTAssertEqual(metadata.width, w, "\(tc.name): unexpected width")
            }
            if let h = tc.expectedHeight {
                XCTAssertEqual(metadata.height, h, "\(tc.name): unexpected height")
            }

            let thumbnails = try await reader.getThumbnailList()
            XCTAssertGreaterThanOrEqual(
                thumbnails.count, tc.minThumbnails,
                "\(tc.name): expected >= \(tc.minThumbnails) thumbnails")

            let data = try await reader.getThumbnail(at: 0)
            XCTAssertFalse(data.isEmpty, "\(tc.name): thumbnail data should not be empty")

            XCTAssertLessThanOrEqual(
                readCount, tc.maxReadCount,
                "\(tc.name): too many reads (\(readCount))")
            XCTAssertLessThanOrEqual(
                totalBytes, tc.maxBytes,
                "\(tc.name): too many bytes (\(totalBytes))")

            print(
                "\(tc.name) - reads: \(readCount), bytes: \(totalBytes), thumbnails: \(thumbnails.count)"
            )
            testedCount += 1
        }
        XCTAssertGreaterThan(testedCount, 0, "No test files found at all")
    }

    func testMp4Reader() async throws {
        guard let url = Bundle.module.url(forResource: "Pocket3", withExtension: "MP4") else {
            throw XCTSkip("Pocket3.MP4 not found")
        }
        let reader = Mp4Reader(readAt: Self.fileReadAt(url))

        let metadata = try await reader.getMetadata()
        XCTAssertGreaterThan(metadata.width, 0)
        XCTAssertGreaterThan(metadata.height, 0)
        if let d = metadata.duration { XCTAssertTrue(d > 3.5 && d < 4.0) }

        let thumbnails = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnails.isEmpty)
        let data = try await reader.getThumbnail(at: 0)
        XCTAssertFalse(data.isEmpty)
    }

    func testMp4ReaderH264() async throws {
        guard let url = Bundle.module.url(forResource: "IMG_0772", withExtension: "MOV") else {
            throw XCTSkip("IMG_0772.MOV not found")
        }
        let reader = Mp4Reader(readAt: Self.fileReadAt(url))

        let metadata = try await reader.getMetadata()
        XCTAssertEqual(metadata.width, 1920)
        XCTAssertEqual(metadata.height, 1080)
        if let d = metadata.duration { XCTAssertTrue(d > 3.2 && d < 3.3) }

        let thumbnails = try await reader.getThumbnailList()
        XCTAssertFalse(thumbnails.isEmpty)
        XCTAssertEqual(thumbnails[0].format, "heic")
        XCTAssertEqual(thumbnails[0].width, 1920)
        XCTAssertEqual(thumbnails[0].height, 1080)

        let data = try await reader.getThumbnail(at: 0)
        XCTAssertGreaterThan(data.count, 100 * 1024)
    }

    func testCr3Reader() async throws {
        guard
            let url = Bundle.module.url(
                forResource: "Canon_EOS_R5", withExtension: "CR3",
                subdirectory: "Resources/samples")
        else {
            throw XCTSkip("Canon_EOS_R5.CR3 not found")
        }
        let reader = Cr3Reader(readAt: Self.fileReadAt(url))

        let metadata = try await reader.getMetadata()
        XCTAssertEqual(metadata.width, 8192)
        XCTAssertEqual(metadata.height, 5464)

        let thumbnails = try await reader.getThumbnailList()
        XCTAssertGreaterThanOrEqual(thumbnails.count, 2)

        for (i, thumb) in thumbnails.enumerated() {
            XCTAssertEqual(thumb.format, "jpeg")
            let data = try await reader.getThumbnail(at: i)
            XCTAssertFalse(data.isEmpty)
            // Verify JPEG header
            XCTAssertEqual(data[0], 0xFF)
            XCTAssertEqual(data[1], 0xD8)
        }

        print(
            "CR3 - thumbnails: \(thumbnails.count), sizes: \(thumbnails.map { "\($0.width ?? 0)x\($0.height ?? 0)" }.joined(separator: ", "))"
        )
    }

    func testInvalidIndex() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "iPhone", withExtension: "HEIC"))
        let reader = HeifReader(readAt: Self.fileReadAt(url))

        do {
            _ = try await reader.getThumbnail(at: 999)
            XCTFail("Should throw error for invalid index")
        } catch ImageReaderError.indexOutOfBounds {
            // Expected
        }
    }

    private static func fileReadAt(_ url: URL) -> (UInt64, UInt32) async throws -> Data {
        return { offset, length in
            let fh = try FileHandle(forReadingFrom: url)
            defer { fh.closeFile() }
            try fh.seek(toOffset: offset)
            return fh.readData(ofLength: Int(length))
        }
    }
}
